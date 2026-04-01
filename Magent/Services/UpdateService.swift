import Cocoa
import MagentCore

private struct UpdateReleaseAsset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct UpdateReleaseResponse: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [UpdateReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case body
        case assets
    }
}

private struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? value
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.indices.contains(0) ? Int(parts[0]) : nil else { return nil }
        let minor = parts.indices.contains(1) ? Int(parts[1]) : 0
        let patch = parts.indices.contains(2) ? Int(parts[2]) : 0
        guard let minor, let patch else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    var displayString: String {
        "\(major).\(minor).\(patch)"
    }
}

private struct AvailableUpdate: Sendable {
    let version: SemanticVersion
    let releaseNotes: String?
    let assetURL: URL
    let assetKind: ReleaseAssetKind
}

struct PendingUpdateSummary: Sendable {
    let currentVersion: String
    let availableVersion: String
    let releaseNotes: String?
    let isSkipped: Bool
}

private enum UpdateAvailability: Sendable {
    case available(AvailableUpdate)
    case upToDate
    case noPublishedRelease
}

private enum ReleaseAssetKind: String, Sendable {
    case dmg
    case zip
}

private enum UpdateError: LocalizedError {
    case invalidHTTPStatus(Int)
    case invalidLatestVersion(String)
    case invalidCurrentVersion(String)
    case missingReleaseAsset
    case unwritableInstallLocation(String)
    case failedToStartUpdater(String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let status):
            return "Update server returned HTTP \(status)."
        case .invalidLatestVersion(let version):
            return "Latest release version is invalid: \(version)."
        case .invalidCurrentVersion(let version):
            return "Current app version is invalid: \(version)."
        case .missingReleaseAsset:
            return "Latest release is missing a Magent.dmg or Magent.zip asset."
        case .unwritableInstallLocation(let path):
            return "Install location is not writable: \(path)."
        case .failedToStartUpdater(let message):
            return "Could not start updater: \(message)"
        case .extractionFailed(let message):
            return "Failed to extract update: \(message)"
        }
    }
}

@MainActor
final class UpdateService {

    static let shared = UpdateService()

    private let persistence = PersistenceService.shared
    private let releasesURL = URL(string: "https://api.github.com/repos/vapor-pawelw/mAgent/releases?per_page=10")!
    private let updaterLogPath = "/tmp/magent-self-update.log"

    private var isChecking = false
    private var isUpdating = false
    private var detectedUpdate: AvailableUpdate?
    private var pollingTask: Task<Void, Never>?
    private var shownUpdateBannerForVersion: String?
    /// Holds the path to a downloaded+extracted app bundle ready for swap.
    private var preparedAppURL: URL?
    /// The version string of the prepared update (used to match against detectedUpdate).
    private var preparedVersion: String?

    private static let pollingInterval: TimeInterval = 3600 // 1 hour

    private enum InstallStrategy {
        case homebrewCask
        case bundleReplacement
    }

    private enum CheckTrigger {
        case launch
        case manual
        case periodic
    }

    func checkForUpdatesOnLaunchIfEnabled() async {
        let settings = persistence.loadSettings()
        guard settings.autoCheckForUpdates else { return }
        await checkForUpdates(trigger: .launch)
    }

    func checkForUpdatesManually() async {
        await checkForUpdates(trigger: .manual)
    }

    func startPeriodicUpdateChecks() {
        guard persistence.loadSettings().autoCheckForUpdates else { return }
        stopPeriodicUpdateChecks()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollingInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.checkForUpdates(trigger: .periodic)
            }
        }
    }

    func stopPeriodicUpdateChecks() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func handleAutoCheckSettingChanged() {
        if persistence.loadSettings().autoCheckForUpdates {
            startPeriodicUpdateChecks()
        } else {
            stopPeriodicUpdateChecks()
        }
    }

    var pendingUpdateSummary: PendingUpdateSummary? {
        guard let detectedUpdate else { return nil }
        let availableVersion = detectedUpdate.version.displayString
        return PendingUpdateSummary(
            currentVersion: currentVersionString(),
            availableVersion: availableVersion,
            releaseNotes: normalizedReleaseNotes(detectedUpdate.releaseNotes),
            isSkipped: isVersionSkipped(availableVersion)
        )
    }

    /// True when the update has been downloaded and extracted, ready for install,
    /// and the prepared version still matches the currently detected update.
    var isUpdateReadyToInstall: Bool {
        guard let preparedVersion, preparedAppURL != nil else { return false }
        return preparedVersion == detectedUpdate?.version.displayString
    }

    func installDetectedUpdateIfAvailable() async {
        guard let detectedUpdate else { return }
        await downloadUpdate(detectedUpdate)
    }

    /// Called when user clicks "Install and relaunch" after download is complete.
    func installPreparedUpdate() async {
        guard let preparedAppURL, let preparedVersion,
              let detectedUpdate,
              preparedVersion == detectedUpdate.version.displayString else { return }
        await performSwapAndRelaunch(update: detectedUpdate, preparedAppURL: preparedAppURL)
    }

    private func checkForUpdates(trigger: CheckTrigger) async {
        guard !isChecking else {
            if trigger == .manual {
                BannerManager.shared.show(message: String(localized: .UpdateStrings.updateCheckAlreadyInProgress), style: .info)
            }
            return
        }

        isChecking = true
        defer { isChecking = false }
        pruneSkippedVersionIfCurrentOrOlder()

        do {
            switch try await fetchUpdateAvailability() {
            case .noPublishedRelease:
                setDetectedUpdate(nil)
                if trigger == .manual {
                    BannerManager.shared.show(
                        message: String(localized: .UpdateStrings.updateNoNewReleases),
                        style: .info
                    )
                }
            case .upToDate:
                setDetectedUpdate(nil)
                if trigger == .manual {
                    BannerManager.shared.show(
                        message: String(localized: .UpdateStrings.updateUpToDate(currentVersionString())),
                        style: .info
                    )
                }
            case .available(let available):
                setDetectedUpdate(available)
                let availableVersion = available.version.displayString
                guard !isVersionSkipped(availableVersion) else {
                    if trigger == .manual {
                        BannerManager.shared.show(
                            message: String(localized: .UpdateStrings.updateVersionSkipped(availableVersion)),
                            style: .info
                        )
                    }
                    return
                }
                if isUpdateReadyToInstall {
                    showReadyToInstallBanner(version: availableVersion)
                } else {
                    if trigger == .periodic {
                        // Only show banner if we haven't already shown one for this version
                        guard shownUpdateBannerForVersion != availableVersion else { return }
                    }
                    showAvailableUpdateBanner(available)
                }
            }
        } catch {
            if trigger == .manual {
                BannerManager.shared.show(
                    message: error.localizedDescription,
                    style: .warning,
                    duration: 5
                )
            }
        }
    }

    private func showAvailableUpdateBanner(_ available: AvailableUpdate) {
        #if DEBUG
        return
        #endif
        let availableVersion = available.version.displayString
        shownUpdateBannerForVersion = availableVersion
        let currentVersion = currentVersionString()
        BannerManager.shared.show(
            message: String(localized: .UpdateStrings.updateAvailable(currentVersion, availableVersion)),
            style: .info,
            duration: nil,
            isDismissible: true,
            actions: [
                BannerAction(title: String(localized: .UpdateStrings.updateNow)) {
                    Task { @MainActor in
                        await UpdateService.shared.installDetectedUpdateIfAvailable()
                    }
                },
                BannerAction(title: String(localized: .UpdateStrings.updateSkipVersion)) {
                    Task { @MainActor in
                        UpdateService.shared.skipVersion(availableVersion)
                    }
                },
            ],
            details: normalizedReleaseNotes(available.releaseNotes),
            detailsCollapsedTitle: String(localized: .UpdateStrings.updateShowChanges),
            detailsExpandedTitle: String(localized: .UpdateStrings.updateHideChanges)
        )
    }

    private func skipVersion(_ version: String) {
        var settings = persistence.loadSettings()
        settings.skippedUpdateVersion = version
        try? persistence.saveSettings(settings)
        notifyUpdateStateChanged()
        BannerManager.shared.dismissCurrent()
    }

    private func setDetectedUpdate(_ update: AvailableUpdate?) {
        let previousVersion = detectedUpdate?.version.displayString
        let nextVersion = update?.version.displayString
        let previousNotes = detectedUpdate?.releaseNotes
        let nextNotes = update?.releaseNotes
        detectedUpdate = update

        // Invalidate prepared payload when the detected version changes.
        if previousVersion != nextVersion {
            invalidatePreparedUpdate()
        }

        guard previousVersion != nextVersion || previousNotes != nextNotes else { return }
        notifyUpdateStateChanged()
    }

    private func invalidatePreparedUpdate() {
        if let preparedAppURL {
            try? FileManager.default.removeItem(at: preparedAppURL.deletingLastPathComponent())
        }
        preparedAppURL = nil
        preparedVersion = nil
    }

    private func notifyUpdateStateChanged() {
        NotificationCenter.default.post(name: .magentUpdateStateChanged, object: nil)
    }

    private func isVersionSkipped(_ version: String) -> Bool {
        persistence.loadSettings().skippedUpdateVersion == version
    }

    private func pruneSkippedVersionIfCurrentOrOlder() {
        let currentVersionRaw = currentVersionString()
        guard let currentVersion = SemanticVersion(currentVersionRaw) else { return }

        var settings = persistence.loadSettings()
        guard let skippedVersionRaw = settings.skippedUpdateVersion,
              let skippedVersion = SemanticVersion(skippedVersionRaw),
              skippedVersion <= currentVersion else {
            return
        }

        settings.skippedUpdateVersion = nil
        try? persistence.saveSettings(settings)
        notifyUpdateStateChanged()
    }

    private func normalizedReleaseNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fetchUpdateAvailability() async throws -> UpdateAvailability {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Magent-Updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidHTTPStatus(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateError.invalidHTTPStatus(http.statusCode)
        }

        let releases = try JSONDecoder().decode([UpdateReleaseResponse].self, from: data)
        guard let latest = releases.first(where: { !$0.draft && !$0.prerelease }) else {
            return .noPublishedRelease
        }

        guard let latestVersion = SemanticVersion(latest.tagName) else {
            throw UpdateError.invalidLatestVersion(latest.tagName)
        }
        let currentVersionRaw = currentVersionString()
        guard let currentVersion = SemanticVersion(currentVersionRaw) else {
            throw UpdateError.invalidCurrentVersion(currentVersionRaw)
        }
        guard latestVersion > currentVersion else { return .upToDate }

        let preferredAsset: (asset: UpdateReleaseAsset, kind: ReleaseAssetKind)? =
            latest.assets.first(where: { $0.name == "Magent.dmg" }).map { ($0, .dmg) }
            ?? latest.assets.first(where: { $0.name == "Magent.zip" }).map { ($0, .zip) }
            ?? latest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }).map { ($0, .dmg) }
            ?? latest.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }).map { ($0, .zip) }
        guard let preferredAsset,
              let assetURL = URL(string: preferredAsset.asset.browserDownloadURL) else {
            throw UpdateError.missingReleaseAsset
        }

        return .available(
            AvailableUpdate(
                version: latestVersion,
                releaseNotes: latest.body,
                assetURL: assetURL,
                assetKind: preferredAsset.kind
            )
        )
    }

    // MARK: - Installation

    /// Phase 1: Download and extract the update, then show "Install and relaunch" button.
    private func downloadUpdate(_ update: AvailableUpdate) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            let appBundlePath = Bundle.main.bundlePath
            let strategy = await resolveInstallStrategy(appBundlePath: appBundlePath)

            switch strategy {
            case .homebrewCask:
                // Homebrew manages its own download; start it detached and close.
                let updaterScriptPath = "/tmp/magent-self-update-\(UUID().uuidString).sh"
                try writeHomebrewUpdaterScript(at: updaterScriptPath)
                let q = ShellExecutor.shellQuote
                let command = "/usr/bin/nohup /bin/zsh \(q(updaterScriptPath)) \(q(String(ProcessInfo.processInfo.processIdentifier))) \(q(updaterLogPath)) >/dev/null 2>&1 &"
                let result = await ShellExecutor.execute(command)
                guard result.exitCode == 0 else {
                    let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw UpdateError.failedToStartUpdater(msg.isEmpty ? "unknown error" : msg)
                }
                clearSkippedVersion(matching: update.version.displayString)
                showUpdateProgressBanner("Updating to \(update.version.displayString) via Homebrew. Magent will restart shortly...")
                try? await Task.sleep(nanoseconds: 900_000_000)
                NSApp.terminate(nil)

            case .bundleReplacement:
                let installDirectory = URL(fileURLWithPath: appBundlePath).deletingLastPathComponent().path
                guard FileManager.default.isWritableFile(atPath: installDirectory) else {
                    throw UpdateError.unwritableInstallLocation(installDirectory)
                }

                let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("magent-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // Phase 1: Download in-app so user sees progress.
                showUpdateProgressBanner(
                    String(localized: .UpdateStrings.updateDownloading(update.version.displayString)),
                    showsSpinner: true
                )
                let archiveURL = tempDir.appendingPathComponent("Magent.\(update.assetKind.rawValue)")
                try await downloadAsset(from: update.assetURL, to: archiveURL)

                // Phase 2: Unpack/prepare in-app.
                showUpdateProgressBanner(
                    String(localized: .UpdateStrings.updatePreparing),
                    showsSpinner: true
                )
                let extracted = try await extractApp(from: archiveURL, kind: update.assetKind, in: tempDir)

                // Phase 3: Store prepared app and show "Install and relaunch" banner.
                self.preparedAppURL = extracted
                self.preparedVersion = update.version.displayString
                showReadyToInstallBanner(version: update.version.displayString)
            }
        } catch {
            BannerManager.shared.show(
                message: error.localizedDescription,
                style: .error,
                duration: 6
            )
        }
    }

    /// Phase 2: Swap the prepared app bundle and relaunch.
    private func performSwapAndRelaunch(update: AvailableUpdate, preparedAppURL: URL) async {
        guard !isUpdating else { return }
        isUpdating = true
        // Clear prepared state immediately to prevent duplicate clicks.
        self.preparedAppURL = nil
        self.preparedVersion = nil

        do {
            let appBundlePath = Bundle.main.bundlePath
            let swapScriptPath = "/tmp/magent-self-update-\(UUID().uuidString).sh"
            try writeSwapScript(at: swapScriptPath)
            let q = ShellExecutor.shellQuote
            let command = "/usr/bin/nohup /bin/zsh \(q(swapScriptPath)) \(q(String(ProcessInfo.processInfo.processIdentifier))) \(q(preparedAppURL.path)) \(q(appBundlePath)) \(q(updaterLogPath)) >/dev/null 2>&1 &"
            let result = await ShellExecutor.execute(command)
            guard result.exitCode == 0 else {
                let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdateError.failedToStartUpdater(msg.isEmpty ? "unknown error" : msg)
            }

            clearSkippedVersion(matching: update.version.displayString)
            showUpdateProgressBanner(
                String(localized: .UpdateStrings.updateInstalling)
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            isUpdating = false
            BannerManager.shared.show(
                message: error.localizedDescription,
                style: .error,
                duration: 6
            )
        }
    }

    private func showReadyToInstallBanner(version: String) {
        BannerManager.shared.show(
            message: String(localized: .UpdateStrings.updateReadyToInstall(version)),
            style: .info,
            duration: nil,
            isDismissible: true,
            actions: [
                BannerAction(title: String(localized: .UpdateStrings.updateInstallAndRelaunch)) {
                    Task { @MainActor in
                        await UpdateService.shared.installPreparedUpdate()
                    }
                },
            ]
        )
        notifyUpdateStateChanged()
    }

    private func showUpdateProgressBanner(_ message: String, showsSpinner: Bool = false) {
        BannerManager.shared.show(
            message: message,
            style: .info,
            duration: nil,
            isDismissible: false,
            showsSpinner: showsSpinner
        )
    }

    // Downloads the release asset to a local file. Runs via URLSession's transfer
    // infrastructure (off the main thread); suspends this task until complete.
    private func downloadAsset(from url: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("Magent-Updater", forHTTPHeaderField: "User-Agent")
        let (tempURL, urlResponse) = try await URLSession.shared.download(for: request)
        guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw UpdateError.invalidHTTPStatus((urlResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    /// Clears launch-blocking extended attributes that can survive archive extraction
    /// and prevent Finder/LaunchServices from opening the updated app bundle.
    private func clearLaunchBlockingExtendedAttributes(at appURL: URL) async {
        let q = ShellExecutor.shellQuote
        for attribute in ["com.apple.quarantine", "com.apple.provenance"] {
            _ = await ShellExecutor.execute(
                "/usr/bin/xattr -dr \(q(attribute)) \(q(appURL.path)) >/dev/null 2>&1 || true"
            )
        }
    }

    // Mounts/unpacks the downloaded archive and returns the path to the extracted Magent.app.
    private func extractApp(from archiveURL: URL, kind: ReleaseAssetKind, in tempDir: URL) async throws -> URL {
        let q = ShellExecutor.shellQuote
        switch kind {
        case .dmg:
            let mountDir = tempDir.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

            let attachResult = await ShellExecutor.execute(
                "/usr/bin/hdiutil attach \(q(archiveURL.path)) -nobrowse -readonly -mountpoint \(q(mountDir.path)) -quiet"
            )
            guard attachResult.exitCode == 0 else {
                throw UpdateError.extractionFailed("Failed to mount DMG (exit \(attachResult.exitCode))")
            }

            let findResult = await ShellExecutor.execute(
                "/usr/bin/find \(q(mountDir.path)) -maxdepth 3 -type d -name 'Magent.app' | /usr/bin/head -1"
            )
            let mountedApp = findResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mountedApp.isEmpty else {
                await ShellExecutor.execute("/usr/bin/hdiutil detach \(q(mountDir.path)) -quiet 2>/dev/null || true")
                throw UpdateError.extractionFailed("Magent.app not found in DMG")
            }

            let destApp = tempDir.appendingPathComponent("Magent.app")
            let copyResult = await ShellExecutor.execute(
                "/usr/bin/ditto \(q(mountedApp)) \(q(destApp.path))"
            )
            await ShellExecutor.execute("/usr/bin/hdiutil detach \(q(mountDir.path)) -quiet 2>/dev/null || true")
            guard copyResult.exitCode == 0 else {
                throw UpdateError.extractionFailed("Failed to copy app from DMG (exit \(copyResult.exitCode))")
            }
            await clearLaunchBlockingExtendedAttributes(at: destApp)
            return destApp

        case .zip:
            let unpackDir = tempDir.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)

            let unpackResult = await ShellExecutor.execute(
                "/usr/bin/ditto -x -k \(q(archiveURL.path)) \(q(unpackDir.path))"
            )
            guard unpackResult.exitCode == 0 else {
                throw UpdateError.extractionFailed("Failed to unpack ZIP (exit \(unpackResult.exitCode))")
            }

            let findResult = await ShellExecutor.execute(
                "/usr/bin/find \(q(unpackDir.path)) -maxdepth 3 -type d -name 'Magent.app' | /usr/bin/head -1"
            )
            let appPath = findResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appPath.isEmpty else {
                throw UpdateError.extractionFailed("Magent.app not found in archive")
            }
            let appURL = URL(fileURLWithPath: appPath)
            await clearLaunchBlockingExtendedAttributes(at: appURL)
            return appURL
        }
    }

    // Writes a minimal swap script that only waits for this process to exit,
    // moves the pre-prepared app bundle into place, and relaunches.
    private func writeSwapScript(at path: String) throws {
        let script = """
        #!/bin/zsh
        set -euo pipefail

        pid="$1"
        new_app="$2"
        target_app="$3"
        log_path="$4"

        exec >>"$log_path" 2>&1
        echo "[magent-updater] swap started at $(date)"

        # Wait for Magent to exit before touching the bundle.
        while /bin/kill -0 "$pid" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if [[ ! -d "$new_app" ]]; then
          echo "[magent-updater] prepared app not found: $new_app"
          exit 22
        fi

        if [[ ! -d "$target_app" ]]; then
          echo "[magent-updater] target path not found: $target_app"
          exit 23
        fi

        backup_app="${target_app}.magent-backup"
        /bin/rm -rf "$backup_app"

        if ! /bin/mv "$target_app" "$backup_app"; then
          echo "[magent-updater] failed to move current app to backup"
          exit 30
        fi

        if ! /bin/mv "$new_app" "$target_app"; then
          echo "[magent-updater] failed to install new app, restoring backup"
          /bin/mv "$backup_app" "$target_app" || true
          exit 31
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
        /usr/bin/xattr -dr com.apple.provenance "$target_app" >/dev/null 2>&1 || true

        /bin/rm -rf "$backup_app"
        /usr/bin/open "$target_app"
        /bin/rm -f "$0"
        echo "[magent-updater] update completed"
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func resolveInstallStrategy(appBundlePath: String) async -> InstallStrategy {
        let normalizedBundlePath = URL(fileURLWithPath: appBundlePath).standardizedFileURL.path
        guard normalizedBundlePath == "/Applications/Magent.app" else {
            return .bundleReplacement
        }

        let result = await ShellExecutor.execute("""
        PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        command -v brew >/dev/null 2>&1 || exit 1
        brew list --cask magent >/dev/null 2>&1
        """)
        return result.exitCode == 0 ? .homebrewCask : .bundleReplacement
    }

    private func writeHomebrewUpdaterScript(at path: String) throws {
        let script = """
        #!/bin/zsh
        set -euo pipefail

        pid="$1"
        log_path="$2"
        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        exec >>"$log_path" 2>&1

        echo "[magent-updater] homebrew flow started at $(date)"

        while /bin/kill -0 "$pid" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if ! command -v brew >/dev/null 2>&1; then
          echo "[magent-updater] brew not found"
          exit 40
        fi

        if ! brew list --cask magent >/dev/null 2>&1; then
          echo "[magent-updater] magent cask is not installed"
          exit 41
        fi

        if ! brew upgrade --cask magent; then
          echo "[magent-updater] brew upgrade failed, trying reinstall"
          brew reinstall --cask magent
        fi

        if [[ -d "/Applications/Magent.app" ]]; then
          /usr/bin/xattr -dr com.apple.quarantine "/Applications/Magent.app" >/dev/null 2>&1 || true
          /usr/bin/xattr -dr com.apple.provenance "/Applications/Magent.app" >/dev/null 2>&1 || true
        fi

        /usr/bin/open -a Magent
        /bin/rm -f "$0"
        echo "[magent-updater] homebrew flow completed"
        """

        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func currentVersionString() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private func clearSkippedVersion(matching version: String) {
        var settings = persistence.loadSettings()
        guard settings.skippedUpdateVersion == version else { return }
        settings.skippedUpdateVersion = nil
        try? persistence.saveSettings(settings)
        notifyUpdateStateChanged()
    }
}
