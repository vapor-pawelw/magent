import Foundation
import os
import MagentCore

/// Loads, caches, and refreshes the agent model manifest (agent-models.json).
///
/// Priority: local cache → bundled resource → hardcoded fallback.
/// Remote fetch happens on app launch and is throttled to once per 10 minutes
/// when the launch sheet requests it.
final class AgentModelsService: @unchecked Sendable {
    // @unchecked Sendable: all mutable state is synchronized via `state` (OSAllocatedUnfairLock).

    static let shared = AgentModelsService()

    private static let remoteURL = URL(string: "https://raw.githubusercontent.com/vapor-pawelw/mAgent/main/config/agent-models.json")!
    private static nonisolated let throttleInterval: TimeInterval = 600 // 10 minutes

    private struct State {
        var manifest: AgentModelsManifest
        var lastFetchDate: Date?
        var isFetching = false
    }

    private let state: OSAllocatedUnfairLock<State>

    private var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("agent-models.json")
    }

    var manifest: AgentModelsManifest {
        state.withLock { $0.manifest }
    }

    private init() {
        // Load order: local cache → bundled resource → hardcoded fallback
        let initial: AgentModelsManifest
        if let cached = Self.loadJSON(from: Self.cacheURLStatic()) {
            initial = cached
        } else if let bundled = Self.loadBundledManifest() {
            initial = bundled
        } else {
            initial = Self.hardcodedFallback()
        }
        state = OSAllocatedUnfairLock(initialState: State(manifest: initial))
    }

    // MARK: - Public API

    /// Fetch remote manifest on app launch (fire and forget).
    func refreshOnLaunch() {
        fetchRemoteIfNeeded(force: true)
    }

    /// Called when the launch sheet is about to show — respects throttle.
    func refreshIfThrottled() {
        fetchRemoteIfNeeded(force: false)
    }

    /// Returns model config for the given agent type from the current manifest.
    func config(for agentType: AgentType) -> AgentModelConfig? {
        manifest.config(for: agentType)
    }

    /// Validates a model id against the current manifest, returning nil if stale/unknown.
    func validatedModelId(_ modelId: String?, for agentType: AgentType) -> String? {
        guard let modelId, let agentConfig = config(for: agentType) else { return nil }
        return agentConfig.models.contains(where: { $0.id == modelId }) ? modelId : nil
    }

    /// Validates a reasoning level against the current manifest for a given agent+model, returning nil if stale/unknown.
    func validatedReasoningLevel(_ level: String?, for agentType: AgentType, modelId: String?) -> String? {
        guard let level, let agentConfig = config(for: agentType) else { return nil }
        let validLevels = agentConfig.effectiveReasoningLevels(for: modelId)
        return validLevels.contains(level) ? level : nil
    }

    // MARK: - Fetch

    private func fetchRemoteIfNeeded(force: Bool) {
        let shouldFetch = state.withLock { s -> Bool in
            if s.isFetching { return false }
            if !force, let lastFetch = s.lastFetchDate, Date().timeIntervalSince(lastFetch) < Self.throttleInterval {
                return false
            }
            s.isFetching = true
            return true
        }
        guard shouldFetch else { return }

        Task {
            defer {
                state.withLock { s in
                    s.isFetching = false
                    s.lastFetchDate = Date()
                }
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.remoteURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                guard let remote = try? JSONDecoder().decode(AgentModelsManifest.self, from: data) else { return }

                // Write to cache
                try? data.write(to: cacheURL, options: .atomic)

                state.withLock { $0.manifest = remote }

                await MainActor.run {
                    NotificationCenter.default.post(name: .agentModelsManifestUpdated, object: nil)
                }
            } catch {
                // Silently ignore — we have a local fallback
            }
        }
    }

    // MARK: - Loading Helpers

    private static func cacheURLStatic() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
        return appSupport.appendingPathComponent("agent-models.json")
    }

    private static func loadJSON(from url: URL) -> AgentModelsManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AgentModelsManifest.self, from: data)
    }

    private static func loadBundledManifest() -> AgentModelsManifest? {
        guard let url = Bundle.main.url(forResource: "agent-models", withExtension: "json") else { return nil }
        return loadJSON(from: url)
    }

    private static func hardcodedFallback() -> AgentModelsManifest {
        AgentModelsManifest(
            version: 1,
            agents: [
                "claude": AgentModelConfig(
                    models: [
                        AgentModel(id: "opus", label: "Opus"),
                        AgentModel(id: "sonnet", label: "Sonnet"),
                        AgentModel(id: "haiku", label: "Haiku"),
                    ],
                    reasoningLevels: ["low", "medium", "high", "max"]
                ),
                "codex": AgentModelConfig(
                    models: [
                        AgentModel(id: "gpt-5.4", label: "GPT 5.4"),
                        AgentModel(id: "gpt-5.4-mini", label: "GPT 5.4 Mini"),
                        AgentModel(id: "gpt-5.3-codex", label: "GPT 5.3 Codex"),
                    ],
                    reasoningLevels: ["low", "medium", "high", "xhigh"]
                ),
            ]
        )
    }
}

extension Notification.Name {
    static let agentModelsManifestUpdated = Notification.Name("agentModelsManifestUpdated")
}
