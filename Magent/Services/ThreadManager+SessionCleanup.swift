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
    /// magent-busy, shielded, pinned, has unsubmitted input, or currently visible to the user).
    /// Computed from the same live-session subset as `liveSessionCount` so that
    /// `live - protected` accurately reflects killable sessions.
    var protectedSessionCount: Int {
        let settings = persistence.loadSettings()
        return threads.filter { !$0.isArchived }.reduce(0) { total, thread in
            total + thread.tmuxSessionNames.filter { sessionName in
                !thread.deadSessions.contains(sessionName)
                    && !evictedIdleSessions.contains(sessionName)
                    && isSessionProtected(sessionName, in: thread, settings: settings)
            }.count
        }
    }

    /// Returns true if a session should not be closed during cleanup.
    /// Overload that loads settings once — prefer the variant that takes pre-loaded settings
    /// when calling in a loop.
    func isSessionProtected(_ sessionName: String, in thread: MagentThread) -> Bool {
        let settings = persistence.loadSettings()
        return isSessionProtected(sessionName, in: thread, settings: settings)
    }

    /// Returns true if a session should not be closed during cleanup.
    func isSessionProtected(_ sessionName: String, in thread: MagentThread, settings: AppSettings) -> Bool {
        // Never close the session the user is currently looking at.
        if thread.id == activeThreadId && thread.lastSelectedTabIdentifier == sessionName {
            return true
        }
        // Thread-level or session-level "Keep Alive" — never close.
        if thread.isKeepAlive || thread.protectedTmuxSessions.contains(sessionName) {
            return true
        }
        // Section-level "Keep Alive" — never close.
        if let sectionId = thread.sectionId {
            let sections = settings.sections(for: thread.projectId)
            if let section = sections.first(where: { $0.id == sectionId }), section.isKeepAlive {
                return true
            }
        }
        // Pinned tabs/threads are protected when the setting is enabled.
        if settings.protectPinnedFromEviction {
            if thread.isPinned || thread.pinnedTmuxSessions.contains(sessionName) {
                return true
            }
        }
        // Sessions that were busy within the last 5 minutes are protected.
        if let lastBusy = sessionLastBusyAt[sessionName],
           Date().timeIntervalSince(lastBusy) < 300 {
            return true
        }
        return thread.busySessions.contains(sessionName)
            || thread.magentBusySessions.contains(sessionName)
            || thread.waitingForInputSessions.contains(sessionName)
            || thread.hasUnsubmittedInputSessions.contains(sessionName)
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
        let settings = persistence.loadSettings()
        let nonArchived = threads.filter { !$0.isArchived }
        var result: [CleanupCandidate] = []

        for thread in nonArchived {
            var killableInThread: [String] = []
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread, settings: settings) else { continue }
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
        let settings = persistence.loadSettings()
        let nonArchived = threads.filter { !$0.isArchived }

        // Collect all idle, alive sessions.
        var toKill: [(threadId: UUID, sessionName: String)] = []
        for thread in nonArchived {
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread, settings: settings) else { continue }
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
        let enabling: Bool
        if threads[idx].protectedTmuxSessions.contains(sessionName) {
            threads[idx].protectedTmuxSessions.remove(sessionName)
            enabling = false
        } else {
            threads[idx].protectedTmuxSessions.insert(sessionName)
            enabling = true
        }
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Immediately recover the session if it was dead/evicted.
        if enabling {
            let thread = threads[idx]
            recoverDeadSessions([sessionName], in: thread)
        }

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

        // Recover any dead/evicted sessions now that the whole thread is protected.
        let thread = threads[idx]
        let deadSessionNames = Array(thread.deadSessions)
        if !deadSessionNames.isEmpty {
            recoverDeadSessions(deadSessionNames, in: thread)
        }
    }

    /// Toggles "Keep Alive" on a whole section. When enabled, all threads in that section
    /// are protected from eviction regardless of per-thread markers.
    func toggleSectionKeepAlive(projectId: UUID, sectionId: UUID) {
        var settings = persistence.loadSettings()
        let enabling: Bool

        // Project-level overrides take precedence: if the project has its own section list,
        // only mutate there. A global section ID passed for a project with overrides is a
        // no-op — the project's section list is the authoritative source.
        if let projectIdx = settings.projects.firstIndex(where: { $0.id == projectId }),
           var overrides = settings.projects[projectIdx].threadSections {
            guard let idx = overrides.firstIndex(where: { $0.id == sectionId }) else { return }
            overrides[idx].isKeepAlive.toggle()
            enabling = overrides[idx].isKeepAlive
            settings.projects[projectIdx].threadSections = overrides
        } else if let idx = settings.threadSections.firstIndex(where: { $0.id == sectionId }) {
            settings.threadSections[idx].isKeepAlive.toggle()
            enabling = settings.threadSections[idx].isKeepAlive
        } else { return }

        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["sectionId": sectionId])

        // Recover dead sessions in all threads belonging to this section.
        if enabling {
            for thread in threads where !thread.isArchived && thread.sectionId == sectionId {
                let deadSessionNames = Array(thread.deadSessions)
                if !deadSessionNames.isEmpty {
                    recoverDeadSessions(deadSessionNames, in: thread)
                }
            }
        }
    }

    /// Toggles thread-level "Keep Alive". When enabled, all sessions in the thread are
    /// protected from eviction regardless of per-session markers.
    func toggleThreadKeepAlive(threadId: UUID) {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[idx].isKeepAlive.toggle()
        let enabling = threads[idx].isKeepAlive
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Immediately recover all dead/evicted sessions in the thread.
        if enabling {
            let thread = threads[idx]
            let deadSessionNames = Array(thread.deadSessions)
            if !deadSessionNames.isEmpty {
                recoverDeadSessions(deadSessionNames, in: thread)
            }
        }
    }

    // MARK: - Manual Session Kill

    /// Manually kills a single tmux session, preserving tab metadata.
    /// Uses the same eviction model as idle cleanup: evict from cache, mark evicted, kill tmux.
    func killSession(threadId: UUID, sessionName: String) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }

        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions([sessionName])
        }

        evictedIdleSessions.insert(sessionName)

        do {
            try await tmux.killSession(name: sessionName)
            knownGoodSessionContexts.removeValue(forKey: sessionName)
            threads[idx].deadSessions.insert(sessionName)
            delegate?.threadManager(self, didUpdateThreads: threads)
        } catch {
            evictedIdleSessions.remove(sessionName)
            NSLog("[SessionCleanup] Manual kill failed for \(sessionName): \(error)")
        }
    }

    /// Manually kills all live tmux sessions for a thread, preserving tab metadata.
    func killAllSessions(threadId: UUID) async {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[idx]

        let liveNames = thread.tmuxSessionNames.filter {
            !thread.deadSessions.contains($0) && !evictedIdleSessions.contains($0)
        }
        guard !liveNames.isEmpty else { return }

        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions(liveNames)
        }

        for sessionName in liveNames {
            evictedIdleSessions.insert(sessionName)
            do {
                try await tmux.killSession(name: sessionName)
                knownGoodSessionContexts.removeValue(forKey: sessionName)
                threads[idx].deadSessions.insert(sessionName)
            } catch {
                evictedIdleSessions.remove(sessionName)
                NSLog("[SessionCleanup] Manual kill failed for \(sessionName): \(error)")
            }
        }

        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    // MARK: - Keep Alive Recovery

    /// Removes sessions from the evicted set and triggers async recreation for
    /// any that are currently dead. Called when keep-alive is enabled.
    private func recoverDeadSessions(_ sessionNames: [String], in thread: MagentThread) {
        for name in sessionNames {
            evictedIdleSessions.remove(name)
        }
        let deadNames = sessionNames.filter { thread.deadSessions.contains($0) }
        guard !deadNames.isEmpty else { return }

        let threadId = thread.id
        Task { [weak self] in
            guard let self else { return }
            var anyRecovered = false
            for name in deadNames {
                // Re-fetch the thread to avoid recreating sessions for
                // a thread/tab that was deleted/archived in the meantime.
                guard let freshThread = self.threads.first(where: { $0.id == threadId }),
                      !freshThread.isArchived else { break }
                if await self.recreateSessionIfNeeded(sessionName: name, thread: freshThread) {
                    anyRecovered = true
                }
            }
            if anyRecovered {
                self.delegate?.threadManager(self, didUpdateThreads: self.threads)
            }
        }
    }
}
