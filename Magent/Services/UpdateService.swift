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
    private let preparedUpdateRootURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("magent-prepared-update", isDirectory: true)

    private var isChecking = false
    private var isUpdating = false
    private var detectedUpdate: AvailableUpdate?
    private var pollingTask: Task<Void, Never>?
    private var shownUpdateBannerForVersion: String?
    /// Holds the path to a downloaded+extracted app bundle ready for swap.
    private var preparedAppURL: URL?
    /// The version string of the prepared update (used to match against detectedUpdate).
    private var preparedVersion: String?
    private var bundleUpdatePhase: BundleUpdatePhase = .idle

    private enum BundleUpdatePhase: Equatable {
        case idle
        case downloading(progressPercent: Int?)
        case preparing
        case readyToInstall
        case installing
    }

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
        guard let preparedVersion, let preparedAppURL else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: preparedAppURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return preparedVersion == detectedUpdate?.version.displayString
    }

    var isUpdateDownloadInProgress: Bool {
        switch bundleUpdatePhase {
        case .downloading, .preparing:
            return true
        case .idle, .readyToInstall, .installing:
            return false
        }
    }

    var isUpdatePreparing: Bool {
        if case .preparing = bundleUpdatePhase {
            return true
        }
        return false
    }

    var isUpdateInstallInProgress: Bool {
        if case .installing = bundleUpdatePhase {
            return true
        }
        return false
    }

    var updateDownloadProgressPercent: Int? {
        if case .downloading(let percent) = bundleUpdatePhase {
            return percent
        }
        return nil
    }

    func installDetectedUpdateIfAvailable() async {
        guard let detectedUpdate else { return }
        await downloadUpdate(detectedUpdate)
    }

    /// Called when user clicks "Install and relaunch" after download is complete.
    func installPreparedUpdate() async {
        guard let detectedUpdate else {
            BannerManager.shared.show(
                message: "No update is currently available to install.",
                style: .warning,
                duration: 5
            )
            return
        }
        guard let preparedAppURL, let preparedVersion else {
            setBundleUpdatePhase(.idle)
            BannerManager.shared.show(
                message: "The downloaded update is no longer available. Please download it again.",
                style: .warning,
                duration: 6
            )
            return
        }
        guard preparedVersion == detectedUpdate.version.displayString else {
            invalidatePreparedUpdate()
            BannerManager.shared.show(
                message: "The downloaded update does not match the latest available version. Please download again.",
                style: .warning,
                duration: 6
            )
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: preparedAppURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            invalidatePreparedUpdate()
            BannerManager.shared.show(
                message: "The prepared update bundle could not be found. Please download it again.",
                style: .warning,
                duration: 6
            )
            return
        }
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
        _ = available
        #endif
        #if !DEBUG
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
        #endif
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

        if let nextVersion {
            if restorePreparedUpdateIfAvailable(forVersion: nextVersion) {
                setBundleUpdatePhase(.readyToInstall)
            } else if !isUpdateDownloadInProgress && !isUpdateInstallInProgress {
                setBundleUpdatePhase(.idle)
            }
        } else {
            setBundleUpdatePhase(.idle)
        }

        guard previousVersion != nextVersion || previousNotes != nextNotes else { return }
        notifyUpdateStateChanged()
    }

    private func invalidatePreparedUpdate() {
        try? FileManager.default.removeItem(at: preparedUpdateRootURL)
        preparedAppURL = nil
        preparedVersion = nil
        if case .readyToInstall = bundleUpdatePhase {
            setBundleUpdatePhase(.idle)
        }
    }

    private func setBundleUpdatePhase(_ phase: BundleUpdatePhase) {
        guard bundleUpdatePhase != phase else { return }
        bundleUpdatePhase = phase
        notifyUpdateStateChanged()
    }

    private func preparedUpdateDirectory(forVersion version: String) -> URL {
        preparedUpdateRootURL.appendingPathComponent(version, isDirectory: true)
    }

    private func preparedUpdateAppURL(forVersion version: String) -> URL {
        preparedUpdateDirectory(forVersion: version)
            .appendingPathComponent("Magent.app", isDirectory: true)
    }

    @discardableResult
    private func restorePreparedUpdateIfAvailable(forVersion version: String) -> Bool {
        let candidate = preparedUpdateAppURL(forVersion: version)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            preparedAppURL = nil
            preparedVersion = nil
            return false
        }
        preparedAppURL = candidate
        preparedVersion = version
        return true
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
                setBundleUpdatePhase(.installing)
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

                let version = update.version.displayString
                try? FileManager.default.removeItem(at: preparedUpdateRootURL)
                let tempDir = preparedUpdateDirectory(forVersion: version)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                // Phase 1: Download in-app so user sees progress.
                setBundleUpdatePhase(.downloading(progressPercent: 0))
                showUpdateProgressBanner(
                    String(localized: .UpdateStrings.updateDownloading(update.version.displayString)),
                    showsSpinner: true
                )
                let archiveURL = tempDir.appendingPathComponent("Magent.\(update.assetKind.rawValue)")
                try await downloadAsset(from: update.assetURL, to: archiveURL)

                // Phase 2: Unpack/prepare in-app.
                setBundleUpdatePhase(.preparing)
                showUpdateProgressBanner(
                    String(localized: .UpdateStrings.updatePreparing),
                    showsSpinner: true
                )
                let extracted = try await extractApp(from: archiveURL, kind: update.assetKind, in: tempDir)

                // Phase 3: Store prepared app and show "Install and relaunch" banner.
                let finalPreparedURL = tempDir.appendingPathComponent("Magent.app", isDirectory: true)
                if extracted.path != finalPreparedURL.path {
                    if FileManager.default.fileExists(atPath: finalPreparedURL.path) {
                        try FileManager.default.removeItem(at: finalPreparedURL)
                    }
                    try FileManager.default.moveItem(at: extracted, to: finalPreparedURL)
                }
                self.preparedAppURL = finalPreparedURL
                self.preparedVersion = version
                showReadyToInstallBanner(version: version)
            }
        } catch {
            setBundleUpdatePhase(.idle)
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
        setBundleUpdatePhase(.installing)

        do {
            let appBundlePath = Bundle.main.bundlePath
            var isPreparedDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: preparedAppURL.path, isDirectory: &isPreparedDirectory),
                  isPreparedDirectory.boolValue else {
                throw UpdateError.extractionFailed("Prepared update bundle is missing.")
            }
            let installDirectory = URL(fileURLWithPath: appBundlePath).deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: installDirectory) else {
                throw UpdateError.unwritableInstallLocation(installDirectory)
            }
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
            self.preparedAppURL = nil
            self.preparedVersion = nil
            showUpdateProgressBanner(
                String(localized: .UpdateStrings.updateInstalling)
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        } catch {
            isUpdating = false
            if FileManager.default.fileExists(atPath: preparedAppURL.path) {
                setBundleUpdatePhase(.readyToInstall)
            } else {
                invalidatePreparedUpdate()
                setBundleUpdatePhase(.idle)
            }
            BannerManager.shared.show(
                message: error.localizedDescription,
                style: .error,
                duration: 6
            )
        }
    }

    private func showReadyToInstallBanner(version: String) {
        setBundleUpdatePhase(.readyToInstall)
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
        let (bytes, urlResponse) = try await URLSession.shared.bytes(for: request)
        guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateError.invalidHTTPStatus((urlResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let expectedLength = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var buffer = [UInt8]()
        buffer.reserveCapacity(64 * 1024)
        var bytesReceived: Int64 = 0
        var lastPublishedPercent = -1

        do {
            for try await byte in bytes {
                buffer.append(byte)
                bytesReceived += 1

                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: Data(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }

                if let expectedLength {
                    let ratio = min(max(Double(bytesReceived) / Double(expectedLength), 0), 1)
                    let percent = Int((ratio * 100).rounded(.down))
                    if percent != lastPublishedPercent {
                        lastPublishedPercent = percent
                        setBundleUpdatePhase(.downloading(progressPercent: percent))
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
            }
            setBundleUpdatePhase(.downloading(progressPercent: 100))
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
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
                _ = await ShellExecutor.execute("/usr/bin/hdiutil detach \(q(mountDir.path)) -quiet 2>/dev/null || true")
                throw UpdateError.extractionFailed("Magent.app not found in DMG")
            }

            let destApp = tempDir.appendingPathComponent("Magent.app")
            let copyResult = await ShellExecutor.execute(
                "/usr/bin/ditto \(q(mountedApp)) \(q(destApp.path))"
            )
            _ = await ShellExecutor.execute("/usr/bin/hdiutil detach \(q(mountDir.path)) -quiet 2>/dev/null || true")
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
