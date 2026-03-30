import Foundation
import MagentCore

extension ThreadManager {

    /// Evicts the oldest idle tmux sessions when the number of idle sessions
    /// exceeds `AppSettings.maxIdleSessions`.  Only sessions that have been
    /// non-busy for at least 10 minutes and not visited for at least 1 hour are
    /// counted as idle.  Main-thread sessions, the currently selected session,
    /// Keep Alive (shielded) sessions, and pinned sessions (when enabled) are
    /// always exempt.
    func evictIdleSessionsIfNeeded() async {
        let settings = persistence.loadSettings()
        guard let maxIdle = settings.maxIdleSessions else { return }
        let protectPinned = settings.protectPinnedFromEviction

        // Gather all live tmux sessions referenced by non-archived threads.
        let liveSessions: Set<String>
        do {
            liveSessions = Set(try await tmux.listSessions())
        } catch {
            return
        }

        let now = Date()
        let minIdleDuration: TimeInterval = 600         // 10 minutes since last busy
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

                // Thread-level or session-level "Keep Alive" — never evict.
                if thread.isKeepAlive || thread.protectedTmuxSessions.contains(session) { continue }

                // Pinned threads/tabs are protected when the setting is enabled.
                if protectPinned && (thread.isPinned || thread.pinnedTmuxSessions.contains(session)) { continue }

                // Currently busy — not idle.
                if thread.busySessions.contains(session) { continue }

                // Magent setup/injection is still in progress — not idle.
                if thread.magentBusySessions.contains(session) { continue }

                // Active rate limit state is protective — don't evict blocked tabs.
                if thread.rateLimitedSessions[session] != nil { continue }

                // Was busy within the last 10 minutes — not idle yet.
                if let lastBusy = sessionLastBusyAt[session],
                   now.timeIntervalSince(lastBusy) < minIdleDuration { continue }

                // Visited within the last hour — not idle yet.
                let lastVisited = sessionLastVisitedAt[session] ?? .distantPast
                if now.timeIntervalSince(lastVisited) < minUnvisitedDuration { continue }

                // Waiting for user input — don't evict.
                if thread.waitingForInputSessions.contains(session) { continue }

                // Has unsubmitted typed input at the prompt — don't evict.
                if thread.hasUnsubmittedInputSessions.contains(session) { continue }

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

        // Evict cached Ghostty surfaces before killing tmux sessions.
        let sessionNames = toEvict.map(\.session)
        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions(sessionNames)
        }

        for candidate in toEvict {
            NSLog("[IdleEviction] Evicting idle session: \(candidate.session) (last visited: \(candidate.lastVisited))")
            do {
                try await tmux.killSession(name: candidate.session)
                evictedIdleSessions.insert(candidate.session)
                if let idx = threads.firstIndex(where: { !$0.isArchived && $0.tmuxSessionNames.contains(candidate.session) }) {
                    threads[idx].deadSessions.insert(candidate.session)
                }
            } catch {
                NSLog("[IdleEviction] Failed to kill session \(candidate.session): \(error)")
            }
        }

        if !toEvict.isEmpty {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        NSLog("[IdleEviction] Evicted \(toEvict.count) idle session(s), idle count was \(idleCount), limit \(maxIdle)")
    }
}
