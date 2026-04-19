import Foundation
import MagentCore  // AgentType for lastRuntimeDetectedAgentBySession

/// Metadata cached after verifying a session belongs to its expected thread/path context.
/// Avoids re-querying tmux on every `ensureSessionPrepared` call when nothing has changed.
struct KnownGoodSessionContext {
    let threadId: UUID
    let expectedPath: String
    let projectPath: String
    let isAgentSession: Bool
    let validatedAt: Date
}

/// Tracks transient per-session lifecycle state shared across multiple services.
/// Extracted from ThreadManager to decouple session tracking from thread management.
final class SessionTracker {

    /// How long a cached runtime-detected agent type is trusted when live detection
    /// transiently returns nil (e.g. pane command becomes xcodebuild while Claude runs tools).
    static let lastRuntimeDetectedAgentTTL: TimeInterval = 60

    var sessionLastVisitedAt: [String: Date] = [:]
    var sessionLastBusyAt: [String: Date] = [:]
    var evictedIdleSessions: Set<String> = []
    var sessionsBeingRecreated: Set<String> = []
    var knownGoodSessionContexts: [String: KnownGoodSessionContext] = [:]

    /// Caches the last runtime-detected agent type per session. When `ps` child-process
    /// detection transiently fails (e.g. Claude reports its version as `pane_current_command`
    /// instead of "claude"), this prevents the session from flipping to `nil` and losing busy state.
    /// Entries expire after `lastRuntimeDetectedAgentTTL` seconds of consecutive nil detections.
    var lastRuntimeDetectedAgentBySession: [String: (agent: AgentType, detectedAt: Date)] = [:]

    // MARK: - Convenience

    func markVisited(_ sessionName: String) {
        sessionLastVisitedAt[sessionName] = Date()
    }

    func markBusy(_ sessionName: String) {
        sessionLastBusyAt[sessionName] = Date()
    }

    func markEvicted(_ sessionName: String) {
        evictedIdleSessions.insert(sessionName)
    }

    func clearEviction(_ sessionName: String) {
        evictedIdleSessions.remove(sessionName)
    }

    func isEvicted(_ sessionName: String) -> Bool {
        evictedIdleSessions.contains(sessionName)
    }

    func cleanupForThread(sessionNames: [String]) {
        for name in sessionNames {
            sessionLastVisitedAt.removeValue(forKey: name)
            sessionLastBusyAt.removeValue(forKey: name)
            evictedIdleSessions.remove(name)
            sessionsBeingRecreated.remove(name)
            knownGoodSessionContexts.removeValue(forKey: name)
            lastRuntimeDetectedAgentBySession.removeValue(forKey: name)
        }
    }

    func seedVisitTimestamps(for sessionNames: [String], at date: Date = Date()) {
        for name in sessionNames {
            sessionLastVisitedAt[name] = date
        }
    }
}
