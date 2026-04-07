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

    var threads: [MagentThread] = []
    var pendingThreadIds: Set<UUID> = []
    /// When true, the next `didCreateThread` delegate call will skip sidebar auto-selection.
    /// Set by the IPC handler for `--no-select`; consumed and reset by the delegate.
    var skipNextAutoSelect: Bool = false
    var activeThreadId: UUID?
    /// Dedupes completion attention events across legacy bell sources and the
    /// synthetic busy->idle completion path.
    var recentBellBySession: [String: Date] = [:]
    var autoRenameInProgress: Set<UUID> = []
    /// Tracks threads for which an auto-rename failure banner has already been shown this session.
    var autoRenameFailedBannerShownThreadIds: Set<UUID> = []
    var knownGoodSessionContexts: [String: KnownGoodSessionContext] = [:]
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
    /// Global per-agent rate-limit cache (Claude/Codex), shared across all tabs/threads.
    var globalAgentRateLimits: [AgentType: AgentRateLimitInfo] = [:]
    /// Persisted cache of seen rate-limit fingerprints → concrete resetAt dates.
    /// Prevents re-detecting stale messages after restart and anchors relative/bare-time
    /// reset phrases to the concrete Date they were first computed at.
    /// Time-only entries (no date anchor) are kept as tombstones after expiry to prevent
    /// stale pane text like "resets 11am" from being re-anchored daily.
    var rateLimitFingerprintCache: [String: RateLimitCacheEntry] = [:]
    /// Persisted allowlist of fingerprints the user manually ignored per agent.
    var ignoredRateLimitFingerprintsByAgent: [AgentType: Set<String>] = [:]
    var rateLimitCacheLoaded = false
    /// Tracks threads whose base branch was missing and got reset to project default.
    /// Keyed by thread ID, consumed when the user selects the thread (banner shown once).
    var baseBranchResets: [UUID: BaseBranchReset] = [:]
    var rateLimitCacheDirty = false
    var ignoredRateLimitCacheLoaded = false
    var ignoredRateLimitCacheDirty = false
    var lastPublishedRateLimitSummary: String?
    /// Tracks when each tmux session was last viewed by the user (tab selected).
    var sessionLastVisitedAt: [String: Date] = [:]
    /// Tracks when each tmux session last transitioned from busy to idle.
    var sessionLastBusyAt: [String: Date] = [:]
    /// Sessions intentionally killed by idle eviction. checkForDeadSessions skips these;
    /// cleared when the user revisits the thread, allowing on-demand recreation.
    var evictedIdleSessions: Set<String> = []
    var sessionsBeingRecreated: Set<String> = []
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
    var isPRSyncRunning = false
    /// Timestamp of the last completed PR + Jira background sync pass.
    var lastStatusSyncAt: Date?
    /// Whether the last sync pass encountered errors (network, auth, etc.).
    var lastStatusSyncFailed = false
    /// Human-readable summary of the most recent sync failure, used by the status bar.
    var lastStatusSyncFailureSummary: String?
    /// Tracks when each tmux session was last scanned for rate-limit text.
    /// Used to throttle non-active-session scans to once every 15 seconds.
    var lastRateLimitScanBySession: [String: Date] = [:]
    var _cachedRemoteByProjectId: [UUID: GitRemote] = [:]
    var _mismatchBannerShownProjectIds: Set<UUID> = []
    var jiraTicketCache: [String: JiraTicketCacheEntry] = [:]
    var jiraTicketCacheLoaded = false
    var isJiraVerificationRunning = false
    var _jiraProjectStatusesCache: [String: [JiraProjectStatus]] = [:]
    var _jiraProjectStatusesCacheLoaded = false
    var prCache: [String: PullRequestCacheEntry] = [:]
    var prCacheLoaded = false
    /// Pending prompt recoveries for .newTab entries, keyed by thread ID.
    /// Stored at launch and shown as embedded banners when the thread is selected.
    var pendingPromptRecoveriesByThread: [UUID: [PendingPromptRecoveryInfo]] = [:]

    // MARK: - Lifecycle

    func loadThreads() {
        threads = persistence.loadThreads().filter { !$0.isArchived }
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
            if await migrateSessionAgentTypes(threadIndex: i) {
                didMigrate = true
            }
            if pruneSessionAgentTypesToKnownSessions(threadIndex: i) {
                didMigrate = true
            }
            if pruneSubmittedPromptHistoryToKnownSessions(threadIndex: i) {
                didMigrate = true
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
