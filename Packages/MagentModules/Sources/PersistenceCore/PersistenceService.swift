import Foundation
import MagentModels
import os

private let logger = Logger(subsystem: "com.magent.persistence", category: "PersistenceService")

public final class PersistenceService {

    public static let shared = PersistenceService()
    public static let restorableCriticalFileNames = [
        "threads.json",
        "settings.json",
        "agent-launch-prompt-drafts.json",
    ]

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Write Protection

    /// Files blocked from being overwritten due to load failures.
    /// Populated at startup when critical files fail to decode; cleared when the
    /// user explicitly chooses "Continue with Reset" in the recovery alert.
    private var writeBlockedFiles: Set<String> = []

    /// Block all writes to the named file until explicitly unblocked.
    public func blockWrites(for fileName: String) {
        writeBlockedFiles.insert(fileName)
    }

    /// Block all writes to the named files until explicitly unblocked.
    public func blockWrites(for fileNames: [String]) {
        for fileName in fileNames {
            blockWrites(for: fileName)
        }
    }

    /// Allow writes to the named file again (after user chose to reset).
    public func unblockWrites(for fileName: String) {
        writeBlockedFiles.remove(fileName)
    }

    /// Allow writes to the named files again.
    public func unblockWrites(for fileNames: [String]) {
        for fileName in fileNames {
            unblockWrites(for: fileName)
        }
    }

    /// True if any critical file is currently write-blocked.
    public var hasBlockedWrites: Bool {
        !writeBlockedFiles.isEmpty
    }

    // MARK: - File Backup

    /// Creates a timestamped backup of a file (e.g. "settings.corrupted.2026-03-18-143022.json").
    /// Returns the backup URL on success, nil on failure.
    @discardableResult
    public func backupFile(at url: URL) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let backupName = "\(stem).corrupted.\(timestamp).\(ext)"
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backupName)
        do {
            try fileManager.copyItem(at: url, to: backupURL)
            logger.info("Backed up corrupted file to \(backupURL.path)")
            return backupURL
        } catch {
            logger.error("Failed to backup \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - File URLs

    private var appSupportURL: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var threadsURL: URL {
        appSupportURL.appendingPathComponent("threads.json")
    }

    private var settingsURL: URL {
        appSupportURL.appendingPathComponent("settings.json")
    }

    private var settingsBackupURL: URL {
        appSupportURL.appendingPathComponent("settings.bak.json")
    }

    private var backupsURL: URL {
        appSupportURL.appendingPathComponent("backups", isDirectory: true)
    }
    private var agentLaunchPromptDraftsURL: URL {
        appSupportURL.appendingPathComponent("agent-launch-prompt-drafts.json")
    }

    private var agentLastSelectionsURL: URL {
        appSupportURL.appendingPathComponent("agent-last-selections.json")
    }

    // MARK: - Schema Migrations
    //
    // Register migration closures here when bumping SchemaVersion constants.
    // Each closure transforms the JSON payload from version N to N+1.
    // See PersistenceValidation.swift for the full versioning contract.

    /// Migrations for threads.json payload. Currently empty (v1 is the initial version).
    private let threadsMigrations: SchemaMigrations = [:]

    /// Migrations for settings.json payload. Currently empty (v1 is the initial version).
    private let settingsMigrations: SchemaMigrations = [:]

    // MARK: - Versioned Decode

    /// Core decode method: handles versioned envelope detection, version checking,
    /// migration, and legacy (v0, no envelope) fallback.
    private func decodeVersioned<T: Codable>(
        _ type: T.Type,
        from url: URL,
        currentVersion: Int,
        migrations: SchemaMigrations = [:]
    ) -> LoadOutcome<T> {
        let primaryOutcome = decodeVersionedPrimary(
            type,
            from: url,
            currentVersion: currentVersion,
            migrations: migrations
        )
        if let recoveredOutcome = recoverFromBackupIfPossible(
            type,
            primaryOutcome: primaryOutcome,
            primaryURL: url,
            currentVersion: currentVersion,
            migrations: migrations
        ) {
            return recoveredOutcome
        }
        return primaryOutcome
    }

    private func decodeVersionedPrimary<T: Codable>(
        _ type: T.Type,
        from url: URL,
        currentVersion: Int,
        migrations: SchemaMigrations = [:]
    ) -> LoadOutcome<T> {
        guard let data = try? Data(contentsOf: url) else { return .fileNotFound }
        let fileName = url.lastPathComponent

        // Check for versioned envelope (top-level dictionary with "schemaVersion" key)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["schemaVersion"] as? Int {

            // Newer than this app supports — cannot safely decode
            if version > currentVersion {
                return .decodeFailed(PersistenceLoadFailure(
                    fileName: fileName,
                    filePath: url,
                    reason: .incompatibleVersion(fileVersion: version, appVersion: currentVersion)
                ))
            }

            do {
                if version < currentVersion, let payloadJSON = json["data"] {
                    // Apply sequential migrations from file version to current
                    var migrated = payloadJSON
                    for v in version..<currentVersion {
                        if let migration = migrations[v] {
                            migrated = try migration(migrated)
                        }
                    }
                    let migratedData = try JSONSerialization.data(withJSONObject: migrated)
                    return .loaded(try decoder.decode(T.self, from: migratedData))
                } else {
                    // Current version — decode envelope directly
                    let envelope = try decoder.decode(VersionedEnvelope<T>.self, from: data)
                    return .loaded(envelope.data)
                }
            } catch {
                return .decodeFailed(PersistenceLoadFailure(
                    fileName: fileName,
                    filePath: url,
                    reason: .decodeFailed(error.localizedDescription)
                ))
            }
        }

        // No versioned envelope — try legacy (v0) direct decode
        do {
            let value = try decoder.decode(T.self, from: data)
            return .loaded(value)
        } catch {
            return .decodeFailed(PersistenceLoadFailure(
                fileName: fileName,
                filePath: url,
                reason: .decodeFailed(error.localizedDescription)
            ))
        }
    }

    private func recoverFromBackupIfPossible<T: Codable>(
        _ type: T.Type,
        primaryOutcome: LoadOutcome<T>,
        primaryURL: URL,
        currentVersion: Int,
        migrations: SchemaMigrations = [:]
    ) -> LoadOutcome<T>? {
        switch primaryOutcome {
        case .loaded:
            return nil
        case .fileNotFound:
            break
        case .decodeFailed(let failure):
            guard case .decodeFailed = failure.reason else {
                return nil
            }
        }

        for candidateURL in recoveryCandidateURLs(for: primaryURL) {
            let fallbackOutcome = decodeVersionedPrimary(
                type,
                from: candidateURL,
                currentVersion: currentVersion,
                migrations: migrations
            )
            guard case .loaded(let recoveredValue) = fallbackOutcome else { continue }

            do {
                try restorePrimaryFile(at: primaryURL, from: candidateURL)
                logger.info("Recovered \(primaryURL.lastPathComponent) from backup source \(candidateURL.lastPathComponent)")
            } catch {
                logger.error(
                    "Recovered \(primaryURL.lastPathComponent) in memory but failed to restore primary file: \(error.localizedDescription)"
                )
            }

            return .loaded(recoveredValue)
        }

        return nil
    }

    private func recoveryCandidateURLs(for primaryURL: URL) -> [URL] {
        var candidates: [URL] = []

        let rollingBackupURL = primaryURL
            .deletingLastPathComponent()
            .appendingPathComponent(primaryURL.deletingPathExtension().lastPathComponent + ".bak.json")
        if fileManager.fileExists(atPath: rollingBackupURL.path) {
            candidates.append(rollingBackupURL)
        }

        let snapshotDirectories = (try? fileManager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let sortedSnapshotDirectories = snapshotDirectories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        for snapshotDirectory in sortedSnapshotDirectories {
            let candidateURL = snapshotDirectory.appendingPathComponent(primaryURL.lastPathComponent)
            guard fileManager.fileExists(atPath: candidateURL.path) else { continue }
            candidates.append(candidateURL)
        }

        return candidates
    }

    private func restorePrimaryFile(at primaryURL: URL, from backupURL: URL) throws {
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: primaryURL.path) {
            _ = backupFile(at: primaryURL)
            try fileManager.removeItem(at: primaryURL)
        }
        try fileManager.copyItem(at: backupURL, to: primaryURL)
    }

    /// Returns true if the file on disk is in legacy (pre-envelope) format.
    private func isLegacyFormat(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] is Int else {
            return true
        }
        return false
    }

    // MARK: - Threads

    private var _pendingThreadSaveWorkItem: DispatchWorkItem?

    private func ensureWritesAllowed(for fileName: String) throws {
        guard !writeBlockedFiles.contains(fileName) else {
            throw PersistenceWriteBlockedError(fileName: fileName)
        }
    }

    /// Cancels any debounced thread write that has not started yet.
    public func cancelPendingThreadSave() {
        _pendingThreadSaveWorkItem?.cancel()
        _pendingThreadSaveWorkItem = nil
    }

    /// Validates and loads threads.json, returning a detailed outcome.
    /// Use this at startup for pre-flight validation before the UI appears.
    public func tryLoadThreads() -> LoadOutcome<[MagentThread]> {
        decodeVersioned(
            [MagentThread].self,
            from: threadsURL,
            currentVersion: SchemaVersion.threads,
            migrations: threadsMigrations
        )
    }

    public func loadThreads() -> [MagentThread] {
        switch tryLoadThreads() {
        case .loaded(let threads):
            // Upgrade legacy (v0) files to versioned envelope on first load
            if isLegacyFormat(threadsURL) {
                try? saveThreads(threads)
            }
            return threads
        case .fileNotFound:
            return []
        case .decodeFailed(let failure):
            logger.error("Failed to load threads: \(failure.localizedDescription)")
            return []
        }
    }

    public func saveThreads(_ threads: [MagentThread]) throws {
        try ensureWritesAllowed(for: threadsURL.lastPathComponent)
        BackupService.shared.createRollingBackup(of: threadsURL)
        let envelope = VersionedEnvelope(schemaVersion: SchemaVersion.threads, data: threads)
        let data = try encoder.encode(envelope)
        try data.write(to: threadsURL, options: .atomic)
    }

    /// Saves the active (non-archived) threads while preserving any archived threads
    /// already on disk. Use this instead of `saveThreads(_:)` when `threads` only
    /// contains active threads (the normal ThreadManager in-memory list).
    public func saveActiveThreads(_ activeThreads: [MagentThread]) throws {
        let existingArchived = loadThreads().filter { $0.isArchived }
        try saveThreads(activeThreads + existingArchived)
    }

    /// Debounced variant of `saveActiveThreads`. Coalesces rapid saves (e.g. multiple
    /// state changes within a single session-monitor tick) into one disk write after a
    /// short delay. The latest snapshot always wins — earlier snapshots are discarded.
    /// Use the throwing `saveActiveThreads(_:)` when you need synchronous confirmation.
    public func debouncedSaveActiveThreads(_ activeThreads: [MagentThread]) {
        _pendingThreadSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.saveActiveThreads(activeThreads)
        }
        _pendingThreadSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Settings

    /// In-memory cache of the last loaded/saved settings. Avoids repeated disk reads
    /// + JSON decodes — `loadSettings()` is called dozens of times per session-monitor
    /// tick and inside per-cell rendering. The cache is invalidated on every `saveSettings`
    /// call so consumers always see the latest values.
    private var _cachedSettings: AppSettings?

    /// Validates and loads settings.json, returning a detailed outcome.
    /// Use this at startup for pre-flight validation before the UI appears.
    public func tryLoadSettings() -> LoadOutcome<AppSettings> {
        decodeVersioned(
            AppSettings.self,
            from: settingsURL,
            currentVersion: SchemaVersion.settings,
            migrations: settingsMigrations
        )
    }

    public func loadSettings() -> AppSettings {
        if let cached = _cachedSettings { return cached }

        let settings: AppSettings
        switch tryLoadSettings() {
        case .loaded(let s):
            settings = s
            _cachedSettings = settings
            // Upgrade legacy (v0) files to versioned envelope.
            // This also persists default threadSections UUIDs for stability.
            if isLegacyFormat(settingsURL) {
                try? saveSettings(settings)
            }
        case .fileNotFound:
            settings = AppSettings()
            _cachedSettings = settings
        case .decodeFailed(let failure):
            logger.error("Failed to load settings: \(failure.localizedDescription)")
            settings = AppSettings()
            _cachedSettings = settings
        }

        return settings
    }

    public struct SettingsRollingRecoveryResult: Sendable {
        public let sourceFileName: String
        public let previousCoverageCount: Int
        public let recoveredCoverageCount: Int
    }

    /// When active threads exist but the current settings file is missing, empty, or no
    /// longer references those projects, try to restore the last rolling backup before
    /// the app falls back to onboarding/default settings.
    public func recoverSettingsFromRollingBackupIfNeeded(
        activeThreadProjectIDs: Set<UUID>
    ) -> SettingsRollingRecoveryResult? {
        guard !activeThreadProjectIDs.isEmpty else { return nil }

        let currentSettings = tryLoadSettings()
        let currentCoverageCount: Int
        switch currentSettings {
        case .loaded(let settings):
            currentCoverageCount = Set(settings.projects.map(\.id)).intersection(activeThreadProjectIDs).count
        case .fileNotFound, .decodeFailed:
            currentCoverageCount = 0
        }

        guard currentCoverageCount < activeThreadProjectIDs.count else { return nil }

        let backupSettings: AppSettings
        switch decodeVersioned(
            AppSettings.self,
            from: settingsBackupURL,
            currentVersion: SchemaVersion.settings,
            migrations: settingsMigrations
        ) {
        case .loaded(let settings):
            backupSettings = settings
        case .fileNotFound, .decodeFailed:
            return nil
        }

        let recoveredCoverageCount = Set(backupSettings.projects.map(\.id)).intersection(activeThreadProjectIDs).count
        guard backupSettings.isConfigured,
              !backupSettings.projects.isEmpty,
              recoveredCoverageCount > currentCoverageCount else {
            return nil
        }

        do {
            let envelope = VersionedEnvelope(schemaVersion: SchemaVersion.settings, data: backupSettings)
            let data = try encoder.encode(envelope)
            try data.write(to: settingsURL, options: .atomic)
            _cachedSettings = backupSettings
            logger.info(
                "Recovered settings.json from \(self.settingsBackupURL.lastPathComponent) (\(currentCoverageCount) -> \(recoveredCoverageCount) matching project ids)"
            )
            return SettingsRollingRecoveryResult(
                sourceFileName: settingsBackupURL.lastPathComponent,
                previousCoverageCount: currentCoverageCount,
                recoveredCoverageCount: recoveredCoverageCount
            )
        } catch {
            logger.error("Failed to recover settings from \(self.settingsBackupURL.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try ensureWritesAllowed(for: settingsURL.lastPathComponent)
        BackupService.shared.createRollingBackup(of: settingsURL)
        let envelope = VersionedEnvelope(schemaVersion: SchemaVersion.settings, data: settings)
        let data = try encoder.encode(envelope)
        try data.write(to: settingsURL, options: .atomic)
        _cachedSettings = settings
    }

    /// Drops the in-memory settings cache so the next `loadSettings()` re-reads from disk.
    /// Call this if settings.json may have been modified externally (e.g. by another process).
    public func invalidateSettingsCache() {
        _cachedSettings = nil
    }

    // MARK: - Agent Launch Prompt Drafts

    public func loadAgentLaunchPromptDrafts() -> [String: AgentLaunchPromptDraft] {
        guard let data = try? Data(contentsOf: agentLaunchPromptDraftsURL) else { return [:] }
        return (try? decoder.decode([String: AgentLaunchPromptDraft].self, from: data)) ?? [:]
    }

    public func saveAgentLaunchPromptDrafts(_ drafts: [String: AgentLaunchPromptDraft]) {
        guard (try? ensureWritesAllowed(for: agentLaunchPromptDraftsURL.lastPathComponent)) != nil else { return }
        BackupService.shared.createRollingBackup(of: agentLaunchPromptDraftsURL)
        guard let data = try? encoder.encode(drafts) else { return }
        try? data.write(to: agentLaunchPromptDraftsURL, options: .atomic)
    }

    // MARK: - Agent Last Selections

    /// Loads last-used agent selections keyed by draft scope key.
    /// Values are agent raw strings ("claude", "codex", "custom"), "default" for project default, or "terminal".
    public func loadAgentLastSelections() -> [String: String] {
        guard let data = try? Data(contentsOf: agentLastSelectionsURL) else { return [:] }
        return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }

    public func saveAgentLastSelections(_ selections: [String: String]) {
        guard let data = try? encoder.encode(selections) else { return }
        try? data.write(to: agentLastSelectionsURL, options: .atomic)
    }

    // MARK: - Worktree Metadata Cache

    private func worktreeCacheURL(worktreesBasePath: String) -> URL {
        URL(fileURLWithPath: worktreesBasePath).appendingPathComponent(".magent-cache.json")
    }

    public func loadWorktreeCache(worktreesBasePath: String) -> WorktreeMetadataCache {
        let url = worktreeCacheURL(worktreesBasePath: worktreesBasePath)
        guard let data = try? Data(contentsOf: url) else { return WorktreeMetadataCache() }
        return (try? decoder.decode(WorktreeMetadataCache.self, from: data)) ?? WorktreeMetadataCache()
    }

    public func saveWorktreeCache(_ cache: WorktreeMetadataCache, worktreesBasePath: String) {
        let url = worktreeCacheURL(worktreesBasePath: worktreesBasePath)
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func pruneWorktreeCache(worktreesBasePath: String, activeNames: Set<String>) {
        var cache = loadWorktreeCache(worktreesBasePath: worktreesBasePath)
        let before = cache.worktrees.count
        cache.worktrees = cache.worktrees.filter { activeNames.contains($0.key) }
        guard cache.worktrees.count != before else { return }
        saveWorktreeCache(cache, worktreesBasePath: worktreesBasePath)
    }

    // MARK: - Rate Limit Fingerprint Cache

    private var rateLimitCacheURL: URL {
        appSupportURL.appendingPathComponent("rate-limit-cache.json")
    }

    private var ignoredRateLimitFingerprintsURL: URL {
        appSupportURL.appendingPathComponent("ignored-rate-limit-fingerprints.json")
    }

    /// Loads persisted rate limit fingerprints (fingerprint -> concrete resetAt).
    /// Automatically prunes expired entries on load.
    public func loadRateLimitCache() -> [String: Date] {
        let url = rateLimitCacheURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let cache = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
        let now = Date()
        let maxFingerprintLength = 512
        let pruned = cache.reduce(into: [String: Date]()) { result, entry in
            let normalizedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty,
                  normalizedKey.count <= maxFingerprintLength,
                  entry.value > now else {
                return
            }
            result[normalizedKey] = entry.value
        }
        if pruned != cache {
            saveRateLimitCache(pruned)
        }
        return pruned
    }

    public func saveRateLimitCache(_ cache: [String: Date]) {
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: rateLimitCacheURL, options: .atomic)
    }

    // MARK: - Jira Ticket Cache

    private var jiraTicketCacheURL: URL {
        appSupportURL.appendingPathComponent("jira-ticket-cache.json")
    }

    public func loadJiraTicketCache() -> [String: JiraTicketCacheEntry] {
        guard let data = try? Data(contentsOf: jiraTicketCacheURL) else { return [:] }
        return (try? decoder.decode([String: JiraTicketCacheEntry].self, from: data)) ?? [:]
    }

    public func saveJiraTicketCache(_ cache: [String: JiraTicketCacheEntry]) {
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: jiraTicketCacheURL, options: .atomic)
    }

    // MARK: - Pull Request Cache

    private var prCacheURL: URL {
        appSupportURL.appendingPathComponent("pr-cache.json")
    }

    /// Loads cached PR info keyed by branch name.
    public func loadPRCache() -> [String: PullRequestCacheEntry] {
        guard let data = try? Data(contentsOf: prCacheURL) else { return [:] }
        return (try? decoder.decode([String: PullRequestCacheEntry].self, from: data)) ?? [:]
    }

    public func savePRCache(_ cache: [String: PullRequestCacheEntry]) {
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: prCacheURL, options: .atomic)
    }

    public func loadIgnoredRateLimitFingerprints() -> [AgentType: Set<String>] {
        let url = ignoredRateLimitFingerprintsURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let raw = (try? decoder.decode([String: [String]].self, from: data)) ?? [:]

        var parsed: [AgentType: Set<String>] = [:]
        for (agentRaw, fingerprints) in raw {
            guard let agent = AgentType(rawValue: agentRaw),
                  agent == .claude || agent == .codex else {
                continue
            }
            let normalized = Set(
                fingerprints
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            if !normalized.isEmpty {
                parsed[agent] = normalized
            }
        }
        return parsed
    }

    public func saveIgnoredRateLimitFingerprints(_ ignored: [AgentType: Set<String>]) {
        var raw: [String: [String]] = [:]
        for (agent, fingerprints) in ignored {
            guard agent == .claude || agent == .codex else { continue }
            let normalized = fingerprints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            guard !normalized.isEmpty else { continue }
            raw[agent.rawValue] = normalized
        }
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: ignoredRateLimitFingerprintsURL, options: .atomic)
    }
}
