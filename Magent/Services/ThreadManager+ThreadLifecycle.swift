import Foundation
import MagentCore

// MARK: - Type forwards

extension ThreadManager {
    /// Forward so callers that matched on `ThreadManager.RecoveryResult` keep compiling.
    typealias RecoveryResult = ThreadLifecycleService.RecoveryResult
}

// MARK: - Forwarding layer

extension ThreadManager {

    // MARK: - Ghostty Surface Teardown

    func releaseLivingGhosttySurfaces(for thread: MagentThread) {
        threadLifecycleService.releaseLivingGhosttySurfaces(for: thread)
    }

    // MARK: - Thread Creation

    @discardableResult
    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        initialDraftTab: PersistedDraftTab? = nil,
        requestedName: String? = nil,
        requestedBaseBranch: String? = nil,
        pendingPromptFileURL: URL? = nil,
        requestedSectionId: UUID? = nil,
        insertAfterThreadId: UUID? = nil,
        insertAtTopOfVisibleGroup: Bool = false,
        skipAutoSelect: Bool = false,
        initialWebURL: URL? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        localFileSyncEntriesOverride: [LocalFileSyncEntry]? = nil
    ) async throws -> MagentThread {
        try await threadLifecycleService.createThread(
            project: project,
            requestedAgentType: requestedAgentType,
            useAgentCommand: useAgentCommand,
            initialPrompt: initialPrompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            initialDraftTab: initialDraftTab,
            requestedName: requestedName,
            requestedBaseBranch: requestedBaseBranch,
            pendingPromptFileURL: pendingPromptFileURL,
            requestedSectionId: requestedSectionId,
            insertAfterThreadId: insertAfterThreadId,
            insertAtTopOfVisibleGroup: insertAtTopOfVisibleGroup,
            skipAutoSelect: skipAutoSelect,
            initialWebURL: initialWebURL,
            modelId: modelId,
            reasoningLevel: reasoningLevel,
            localFileSyncEntriesOverride: localFileSyncEntriesOverride
        )
    }

    // MARK: - Main Thread

    @discardableResult
    func createMainThread(project: Project) async throws -> MagentThread {
        try await threadLifecycleService.createMainThread(project: project)
    }

    func ensureMainThreads() async {
        await threadLifecycleService.ensureMainThreads()
    }

    // MARK: - Archive Thread

    func markThreadArchiving(id: UUID) {
        threadLifecycleService.markThreadArchiving(id: id)
    }

    func clearThreadArchivingState(id: UUID) {
        threadLifecycleService.clearThreadArchivingState(id: id)
    }

    func suggestedArchiveCommitMessage(for thread: MagentThread) async -> String {
        await threadLifecycleService.suggestedArchiveCommitMessage(for: thread)
    }

    @discardableResult
    func archiveThread(
        _ thread: MagentThread,
        promptForLocalSyncConflicts: Bool = false,
        force: Bool = false,
        forceCommitMessage: String? = nil,
        syncLocalPathsBackToRepo: Bool? = nil,
        awaitLocalSync: Bool = false
    ) async throws -> String? {
        try await threadLifecycleService.archiveThread(
            thread,
            promptForLocalSyncConflicts: promptForLocalSyncConflicts,
            force: force,
            forceCommitMessage: forceCommitMessage,
            syncLocalPathsBackToRepo: syncLocalPathsBackToRepo,
            awaitLocalSync: awaitLocalSync
        )
    }

    func restoreArchivedThread(id threadId: UUID) async throws -> MagentThread {
        try await threadLifecycleService.restoreArchivedThread(id: threadId)
    }

    func restoreArchivedThreadFromUserAction(id threadId: UUID, threadName: String) async -> Bool {
        await threadLifecycleService.restoreArchivedThreadFromUserAction(id: threadId, threadName: threadName)
    }

    // MARK: - Delete Thread

    func deleteThread(_ thread: MagentThread) async throws {
        try await threadLifecycleService.deleteThread(thread)
    }

    // MARK: - Worktree Recovery

    func recoverWorktree(for thread: MagentThread) async -> ThreadLifecycleService.RecoveryResult {
        await threadLifecycleService.recoverWorktree(for: thread)
    }

    // MARK: - Static helpers (forwarded for callers that reference ThreadManager namespace)

    static func clearPersistedSessionState(for thread: inout MagentThread) {
        ThreadLifecycleService.clearPersistedSessionState(for: &thread)
    }

    /// Excludes a Jira ticket from future assignment. Nonisolated so it can be called
    /// from both main-actor and @concurrent contexts (e.g., JiraIntegrationService).
    nonisolated static func excludeJiraTicketInPersistence(key: String, projectId: UUID, persistence: PersistenceService) {
        var settings = persistence.loadSettings()
        if let idx = settings.projects.firstIndex(where: { $0.id == projectId }) {
            settings.projects[idx].jiraExcludedTicketKeys.insert(key)
            try? persistence.saveSettings(settings)
        }
    }
}
