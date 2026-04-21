import Foundation

extension Notification.Name {
    static let magentArchivedThreadsDidChange = Notification.Name("magentArchivedThreadsDidChange")
    static let magentDeadSessionsDetected = Notification.Name("magentDeadSessionsDetected")
    static let magentAgentCompletionDetected = Notification.Name("magentAgentCompletionDetected")
    static let magentAgentWaitingForInput = Notification.Name("magentAgentWaitingForInput")
    static let magentAgentBusySessionsChanged = Notification.Name("magentAgentBusySessionsChanged")
    static let magentAgentRateLimitChanged = Notification.Name("magentAgentRateLimitChanged")
    static let magentGlobalRateLimitSummaryChanged = Notification.Name("magentGlobalRateLimitSummaryChanged")
    static let magentSectionsDidChange = Notification.Name("magentSectionsDidChange")
    static let magentOpenSettings = Notification.Name("magentOpenSettings")
    static let magentOpenExternalLinkInApp = Notification.Name("magentOpenExternalLinkInApp")
    static let magentShowDiffViewer = Notification.Name("magentShowDiffViewer")
    static let magentHideDiffViewer = Notification.Name("magentHideDiffViewer")
    static let magentDiffViewerScrolledToFile = Notification.Name("magentDiffViewerScrolledToFile")
    static let magentNavigateToThread = Notification.Name("magentNavigateToThread")
    static let magentPullRequestInfoChanged = Notification.Name("magentPullRequestInfoChanged")
    static let magentJiraTicketInfoChanged = Notification.Name("magentJiraTicketInfoChanged")
    static let magentStatusSyncCompleted = Notification.Name("magentStatusSyncCompleted")
    static let magentPromptTOCVisibilityChanged = Notification.Name("magentPromptTOCVisibilityChanged")
    static let magentSettingsDidChange = Notification.Name("magentSettingsDidChange")
    static let magentProjectVisibilityDidChange = Notification.Name("magentProjectVisibilityDidChange")
    static let magentUpdateStateChanged = Notification.Name("magentUpdateStateChanged")
    static let magentThreadCreationFinished = Notification.Name("magentThreadCreationFinished")
    /// Posted after thread metadata snapshots are applied in the sidebar so
    /// pop-out windows can refresh from the latest ThreadManager state.
    static let magentThreadsDidChange = Notification.Name("magentThreadsDidChange")
    /// Posted by `injectAfterStart` just before it begins waiting for the agent TUI
    /// so that the loading overlay knows to suppress poll-timer dismissal.
    static let magentAgentInjectionStarted = Notification.Name("magentAgentInjectionStarted")
    /// Posted by `injectAfterStart` when an initial prompt is queued and waiting for
    /// the agent to become ready, so the UI can show a "pending injection" banner.
    static let magentPendingPromptInjection = Notification.Name("magentPendingPromptInjection")
    /// Posted by `injectAfterStart` after all tmux keys (including Enter) are sent.
    /// Carries "sessionName" (String) and "includedInitialPrompt" (Bool).
    static let magentAgentKeysInjected = Notification.Name("magentAgentKeysInjected")
    /// Posted by `injectAfterStart` when an initial prompt was never injected because
    /// the agent prompt marker failed to appear within the timeout window.
    static let magentInitialPromptInjectionFailed = Notification.Name("magentInitialPromptInjectionFailed")
    /// Posted by `removeTabBySessionName` just before model cleanup begins.
    /// Carries "threadId" (UUID) and "sessionName" (String) so the terminal
    /// detail view can remove the surface immediately and prevent a Ghostty
    /// use-after-free when the tmux session (and its process) was killed via
    /// the IPC path, which doesn't call removeFromSuperview() directly.
    static let magentTabWillClose = Notification.Name("magentTabWillClose")
    /// Posted when a pending prompt recovery is added or removed for a thread.
    /// Carries "threadId" (UUID).
    static let magentPendingPromptRecovery = Notification.Name("magentPendingPromptRecovery")
    /// Posted by ThreadDetailViewController when the user clicks "Reopen as Thread"
    /// on a per-thread recovery banner. Carries "projectId" (UUID), "tempFileURL" (URL),
    /// and "prefill" (AgentLaunchSheetPrefill).
    static let magentRecoveryReopenRequested = Notification.Name("magentRecoveryReopenRequested")
    /// Posted after `cleanupIdleSessions` finishes. Carries "closedCount" (Int).
    static let magentSessionCleanupCompleted = Notification.Name("magentSessionCleanupCompleted")
    /// Posted when Keep Alive protection changes on a thread. Carries "threadId" (UUID).
    static let magentKeepAliveChanged = Notification.Name("magentKeepAliveChanged")
    /// Posted when thread favorites change.
    static let magentFavoritesChanged = Notification.Name("magentFavoritesChanged")
    /// Posted when tmux zombie summary or recovery state changes.
    static let magentTmuxHealthChanged = Notification.Name("magentTmuxHealthChanged")

    // MARK: - Pop-out Windows

    /// Posted when a thread is returned from a pop-out window to the main window. Carries "threadId" (UUID).
    static let magentThreadReturnedToMain = Notification.Name("magentThreadReturnedToMain")
    /// Posted when a detached tab is returned to its parent thread. Carries "sessionName" (String), "threadId" (UUID).
    static let magentTabReturnedToThread = Notification.Name("magentTabReturnedToThread")
    /// Posted when a thread is popped out into a separate window. Carries "threadId" (UUID).
    static let magentThreadPoppedOut = Notification.Name("magentThreadPoppedOut")
    /// Posted when a tab is detached into a separate window. Carries "sessionName" (String), "threadId" (UUID).
    static let magentTabDetached = Notification.Name("magentTabDetached")
    /// Posted to request popping out a specific thread. Carries "threadId" (UUID).
    static let magentPopOutThreadRequested = Notification.Name("magentPopOutThreadRequested")
    /// Posted when terminal/web/draft focus indicates the thread whose changes context
    /// should be shown in the sidebar diff panel. Carries "threadId" (UUID).
    static let magentFocusedThreadContextChanged = Notification.Name("magentFocusedThreadContextChanged")
}
