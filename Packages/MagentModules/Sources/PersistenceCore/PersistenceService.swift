import Foundation
import MagentModels

public final class PersistenceService {

    public static let shared = PersistenceService()

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

    private var agentLaunchPromptDraftsURL: URL {
        appSupportURL.appendingPathComponent("agent-launch-prompt-drafts.json")
    }

    private var agentLastSelectionsURL: URL {
        appSupportURL.appendingPathComponent("agent-last-selections.json")
    }

    // MARK: - Threads

    private var _pendingThreadSaveWorkItem: DispatchWorkItem?

    public func loadThreads() -> [MagentThread] {
        guard let data = try? Data(contentsOf: threadsURL) else { return [] }
        return (try? decoder.decode([MagentThread].self, from: data)) ?? []
    }

    public func saveThreads(_ threads: [MagentThread]) throws {
        let data = try encoder.encode(threads)
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

    public func loadSettings() -> AppSettings {
        if let cached = _cachedSettings { return cached }
        guard let data = try? Data(contentsOf: settingsURL) else {
            let defaults = AppSettings()
            _cachedSettings = defaults
            return defaults
        }
        let settings = (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()

        // Ensure default threadSections are persisted so their UUIDs are stable.
        // If the JSON doesn't contain "threadSections", the decoder generated fresh
        // defaults — save them so subsequent loads return the same UUIDs.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["threadSections"] == nil {
            try? saveSettings(settings)
        }

        _cachedSettings = settings
        return settings
    }

    public func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
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

    /// Loads persisted rate limit fingerprints (fingerprint → concrete resetAt).
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
