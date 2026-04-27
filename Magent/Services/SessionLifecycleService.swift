import AppKit
import Foundation
import os
import UserNotifications
import MagentCore

private extension Logger {
    static let busyState = Logger(subsystem: "com.magent.app", category: "BusyState")
}

// MARK: - SessionRecreationAction

enum SessionRecreationAction {
    case recreateMissingAgentSession
    case recreateMismatchedAgentSession
    case recreateMissingTerminalSession
    case recreateMismatchedTerminalSession

    var loadingOverlayDetail: String {
        switch self {
        case .recreateMissingAgentSession:
            return "Recovering a missing tmux session and restoring the saved agent conversation."
        case .recreateMismatchedAgentSession:
            return "Replacing a stale tmux session that points at the wrong worktree, then restoring the saved conversation."
        case .recreateMissingTerminalSession:
            return "Recovering a missing tmux session for this tab."
        case .recreateMismatchedTerminalSession:
            return "Replacing a stale tmux session that points at the wrong worktree."
        }
    }
}

// MARK: - CleanupCandidate

struct CleanupCandidate {
    let threadId: UUID
    let threadName: String
    let sessionName: String
    let tabDisplayName: String?
    let isEntireThread: Bool
}

// MARK: - SessionLifecycleService

/// Owns session protection, idle eviction, keep-alive toggling, manual kill, stale session
/// cleanup, dead-session detection, busy/waiting/completion state syncing, and tab management
/// helpers. Session recreation itself stays in ThreadManager+SessionRecreation until Phase 5.
final class SessionLifecycleService {

    let store: ThreadStore
    let sessionTracker: SessionTracker
    let persistence: PersistenceService
    let tmux: TmuxService

    // MARK: - Callbacks

    /// Called whenever the service mutates thread state that the UI needs to reflect.
    var onThreadsChanged: (() -> Void)?

    /// Provided by ThreadManager so the service can trigger session recreation without
    /// importing or referencing the full agent-setup machinery.
    var recreateSession: ((String, MagentThread) async -> Bool)?

    /// Returns the configured agent type for a session on a given thread.
    var agentType: ((MagentThread, String) -> AgentType?)?

    /// Returns true if the session is currently blocked by an active rate limit.
    var isSessionProtectedByRateLimit: ((String) -> Bool)?

    /// Returns true if the session is currently visible in a pop-out window.
    /// Used as a fallback; the service also calls `PopoutWindowManager.shared` directly.
    var isMagentBusy: ((String) -> Bool)?

    // MARK: - Callbacks for AgentState (to avoid direct ThreadManager references)

    /// Updates the app dock badge (unread count, etc.).
    var updateDockBadge: (() -> Void)?

    /// Requests a dock bounce when a new unread completion arrives.
    var requestDockBounce: (() -> Void)?

    /// Bumps a thread to the top of its section when auto-reorder-on-completion is enabled.
    var bumpThreadToTop: ((UUID) -> Void)?

    /// Schedules an async refresh of the agent conversation ID for a session.
    var scheduleConversationIDRefresh: ((UUID, String) -> Void)?

    /// Fires the auto-rename flow after an agent completes its first task on a thread.
    var triggerAutoRename: ((UUID, String) async -> Void)?

    /// Refreshes the git dirty state indicator for a thread.
    var refreshDirtyState: ((UUID) async -> Void)?

    /// Refreshes the "delivered" git state indicator for a thread.
    var refreshDeliveredState: ((UUID) async -> Void)?

    /// Posts busy-sessions-changed notification for a thread.
    var postBusySessionsChanged: ((MagentThread) -> Void)?

    /// Clears rate-limit-after-recovery state; returns thread IDs whose rate limit was cleared.
    var clearRateLimitAfterRecovery: ((UUID, String, String?) async -> Set<UUID>)?

    /// Applies a rate-limit marker from the prompt-based detection path.
    /// Returns `(didChange, additionalChangedThreadIds)` to avoid inout across closure boundary.
    var applyRateLimitMarker: ((AgentRateLimitInfo, AgentType, [AgentType: Set<String>]) -> (Bool, Set<UUID>))?

    /// Clears prompt-based rate-limit markers for an agent.
    /// Returns `(didChange, additionalChangedThreadIds)` to avoid inout across closure boundary.
    var clearPromptRateLimitMarkers: ((AgentType) -> (Bool, Set<UUID>))?

    /// Checks whether pane content contains an active, non-ignored rate limit for an agent.
    var paneHasActiveNonIgnoredRateLimit: ((AgentType, String, String?, String?) -> Bool)?

    /// Publishes a rate-limit summary banner if the state changed.
    var publishRateLimitSummary: (() async -> Void)?

    /// Detects the running agent type from a pane command name.
    var detectedAgentType: ((String) -> AgentType?)?

    /// Detects the running agent type from pane command + child processes.
    var detectedRunningAgentType: ((String, [(pid: pid_t, args: String)]) -> AgentType?)?

    /// Detects the running agent type by inspecting a live session's pane.
    var detectedAgentTypeInSession: ((String) async -> AgentType?)?

    // MARK: - Owned State

    /// Transient — tracks when each unrecognised "ma-" session was first seen so
    /// `cleanupStaleMagentSessions` can apply a grace-period before killing.
    var staleMagentSessionsFirstSeenAt: [String: Date] = [:]

    /// When the last pass of `cleanupStaleMagentSessions` ran (used by the session monitor).
    var lastStaleSessionCleanupAt: Date = .distantPast

    /// Dedup guard for bell-driven agent-completion events — maps session name to the
    /// last bell timestamp so rapid double-bells within 1 s are ignored.
    var recentBellBySession: [String: Date] = [:]

    /// Sessions whose "waiting for input" notification has already been sent — prevents
    /// re-notifying on every subsequent poll tick while the session stays in waiting state.
    var notifiedWaitingSessions: Set<String> = []

    /// Sessions that had a rate limit lifted and still need the user to visit and continue work.
    /// Protects those entries in `waitingForInputSessions` from being auto-cleared by
    /// `checkForWaitingForInput` (which normally clears on idle prompt, not interactive prompt).
    var rateLimitLiftPendingResumeSessions: Set<String> = []

    // MARK: - Init

    init(store: ThreadStore, sessionTracker: SessionTracker, persistence: PersistenceService, tmux: TmuxService) {
        self.store = store
        self.sessionTracker = sessionTracker
        self.persistence = persistence
        self.tmux = tmux
    }

    // MARK: - Session Counts

    var totalSessionCount: Int {
        store.threads.filter { !$0.isArchived }.reduce(0) { $0 + $1.tmuxSessionNames.count }
    }

    var liveSessionCount: Int {
        store.threads.filter { !$0.isArchived }.reduce(0) { total, thread in
            total + thread.tmuxSessionNames.filter {
                !thread.deadSessions.contains($0) && !sessionTracker.evictedIdleSessions.contains($0)
            }.count
        }
    }

    var protectedSessionCount: Int {
        let settings = persistence.loadSettings()
        return store.threads.filter { !$0.isArchived }.reduce(0) { total, thread in
            total + thread.tmuxSessionNames.filter { sessionName in
                !thread.deadSessions.contains(sessionName)
                    && !sessionTracker.evictedIdleSessions.contains(sessionName)
                    && isSessionProtected(sessionName, in: thread, settings: settings)
            }.count
        }
    }

    // MARK: - Session Protection

    func isSessionProtected(_ sessionName: String, in thread: MagentThread) -> Bool {
        let settings = persistence.loadSettings()
        return isSessionProtected(sessionName, in: thread, settings: settings)
    }

    func isSessionProtected(_ sessionName: String, in thread: MagentThread, settings: AppSettings) -> Bool {
        // Never close the session the user is currently looking at.
        if thread.id == store.activeThreadId && thread.lastSelectedTabIdentifier == sessionName {
            return true
        }
        // Protect sessions visible in pop-out windows.
        if PopoutWindowManager.shared.visibleSessionNames.contains(sessionName) {
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
        if let lastBusy = sessionTracker.sessionLastBusyAt[sessionName],
           Date().timeIntervalSince(lastBusy) < 300 {
            return true
        }
        return thread.busySessions.contains(sessionName)
            || thread.magentBusySessions.contains(sessionName)
            || thread.waitingForInputSessions.contains(sessionName)
            || thread.hasUnsubmittedInputSessions.contains(sessionName)
            || thread.rateLimitedSessions[sessionName] != nil
    }

    // MARK: - Cleanup Candidates

    func collectCleanupCandidates() -> [CleanupCandidate] {
        let settings = persistence.loadSettings()
        let nonArchived = store.threads.filter { !$0.isArchived }
        var result: [CleanupCandidate] = []

        for thread in nonArchived {
            var killableInThread: [String] = []
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread, settings: settings) else { continue }
                guard !thread.deadSessions.contains(sessionName) else { continue }
                guard !sessionTracker.evictedIdleSessions.contains(sessionName) else { continue }
                killableInThread.append(sessionName)
            }

            let allTerminalSessions = thread.tmuxSessionNames.filter {
                !thread.deadSessions.contains($0) && !sessionTracker.evictedIdleSessions.contains($0)
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

    // MARK: - Manual Cleanup

    /// Kills all idle tmux sessions across all threads, freeing system resources.
    /// Protected sessions (busy, waiting, rate-limited, currently visible) are never killed.
    /// Returns the number of sessions killed.
    @discardableResult
    func cleanupIdleSessions() async -> Int {
        let settings = persistence.loadSettings()
        let nonArchived = store.threads.filter { !$0.isArchived }

        var toKill: [(threadId: UUID, sessionName: String)] = []
        for thread in nonArchived {
            for sessionName in thread.tmuxSessionNames {
                guard !isSessionProtected(sessionName, in: thread, settings: settings) else { continue }
                guard !thread.deadSessions.contains(sessionName) else { continue }
                guard !sessionTracker.evictedIdleSessions.contains(sessionName) else { continue }
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
            sessionTracker.evictedIdleSessions.insert(sessionName)

            do {
                try await tmux.killSession(name: sessionName)
                sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
                if let idx = store.threads.firstIndex(where: { $0.id == threadId }) {
                    store.threads[idx].deadSessions.insert(sessionName)
                }
                killedCount += 1
            } catch {
                // If kill failed, remove from evicted set so it can be retried.
                sessionTracker.evictedIdleSessions.remove(sessionName)
                NSLog("[SessionCleanup] Failed to kill session \(sessionName): \(error)")
            }
        }

        if killedCount > 0 {
            onThreadsChanged?()
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
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        let enabling: Bool
        if store.threads[idx].protectedTmuxSessions.contains(sessionName) {
            store.threads[idx].protectedTmuxSessions.remove(sessionName)
            enabling = false
        } else {
            store.threads[idx].protectedTmuxSessions.insert(sessionName)
            enabling = true
        }
        try? persistence.saveActiveThreads(store.threads)
        onThreadsChanged?()
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Immediately recover the session if it was dead/evicted.
        if enabling {
            let thread = store.threads[idx]
            recoverDeadSessions([sessionName], in: thread)
        }

        // Offer to promote to thread-level Keep Alive when all tabs are individually protected.
        let thread = store.threads[idx]
        if !thread.isKeepAlive
            && !thread.didOfferKeepAlivePromotion
            && thread.tmuxSessionNames.count > 1
            && thread.tmuxSessionNames.allSatisfy({ thread.protectedTmuxSessions.contains($0) })
        {
            store.threads[idx].didOfferKeepAlivePromotion = true
            try? persistence.saveActiveThreads(store.threads)
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
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[idx].isKeepAlive = true
        store.threads[idx].protectedTmuxSessions.removeAll()
        try? persistence.saveActiveThreads(store.threads)
        onThreadsChanged?()
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Recover any dead/evicted sessions now that the whole thread is protected.
        let thread = store.threads[idx]
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
            for thread in store.threads where !thread.isArchived && thread.sectionId == sectionId {
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
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[idx].isKeepAlive.toggle()
        let enabling = store.threads[idx].isKeepAlive
        try? persistence.saveActiveThreads(store.threads)
        onThreadsChanged?()
        NotificationCenter.default.post(name: .magentKeepAliveChanged, object: nil, userInfo: ["threadId": threadId])

        // Immediately recover all dead/evicted sessions in the thread.
        if enabling {
            let thread = store.threads[idx]
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
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else { return }

        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions([sessionName])
        }

        sessionTracker.evictedIdleSessions.insert(sessionName)

        do {
            try await tmux.killSession(name: sessionName)
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
            store.threads[idx].deadSessions.insert(sessionName)
            onThreadsChanged?()
        } catch {
            sessionTracker.evictedIdleSessions.remove(sessionName)
            NSLog("[SessionCleanup] Manual kill failed for \(sessionName): \(error)")
        }
    }

    /// Manually kills all live tmux sessions for a thread, preserving tab metadata.
    func killAllSessions(threadId: UUID) async {
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = store.threads[idx]

        let liveNames = thread.tmuxSessionNames.filter {
            !thread.deadSessions.contains($0) && !sessionTracker.evictedIdleSessions.contains($0)
        }
        guard !liveNames.isEmpty else { return }

        await MainActor.run {
            ReusableTerminalViewCache.shared.evictSessions(liveNames)
        }

        for sessionName in liveNames {
            sessionTracker.evictedIdleSessions.insert(sessionName)
            do {
                try await tmux.killSession(name: sessionName)
                sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
                store.threads[idx].deadSessions.insert(sessionName)
            } catch {
                sessionTracker.evictedIdleSessions.remove(sessionName)
                NSLog("[SessionCleanup] Manual kill failed for \(sessionName): \(error)")
            }
        }

        onThreadsChanged?()
    }

    // MARK: - Keep Alive Recovery

    /// Removes sessions from the evicted set and triggers async recreation for
    /// any that are currently dead. Called when keep-alive is enabled.
    private func recoverDeadSessions(_ sessionNames: [String], in thread: MagentThread) {
        for name in sessionNames {
            sessionTracker.evictedIdleSessions.remove(name)
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
                guard let freshThread = self.store.threads.first(where: { $0.id == threadId }),
                      !freshThread.isArchived else { break }
                if await self.recreateSession?(name, freshThread) == true {
                    anyRecovered = true
                }
            }
            if anyRecovered {
                self.onThreadsChanged?()
            }
        }
    }

    // MARK: - Idle Eviction

    /// Evicts the oldest idle tmux sessions when the number of idle sessions
    /// exceeds `AppSettings.maxIdleSessions`. Only sessions that have been
    /// non-busy for at least 10 minutes and not visited for at least 1 hour are
    /// counted as idle. Main-thread sessions, the currently selected session,
    /// Keep Alive (shielded) sessions, and pinned sessions (when enabled) are
    /// always exempt.
    func evictIdleSessionsIfNeeded() async {
        let settings = persistence.loadSettings()
        guard let maxIdle = settings.maxIdleSessions else { return }
        let protectPinned = settings.protectPinnedFromEviction

        // Build a lookup of section keep-alive state per project.
        let keepAliveSectionIds: Set<UUID> = {
            var ids = Set<UUID>()
            for section in settings.threadSections where section.isKeepAlive {
                ids.insert(section.id)
            }
            for project in settings.projects {
                if let overrides = project.threadSections {
                    for section in overrides where section.isKeepAlive {
                        ids.insert(section.id)
                    }
                }
            }
            return ids
        }()

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
            guard let activeId = store.activeThreadId,
                  let thread = store.threads.first(where: { $0.id == activeId }) else { return nil }
            return thread.lastSelectedTabIdentifier
        }()

        // Build the list of sessions that qualify as "idle" for counting purposes.
        var idleCandidates: [(session: String, lastVisited: Date)] = []
        for thread in store.threads where !thread.isArchived {
            for session in thread.tmuxSessionNames where liveSessions.contains(session) {
                // Never count main-thread sessions as idle.
                if thread.isMain { continue }

                // Never count the currently visible session as idle.
                if session == currentSession { continue }

                // Protect sessions visible in pop-out windows.
                if PopoutWindowManager.shared.visibleSessionNames.contains(session) { continue }

                // Already evicted — not live for our purposes.
                if sessionTracker.evictedIdleSessions.contains(session) { continue }

                // Thread-level or session-level "Keep Alive" — never evict.
                if thread.isKeepAlive || thread.protectedTmuxSessions.contains(session) { continue }

                // Section-level "Keep Alive" — never evict.
                if let sid = thread.sectionId, keepAliveSectionIds.contains(sid) { continue }

                // Pinned threads/tabs are protected when the setting is enabled.
                if protectPinned && (thread.isPinned || thread.pinnedTmuxSessions.contains(session)) { continue }

                // Currently busy — not idle.
                if thread.busySessions.contains(session) { continue }

                // Magent setup/injection is still in progress — not idle.
                if thread.magentBusySessions.contains(session) { continue }

                // Active rate limit state is protective — don't evict blocked tabs.
                if thread.rateLimitedSessions[session] != nil { continue }

                // Was busy within the last 10 minutes — not idle yet.
                if let lastBusy = sessionTracker.sessionLastBusyAt[session],
                   now.timeIntervalSince(lastBusy) < minIdleDuration { continue }

                // Visited within the last hour — not idle yet.
                let lastVisited = sessionTracker.sessionLastVisitedAt[session] ?? .distantPast
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
                sessionTracker.evictedIdleSessions.insert(candidate.session)
                if let idx = store.threads.firstIndex(where: { !$0.isArchived && $0.tmuxSessionNames.contains(candidate.session) }) {
                    store.threads[idx].deadSessions.insert(candidate.session)
                }
            } catch {
                NSLog("[IdleEviction] Failed to kill session \(candidate.session): \(error)")
            }
        }

        if !toEvict.isEmpty {
            onThreadsChanged?()
        }

        NSLog("[IdleEviction] Evicted \(toEvict.count) idle session(s), idle count was \(idleCount), limit \(maxIdle)")
    }

    // MARK: - Stale Session Cleanup

    /// Kills live tmux sessions prefixed with "ma-" that are not referenced by any non-archived thread/tab.
    @discardableResult
    func cleanupStaleMagentSessions(minimumStaleAge: TimeInterval = 0, now: Date = Date()) async -> [String] {
        let referencedSessions = referencedMagentSessionNames()

        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return []
        }

        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("ma-") && !referencedSessions.contains(sessionName)
        }

        guard !staleSessions.isEmpty else { return [] }

        let staleSet = Set(staleSessions)
        staleMagentSessionsFirstSeenAt = staleMagentSessionsFirstSeenAt.filter { staleSet.contains($0.key) }

        let sessionsToKill: [String]
        if minimumStaleAge > 0 {
            var matured = [String]()
            for sessionName in staleSessions {
                let firstSeen = staleMagentSessionsFirstSeenAt[sessionName] ?? now
                staleMagentSessionsFirstSeenAt[sessionName] = firstSeen
                if now.timeIntervalSince(firstSeen) >= minimumStaleAge {
                    matured.append(sessionName)
                }
            }
            sessionsToKill = matured
        } else {
            sessionsToKill = staleSessions
        }

        guard !sessionsToKill.isEmpty else { return [] }

        for sessionName in sessionsToKill {
            try? await tmux.killSession(name: sessionName)
            staleMagentSessionsFirstSeenAt.removeValue(forKey: sessionName)
        }

        return sessionsToKill
    }

    /// Lightweight stale-session cleanup that runs entirely off the main thread.
    /// Takes pre-captured referenced sessions and a tmux service reference so no main-actor
    /// hop is needed. Skips `staleMagentSessionsFirstSeenAt` tracking (only relevant for the
    /// 5-minute poller cadence, not post-archive one-shot cleanup).
    nonisolated static func cleanupStaleSessions(
        tmux: TmuxService,
        referencedSessions: Set<String>
    ) async {
        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return
        }
        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("ma-") && !referencedSessions.contains(sessionName)
        }
        for sessionName in staleSessions {
            try? await tmux.killSession(name: sessionName)
        }
    }

    func referencedMagentSessionNames() -> Set<String> {
        var names = Set<String>()

        // Include both in-memory and persisted threads so cleanup is safe during transitional states.
        let allNonArchivedThreads = store.threads.filter { !$0.isArchived } + persistence.loadThreads().filter { !$0.isArchived }
        for thread in allNonArchivedThreads {
            for sessionName in thread.tmuxSessionNames where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            for sessionName in thread.agentTmuxSessions where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            for sessionName in thread.pinnedTmuxSessions where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            if let selectedSession = thread.lastSelectedTabIdentifier, selectedSession.hasPrefix("ma-") {
                names.insert(selectedSession)
            }
        }

        return names
    }

    // MARK: - Tab State Management

    func updateLastSelectedTab(for threadId: UUID, identifier: String?) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        if let identifier {
            sessionTracker.sessionLastVisitedAt[identifier] = Date()
            sessionTracker.evictedIdleSessions.remove(identifier)
        }
        if store.threads[index].lastSelectedTabIdentifier == identifier { return }
        store.threads[index].lastSelectedTabIdentifier = identifier
        try? persistence.saveActiveThreads(store.threads)
    }

    @MainActor
    func setActiveThread(_ threadId: UUID?) {
        store.activeThreadId = threadId
        if let threadId,
           let thread = store.threads.first(where: { $0.id == threadId }) {
            let now = Date()
            for session in thread.tmuxSessionNames {
                sessionTracker.sessionLastVisitedAt[session] = now
                sessionTracker.evictedIdleSessions.remove(session)
            }
        }
    }

    func registerFallbackSession(_ sessionName: String, for threadId: UUID, agentType: AgentType?) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard !store.threads[index].tmuxSessionNames.contains(sessionName) else { return }
        store.threads[index].tmuxSessionNames.append(sessionName)
        sessionTracker.sessionLastVisitedAt[sessionName] = Date()
        if agentType != nil {
            store.threads[index].agentTmuxSessions.append(sessionName)
            if let agentType {
                store.threads[index].sessionAgentTypes[sessionName] = agentType
            }
            store.threads[index].agentHasRun = true
        }
        store.threads[index].customTabNames[sessionName] = TmuxSessionNaming.defaultTabDisplayName(for: agentType)
        store.threads[index].lastSelectedTabIdentifier = sessionName
        try? persistence.saveActiveThreads(store.threads)
    }

    func reorderTabs(for threadId: UUID, newOrder: [String]) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[index].tmuxSessionNames = newOrder
        try? persistence.saveActiveThreads(store.threads)
    }

    func updatePinnedTabs(for threadId: UUID, pinnedSessions: [String]) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[index].pinnedTmuxSessions = pinnedSessions
        try? persistence.saveActiveThreads(store.threads)
    }

    func updatePersistedWebTabs(for threadId: UUID, webTabs: [PersistedWebTab]) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[index].persistedWebTabs = webTabs
        try? persistence.saveActiveThreads(store.threads)
    }

    func updatePersistedDraftTabs(for threadId: UUID, draftTabs: [PersistedDraftTab]) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        store.threads[index].persistedDraftTabs = draftTabs
        try? persistence.saveActiveThreads(store.threads)
    }

    // MARK: - Waiting-for-Input Detection

    func checkForWaitingForInput() async {
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        var changed = false
        var changedThreadIds = Set<UUID>()
        var notifyPairs: [(threadId: UUID, sessionName: String)] = []

        let waitingSnapshot: [(id: UUID, sessions: [String])] = store.threads
            .filter { !$0.isArchived }
            .map { ($0.id, $0.agentTmuxSessions) }
        for (threadId, sessions) in waitingSnapshot {
            for session in sessions {
                guard let ti = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                let wasWaiting = store.threads[ti].waitingForInputSessions.contains(session)
                let isBusy = store.threads[ti].busySessions.contains(session)

                // Only check busy sessions (or already-waiting sessions to detect resolution)
                guard isBusy || wasWaiting else { continue }

                guard let paneContent = await tmux.cachedCapturePane(sessionName: session) else { continue }
                guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                let isWaiting = matchesWaitingForInputPattern(paneContent)

                if isWaiting && !wasWaiting {
                    // Transition: busy → waiting
                    store.threads[i].busySessions.remove(session)
                    store.threads[i].waitingForInputSessions.insert(session)
                    changed = true
                    changedThreadIds.insert(store.threads[i].id)

                    let isActiveThread = store.threads[i].id == store.activeThreadId
                    let isActiveTab = isActiveThread && store.threads[i].lastSelectedTabIdentifier == session
                    if !isActiveTab && !notifiedWaitingSessions.contains(session) {
                        notifiedWaitingSessions.insert(session)
                        notifyPairs.append((threadId, session))
                    }
                } else if !isWaiting && wasWaiting {
                    // If this session was marked waiting because a rate limit lifted
                    // (not because the agent asked a question), keep the indicator until
                    // the user visits the tab or the agent resumes work.
                    if rateLimitLiftPendingResumeSessions.contains(session) && !isBusy {
                        continue
                    }
                    store.threads[i].waitingForInputSessions.remove(session)
                    rateLimitLiftPendingResumeSessions.remove(session)
                    notifiedWaitingSessions.remove(session)
                    changed = true
                    changedThreadIds.insert(store.threads[i].id)
                    // syncBusy will re-mark as busy on the same tick
                }
            }
        }

        guard changed else { return }
        for (threadId, sessionName) in notifyPairs {
            guard let thread = store.threads.first(where: { $0.id == threadId }) else { continue }
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "Project"
            sendAgentWaitingNotification(for: thread, projectName: projectName, playSound: playSound, sessionName: sessionName)
        }

        await MainActor.run {
            updateDockBadge?()
            onThreadsChanged?()
            for threadId in changedThreadIds {
                if let thread = store.threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChanged?(thread)
                }
            }
            for i in store.threads.indices where !store.threads[i].isArchived && store.threads[i].hasWaitingForInput {
                NotificationCenter.default.post(
                    name: .magentAgentWaitingForInput,
                    object: nil,
                    userInfo: [
                        "threadId": store.threads[i].id,
                        "waitingSessions": store.threads[i].waitingForInputSessions
                    ]
                )
            }
        }
    }

    private func matchesWaitingForInputPattern(_ text: String) -> Bool {
        // Trim trailing whitespace/newlines and look at the last non-empty lines
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmedLines = lines.suffix(20).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return false }
        let lastChunk = trimmedLines.suffix(15).joined(separator: "\n")

        // If the agent is actively processing ("esc to interrupt" visible), it's
        // not waiting for input — even if a waiting-style phrase is in older output.
        if paneContentShowsEscToInterrupt(text) { return false }

        // The Claude Code rate-limit prompt uses ❯ + numbered list and would
        // otherwise match the interactive selector pattern below. Exclude it
        // so it's handled as a rate-limit marker by syncBusySessionsFromProcessState.
        if isInteractiveRateLimitPromptText(lastChunk) {
            return false
        }

        // Claude Code plan mode
        if lastChunk.contains("Would you like to proceed?") { return true }

        // Claude Code permission prompts
        if lastChunk.contains("Do you want to") && (lastChunk.contains("Yes") || lastChunk.contains("No")) { return true }

        // Codex approval prompts
        if lastChunk.contains("approve") && lastChunk.contains("deny") { return true }

        // Claude Code AskUserQuestion / interactive prompt: ❯ selector at line start
        // Only match when ❯ is at the start of a line (interactive selector indicator),
        // not just anywhere in terminal (e.g. Claude Code's input prompt character).
        let lastFew = trimmedLines.suffix(6)
        let hasSelectorAtLineStart = lastFew.contains { $0.hasPrefix("\u{276F}") }
        if hasSelectorAtLineStart && lastFew.contains(where: { $0.range(of: #"^\u{276F}?\s*\d+\."#, options: .regularExpression) != nil }) { return true }

        // Claude Code ExitPlanMode / plan approval prompt
        if lastChunk.contains("Do you want me to go ahead") { return true }

        return false
    }

    private func isInteractiveRateLimitPromptText(_ text: String) -> Bool {
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = text.lowercased()
        let hasLimitContext = normalized.contains("limit")
            || normalized.contains("rate")
            || normalized.contains("quota")
        let hasWaitChoice = lines.contains(where: isClaudeRateLimitWaitChoiceLine)
            || normalized.contains("stop and wait")
        let hasSwitchChoice = lines.contains(where: isClaudeRateLimitSwitchChoiceLine)
            || normalized.contains("switch to extra usage")
            || normalized.contains("switch to max")
            || normalized.contains("switch to pro")

        return (hasWaitChoice && hasSwitchChoice)
            || (hasLimitContext && (hasWaitChoice || hasSwitchChoice))
    }

    private func isClaudeRateLimitWaitChoiceLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.range(of: #"^\d+\.\s*stop and wait\b"#, options: .regularExpression) != nil else {
            return false
        }
        return normalized.contains("reset")
            || normalized.contains("limit")
            || normalized.contains("quota")
            || normalized.contains("until")
            || normalized.contains("available")
            || normalized.contains("try again")
            || normalized.contains("retry")
    }

    private func isClaudeRateLimitSwitchChoiceLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.range(of: #"^\d+\.\s*switch to\b"#, options: .regularExpression) != nil else {
            return false
        }
        return normalized.contains("extra usage")
            || normalized.contains("max")
            || normalized.contains("pro")
            || normalized.contains("plan")
    }

    private func sendAgentWaitingNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = String(localized: .NotificationStrings.notificationsAgentNeedsInputTitle)
            content.body = "\(projectName) · \(thread.taskDescription ?? thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

            let request = UNNotificationRequest(
                identifier: "magent-agent-waiting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: - Dead Session Detection

    func checkForDeadSessions() async {
        let liveSessions: Set<String>
        do {
            liveSessions = Set(try await tmux.listSessions())
        } catch {
            // tmux server not running — all sessions are dead
            liveSessions = []
        }

        var changed = false
        for (index, thread) in store.threads.enumerated() {
            guard !thread.isArchived else { continue }

            let currentDead = Set(thread.tmuxSessionNames.filter {
                !liveSessions.contains($0)
            })
            guard currentDead != thread.deadSessions else { continue }

            let newlyDead = currentDead.subtracting(thread.deadSessions)
            store.threads[index].deadSessions = currentDead
            changed = true

            // Auto-recreate the currently visible session so the user isn't
            // stuck on a dead terminal — but not if it was intentionally evicted.
            // Other dead sessions stay dead until selected.
            if let visibleSession = thread.lastSelectedTabIdentifier,
               thread.id == store.activeThreadId,
               newlyDead.contains(visibleSession),
               !sessionTracker.evictedIdleSessions.contains(visibleSession) {
                _ = await recreateSession?(visibleSession, thread)
            }

            if !newlyDead.isEmpty {
                let newlyDeadCopy = Array(newlyDead)
                let threadId = thread.id
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .magentDeadSessionsDetected,
                        object: nil,
                        userInfo: [
                            "deadSessions": newlyDeadCopy,
                            "threadId": threadId
                        ]
                    )
                }
            }
        }

        if changed {
            await MainActor.run {
                onThreadsChanged?()
            }
        }
    }

    // MARK: - Agent Completion Detection

    private struct CompletionProcessingResult {
        var changed = false
        var changedThreadIds = Set<UUID>()
        var newlyUnreadThreadIds = Set<UUID>()
    }

    func checkForAgentCompletions() async {
        let sessions = await tmux.consumeAgentCompletionSessions()
        guard !sessions.isEmpty else { return }
        await processAgentCompletionSessions(sessions)
    }

    private func processAgentCompletionSessions(_ sessions: [String], now: Date = Date()) async {
        guard !sessions.isEmpty else { return }

        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        let orderedUniqueSessions = deduplicatedSessions(sessions)
        let result = processCompletedAgentSessions(
            orderedUniqueSessions,
            completedAt: now,
            settings: settings,
            playSound: playSound,
            shouldApplyRecentCompletionCooldown: true
        )

        guard result.changed else { return }
        persistence.debouncedSaveActiveThreads(store.threads)

        // Refresh dirty and delivered states only for threads that just completed,
        // not the full scan — avoids running git-status on every thread on each bell.
        for threadId in result.changedThreadIds {
            await refreshDirtyState?(threadId)
            await refreshDeliveredState?(threadId)
        }

        // Trigger auto-rename for threads that haven't been renamed yet.
        // This covers the case where a thread is not currently displayed
        // (no ThreadDetailViewController), so the TOC-based rename path
        // never fires. We spawn these as fire-and-forget tasks to avoid
        // blocking the completion notification flow.
        for session in orderedUniqueSessions {
            if let index = store.threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }),
               !store.threads[index].didAutoRenameFromFirstPrompt,
               !store.threads[index].isMain {
                let threadId = store.threads[index].id
                Task {
                    await self.triggerAutoRename?(threadId, session)
                }
            }
        }

        await MainActor.run {
            updateDockBadge?()
            if !result.newlyUnreadThreadIds.isEmpty {
                requestDockBounce?()
            }
            onThreadsChanged?()
            for threadId in result.changedThreadIds {
                if let thread = store.threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChanged?(thread)
                }
            }
            for session in orderedUniqueSessions {
                if let index = store.threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) {
                    NotificationCenter.default.post(
                        name: .magentAgentCompletionDetected,
                        object: nil,
                        userInfo: [
                            "threadId": store.threads[index].id,
                            "unreadSessions": store.threads[index].unreadCompletionSessions
                        ]
                    )
                }
            }
        }
    }

    private func deduplicatedSessions(_ sessions: [String]) -> [String] {
        sessions.reduce(into: [String]()) { result, session in
            if !result.contains(session) {
                result.append(session)
            }
        }
    }

    @discardableResult
    private func processCompletedAgentSessions(
        _ sessions: [String],
        completedAt: Date,
        settings: AppSettings,
        playSound: Bool,
        shouldApplyRecentCompletionCooldown: Bool
    ) -> CompletionProcessingResult {
        var result = CompletionProcessingResult()

        for session in sessions {
            if shouldApplyRecentCompletionCooldown,
               let previous = recentBellBySession[session],
               completedAt.timeIntervalSince(previous) < 1.0 {
                continue
            }
            recentBellBySession[session] = completedAt

            guard let index = store.threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) else {
                continue
            }

            store.threads[index].lastAgentCompletionAt = completedAt
            if settings.autoReorderThreadsOnAgentCompletion {
                bumpThreadToTop?(store.threads[index].id)
            }
            store.threads[index].busySessions.remove(session)
            store.threads[index].waitingForInputSessions.remove(session)
            store.threads[index].hasUnsubmittedInputSessions.remove(session)
            notifiedWaitingSessions.remove(session)

            let isActiveThread = store.threads[index].id == store.activeThreadId
            let isActiveTab = isActiveThread && store.threads[index].lastSelectedTabIdentifier == session
            if !isActiveTab {
                // Use the raw set here, not `hasUnreadAgentCompletion`, which is now
                // busy-suppressed for display. We need to detect the actual underlying
                // empty→non-empty transition so dock-bounce/notification logic still fires.
                let hadUnreadCompletion = !store.threads[index].unreadCompletionSessions.isEmpty
                store.threads[index].unreadCompletionSessions.insert(session)
                if !hadUnreadCompletion {
                    result.newlyUnreadThreadIds.insert(store.threads[index].id)
                }
            }
            result.changed = true
            result.changedThreadIds.insert(store.threads[index].id)
            scheduleConversationIDRefresh?(store.threads[index].id, session)

            let projectName = settings.projects.first(where: { $0.id == store.threads[index].projectId })?.name ?? "Project"
            sendAgentCompletionNotification(
                for: store.threads[index],
                projectName: projectName,
                playSound: playSound,
                sessionName: session
            )
        }

        return result
    }

    private func sendAgentCompletionNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = String(localized: .NotificationStrings.notificationsAgentFinishedTitle)
            content.body = "\(projectName) · \(thread.taskDescription ?? thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

            let request = UNNotificationRequest(
                identifier: "magent-agent-finished-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Play sound directly via NSSound as a fallback — UNNotification sound
        // can be throttled by macOS when many notifications are delivered.
        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: - Busy Session Sync

    /// Syncs `busySessions` by detecting what agent is actually running in each pane,
    /// then applying agent-specific idle/busy logic. If no known agent is detected
    /// (terminal session), the session is treated as not busy.
    func syncBusySessionsFromProcessState() async {
        var changed = false
        var busyChangedThreadIds = Set<UUID>()
        var rateLimitChangedThreadIds = Set<UUID>()
        var agentsWithVisibleRateLimitPrompt = Set<AgentType>()
        var runtimeActiveRateLimitSessionsByAgent: [AgentType: Set<String>] = [:]
        var implicitCompletionSessions: [String] = []

        func publishBusySyncChangesIfNeeded() async {
            // Tick debounce timers for ALL threads every pass so pending
            // transitions commit as soon as their 1-second window expires,
            // regardless of whether a different thread triggered `changed`.
            var debounceCommitted = false
            for i in store.threads.indices {
                if store.threads[i].updateBusyStateDuration() {
                    debounceCommitted = true
                }
            }
            guard changed || debounceCommitted else { return }
            await MainActor.run {
                onThreadsChanged?()
                for threadId in busyChangedThreadIds {
                    if let thread = store.threads.first(where: { $0.id == threadId }) {
                        postBusySessionsChanged?(thread)
                    }
                }
                for threadId in rateLimitChangedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: nil,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
            await publishRateLimitSummary?()
        }

        // Reconcile stale transient state first. This catches session renames or
        // removals performed outside Magent and prevents stuck busy/waiting flags.
        for i in store.threads.indices where !store.threads[i].isArchived {
            if pruneTransientSessionStateToKnownAgentSessions(threadIndex: i) {
                changed = true
                busyChangedThreadIds.insert(store.threads[i].id)
            }
        }

        // Collect all agent sessions across non-archived threads
        var allAgentSessions = Set<String>()
        for thread in store.threads where !thread.isArchived {
            allAgentSessions.formUnion(thread.agentTmuxSessions)
        }
        guard !allAgentSessions.isEmpty else {
            await publishBusySyncChangesIfNeeded()
            return
        }

        let paneStates = await tmux.activePaneStates(forSessions: allAgentSessions)
        guard !paneStates.isEmpty else {
            await publishBusySyncChangesIfNeeded()
            return
        }

        // Only fall back to a full child-process scan for panes whose current command
        // does not already identify the running agent.
        let unresolvedPanePids = Set(
            paneStates.values.compactMap { paneState -> pid_t? in
                guard paneState.pid > 0 else { return nil }
                guard detectedAgentType?(paneState.command) == nil else { return nil }
                return paneState.pid
            }
        )
        let childProcessesByPid = await tmux.childProcesses(forParents: unresolvedPanePids)

        // Snapshot thread IDs and their sessions before iterating. The `store.threads`
        // array can shrink during `await` suspension points (e.g. archive), which
        // would invalidate raw indices and cause an out-of-bounds crash.
        let threadSnapshot: [(id: UUID, sessions: [String])] = store.threads
            .filter { !$0.isArchived }
            .map { ($0.id, $0.agentTmuxSessions) }

        for (threadId, sessions) in threadSnapshot {
            for session in sessions {
                guard let paneState = paneStates[session] else { continue }
                guard let ti = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }

                if store.threads[ti].waitingForInputSessions.contains(session) { continue }

                // Detect agent type: first try the pane command name, then child
                // processes, then a version-number heuristic for agents (like Claude)
                // that set their process title to a semver string.
                let children = detectedAgentType?(paneState.command) == nil
                    ? childProcessesByPid[paneState.pid] ?? []
                    : []
                var detectedAgent = detectedRunningAgentType?(paneState.command, children)

                // Agents like Claude Code set pane_current_command to their version
                // (e.g. "2.1.92") which doesn't match "claude"/"codex" by name.
                // When the command looks like a semver and this session has a known
                // configured agent type, trust the configured type directly — avoids
                // depending on the ps child scan for every tick.
                if detectedAgent == nil,
                   looksLikeSemver(paneState.command),
                   let configuredType = store.threads[ti].sessionAgentTypes[session] {
                    detectedAgent = configuredType
                }

                // Runtime process detection is authoritative, but can transiently fail
                // while an agent runs tools (e.g. pane command becomes xcodebuild).
                // Only use persisted session type as a weak hint when pane output
                // contains evidence for that specific agent.
                if detectedAgent == nil,
                   let hintedType = store.threads[ti].sessionAgentTypes[session],
                   (hintedType == .claude || hintedType == .codex),
                   await paneContentSupportsAgentHint(sessionName: session, hintedAgent: hintedType) {
                    detectedAgent = hintedType
                }

                if let agent = detectedAgent {
                    // Cache successful detection so transient failures on future
                    // ticks don't flip the session to nil and wipe busy state.
                    sessionTracker.lastRuntimeDetectedAgentBySession[session] = (agent: agent, detectedAt: Date())
                    if agent == .claude || agent == .codex {
                        runtimeActiveRateLimitSessionsByAgent[agent, default: []].insert(session)
                    }
                } else if let cached = sessionTracker.lastRuntimeDetectedAgentBySession[session],
                          Date().timeIntervalSince(cached.detectedAt) < SessionTracker.lastRuntimeDetectedAgentTTL {
                    detectedAgent = cached.agent
                    Logger.busyState.debug(
                        "Agent detection nil for \(session, privacy: .public), falling back to cached \(String(describing: cached.agent), privacy: .public) (age: \(Int(Date().timeIntervalSince(cached.detectedAt)))s)"
                    )
                } else {
                    // No detection and no valid cache — genuinely no agent.
                    sessionTracker.lastRuntimeDetectedAgentBySession.removeValue(forKey: session)
                }

                switch detectedAgent {
                case .codex?:
                    // Codex: busy while active "Working"/interrupt/background status
                    // markers are visible in the latest scope.
                    let isBusy = await paneShowsEscToInterrupt(sessionName: session)
                    guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                    let wasBusy = store.threads[i].busySessions.contains(session)
                    if isBusy {
                        if !wasBusy {
                            store.threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(store.threads[i].id)
                        }
                        let recoveredIds = await clearRateLimitAfterRecovery?(threadId, session, nil) ?? []
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                    } else {
                        if wasBusy {
                            store.threads[i].busySessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(store.threads[i].id)
                        }

                        if await syncUnsubmittedInputState(threadId: threadId, sessionName: session, agentType: .codex) {
                            changed = true
                            busyChangedThreadIds.insert(threadId)
                        }
                        guard let ci = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        let hasUnsubmittedInput = store.threads[ci].hasUnsubmittedInputSessions.contains(session)
                        if wasBusy && !hasUnsubmittedInput {
                            implicitCompletionSessions.append(session)
                        }
                    }
                    if isBusy {
                        // Agent is busy — clear any stale unsubmitted-input flag.
                        if let ci = store.threads.firstIndex(where: { $0.id == threadId }),
                           store.threads[ci].hasUnsubmittedInputSessions.contains(session) {
                            store.threads[ci].hasUnsubmittedInputSessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threadId)
                        }
                    }

                    if wasBusy
                        && !isBusy
                        && !store.threads[i].waitingForInputSessions.contains(session)
                        && store.threads[i].rateLimitedSessions[session] == nil {
                        await processAgentCompletionSessions([session])
                    }

                case .claude?:
                    // Claude: skip if a completion bell was received recently — the bell fires
                    // just before process exit, so the process name can lag behind briefly.
                    let recentlyCompleted: Bool = {
                        guard let bellDate = recentBellBySession[session] else { return false }
                        return Date().timeIntervalSince(bellDate) < 5.0
                    }()
                    if recentlyCompleted { continue }

                    let content = await tmux.cachedCapturePane(sessionName: session)
                    let showsRateLimitPrompt = content.map { isAtRateLimitPrompt($0) } ?? false
                    if showsRateLimitPrompt {
                        // Check the actual pane content (120 lines) to see if the
                        // rate limit reset time is still in the future. This works
                        // regardless of whether rate-limit detection is enabled,
                        // and avoids treating stale prompts (e.g. /rate-limit-options
                        // opened after the limit lifted) as active rate limits.
                        let widerContent = await tmux.cachedCapturePane(sessionName: session, lastLines: 120)
                        let lastPromptForRL = store.threads.first(where: { $0.id == threadId })?.submittedPromptsBySession[session]?.last
                        let isActiveLimit = widerContent.map {
                            paneHasActiveNonIgnoredRateLimit?(.claude, $0, lastPromptForRL, session) ?? false
                        } ?? false

                        if isActiveLimit {
                            agentsWithVisibleRateLimitPrompt.insert(.claude)
                            guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                            let promptMarker = AgentRateLimitInfo(
                                resetAt: Date.distantFuture,
                                resetDescription: nil,
                                detectedAt: Date(),
                                isPromptBased: true,
                                agentType: .claude
                            )
                            if let (didChange, changedIds) = applyRateLimitMarker?(promptMarker, .claude, runtimeActiveRateLimitSessionsByAgent) {
                                if didChange { changed = true }
                                rateLimitChangedThreadIds.formUnion(changedIds)
                            }
                            if store.threads[i].busySessions.contains(session) {
                                store.threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                            if store.threads[i].hasUnsubmittedInputSessions.contains(session) {
                                store.threads[i].hasUnsubmittedInputSessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                        } else {
                            // Stale rate-limit prompt (limit expired but menu still
                            // visible). Clear busy/unsubmitted-input state but do NOT
                            // call syncUnsubmittedInputState — the stale menu text
                            // could cause it to latch onto an older ❯ line in scrollback.
                            guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                            if store.threads[i].busySessions.contains(session) {
                                store.threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                            if store.threads[i].hasUnsubmittedInputSessions.contains(session) {
                                store.threads[i].hasUnsubmittedInputSessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                        }
                    } else if let content, isAgentIdleAtPrompt(content) {
                        // Prompt is visible and no "esc to interrupt" in the narrow
                        // window. Check a wider capture for background activity
                        // (run_in_background tools, active task spinners) that can
                        // sit above the 15-line window in tall panes.
                        let widerContent = await tmux.cachedCapturePane(sessionName: session, lastLines: 30)
                        let hasBackgroundWork = widerContent.map { paneContentShowsBackgroundActivity($0) } ?? false
                        if hasBackgroundWork {
                            guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                            if !store.threads[i].busySessions.contains(session) {
                                store.threads[i].busySessions.insert(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                        } else {
                            guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                            if store.threads[i].busySessions.contains(session) {
                                store.threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(store.threads[i].id)
                            }
                            // Check for unsubmitted typed input at the idle prompt.
                            if await syncUnsubmittedInputState(threadId: threadId, sessionName: session, agentType: .claude) {
                                changed = true
                                busyChangedThreadIds.insert(threadId)
                            }
                        }
                    } else {
                        // Claude is running but not idle at prompt — treat as busy
                        guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        if !store.threads[i].busySessions.contains(session) {
                            store.threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(store.threads[i].id)
                        }
                        // Clear unsubmitted-input flag — user submitted or agent took over.
                        if store.threads[i].hasUnsubmittedInputSessions.contains(session) {
                            store.threads[i].hasUnsubmittedInputSessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(store.threads[i].id)
                        }
                        let recoveredIds = await clearRateLimitAfterRecovery?(threadId, session, content) ?? []
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                    }

                case .custom?, nil:
                    // No known agent detected — terminal session or agent has exited.
                    // Clear any stale busy/waiting/rate-limit/unsubmitted-input state.
                    guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { continue }
                    if store.threads[i].busySessions.contains(session) {
                        store.threads[i].busySessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(store.threads[i].id)
                    }
                    if store.threads[i].waitingForInputSessions.contains(session) {
                        store.threads[i].waitingForInputSessions.remove(session)
                        notifiedWaitingSessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(store.threads[i].id)
                    }
                    if store.threads[i].hasUnsubmittedInputSessions.contains(session) {
                        store.threads[i].hasUnsubmittedInputSessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(store.threads[i].id)
                    }
                }
            }
        }

        if !agentsWithVisibleRateLimitPrompt.contains(.claude),
           let (didChange, changedIds) = clearPromptRateLimitMarkers?(.claude) {
            if didChange { changed = true }
            rateLimitChangedThreadIds.formUnion(changedIds)
        }

        // Stamp sessionLastBusyAt for all currently-busy sessions so idle eviction
        // knows when a session was last actively working.
        let busyNow = Date()
        for thread in store.threads where !thread.isArchived {
            for session in thread.busySessions {
                sessionTracker.sessionLastBusyAt[session] = busyNow
            }
        }

        let deduplicatedImplicitCompletionSessions = deduplicatedSessions(implicitCompletionSessions)
        let settings = persistence.loadSettings()
        let implicitCompletionResult = processCompletedAgentSessions(
            deduplicatedImplicitCompletionSessions,
            completedAt: Date(),
            settings: settings,
            playSound: settings.playSoundForAgentCompletion,
            shouldApplyRecentCompletionCooldown: true
        )
        if implicitCompletionResult.changed {
            changed = true
            busyChangedThreadIds.formUnion(implicitCompletionResult.changedThreadIds)
            for threadId in implicitCompletionResult.changedThreadIds {
                await refreshDirtyState?(threadId)
                await refreshDeliveredState?(threadId)
            }

            for session in deduplicatedImplicitCompletionSessions {
                if let index = store.threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }),
                   !store.threads[index].didAutoRenameFromFirstPrompt,
                   !store.threads[index].isMain {
                    let threadId = store.threads[index].id
                    Task {
                        await self.triggerAutoRename?(threadId, session)
                    }
                }
            }

            await MainActor.run {
                updateDockBadge?()
                if !implicitCompletionResult.newlyUnreadThreadIds.isEmpty {
                    requestDockBounce?()
                }
                for session in deduplicatedImplicitCompletionSessions {
                    if let index = store.threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) {
                        NotificationCenter.default.post(
                            name: .magentAgentCompletionDetected,
                            object: nil,
                            userInfo: [
                                "threadId": store.threads[index].id,
                                "unreadSessions": store.threads[index].unreadCompletionSessions
                            ]
                        )
                    }
                }
            }
        }

        await publishBusySyncChangesIfNeeded()
    }

    /// Returns true when the "esc to interrupt" status bar text is visible in the
    /// last 15 non-empty lines of pane content. This is the definitive Claude Code
    /// busy signal — present while the agent is actively processing, absent when idle.
    func paneContentShowsEscToInterrupt(_ paneContent: String) -> Bool {
        let nonEmpty = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(15)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return nonEmpty.contains(where: isEscToInterruptStatusLine)
    }

    /// Returns true when the string looks like a semver version (e.g. "2.1.92").
    /// Agents like Claude Code set their process title to their version number,
    /// so tmux's pane_current_command reports "2.1.92" instead of "claude".
    private func looksLikeSemver(_ string: String) -> Bool {
        string.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
    }

    private func isEscToInterruptStatusLine(_ line: String) -> Bool {
        // Only treat status-like lines as busy markers. This avoids false
        // positives when the phrase appears in normal conversation text.
        let directStatusMatch = line.range(
            of: #"^\s*(?:[•⏵]+[[:space:]]*)?esc to interrupt\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if directStatusMatch { return true }

        // Claude can render status with leading context, e.g.:
        // "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"
        // May also have trailing content like "7% until auto-compact"
        return line.range(
            of: #"\s·\s*esc to interrupt\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isAgentIdleAtPrompt(_ paneContent: String) -> Bool {
        // "esc to interrupt" is shown in the status bar while Claude processes
        // → definitely busy, regardless of prompt visibility.
        if paneContentShowsEscToInterrupt(paneContent) { return false }

        let nonEmpty = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(15)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // ❯ prompt visible without the busy status bar → agent is idle
        let hasPrompt = nonEmpty.contains(where: { $0.hasPrefix("\u{276F}") })
        return hasPrompt
    }

    /// Detects secondary busy indicators in Claude Code output that signal
    /// background work is in progress, even when the `❯` prompt is visible.
    /// This catches `run_in_background` Bash tools, active Agent subagents,
    /// and in-progress task lists. Uses a wider pane capture (30+ lines) to
    /// see indicators that may sit above the narrow 15-line prompt window.
    func paneContentShowsBackgroundActivity(_ paneContent: String) -> Bool {
        let lines = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines {
            // "⎿  Running…" — a tool (Bash, Agent, etc.) is actively executing
            if line.hasPrefix("\u{23BF}") && line.contains("Running") { return true }
            // "✳" spinner prefix — an active task/thinking block with live progress
            if line.hasPrefix("\u{2733}") { return true }
        }
        return false
    }

    /// Detects the Claude Code interactive rate-limit prompt.
    private func isAtRateLimitPrompt(_ paneContent: String) -> Bool {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let recentLines = lines.suffix(30)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !recentLines.isEmpty else { return false }

        let normalized = recentLines
            .joined(separator: "\n")
            .lowercased()
        let hasLimitContext = normalized.contains("limit")
            || normalized.contains("rate")
            || normalized.contains("quota")
        let hasWaitChoice = recentLines.contains(where: isClaudeRateLimitWaitChoiceLine)
            || normalized.contains("stop and wait")
        let hasSwitchChoice = recentLines.contains(where: isClaudeRateLimitSwitchChoiceLine)
            || normalized.contains("switch to extra usage")
            || normalized.contains("switch to max")
            || normalized.contains("switch to pro")

        return (hasWaitChoice && hasSwitchChoice)
            || (hasLimitContext && (hasWaitChoice || hasSwitchChoice))
    }

    private static let codexBusyHeuristicSelfCheck: Void = {
        assert(
            isCodexBusyStatusLine("• esc to interrupt)"),
            "Codex busy heuristic failed: interrupt marker should be busy"
        )
        assert(
            isCodexBusyStatusLine("Working (35m 47s • esc to interrupt) · 1 background terminal running"),
            "Codex busy heuristic failed: Working line with background terminal should be busy"
        )
        assert(
            !isCodexBusyStatusLine("› Write tests for @filename"),
            "Codex busy heuristic failed: prompt line should not be busy"
        )
    }()

    private func paneShowsEscToInterrupt(sessionName: String) async -> Bool {
#if DEBUG
        Self.codexBusyHeuristicSelfCheck
#endif
        // Capture fresh pane content for busy checks so cache TTL doesn't delay
        // spinner transitions during active Codex runs.
        let freshContent = await tmux.capturePane(sessionName: sessionName, lastLines: 200)
        let paneContent: String
        if let freshContent {
            paneContent = freshContent
        } else if let cachedContent = await tmux.cachedCapturePane(sessionName: sessionName, lastLines: 200) {
            paneContent = cachedContent
        } else {
            return false
        }

        return paneContentShowsCodexBusyStatus(paneContent)
    }

    private func paneContentSupportsAgentHint(sessionName: String, hintedAgent: AgentType) async -> Bool {
        guard let paneContent = await tmux.cachedCapturePane(sessionName: sessionName, lastLines: 120) else {
            return false
        }
        switch hintedAgent {
        case .codex:
            // Hinting from idle prompts is too ambiguous (shell themes can use ›/❯).
            // Only retain a codex hint when active busy markers are visible.
            return paneContentShowsCodexBusyStatus(paneContent)
        case .claude:
            // Hinting from idle prompts is too ambiguous (shell themes can use ›/❯).
            // Only retain a claude hint when the active busy marker is visible.
            return paneContentShowsEscToInterrupt(paneContent)
        case .custom:
            return false
        }
    }

    private func paneContentShowsCodexBusyStatus(_ paneContent: String) -> Bool {
        recentNonEmptyLines(from: paneContent, maxLines: 25).contains(where: Self.isCodexBusyStatusLine)
    }

    private static func isCodexBusyStatusLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("• esc to interrupt)") { return true }
        if normalized.contains("working (") && normalized.contains("esc to interrupt") { return true }
        if normalized.contains("working (") && normalized.contains("background terminal running") { return true }
        if normalized.contains("background terminal running") { return true }
        return false
    }

    private func latestScopeLines(from paneContent: String) -> [String] {
        let lines = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        let scopeSeparatorIndex = lines.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 20 else { return false }
            return trimmed.allSatisfy { $0 == "─" }
        })

        let latestScopeStart = scopeSeparatorIndex.map { lines.index(after: $0) } ?? lines.startIndex
        return Array(lines[latestScopeStart...])
    }

    private func recentNonEmptyLines(from paneContent: String, maxLines: Int) -> [String] {
        guard maxLines > 0 else { return [] }
        var lines = latestScopeLines(from: paneContent)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        let nonEmpty = lines.filter { !$0.isEmpty }
        if nonEmpty.count <= maxLines { return nonEmpty }
        return Array(nonEmpty.suffix(maxLines))
    }

    // MARK: - Unsubmitted Input Detection

    /// Number of lines to capture for unsubmitted-input detection. Matches the
    /// prompt-readiness capture depth so tall panes don't cause false negatives.
    private static let unsubmittedInputCaptureLines = 120

    /// Checks whether the agent prompt has user-typed (non-placeholder) text that
    /// hasn't been submitted. Uses a two-phase approach to avoid a full ANSI tmux
    /// capture on every tick:
    /// 1. Quick check: if the already-cached plain-text capture shows the prompt
    ///    line is bare (marker only, no trailing text), skip the ANSI capture.
    /// 2. Full check: ANSI-aware capture to distinguish dim placeholder from real input.
    private func checkForUnsubmittedInput(sessionName: String, agentType: AgentType) async -> Bool {
        let marker: String
        switch agentType {
        case .claude: marker = "\u{276F}"  // ❯
        case .codex:  marker = "\u{203A}"  // ›
        case .custom: return false
        }

        // Phase 1: quick pre-filter using the already-cached plain-text capture.
        // If the prompt line has no text after the marker, there's nothing to protect.
        if let plainContent = await tmux.cachedCapturePane(
            sessionName: sessionName,
            lastLines: Self.unsubmittedInputCaptureLines
        ) {
            let plainLines = plainContent
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let lastPrompt = plainLines.last(where: { $0.hasPrefix(marker) }) {
                let afterMarker = lastPrompt.dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespaces)
                if afterMarker.isEmpty {
                    return false  // bare prompt — no input to protect
                }
            }
        }

        // Phase 2: ANSI-aware capture to distinguish placeholder from real input.
        guard let ansiContent = await tmux.capturePaneWithEscapes(
            sessionName: sessionName,
            lastLines: Self.unsubmittedInputCaptureLines
        ) else {
            return false
        }

        let lines = ansiContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let promptLine = lines.last(where: {
            ThreadManager.stripAnsiEscapes($0).trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }) else {
            return false
        }

        // isPromptLineEmpty returns true when text after marker is absent or placeholder (dim).
        // If it returns false, the user has typed real input.
        return !ThreadManager.isPromptLineEmpty(promptLine, marker: marker)
    }

    /// Updates the `hasUnsubmittedInputSessions` set for a thread+session based on
    /// ANSI-aware prompt inspection. Returns true if the set changed.
    @discardableResult
    private func syncUnsubmittedInputState(
        threadId: UUID,
        sessionName: String,
        agentType: AgentType
    ) async -> Bool {
        let hasInput = await checkForUnsubmittedInput(sessionName: sessionName, agentType: agentType)
        guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { return false }
        if hasInput {
            if !store.threads[i].hasUnsubmittedInputSessions.contains(sessionName) {
                store.threads[i].hasUnsubmittedInputSessions.insert(sessionName)
                return true
            }
        } else {
            if store.threads[i].hasUnsubmittedInputSessions.contains(sessionName) {
                store.threads[i].hasUnsubmittedInputSessions.remove(sessionName)
                return true
            }
        }
        return false
    }

    // MARK: - Mark Completion / Waiting / Busy

    @MainActor
    func markThreadCompletionSeen(threadId: UUID) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        // Use the raw set, not `hasUnreadAgentCompletion`, so we still clear unread
        // sessions when the thread happens to be busy.
        guard !store.threads[index].unreadCompletionSessions.isEmpty else { return }
        store.threads[index].unreadCompletionSessions.removeAll()
        persistence.debouncedSaveActiveThreads(store.threads)
        updateDockBadge?()
        onThreadsChanged?()
        postCompletionChangedNotification(for: store.threads[index])
    }

    @MainActor
    @discardableResult
    func markAllThreadCompletionsSeen() -> Int {
        var changedThreadIds = [UUID]()
        var changedCount = 0
        for index in store.threads.indices where !store.threads[index].unreadCompletionSessions.isEmpty {
            store.threads[index].unreadCompletionSessions.removeAll()
            changedThreadIds.append(store.threads[index].id)
            changedCount += 1
        }
        guard changedCount > 0 else { return 0 }
        persistence.debouncedSaveActiveThreads(store.threads)
        updateDockBadge?()
        onThreadsChanged?()
        for threadId in changedThreadIds {
            if let index = store.threads.firstIndex(where: { $0.id == threadId }) {
                postCompletionChangedNotification(for: store.threads[index])
            }
        }
        return changedCount
    }

    @MainActor
    func markSessionCompletionSeen(threadId: UUID, sessionName: String) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard store.threads[index].unreadCompletionSessions.contains(sessionName) else { return }
        store.threads[index].unreadCompletionSessions.remove(sessionName)
        persistence.debouncedSaveActiveThreads(store.threads)
        updateDockBadge?()
        onThreadsChanged?()
        postCompletionChangedNotification(for: store.threads[index])
    }

    @MainActor
    func markSessionRateLimitSeen(threadId: UUID, sessionName: String) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard store.threads[index].unreadRateLimitSessions.contains(sessionName) else { return }
        store.threads[index].unreadRateLimitSessions.remove(sessionName)
        onThreadsChanged?()
    }

    @MainActor
    func markSessionWaitingSeen(threadId: UUID, sessionName: String) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard store.threads[index].waitingForInputSessions.contains(sessionName) else { return }
        store.threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        rateLimitLiftPendingResumeSessions.remove(sessionName)
        updateDockBadge?()
        onThreadsChanged?()
    }

    @MainActor
    func markSessionBusy(threadId: UUID, sessionName: String) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard store.threads[index].agentTmuxSessions.contains(sessionName) else { return }
        // Clear waiting/unsubmitted state — user submitted a prompt (or agent auto-resumed)
        store.threads[index].waitingForInputSessions.remove(sessionName)
        store.threads[index].hasUnsubmittedInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        rateLimitLiftPendingResumeSessions.remove(sessionName)
        guard !store.threads[index].busySessions.contains(sessionName) else { return }
        store.threads[index].busySessions.insert(sessionName)
        onThreadsChanged?()
        if let thread = store.threads.first(where: { $0.id == threadId }) {
            postBusySessionsChanged?(thread)
        }
    }

    // MARK: - Busy Sessions Notification

    @MainActor
    func postBusySessionsChangedNotification(for thread: MagentThread) {
        NotificationCenter.default.post(
            name: .magentAgentBusySessionsChanged,
            object: nil,
            userInfo: [
                "threadId": thread.id,
                "busySessions": thread.busySessions
            ]
        )
    }

    @MainActor
    private func postCompletionChangedNotification(for thread: MagentThread) {
        NotificationCenter.default.post(
            name: .magentAgentCompletionDetected,
            object: nil,
            userInfo: [
                "threadId": thread.id,
                "unreadSessions": thread.unreadCompletionSessions,
            ]
        )
    }

    // MARK: - Session-State Rekey/Prune

    /// Rekeys transient, session-scoped state after tmux session renames.
    /// Keeps only sessions that are still agent tabs for this thread.
    @discardableResult
    func remapTransientSessionState(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        guard store.threads.indices.contains(index) else { return false }
        guard !sessionRenameMap.isEmpty else { return false }

        var changed = false
        let validAgentSessions = Set(store.threads[index].agentTmuxSessions)

        let remappedBusy = Set(
            store.threads[index].busySessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedBusy != store.threads[index].busySessions {
            store.threads[index].busySessions = remappedBusy
            changed = true
        }

        let remappedWaiting = Set(
            store.threads[index].waitingForInputSessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedWaiting != store.threads[index].waitingForInputSessions {
            store.threads[index].waitingForInputSessions = remappedWaiting
            changed = true
        }

        // Re-key magentBusySessions — filter against all tmux sessions (not just agent ones)
        // since magent busy applies to any session during injection/setup.
        let validAllSessions = Set(store.threads[index].tmuxSessionNames)
        let remappedMagentBusy = Set(
            store.threads[index].magentBusySessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAllSessions.contains($0) || $0 == MagentThread.threadSetupSentinel }
        )
        if remappedMagentBusy != store.threads[index].magentBusySessions {
            store.threads[index].magentBusySessions = remappedMagentBusy
            changed = true
        }

        let remappedUnsubmitted = Set(
            store.threads[index].hasUnsubmittedInputSessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedUnsubmitted != store.threads[index].hasUnsubmittedInputSessions {
            store.threads[index].hasUnsubmittedInputSessions = remappedUnsubmitted
            changed = true
        }

        // Keep notification dedup state and rate-limit-resume state aligned with waiting sessions after rename.
        let renamedTargets = Set(sessionRenameMap.values)
        for (oldName, newName) in sessionRenameMap where notifiedWaitingSessions.remove(oldName) != nil {
            if remappedWaiting.contains(newName) {
                notifiedWaitingSessions.insert(newName)
            }
        }
        for (oldName, newName) in sessionRenameMap where rateLimitLiftPendingResumeSessions.remove(oldName) != nil {
            if remappedWaiting.contains(newName) {
                rateLimitLiftPendingResumeSessions.insert(newName)
            }
        }
        for target in renamedTargets where !remappedWaiting.contains(target) {
            notifiedWaitingSessions.remove(target)
            rateLimitLiftPendingResumeSessions.remove(target)
        }

        // Re-key runtime agent detection cache so renamed sessions keep their cached type.
        for (oldName, newName) in sessionRenameMap {
            if let cached = sessionTracker.lastRuntimeDetectedAgentBySession.removeValue(forKey: oldName) {
                sessionTracker.lastRuntimeDetectedAgentBySession[newName] = cached
            }
        }

        // Rekey terminal-corruption markers so warnings follow renamed sessions.
        for (oldName, newName) in sessionRenameMap {
            if sessionTracker.rendererUnhealthySessions.remove(oldName) != nil {
                sessionTracker.rendererUnhealthySessions.insert(newName)
            }
            if sessionTracker.replayCorruptedSessions.remove(oldName) != nil {
                sessionTracker.replayCorruptedSessions.insert(newName)
            }
        }

        return changed
    }

    /// Removes stale transient session state that references non-agent sessions.
    /// Returns true when any thread-visible state changed.
    @discardableResult
    func pruneTransientSessionStateToKnownAgentSessions(threadIndex index: Int) -> Bool {
        guard store.threads.indices.contains(index) else { return false }

        var changed = false
        let validAgentSessions = Set(store.threads[index].agentTmuxSessions)

        let prunedBusy = store.threads[index].busySessions.intersection(validAgentSessions)
        if prunedBusy != store.threads[index].busySessions {
            store.threads[index].busySessions = prunedBusy
            changed = true
        }

        let oldWaiting = store.threads[index].waitingForInputSessions
        let prunedWaiting = oldWaiting.intersection(validAgentSessions)
        if prunedWaiting != oldWaiting {
            let removed = oldWaiting.subtracting(prunedWaiting)
            for session in removed {
                notifiedWaitingSessions.remove(session)
                rateLimitLiftPendingResumeSessions.remove(session)
            }
            store.threads[index].waitingForInputSessions = prunedWaiting
            changed = true
        }

        // Prune magentBusySessions against all known tmux sessions + the setup sentinel.
        let validMagentTargets = Set(store.threads[index].tmuxSessionNames)
            .union([MagentThread.threadSetupSentinel])
        let prunedMagentBusy = store.threads[index].magentBusySessions.intersection(validMagentTargets)
        if prunedMagentBusy != store.threads[index].magentBusySessions {
            store.threads[index].magentBusySessions = prunedMagentBusy
            changed = true
        }

        let prunedUnsubmitted = store.threads[index].hasUnsubmittedInputSessions.intersection(validAgentSessions)
        if prunedUnsubmitted != store.threads[index].hasUnsubmittedInputSessions {
            store.threads[index].hasUnsubmittedInputSessions = prunedUnsubmitted
            changed = true
        }

        // Corruption markers apply to all tmux sessions (agent + plain terminal),
        // so prune against all known sessions across every thread.
        let allKnownSessionNames = Set(store.threads.flatMap(\.tmuxSessionNames))
        let prunedRendererUnhealthy = sessionTracker.rendererUnhealthySessions.intersection(allKnownSessionNames)
        if prunedRendererUnhealthy != sessionTracker.rendererUnhealthySessions {
            sessionTracker.rendererUnhealthySessions = prunedRendererUnhealthy
        }
        let prunedReplayCorrupted = sessionTracker.replayCorruptedSessions.intersection(allKnownSessionNames)
        if prunedReplayCorrupted != sessionTracker.replayCorruptedSessions {
            sessionTracker.replayCorruptedSessions = prunedReplayCorrupted
        }

        return changed
    }
}
