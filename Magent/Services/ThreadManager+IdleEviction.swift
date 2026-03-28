import Foundation
import MagentCore

extension ThreadManager {

    /// Evicts the oldest idle tmux sessions when the number of idle sessions
    /// exceeds `AppSettings.maxIdleSessions`.  Only sessions that have been
    /// idle for at least 1 minute and not visited for at least 1 hour are
    /// counted as idle.  Main-thread sessions and the currently selected
    /// session are always exempt.
    func evictIdleSessionsIfNeeded() async {
        let settings = persistence.loadSettings()
        guard let maxIdle = settings.maxIdleSessions else { return }

        // Gather all live tmux sessions referenced by non-archived threads.
        let liveSessions: Set<String>
        do {
            liveSessions = Set(try await tmux.listSessions())
        } catch {
            return
        }

        let now = Date()
        let minIdleDuration: TimeInterval = 60          // 1 minute since last busy
        let minUnvisitedDuration: TimeInterval = 3600    // 1 hour since last visit

        // Find the currently visible session so we never evict it.
        let currentSession: String? = {
            guard let activeId = activeThreadId,
                  let thread = threads.first(where: { $0.id == activeId }) else { return nil }
            return thread.lastSelectedTabIdentifier
        }()

        // Build the list of sessions that qualify as "idle" for counting purposes.
        // A session is idle if it passes all the eviction-eligibility checks.
        var idleCandidates: [(session: String, lastVisited: Date)] = []
        for thread in threads where !thread.isArchived {
            for session in thread.tmuxSessionNames where liveSessions.contains(session) {
                // Never count main-thread sessions as idle.
                if thread.isMain { continue }

                // Never count the currently visible session as idle.
                if session == currentSession { continue }

                // Already evicted — not live for our purposes.
                if evictedIdleSessions.contains(session) { continue }

                // Currently busy — not idle.
                if thread.busySessions.contains(session) { continue }

                // Was busy within the last minute — not idle yet.
                if let lastBusy = sessionLastBusyAt[session],
                   now.timeIntervalSince(lastBusy) < minIdleDuration { continue }

                // Visited within the last hour — not idle yet.
                let lastVisited = sessionLastVisitedAt[session] ?? .distantPast
                if now.timeIntervalSince(lastVisited) < minUnvisitedDuration { continue }

                // Waiting for user input — don't evict.
                if thread.waitingForInputSessions.contains(session) { continue }

                idleCandidates.append((session, lastVisited))
            }
        }

        let idleCount = idleCandidates.count
        guard idleCount > maxIdle else { return }

        // Sort: oldest visit first.
        idleCandidates.sort { $0.lastVisited < $1.lastVisited }

        let excessCount = idleCount - maxIdle
        let toEvict = idleCandidates.prefix(excessCount)
        guard !toEvict.isEmpty else { return }

        for candidate in toEvict {
            NSLog("[IdleEviction] Evicting idle session: \(candidate.session) (last visited: \(candidate.lastVisited))")
            evictedIdleSessions.insert(candidate.session)
            try? await tmux.killSession(name: candidate.session)
        }

        NSLog("[IdleEviction] Evicted \(toEvict.count) idle session(s), idle count was \(idleCount), limit \(maxIdle)")
    }
}
