import Foundation
import MagentCore

extension ThreadManager {

    /// Total number of tmux sessions tracked across all non-archived threads.
    var totalSessionCount: Int {
        threads.filter { !$0.isArchived }.reduce(0) { $0 + $1.tmuxSessionNames.count }
    }

    /// Number of sessions with a live tmux process (not dead/evicted).
    var liveSessionCount: Int {
        threads.filter { !$0.isArchived }.reduce(0) { total, thread in
            total + thread.tmuxSessionNames.filter {
                !thread.deadSessions.contains($0) && !evictedIdleSessions.contains($0)
            }.count
        }
    }

    /// Number of live sessions that are currently protected (busy, waiting, rate-limited,
    /// magent-busy, shielded, pinned, or currently visible to the user).
    /// Computed from the same live-session subset as `liveSessionCount` so that
    /// `live - protected` accurately reflects killable sessions.
    var protectedSessionCount: Int {
        threads.filter { !$0.isArchived }.reduce(0) { total, thread in
            total + thread.tmuxSessionNames.filter { sessionName in
                !thread.deadSessions.contains(sessionName)
                    && !evictedIdleSessions.contains(sessionName)
                    && isSessionProtected(sessionName, in: thread)
            }.count
        }
    }

    /// Returns true if a session should not be closed during cleanup.
    func isSessionProtected(_ sessionName: String, in thread: MagentThread) -> Bool {
        // Never close the session the user is currently looking at.
        if thread.id == activeThreadId && thread.lastSelectedTabIdentifier == sessionName {
            return true
        }
        // Thread-level or session-level "Keep Alive" — never close.
        if thread.isKeepAlive || thread.protectedTmuxSessions.contains(sessionName) {
            return true
        }
        // Pinned tabs/threads are protected when the setting is enabled.
        let settings = persistence.loadSettings()
        if settings.protectPinnedFromEviction {
            if thread.isPinned || thread.pinnedTmuxSessions.contains(sessionName) {
                return true
            }
        }
        return thread.busySessions.contains(sessionName)
            || thread.magentBusySessions.contains(sessionName)
            || thread.waitingForInputSessions.contains(sessionName)
            || thread.rateLimitedSessions[sessionName] != nil
    }

    /// Describes a session that would be killed during cleanup.
    struct CleanupCandidate {
        let threadId: UUID
        let threadName: String
        let sessionName: String
        let tabDisplayName: String?
        let isEntireThread: Bool
    }

    /// Returns the list of sessions that would be killed by `cleanupIdleSessions`,
    /// grouped by thread with metadata for a user-facing confirmation dialog.
    func collectCleanupCandidates() -> [CleanupCandidate] {
        let nonArchived = threads.filter { !$0.isArchived }
        var result: [CleanupCandidate] = []

        for thread in nonArchived {
            var killableInThread: [String] = []
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread) else { continue }
                guard !thread.deadSessions.contains(sessionName) else { continue }
                guard !evictedIdleSessions.contains(sessionName) else { continue }
                killableInThread.append(sessionName)
            }

            let allTerminalSessions = thread.tmuxSessionNames.filter {
                !thread.deadSessions.contains($0) && !evictedIdleSessions.contains($0)
            }
            let isEntireThread = killableInThread.count == allTerminalSessions.count && !killableInThread.isEmpty

            for sessionName in killableInThread {
                let tabName = thread.customTabNames[sessionName]
                result.append(CleanupCandidate(
                    threadId: thread.id,
                    threadName: thread.taskDescription ?? thread.branchName,
                    sessionName: sessionName,
                    tabDisplayName: tabName,
                    isEntireThread: isEntireThread
                ))
            }
        }

        return result
    }

    /// Kills all idle tmux sessions across all threads, freeing system resources.
    /// Tab metadata is preserved — sessions are recreated on demand when the user selects them.
    /// Protected sessions (busy, waiting, rate-limited, currently visible) are never killed.
    /// Uses the same eviction model as `evictIdleSessionsIfNeeded`: marks sessions in
    /// `evictedIdleSessions` so `checkForDeadSessions` skips them, and evicts cached
    /// Ghostty surfaces via `ReusableTerminalViewCache`.
    /// Returns the number of sessions killed.
    @discardableResult
    func cleanupIdleSessions() async -> Int {
        let nonArchived = threads.filter { !$0.isArchived }

        // Collect all idle, alive sessions.
        var toKill: [(threadId: UUID, sessionName: String)] = []
        for thread in nonArchived {
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread) else { continue }
                guard !thread.deadSessions.contains(sessionName) else { continue }
                guard !evictedIdleSessions.contains(sessionName) else { continue }
                toKill.append((threadId: thread.id, sessionName: sessionName))
            }
        }

        guard !toKill.isEmpty else { return 0 }

        // Evict cached Ghostty surfaces before killing tmux sessions to prevent
        // stale surface references in the cache.
        let sessionNames = toKill.map(\.sessionName)
        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions(sessionNames)
        }

        var killedCount = 0
        for (threadId, sessionName) in toKill {
            // Mark as evicted so checkForDeadSessions doesn't recreate.
            evictedIdleSessions.insert(sessionName)

            do {
                try await tmux.killSession(name: sessionName)
                knownGoodSessionContexts.removeValue(forKey: sessionName)
                if let idx = threads.firstIndex(where: { $0.id == threadId }) {
                    threads[idx].deadSessions.insert(sessionName)
                }
                killedCount += 1
            } catch {
                // If kill failed, remove from evicted set so it can be retried.
                evictedIdleSessions.remove(sessionName)
                NSLog("[SessionCleanup] Failed to kill session \(sessionName): \(error)")
            }
        }

        if killedCount > 0 {
            delegate?.threadManager(self, didUpdateThreads: threads)
            NotificationCenter.default.post(name: .magentSessionCleanupCompleted, object: nil, userInfo: [
                "closedCount": killedCount,
            ])
        }

        return killedCount
    }

    // MARK: - Keep Alive

    /// Toggles the "Keep Alive" protection on a single session.
    /// Protected sessions are exempt from both manual cleanup and auto idle eviction.
    func toggleSessionKeepAlive(threadId: UUID, sessionName: String) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        if threads[idx].protectedTmuxSessions.contains(sessionName) {
            threads[idx].protectedTmuxSessions.remove(sessionName)
        } else {
            threads[idx].protectedTmuxSessions.insert(sessionName)
        }
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Offer to promote to thread-level Keep Alive when all tabs are individually protected.
        let thread = threads[idx]
        if !thread.isKeepAlive
            && !thread.didOfferKeepAlivePromotion
            && thread.tmuxSessionNames.count > 1
            && thread.tmuxSessionNames.allSatisfy({ thread.protectedTmuxSessions.contains($0) })
        {
            threads[idx].didOfferKeepAlivePromotion = true
            try? persistence.saveActiveThreads(threads)
            BannerManager.shared.show(
                message: "All tabs are Keep Alive — mark the whole thread as Keep Alive?",
                style: .info,
                duration: 8.0,
                actions: [BannerAction(title: "Keep Alive Thread") { [weak self] in
                    self?.promoteToThreadKeepAlive(threadId: threadId)
                }]
            )
        }
    }

    /// Promotes per-tab keep alive markers to thread-level keep alive,
    /// clearing the individual session markers since they're now redundant.
    private func promoteToThreadKeepAlive(threadId: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[idx].isKeepAlive = true
        threads[idx].protectedTmuxSessions.removeAll()
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])
    }

    /// Toggles thread-level "Keep Alive". When enabled, all sessions in the thread are
    /// protected from eviction regardless of per-session markers.
    func toggleThreadKeepAlive(threadId: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[idx].isKeepAlive.toggle()
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])
    }
}
