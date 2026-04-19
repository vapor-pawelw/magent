import AppKit
import Foundation
import UserNotifications
import MagentCore

@MainActor
protocol ThreadManagerDelegate: AnyObject {
    func threadManager(_ manager: ThreadManager, didCreateThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didArchiveThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didDeleteThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didUpdateThreads threads: [MagentThread])
}

final class ThreadManager {
    static let maxFavoriteThreadCount = 10

    struct StatusSyncResult {
        let hadErrors: Bool
        let failureSummary: String?

        static let success = StatusSyncResult(hadErrors: false, failureSummary: nil)

        static func failure(_ summary: String?) -> StatusSyncResult {
            StatusSyncResult(hadErrors: true, failureSummary: summary)
        }
    }

    struct InitialPromptInjectionFailureInfo {
        let prompt: String
        let shouldSubmitInitialPrompt: Bool
        let agentType: AgentType?
        let requiresAgentRelaunch: Bool
    }

    struct BaseBranchReset: Sendable {
        let oldBase: String
        let newBase: String
    }

    struct PendingPromptRecoveryInfo {
        let tempFileURL: URL
        let prompt: String
        let agentType: AgentType?
        let projectId: UUID
        let modelId: String?
        let reasoningLevel: String?
    }

    static let shared = ThreadManager()

    weak var delegate: ThreadManagerDelegate?

    let persistence = PersistenceService.shared
    let git = GitService.shared
    let tmux = TmuxService.shared

    // MARK: - Extracted service containers (Phase 1)

    let store = ThreadStore()
    let sessionTracker = SessionTracker()

    // MARK: - Extracted service containers (Phase 2)

    lazy var rateLimitService: RateLimitService = {
        let svc = RateLimitService(store: store, persistence: persistence, tmux: tmux)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        svc.resolveAgentType = { [weak self] thread, sessionName in
            self?.agentType(for: thread, sessionName: sessionName)
        }
        // Wire the resume-needed callback so clearing a rate limit can inject
        // per-session waiting markers and dedup state back into ThreadManager.
        svc.onRateLimitLiftResumeNeeded = { [weak self] sessions in
            guard let self else { return }
            self.rateLimitLiftPendingResumeSessions.formUnion(sessions)
            self.notifiedWaitingSessions.formUnion(sessions)
        }
        return svc
    }()

    lazy var pullRequestService: PullRequestService = {
        let svc = PullRequestService(store: store, persistence: persistence, git: git)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        svc.resolveBaseBranch = { [weak self] thread in
            self?.resolveBaseBranch(for: thread) ?? ""
        }
        svc.cachedRemoteResolver = { [weak self] projectId, repoPath in
            await self?.cachedPullRequestRemote(for: projectId, repoPath: repoPath)
        }
        svc.formatFailureSummary = { [weak self] title, details, total in
            self?.statusSyncFailureSummary(title: title, details: details, totalCount: total) ?? "\(title)."
        }
        return svc
    }()

    lazy var jiraIntegrationService: JiraIntegrationService = {
        let svc = JiraIntegrationService(store: store, persistence: persistence)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        return svc
    }()

    lazy var sidebarOrderingService: SidebarOrderingService = {
        let svc = SidebarOrderingService(store: store, persistence: persistence)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        return svc
    }()

    lazy var gitStateService: GitStateService = {
        let svc = GitStateService(store: store, persistence: persistence, tmux: tmux, git: git)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        svc.onBranchesChanged = { [weak self] changedIds in
            await self?.verifyDetectedJiraTickets(forThreadIds: changedIds)
        }
        svc.onBranchSymlinkNeeded = { [weak self] branchName, worktreePath, worktreesBasePath in
            self?.ensureBranchSymlink(
                branchName: branchName,
                worktreePath: worktreePath,
                worktreesBasePath: worktreesBasePath
            )
        }
        svc.cachedRemoteResolver = { [weak self] projectId in
            self?._cachedRemoteByProjectId[projectId]
        }
        return svc
    }()

    lazy var worktreeService: WorktreeService = {
        let svc = WorktreeService(store: store, persistence: persistence, tmux: tmux, git: git)
        svc.onThreadsChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.threadManager(self, didUpdateThreads: self.store.threads)
        }
        return svc
    }()

    // MARK: - ThreadStore forwarding

    var threads: [MagentThread] {
        get { store.threads }
        set { store.threads = newValue }
    }
    var activeThreadId: UUID? {
        get { store.activeThreadId }
        set { store.activeThreadId = newValue }
    }
    var pendingThreadIds: Set<UUID> {
        get { store.pendingThreadIds }
        set { store.pendingThreadIds = newValue }
    }
    /// When true, the next `didCreateThread` delegate call will skip sidebar auto-selection.
    var skipNextAutoSelect: Bool {
        get { store.skipNextAutoSelect }
        set { store.skipNextAutoSelect = newValue }
    }

    // MARK: - SessionTracker forwarding

    var knownGoodSessionContexts: [String: KnownGoodSessionContext] {
        get { sessionTracker.knownGoodSessionContexts }
        set { sessionTracker.knownGoodSessionContexts = newValue }
    }
    var sessionLastVisitedAt: [String: Date] {
        get { sessionTracker.sessionLastVisitedAt }
        set { sessionTracker.sessionLastVisitedAt = newValue }
    }
    var sessionLastBusyAt: [String: Date] {
        get { sessionTracker.sessionLastBusyAt }
        set { sessionTracker.sessionLastBusyAt = newValue }
    }
    var evictedIdleSessions: Set<String> {
        get { sessionTracker.evictedIdleSessions }
        set { sessionTracker.evictedIdleSessions = newValue }
    }
    var sessionsBeingRecreated: Set<String> {
        get { sessionTracker.sessionsBeingRecreated }
        set { sessionTracker.sessionsBeingRecreated = newValue }
    }

    // MARK: - RateLimitService forwarding

    var globalAgentRateLimits: [AgentType: AgentRateLimitInfo] {
        get { rateLimitService.globalAgentRateLimits }
        set { rateLimitService.globalAgentRateLimits = newValue }
    }
    var rateLimitFingerprintCache: [String: RateLimitCacheEntry] {
        get { rateLimitService.rateLimitFingerprintCache }
        set { rateLimitService.rateLimitFingerprintCache = newValue }
    }
    var ignoredRateLimitFingerprintsByAgent: [AgentType: Set<String>] {
        get { rateLimitService.ignoredRateLimitFingerprintsByAgent }
        set { rateLimitService.ignoredRateLimitFingerprintsByAgent = newValue }
    }
    var rateLimitCacheLoaded: Bool {
        get { rateLimitService.rateLimitCacheLoaded }
        set { rateLimitService.rateLimitCacheLoaded = newValue }
    }
    var rateLimitCacheDirty: Bool {
        get { rateLimitService.rateLimitCacheDirty }
        set { rateLimitService.rateLimitCacheDirty = newValue }
    }
    var ignoredRateLimitCacheLoaded: Bool {
        get { rateLimitService.ignoredRateLimitCacheLoaded }
        set { rateLimitService.ignoredRateLimitCacheLoaded = newValue }
    }
    var ignoredRateLimitCacheDirty: Bool {
        get { rateLimitService.ignoredRateLimitCacheDirty }
        set { rateLimitService.ignoredRateLimitCacheDirty = newValue }
    }
    var lastPublishedRateLimitSummary: String? {
        get { rateLimitService.lastPublishedRateLimitSummary }
        set { rateLimitService.lastPublishedRateLimitSummary = newValue }
    }
    var lastRateLimitScanBySession: [String: Date] {
        get { rateLimitService.lastRateLimitScanBySession }
        set { rateLimitService.lastRateLimitScanBySession = newValue }
    }

    // MARK: - PullRequestService forwarding

    var isPRSyncRunning: Bool {
        get { pullRequestService.isPRSyncRunning }
        set { pullRequestService.isPRSyncRunning = newValue }
    }
    var prCache: [String: PullRequestCacheEntry] {
        get { pullRequestService.prCache }
        set { pullRequestService.prCache = newValue }
    }
    var prCacheLoaded: Bool {
        get { pullRequestService.prCacheLoaded }
        set { pullRequestService.prCacheLoaded = newValue }
    }

    // MARK: - JiraIntegrationService forwarding

    var jiraTicketCache: [String: JiraTicketCacheEntry] {
        get { jiraIntegrationService.jiraTicketCache }
        set { jiraIntegrationService.jiraTicketCache = newValue }
    }
    var jiraTicketCacheLoaded: Bool {
        get { jiraIntegrationService.jiraTicketCacheLoaded }
        set { jiraIntegrationService.jiraTicketCacheLoaded = newValue }
    }
    var isJiraVerificationRunning: Bool {
        get { jiraIntegrationService.isJiraVerificationRunning }
        set { jiraIntegrationService.isJiraVerificationRunning = newValue }
    }
    var _jiraProjectStatusesCache: [String: [JiraProjectStatus]] {
        get { jiraIntegrationService._jiraProjectStatusesCache }
        set { jiraIntegrationService._jiraProjectStatusesCache = newValue }
    }
    var _jiraProjectStatusesCacheLoaded: Bool {
        get { jiraIntegrationService._jiraProjectStatusesCacheLoaded }
        set { jiraIntegrationService._jiraProjectStatusesCacheLoaded = newValue }
    }

    // MARK: - GitStateService forwarding

    var baseBranchResets: [UUID: BaseBranchReset] {
        get { gitStateService.baseBranchResets }
        set { gitStateService.baseBranchResets = newValue }
    }

    // MARK: - Remaining inline state (extracted in later phases)

    /// Dedupes completion attention events across legacy bell sources and the
    /// synthetic busy->idle completion path.
    var recentBellBySession: [String: Date] = [:]
    var autoRenameInProgress: Set<UUID> = []
    /// Tracks threads for which an auto-rename failure banner has already been shown this session.
    var autoRenameFailedBannerShownThreadIds: Set<UUID> = []
    var initialPromptInjectionFailuresBySession: [String: InitialPromptInjectionFailureInfo] = [:]
    /// Sessions that have a prompt queued and are waiting for the agent to become ready.
    var pendingPromptInjectionSessions: [String: InitialPromptInjectionFailureInfo] = [:]
    /// In-flight injection tasks, keyed by session name. Used to cancel polling when
    /// the user triggers manual "Inject Now" from the pending-prompt banner.
    var pendingPromptInjectionTasks: [String: Task<Void, Never>] = [:]
    /// Timestamp of the last successful prompt-bearing injection per session.
    /// Lets callers wait for the actual tmux send to complete before renaming sessions.
    var initialPromptInjectionCompletionsBySession: [String: Date] = [:]
    /// One-shot guard for launch-time auto-recovery when an agent exits back to shell
    /// before the retained initial prompt can be injected.
    var initialPromptAutoRelaunchAttempts: Set<String> = []
    /// Per-thread cache of AI-generated rename payloads, keyed by normalized prompt.
    /// Avoids repeat agent calls when the same prompt is re-used for rename on the same thread.
    /// Cleared when a thread is archived or deleted.
    var promptRenameResultCache: [UUID: [String: CachedRenameResult]] = [:]
    /// Dedup tracker — prevents repeated "waiting for input" notifications for the same session.
    var notifiedWaitingSessions: Set<String> = []
    /// Sessions that had a rate limit lifted and still need the user to visit and continue work.
    /// Protects those entries in waitingForInputSessions from being auto-cleared by
    /// checkForWaitingForInput (which normally clears on idle prompt, not interactive prompt).
    var rateLimitLiftPendingResumeSessions: Set<String> = []
    // baseBranchResets is forwarded to gitStateService — see forwarding computed property below.
    var sessionMonitorTimer: Timer?
    var isSessionMonitorTickRunning = false
    var lastStaleSessionCleanupAt: Date = .distantPast
    var staleMagentSessionsFirstSeenAt: [String: Date] = [:]
    var lastTmuxZombieHealthCheckAt: Date = .distantPast
    var lastTmuxZombieSummary: TmuxService.ZombieParentSummary?
    var didShowTmuxZombieWarning = false
    var isRestartingTmuxForRecovery = false
    var _slowTickCounter: Int = 0
    var dirtyCheckTickCounter: Int = 0
    var _jiraSyncTickCounter: Int = 0
    var _prSyncTickCounter: Int = 0
    /// Timestamp of the last completed PR + Jira background sync pass.
    var lastStatusSyncAt: Date?
    /// Whether the last sync pass encountered errors (network, auth, etc.).
    var lastStatusSyncFailed = false
    /// Human-readable summary of the most recent sync failure, used by the status bar.
    var lastStatusSyncFailureSummary: String?
    var _cachedRemoteByProjectId: [UUID: GitRemote] = [:]
    /// Pending prompt recoveries for .newTab entries, keyed by thread ID.
    /// Stored at launch and shown as embedded banners when the thread is selected.
    var pendingPromptRecoveriesByThread: [UUID: [PendingPromptRecoveryInfo]] = [:]
    /// Caches the last runtime-detected agent type per session. When `ps` child-process
    /// detection transiently fails (e.g. Claude reports its version as `pane_current_command`
    /// instead of "claude"), this prevents the session from flipping to `nil` and losing busy state.
    /// Entries expire after `lastRuntimeDetectedAgentTTL` seconds of consecutive nil detections.
    var lastRuntimeDetectedAgentBySession: [String: (agent: AgentType, detectedAt: Date)] = [:]
    static let lastRuntimeDetectedAgentTTL: TimeInterval = 60

    // MARK: - Lifecycle

    func loadThreads() {
        threads = persistence.loadThreads().filter { !$0.isArchived }
    }

    func primePersistedThreadsForLaunch() {
        loadThreads()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    func restoreThreads() async {
        loadThreads()
        installClaudeHooksSettings()
        ensureCodexBellNotification()
        let preSettings = persistence.loadSettings()
        if preSettings.ipcPromptInjectionEnabled {
            installCodexIPCInstructions()
        }

        // Migrate old threads that have no agentTmuxSessions recorded.
        // Heuristic: the first session was always created as the agent tab.
        let settings = persistence.loadSettings()
        var didMigrate = false
        for i in threads.indices {
            if threads[i].agentTmuxSessions.isEmpty && !threads[i].tmuxSessionNames.isEmpty {
                threads[i].agentTmuxSessions = [threads[i].tmuxSessionNames[0]]
                didMigrate = true
            }
            // Migrate: existing threads with agent sessions must have had the agent run.
            if !threads[i].agentHasRun && !threads[i].agentTmuxSessions.isEmpty {
                threads[i].agentHasRun = true
                didMigrate = true
            }
            // Keep persisted conversation IDs only for known agent sessions.
            let validAgentSessions = Set(threads[i].agentTmuxSessions)
            let filteredConversationIDs = threads[i].sessionConversationIDs.filter { validAgentSessions.contains($0.key) }
            if filteredConversationIDs.count != threads[i].sessionConversationIDs.count {
                threads[i].sessionConversationIDs = filteredConversationIDs
                didMigrate = true
            }
            let validSessions = Set(threads[i].tmuxSessionNames)
            let filteredSessionCreatedAts = threads[i].sessionCreatedAts.filter { validSessions.contains($0.key) }
            if filteredSessionCreatedAts.count != threads[i].sessionCreatedAts.count {
                threads[i].sessionCreatedAts = filteredSessionCreatedAts
                didMigrate = true
            }
            let filteredFreshSessions = Set(threads[i].freshAgentSessions.filter { validAgentSessions.contains($0) })
            if filteredFreshSessions.count != threads[i].freshAgentSessions.count {
                threads[i].freshAgentSessions = filteredFreshSessions
                didMigrate = true
            }
            if await migrateSessionAgentTypes(threadIndex: i) {
                didMigrate = true
            }
            if pruneSessionAgentTypesToKnownSessions(threadIndex: i) {
                didMigrate = true
            }
            if pruneSubmittedPromptHistoryToKnownSessions(threadIndex: i) {
                didMigrate = true
            }
            // Protect pre-existing custom tab names from auto-model-detection rewrites.
            // manuallyRenamedTabs decodes as [] from older JSON, so this runs once per
            // session on the first launch after the feature ships and is then a no-op
            // (the set is persisted and already contains the session on subsequent launches).
            for session in threads[i].tmuxSessionNames {
                guard !threads[i].manuallyRenamedTabs.contains(session) else { continue }
                let agentType = threads[i].sessionAgentTypes[session]
                let name = threads[i].customTabNames[session] ?? ""
                if !name.isEmpty && !TmuxSessionNaming.looksLikeDefaultTabName(name, for: agentType) {
                    threads[i].manuallyRenamedTabs.insert(session)
                    didMigrate = true
                }
            }
        }

        // Do NOT prune dead tmux session names — the attach-or-create pattern
        // in ThreadDetailViewController will recreate them when the user opens the thread.

        if didMigrate {
            try? persistence.saveActiveThreads(threads)
        }

        // Migrate session names from old magent- prefix to new ma- format
        await migrateSessionNamesToNewFormat()

        // Sync threads with worktrees on disk for each valid project
        for project in settings.projects where project.isValid {
            await syncThreadsWithWorktrees(for: project)
        }

        // Ensure every project has a main thread
        await ensureMainThreads()

        // Remove orphaned Magent tmux sessions that no longer map to an active thread/tab.
        await cleanupStaleMagentSessions()

        // Set up bell detection pipes on all live agent sessions.
        await ensureBellPipes()

        // Consume bell events that accumulated while the app was not running.
        // We map them to unread completion state at startup (instead of dropping
        // them), and intentionally do not touch recentBellBySession here so busy
        // process re-detection is not suppressed on relaunch.
        let startupCompletionSessions = await tmux.consumeAgentCompletionSessions()
        applyStartupCompletionSessions(startupCompletionSessions)

        // Seed visit timestamps so no sessions are evicted immediately after launch.
        let launchNow = Date()
        for thread in threads where !thread.isArchived {
            for session in thread.tmuxSessionNames {
                sessionLastVisitedAt[session] = launchNow
            }
        }

        // Sync busy state from actual tmux processes so spinners show immediately
        // after restart (busySessions is transient and starts empty on launch).
        await syncBusySessionsFromProcessState()

        // Populate dirty, delivered, and branch states at launch so indicators show immediately.
        await refreshDirtyStates()
        await refreshDeliveredStates()
        await refreshBranchStates()
        await verifyDetectedJiraTickets()
        populatePRInfoFromCache()
        let prSyncResult = await runPRSyncTick()
        lastStatusSyncAt = Date()
        lastStatusSyncFailed = prSyncResult.hadErrors
        lastStatusSyncFailureSummary = prSyncResult.failureSummary

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            NotificationCenter.default.post(name: .magentStatusSyncCompleted, object: nil)
        }
    }

    /// Applies completion events collected during app downtime.
    /// This preserves unread completion indicators after relaunch without
    /// affecting transient busy/waiting state derived from live tmux processes.
    private func applyStartupCompletionSessions(_ sessions: [String]) {
        guard !sessions.isEmpty else { return }

        let now = Date()
        let orderedUniqueSessions = sessions.reduce(into: [String]()) { result, session in
            if !result.contains(session) {
                result.append(session)
            }
        }

        var changed = false
        for session in orderedUniqueSessions {
            guard let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) else {
                continue
            }

            threads[index].lastAgentCompletionAt = now
            bumpThreadToTopOfSection(threads[index].id)

            let isActiveThread = threads[index].id == activeThreadId
            let isActiveTab = isActiveThread && threads[index].lastSelectedTabIdentifier == session
            if !isActiveTab {
                threads[index].unreadCompletionSessions.insert(session)
            }
            changed = true
        }

        if changed {
            try? persistence.saveActiveThreads(threads)
        }
    }
}

extension ThreadManager {
    func statusSyncFailureSummary(title: String, details: [String], totalCount: Int? = nil) -> String {
        let cleanedDetails = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedTotal = max(totalCount ?? cleanedDetails.count, cleanedDetails.count)

        guard !cleanedDetails.isEmpty else {
            return resolvedTotal > 0 ? "\(title) (\(resolvedTotal) error\(resolvedTotal == 1 ? "" : "s"))." : "\(title)."
        }

        var lines = ["\(title):"]
        for detail in cleanedDetails.prefix(3) {
            lines.append("- \(detail)")
        }

        let remaining = resolvedTotal - min(cleanedDetails.count, 3)
        if remaining > 0 {
            lines.append("- \(remaining) more error\(remaining == 1 ? "" : "s")")
        }

        return lines.joined(separator: "\n")
    }

    func mergeStatusSyncFailureSummaries(_ summaries: [String]) -> String? {
        let cleaned = summaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return cleaned.joined(separator: "\n\n")
    }
}
