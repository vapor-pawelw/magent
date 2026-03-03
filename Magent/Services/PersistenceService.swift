import Foundation

final class PersistenceService {

    static let shared = PersistenceService()

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

    // MARK: - Threads

    func loadThreads() -> [MagentThread] {
        guard let data = try? Data(contentsOf: threadsURL) else { return [] }
        return (try? decoder.decode([MagentThread].self, from: data)) ?? []
    }

    func saveThreads(_ threads: [MagentThread]) throws {
        let data = try encoder.encode(threads)
        try data.write(to: threadsURL, options: .atomic)
    }

    // MARK: - Settings

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        let settings = (try? decoder.decode(AppSettings.self, from: data)) ?? AppSettings()

        // Ensure default threadSections are persisted so their UUIDs are stable.
        // If the JSON doesn't contain "threadSections", the decoder generated fresh
        // defaults — save them so subsequent loads return the same UUIDs.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["threadSections"] == nil {
            try? saveSettings(settings)
        }

        return settings
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Worktree Metadata Cache

    private func worktreeCacheURL(worktreesBasePath: String) -> URL {
        URL(fileURLWithPath: worktreesBasePath).appendingPathComponent(".magent-cache.json")
    }

    func loadWorktreeCache(worktreesBasePath: String) -> WorktreeMetadataCache {
        let url = worktreeCacheURL(worktreesBasePath: worktreesBasePath)
        guard let data = try? Data(contentsOf: url) else { return WorktreeMetadataCache() }
        return (try? decoder.decode(WorktreeMetadataCache.self, from: data)) ?? WorktreeMetadataCache()
    }

    func saveWorktreeCache(_ cache: WorktreeMetadataCache, worktreesBasePath: String) {
        let url = worktreeCacheURL(worktreesBasePath: worktreesBasePath)
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func pruneWorktreeCache(worktreesBasePath: String, activeNames: Set<String>) {
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
    func loadRateLimitCache() -> [String: Date] {
        let url = rateLimitCacheURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let cache = (try? decoder.decode([String: Date].self, from: data)) ?? [:]
        let now = Date()
        let pruned = cache.filter { $0.value > now }
        if pruned.count != cache.count {
            saveRateLimitCache(pruned)
        }
        return pruned
    }

    func saveRateLimitCache(_ cache: [String: Date]) {
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: rateLimitCacheURL, options: .atomic)
    }

    func loadIgnoredRateLimitFingerprints() -> [AgentType: Set<String>] {
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

    func saveIgnoredRateLimitFingerprints(_ ignored: [AgentType: Set<String>]) {
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
