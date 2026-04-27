import AppKit
import Foundation
import UserNotifications
import MagentCore

// MARK: - ThreadManager+Helpers
// Thin forwarding layer to AgentSetupService (Phase 5).
// All agent setup logic lives in AgentSetupService.

extension ThreadManager {

    // MARK: - Session Environment

    func sessionEnvironmentVariables(
        threadId: UUID,
        worktreePath: String? = nil,
        projectPath: String,
        worktreeName: String,
        projectName: String,
        agentType: AgentType? = nil
    ) -> [(String, String)] {
        agentSetupService.sessionEnvironmentVariables(
            threadId: threadId,
            worktreePath: worktreePath,
            projectPath: projectPath,
            worktreeName: worktreeName,
            projectName: projectName,
            agentType: agentType
        )
    }

    func shellExportCommand(for environmentVariables: [(String, String)]) -> String {
        agentSetupService.shellExportCommand(for: environmentVariables)
    }

    func resolvedModelLabel(for agentType: AgentType?, modelId: String?) -> String? {
        agentSetupService.resolvedModelLabel(for: agentType, modelId: modelId)
    }

    func applySessionEnvironmentVariables(
        sessionName: String,
        environmentVariables: [(String, String)]
    ) async {
        await agentSetupService.applySessionEnvironmentVariables(
            sessionName: sessionName,
            environmentVariables: environmentVariables
        )
    }

    // MARK: - Agent Readiness

    func waitForAgentPrompt(
        sessionName: String,
        agentType: AgentType?,
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.3
    ) async -> Bool {
        await agentSetupService.waitForAgentPrompt(
            sessionName: sessionName,
            agentType: agentType,
            timeout: timeout,
            interval: interval
        )
    }

    func waitForPromptToAppear(
        sessionName: String,
        prompt: String,
        timeout: TimeInterval = 3.0,
        interval: TimeInterval = 0.15
    ) async -> Bool {
        await agentSetupService.waitForPromptToAppear(
            sessionName: sessionName,
            prompt: prompt,
            timeout: timeout,
            interval: interval
        )
    }

    func detectsInteractiveShellBlocker(_ content: String) -> Bool {
        agentSetupService.detectsInteractiveShellBlocker(content)
    }

    func isAgentContentReady(_ content: String, agentType: AgentType?) -> Bool {
        agentSetupService.isAgentContentReady(content, agentType: agentType)
    }

    static func isPromptLineEmpty(_ line: String, marker: String) -> Bool {
        AgentSetupService.isPromptLineEmpty(line, marker: marker)
    }

    static func stripAnsiEscapes(_ string: String) -> String {
        AgentSetupService.stripAnsiEscapes(string)
    }

    // MARK: - Pending Prompt Injection State

    func initialPromptInjectionFailure(for sessionName: String) -> InitialPromptInjectionFailureInfo? {
        agentSetupService.initialPromptInjectionFailure(for: sessionName)
    }

    func clearInitialPromptInjectionFailure(for sessionName: String) {
        agentSetupService.clearInitialPromptInjectionFailure(for: sessionName)
    }

    func clearTrackedInitialPromptInjection(for sessionName: String) {
        agentSetupService.clearTrackedInitialPromptInjection(for: sessionName)
    }

    func clearTrackedInitialPromptInjection(forSessions sessionNames: some Sequence<String>) {
        agentSetupService.clearTrackedInitialPromptInjection(forSessions: sessionNames)
    }

    func pendingPromptInjection(for sessionName: String) -> InitialPromptInjectionFailureInfo? {
        agentSetupService.pendingPromptInjection(for: sessionName)
    }

    func didCompleteInitialPromptInjection(for sessionName: String) -> Bool {
        agentSetupService.didCompleteInitialPromptInjection(for: sessionName)
    }

    func hasTrackedInitialPromptInjection(for sessionName: String) -> Bool {
        agentSetupService.hasTrackedInitialPromptInjection(for: sessionName)
    }

    func waitForInitialPromptInjectionSettlement(
        sessionName: String,
        timeout: TimeInterval = 35
    ) async -> Bool {
        await agentSetupService.waitForInitialPromptInjectionSettlement(
            sessionName: sessionName,
            timeout: timeout
        )
    }

    func clearPendingPromptInjection(for sessionName: String) {
        agentSetupService.clearPendingPromptInjection(for: sessionName)
    }

    // MARK: - Pending Prompt Recovery

    func addPendingPromptRecovery(for threadId: UUID, info: PendingPromptRecoveryInfo) {
        agentSetupService.addPendingPromptRecovery(for: threadId, info: info)
    }

    func pendingPromptRecoveries(for threadId: UUID) -> [PendingPromptRecoveryInfo] {
        agentSetupService.pendingPromptRecoveries(for: threadId)
    }

    func removePendingPromptRecovery(for threadId: UUID, tempFileURL: URL) {
        agentSetupService.removePendingPromptRecovery(for: threadId, tempFileURL: tempFileURL)
    }

    func clearAllPendingPromptRecoveries(for threadId: UUID) {
        agentSetupService.clearAllPendingPromptRecoveries(for: threadId)
    }

    func cleanupPendingPromptRecoveries(for threadId: UUID) {
        agentSetupService.cleanupPendingPromptRecoveries(for: threadId)
    }

    // MARK: - Injection

    func injectAfterStart(sessionName: String, terminalCommand: String, agentContext: String, initialPrompt: String? = nil, shouldSubmitInitialPrompt: Bool = true, agentType: AgentType? = nil) {
        agentSetupService.injectAfterStart(
            sessionName: sessionName,
            terminalCommand: terminalCommand,
            agentContext: agentContext,
            initialPrompt: initialPrompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            agentType: agentType
        )
    }

    func injectPendingPromptNow(sessionName: String, prompt: String, shouldSubmitInitialPrompt: Bool, agentType: AgentType?) {
        agentSetupService.injectPendingPromptNow(
            sessionName: sessionName,
            prompt: prompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            agentType: agentType
        )
    }

    func effectiveInjection(for projectId: UUID) -> (terminalCommand: String, agentContext: String) {
        agentSetupService.effectiveInjection(for: projectId)
    }

    func preAgentInjectionCommand(for projectId: UUID, settings: AppSettings) -> String {
        agentSetupService.preAgentInjectionCommand(for: projectId, settings: settings)
    }

    @MainActor
    func registerPendingPromptCleanup(fileURL: URL?, sessionName: String) {
        agentSetupService.registerPendingPromptCleanup(fileURL: fileURL, sessionName: sessionName)
    }

    func clearMagentBusy(sessionName: String) {
        agentSetupService.clearMagentBusy(sessionName: sessionName)
    }

    @discardableResult
    func relaunchAgentInExistingSession(
        sessionName: String,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        agentContext: String,
        agentType: AgentType?
    ) -> Bool {
        agentSetupService.relaunchAgentInExistingSession(
            sessionName: sessionName,
            initialPrompt: initialPrompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            agentContext: agentContext,
            agentType: agentType
        )
    }

    // MARK: - Agent Type

    func effectiveAgentType(for projectId: UUID) -> AgentType? {
        agentSetupService.effectiveAgentType(for: projectId)
    }

    func effectiveAgentTypeAvoidingRateLimit(for projectId: UUID, now: Date = Date()) -> AgentType? {
        agentSetupService.effectiveAgentTypeAvoidingRateLimit(for: projectId, now: now)
    }

    /// Detects the running agent type from a pane command name. Kept directly here
    /// because SessionLifecycleService wires it in via the `detectedAgentType` callback.
    func detectedAgentType(from commandLine: String) -> AgentType? {
        agentSetupService.detectedAgentType(from: commandLine)
    }

    /// Detects the running agent type from pane command + child processes.
    func detectedRunningAgentType(
        paneCommand: String,
        childProcesses: [(pid: pid_t, args: String)]
    ) -> AgentType? {
        agentSetupService.detectedRunningAgentType(paneCommand: paneCommand, childProcesses: childProcesses)
    }

    /// Returns the agent type currently running in the given tmux session.
    func detectedAgentTypeInSession(_ sessionName: String) async -> AgentType? {
        await agentSetupService.detectedAgentTypeInSession(sessionName)
    }

    func agentType(for thread: MagentThread, sessionName: String) -> AgentType? {
        agentSetupService.agentType(for: thread, sessionName: sessionName)
    }

    func loadingOverlayAgentType(for thread: MagentThread, sessionName: String) async -> AgentType? {
        await agentSetupService.loadingOverlayAgentType(for: thread, sessionName: sessionName)
    }

    func migrateSessionAgentTypes(threadIndex index: Int) async -> Bool {
        await agentSetupService.migrateSessionAgentTypes(threadIndex: index)
    }

    @discardableResult
    func remapSessionAgentTypes(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        agentSetupService.remapSessionAgentTypes(threadIndex: index, sessionRenameMap: sessionRenameMap)
    }

    @discardableResult
    func pruneSessionAgentTypesToKnownSessions(threadIndex index: Int) -> Bool {
        agentSetupService.pruneSessionAgentTypesToKnownSessions(threadIndex: index)
    }

    @discardableResult
    func remapSessionCreationDates(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        agentSetupService.remapSessionCreationDates(threadIndex: index, sessionRenameMap: sessionRenameMap)
    }

    @discardableResult
    func pruneSessionCreationDatesToKnownSessions(threadIndex index: Int) -> Bool {
        agentSetupService.pruneSessionCreationDatesToKnownSessions(threadIndex: index)
    }

    @discardableResult
    func remapFreshAgentSessions(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        agentSetupService.remapFreshAgentSessions(threadIndex: index, sessionRenameMap: sessionRenameMap)
    }

    @discardableResult
    func pruneFreshAgentSessionsToKnownSessions(threadIndex index: Int) -> Bool {
        agentSetupService.pruneFreshAgentSessionsToKnownSessions(threadIndex: index)
    }

    // MARK: - Agent Conversation IDs

    func conversationID(for threadId: UUID, sessionName: String) -> String? {
        agentSetupService.conversationID(for: threadId, sessionName: sessionName)
    }

    func scheduleAgentConversationIDRefresh(
        threadId: UUID,
        sessionName: String,
        delaySeconds: TimeInterval = 1.2
    ) {
        agentSetupService.scheduleAgentConversationIDRefresh(
            threadId: threadId,
            sessionName: sessionName,
            delaySeconds: delaySeconds
        )
    }

    func refreshAgentConversationID(threadId: UUID, sessionName: String) async {
        await agentSetupService.refreshAgentConversationID(threadId: threadId, sessionName: sessionName)
    }

    // MARK: - Submitted Prompt History

    func replaceSubmittedPromptHistory(threadId: UUID, sessionName: String, prompts: [String]) {
        agentSetupService.replaceSubmittedPromptHistory(
            threadId: threadId,
            sessionName: sessionName,
            prompts: prompts
        )
    }

    func appendToSubmittedPromptHistory(threadId: UUID, sessionName: String, prompt: String) {
        agentSetupService.appendToSubmittedPromptHistory(
            threadId: threadId,
            sessionName: sessionName,
            prompt: prompt
        )
    }

    @discardableResult
    func remapSubmittedPromptHistory(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        agentSetupService.remapSubmittedPromptHistory(threadIndex: index, sessionRenameMap: sessionRenameMap)
    }

    @discardableResult
    func pruneSubmittedPromptHistoryToKnownSessions(threadIndex index: Int) -> Bool {
        agentSetupService.pruneSubmittedPromptHistoryToKnownSessions(threadIndex: index)
    }

    // MARK: - Session-State Rekey/Prune
    // remapTransientSessionState and pruneTransientSessionStateToKnownAgentSessions are
    // in SessionLifecycleService (Phase 4) and forwarded via ThreadManager+AgentState.

    @discardableResult
    func remapInitialPromptInjectionState(sessionRenameMap: [String: String]) -> Bool {
        agentSetupService.remapInitialPromptInjectionState(sessionRenameMap: sessionRenameMap)
    }

    // MARK: - Session Naming (delegates to TmuxSessionNaming)

    /// Renames session names produced by Magent without touching unrelated substrings.
    func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
        agentSetupService.renamedSessionName(sessionName, fromThreadName: oldName, toThreadName: newName, repoSlug: repoSlug)
    }

    static func sanitizeForTmux(_ name: String) -> String {
        TmuxSessionNaming.sanitizeForTmux(name)
    }

    static func repoSlug(from projectName: String) -> String {
        TmuxSessionNaming.repoSlug(from: projectName)
    }

    static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        TmuxSessionNaming.buildSessionName(repoSlug: repoSlug, threadName: threadName, tabSlug: tabSlug)
    }

    static func isMagentSession(_ name: String) -> Bool {
        TmuxSessionNaming.isMagentSession(name)
    }

    // MARK: - Symlinks (delegates to SymlinkManager)

    func cleanupAllBrokenSymlinks() {
        agentSetupService.cleanupAllBrokenSymlinks()
    }

    func createCompatibilitySymlink(from oldPath: String, to newPath: String) {
        agentSetupService.createCompatibilitySymlink(from: oldPath, to: newPath)
    }

    func ensureBranchSymlink(
        branchName: String,
        worktreePath: String,
        worktreesBasePath: String
    ) {
        agentSetupService.ensureBranchSymlink(
            branchName: branchName,
            worktreePath: worktreePath,
            worktreesBasePath: worktreesBasePath
        )
    }

    // MARK: - Claude Settings

    /// Path to the Magent-specific Claude Code settings file.
    static let claudeHooksSettingsPath = AgentSetupService.claudeHooksSettingsPath

    func installClaudeHooksSettings() {
        agentSetupService.installClaudeHooksSettings()
    }

    // MARK: - Codex Config

    func ensureCodexBellNotification() {
        agentSetupService.ensureCodexBellNotification()
    }

    // MARK: - Codex IPC Instructions

    func installCodexIPCInstructions() {
        agentSetupService.installCodexIPCInstructions()
    }

    // MARK: - Agent Start Command

    @discardableResult
    func ensureManagedZdotdir() -> String {
        agentSetupService.ensureManagedZdotdir()
    }

    func cleanupManagedZdotdir() {
        agentSetupService.cleanupManagedZdotdir()
    }

    func terminalStartCommand(
        envExports: String,
        workingDirectory: String
    ) -> String {
        agentSetupService.terminalStartCommand(envExports: envExports, workingDirectory: workingDirectory)
    }

    func agentStartCommand(
        settings: AppSettings,
        projectId: UUID? = nil,
        agentType: AgentType?,
        envExports: String,
        workingDirectory: String,
        resumeSessionID: String? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) -> String {
        agentSetupService.agentStartCommand(
            settings: settings,
            projectId: projectId,
            agentType: agentType,
            envExports: envExports,
            workingDirectory: workingDirectory,
            resumeSessionID: resumeSessionID,
            modelId: modelId,
            reasoningLevel: reasoningLevel
        )
    }

    // MARK: - Name Availability

    func isNameAvailable(_ name: String, project: Project) async throws -> Bool {
        try await agentSetupService.isNameAvailable(name, project: project)
    }

    // MARK: - Agent Trust

    func trustDirectoryIfNeeded(_ path: String, agentType: AgentType?) {
        agentSetupService.trustDirectoryIfNeeded(path, agentType: agentType)
    }

    func resolveAgentType(
        for projectId: UUID,
        requestedAgentType: AgentType?,
        settings: AppSettings
    ) -> AgentType? {
        agentSetupService.resolveAgentType(
            for: projectId,
            requestedAgentType: requestedAgentType,
            settings: settings
        )
    }

    func isTabNameTaken(_ name: String, existingNames: [String]) async -> Bool {
        await agentSetupService.isTabNameTaken(name, existingNames: existingNames)
    }
}

// MARK: - Notification Names

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
    /// Posted when transient terminal-corruption state changes for a tmux session.
    /// Carries "threadId" (UUID), "sessionName" (String), and "isCorrupted" (Bool).
    static let magentTerminalCorruptionChanged = Notification.Name("magentTerminalCorruptionChanged")

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

// MARK: - Errors

enum ThreadManagerError: LocalizedError {
    case threadNotFound
    case invalidName
    case invalidPrompt
    case invalidDescription
    case duplicateName
    case invalidTabIndex
    case cannotDeleteMainThread
    case cannotRenameMainThread
    case nameGenerationFailed(diagnostic: String?)
    case worktreePathConflict([String])
    case noExpectedBranch
    case archiveCancelled
    /// Refused to archive because the worktree has uncommitted/untracked changes.
    case dirtyWorktree(worktreePath: String)
    case localFileSyncFailed(String)
    /// Signal case thrown by the inner conflict handler; carries no data.
    /// The sync entry points catch this and rethrow `.agenticMergeReady` with full context.
    case agenticMergeSignal
    case agenticMergeReady(LocalSyncAgenticMergeContext)

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "Thread not found"
        case .invalidName:
            return "Invalid name. Name must not be empty or contain slashes."
        case .invalidPrompt:
            return "Prompt must not be empty."
        case .invalidDescription:
            return "Invalid description. Use 1-8 words with at least one letter."
        case .duplicateName:
            return "A thread with that name already exists."
        case .invalidTabIndex:
            return "Invalid tab index."
        case .cannotDeleteMainThread:
            return "Main threads cannot be deleted."
        case .cannotRenameMainThread:
            return "Main threads cannot be renamed."
        case .nameGenerationFailed(let diagnostic):
            let base = "Could not generate a thread name."
            if let diagnostic, !diagnostic.isEmpty {
                return "\(base) \(diagnostic)"
            }
            return "\(base) Ensure Claude or Codex is configured and reachable, then try again."
        case .worktreePathConflict(let names):
            let list = names.joined(separator: ", ")
            return "Cannot move worktrees — the following directories already exist in the destination: \(list)"
        case .noExpectedBranch:
            return "No expected branch configured. Set the default branch in project settings."
        case .archiveCancelled:
            return "Archive cancelled."
        case .dirtyWorktree(let worktreePath):
            return "Worktree has uncommitted or untracked changes at \(worktreePath). Commit/stash/discard first. CLI --force does not bypass dirty-worktree safety."
        case .localFileSyncFailed(let message):
            return message
        case .agenticMergeSignal:
            return "Agentic merge requested."
        case .agenticMergeReady:
            return "Agentic merge requested."
        }
    }
}

/// Describes the intent for an agent-driven local sync operation.
enum LocalSyncAgenticOperation: Sendable {
    case syncSourceToDestination
    case reconcileBothWays
}

/// Context passed when the user chooses agent-driven local sync handling.
/// Carries all the information needed to construct an agent prompt for the sync operation.
struct LocalSyncAgenticMergeContext: Sendable {
    let operation: LocalSyncAgenticOperation
    let sourceRoot: String
    let destinationRoot: String
    let syncPaths: [String]
    /// Human-readable label for the source (e.g. "Project" or worktree name)
    let sourceLabel: String
    /// Human-readable label for the destination
    let destinationLabel: String
}
