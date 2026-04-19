import Foundation
import MagentCore

// MARK: - Type forwards

extension ThreadManager {
    /// Forward so callers that used `ThreadManager.GeneratedTaskDescription` keep compiling.
    typealias GeneratedTaskDescription = RenameService.GeneratedTaskDescription
    /// Forward so callers that used `ThreadManager.AutoRenameResult` keep compiling.
    typealias AutoRenameResult = RenameService.AutoRenameResult
}

// MARK: - Forwarding layer

extension ThreadManager {

    // MARK: - Static constants (forwarded from RenameService)

    /// Prefix applied to auto-generated task descriptions when the thread has active draft tabs.
    static let draftDescriptionPrefix: String = RenameService.draftDescriptionPrefix

    // MARK: - Tmux Session Rename

    func renameTmuxSessions(from oldNames: [String], to newNames: [String]) async throws {
        try await renameService.renameTmuxSessions(from: oldNames, to: newNames)
    }

    // MARK: - Rename Thread

    func autoRenameCandidates(
        from prompt: String,
        agentType: AgentType?,
        projectId: UUID? = nil
    ) async -> RenameService.AutoRenameResult {
        await renameService.autoRenameCandidates(from: prompt, agentType: agentType, projectId: projectId)
    }

    @discardableResult
    func renameThreadFromPrompt(
        _ thread: MagentThread,
        prompt: String,
        preferredAgent: AgentType? = nil,
        prefixDraft: Bool = false,
        renameBranch: Bool = true,
        renameDescription: Bool = true,
        renameIcon: Bool = true
    ) async throws -> Bool {
        try await renameService.renameThreadFromPrompt(
            thread,
            prompt: prompt,
            preferredAgent: preferredAgent,
            prefixDraft: prefixDraft,
            renameBranch: renameBranch,
            renameDescription: renameDescription,
            renameIcon: renameIcon
        )
    }

    func renameThread(
        _ thread: MagentThread,
        to newName: String,
        markFirstPromptRenameHandled: Bool = true
    ) async throws {
        try await renameService.renameThread(thread, to: newName, markFirstPromptRenameHandled: markFirstPromptRenameHandled)
    }

    func autoRenameThreadAfterFirstPromptIfNeeded(
        threadId: UUID,
        sessionName: String,
        prompt: String
    ) async -> Bool {
        await renameService.autoRenameThreadAfterFirstPromptIfNeeded(
            threadId: threadId,
            sessionName: sessionName,
            prompt: prompt
        )
    }

    func autoRenameThreadFromDraftPromptIfNeeded(
        threadId: UUID,
        prompt: String
    ) async -> Bool {
        await renameService.autoRenameThreadFromDraftPromptIfNeeded(threadId: threadId, prompt: prompt)
    }

    func stripDraftDescriptionPrefixIfNeeded(threadId: UUID) {
        renameService.stripDraftDescriptionPrefixIfNeeded(threadId: threadId)
    }

    // MARK: - Task Description

    func generateTaskDescriptionIfNeeded(threadId: UUID, prompt: String) async {
        await renameService.generateTaskDescriptionIfNeeded(threadId: threadId, prompt: prompt)
    }

    @discardableResult
    func regenerateTaskDescription(threadId: UUID, prompt: String) async -> String? {
        await renameService.regenerateTaskDescription(threadId: threadId, prompt: prompt)
    }

    func setTaskDescription(threadId: UUID, description: String?) throws {
        try renameService.setTaskDescription(threadId: threadId, description: description)
    }

    func setThreadIcon(threadId: UUID, icon: ThreadIcon, markAsManualOverride: Bool = true) throws {
        try renameService.setThreadIcon(threadId: threadId, icon: icon, markAsManualOverride: markAsManualOverride)
    }

    func setThreadSignEmoji(threadId: UUID, signEmoji: String?) throws {
        try renameService.setThreadSignEmoji(threadId: threadId, signEmoji: signEmoji)
    }

    func setThreadPriority(threadId: UUID, priority: Int?) throws {
        try renameService.setThreadPriority(threadId: threadId, priority: priority)
    }

    func setSyncWithJira(threadId: UUID, enabled: Bool) throws {
        try renameService.setSyncWithJira(threadId: threadId, enabled: enabled)
    }

    // MARK: - Rename Tab

    func renameTab(threadId: UUID, sessionName: String, newDisplayName: String) async throws {
        try await renameService.renameTab(
            threadId: threadId,
            sessionName: sessionName,
            newDisplayName: newDisplayName,
            remapTransientSessionState: { [weak self] idx, map in
                self?.remapTransientSessionState(threadIndex: idx, sessionRenameMap: map) ?? false
            },
            remapInitialPromptInjectionState: { [weak self] map in
                self?.remapInitialPromptInjectionState(sessionRenameMap: map) ?? false
            },
            reKeyKnownGoodSessionContext: { [weak self] old, new in
                if let ctx = self?.knownGoodSessionContexts.removeValue(forKey: old) {
                    self?.knownGoodSessionContexts[new] = ctx
                }
            },
            forceSetupBellPipe: { [weak self] name in
                await self?.tmux.forceSetupBellPipe(for: name)
            }
        )
    }

    // MARK: - Bell-triggered auto-rename

    func extractFirstPromptFromPane(_ paneContent: String) -> String? {
        renameService.extractFirstPromptFromPane(paneContent)
    }

    func triggerAutoRenameFromBellIfNeeded(threadId: UUID, sessionName: String) async {
        await renameService.triggerAutoRenameFromBellIfNeeded(threadId: threadId, sessionName: sessionName)
    }
}
