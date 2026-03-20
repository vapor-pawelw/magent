import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Add Tab

    func addTab(
        to thread: MagentThread,
        useAgentCommand: Bool = false,
        requestedAgentType: AgentType? = nil,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        customTitle: String? = nil,
        tabNameSuffix: String? = nil,
        pendingPromptFileURL: URL? = nil
    ) async throws -> Tab {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]

        // Find the next unused tab index — check both model and live tmux sessions
        let existingNames = currentThread.tmuxSessionNames
        let tabIndex = existingNames.count
        let settings = persistence.loadSettings()

        let tmuxSessionName: String
        let startCmd: String
        let tabDisplayName: String

        var selectedAgentType: AgentType? = nil
        let requestedTabBaseName: String
        let repoSlug = Self.repoSlug(from:
            settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
        )
        if currentThread.isMain {
            let projectPath = currentThread.worktreePath
            let projectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            let sessionEnvironment = sessionEnvironmentVariables(
                threadId: currentThread.id,
                projectPath: projectPath,
                worktreeName: "main",
                projectName: projectName,
                agentType: nil
            )
            let envExports = shellExportCommand(for: sessionEnvironment)
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType,
                    settings: settings
                )
                let sessionEnvironment = sessionEnvironmentVariables(
                    threadId: currentThread.id,
                    projectPath: projectPath,
                    worktreeName: "main",
                    projectName: projectName,
                    agentType: selectedAgentType
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    projectId: currentThread.projectId,
                    agentType: selectedAgentType,
                    envExports: shellExportCommand(for: sessionEnvironment),
                    workingDirectory: projectPath
                )
                requestedTabBaseName = TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
            } else {
                selectedAgentType = nil
                startCmd = terminalStartCommand(
                    envExports: envExports,
                    workingDirectory: projectPath
                )
                requestedTabBaseName = "Terminal"
            }

            tabDisplayName = customTitle.map { uniqueTabDisplayName(baseName: $0, in: currentThread) }
                ?? uniqueTabDisplayName(baseName: requestedTabBaseName + (tabNameSuffix ?? ""), in: currentThread)
            let tabSlug = Self.sanitizeForTmux(tabDisplayName)
            let baseName = Self.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: tabSlug)
            var candidate = baseName
            var suffix = 2
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                candidate = "\(baseName)-\(suffix)"
                suffix += 1
            }
            tmuxSessionName = candidate
        } else {
            let project = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = project?.repoPath ?? currentThread.worktreePath
            let baseSessionEnvironment = sessionEnvironmentVariables(
                threadId: currentThread.id,
                worktreePath: currentThread.worktreePath,
                projectPath: projectPath,
                worktreeName: currentThread.name,
                projectName: project?.name ?? "project"
            )
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType,
                    settings: settings
                )
                let sessionEnvironment = sessionEnvironmentVariables(
                    threadId: currentThread.id,
                    worktreePath: currentThread.worktreePath,
                    projectPath: projectPath,
                    worktreeName: currentThread.name,
                    projectName: project?.name ?? "project",
                    agentType: selectedAgentType
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    projectId: currentThread.projectId,
                    agentType: selectedAgentType,
                    envExports: shellExportCommand(for: sessionEnvironment),
                    workingDirectory: currentThread.worktreePath
                )
                requestedTabBaseName = TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
            } else {
                startCmd = terminalStartCommand(
                    envExports: shellExportCommand(for: baseSessionEnvironment),
                    workingDirectory: currentThread.worktreePath
                )
                requestedTabBaseName = "Terminal"
            }

            tabDisplayName = customTitle.map { uniqueTabDisplayName(baseName: $0, in: currentThread) }
                ?? uniqueTabDisplayName(baseName: requestedTabBaseName + (tabNameSuffix ?? ""), in: currentThread)
            let tabSlug = Self.sanitizeForTmux(tabDisplayName)
            let baseName = Self.buildSessionName(repoSlug: repoSlug, threadName: currentThread.name, tabSlug: tabSlug)
            var candidate = baseName
            var suffix = 2
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                candidate = "\(baseName)-\(suffix)"
                suffix += 1
            }
            tmuxSessionName = candidate
        }

        if useAgentCommand {
            trustDirectoryIfNeeded(currentThread.worktreePath, agentType: selectedAgentType)
        }

        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: currentThread.worktreePath,
            command: startCmd
        )

        let sessionEnvironment: [(String, String)]
        if currentThread.isMain {
            let mainProjectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            sessionEnvironment = sessionEnvironmentVariables(
                threadId: currentThread.id,
                projectPath: currentThread.worktreePath,
                worktreeName: "main",
                projectName: mainProjectName,
                agentType: useAgentCommand ? selectedAgentType : nil
            )
        } else {
            let tabProject = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = tabProject?.repoPath ?? currentThread.worktreePath
            sessionEnvironment = sessionEnvironmentVariables(
                threadId: currentThread.id,
                worktreePath: currentThread.worktreePath,
                projectPath: projectPath,
                worktreeName: currentThread.name,
                projectName: tabProject?.name ?? "project",
                agentType: useAgentCommand ? selectedAgentType : nil
            )
        }
        await applySessionEnvironmentVariables(
            sessionName: tmuxSessionName,
            environmentVariables: sessionEnvironment
        )

        threads[index].tmuxSessionNames.append(tmuxSessionName)
        threads[index].customTabNames[tmuxSessionName] = tabDisplayName
        let shouldMarkAsAgentTab = (currentThread.isMain || useAgentCommand) && selectedAgentType != nil
        if shouldMarkAsAgentTab {
            threads[index].agentTmuxSessions.append(tmuxSessionName)
            if let selectedAgentType {
                threads[index].sessionAgentTypes[tmuxSessionName] = selectedAgentType
            }
            threads[index].agentHasRun = true
        }
        try persistence.saveActiveThreads(threads)
        let tab = Tab(
            threadId: currentThread.id,
            tmuxSessionName: tmuxSessionName,
            index: tabIndex
        )

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
            // Register cleanup before injectAfterStart fires magentAgentKeysInjected,
            // preventing the notification from racing past the listener setup.
            registerPendingPromptCleanup(fileURL: pendingPromptFileURL, sessionName: tmuxSessionName)
        }

        // Inject terminal command (always) and agent context (only for agent tabs)
        let injection = effectiveInjection(for: currentThread.projectId)
        let isAgentTab = shouldMarkAsAgentTab
        injectAfterStart(
            sessionName: tmuxSessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentTab ? injection.agentContext : "",
            initialPrompt: initialPrompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            agentType: selectedAgentType
        )
        if initialPrompt?.isEmpty == false, isAgentTab, shouldSubmitInitialPrompt {
            scheduleAgentConversationIDRefresh(threadId: currentThread.id, sessionName: tmuxSessionName)
        }

        return tab
    }

    // MARK: - Tab Display Name Helpers

    private func uniqueTabDisplayName(baseName: String, in thread: MagentThread) -> String {
        let usedNames = Set(
            thread.tmuxSessionNames.enumerated().map { index, sessionName in
                thread.displayName(for: sessionName, at: index).lowercased()
            }
        )
        if !usedNames.contains(baseName.lowercased()) {
            return baseName
        }

        for suffix in 1...999 {
            let candidate = "\(baseName)-\(suffix)"
            if !usedNames.contains(candidate.lowercased()) {
                return candidate
            }
        }

        return "\(baseName)-\(Int(Date().timeIntervalSince1970))"
    }

    // MARK: - Tab Ordering & Registration

    func reorderTabs(for threadId: UUID, newOrder: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].tmuxSessionNames = newOrder
        try? persistence.saveActiveThreads(threads)
    }

    /// Registers a fallback session name for a thread that had no sessions.
    /// This ensures the session is tracked in tmuxSessionNames (so close-tab works)
    /// and in agentTmuxSessions (so recreateSessionIfNeeded creates an agent, not a terminal).
    func registerFallbackSession(_ sessionName: String, for threadId: UUID, agentType: AgentType?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard !threads[index].tmuxSessionNames.contains(sessionName) else { return }
        threads[index].tmuxSessionNames.append(sessionName)
        if agentType != nil {
            threads[index].agentTmuxSessions.append(sessionName)
            if let agentType {
                threads[index].sessionAgentTypes[sessionName] = agentType
            }
            threads[index].agentHasRun = true
        }
        threads[index].customTabNames[sessionName] = TmuxSessionNaming.defaultTabDisplayName(for: agentType)
        threads[index].lastSelectedTmuxSessionName = sessionName
        try? persistence.saveActiveThreads(threads)
    }

    // MARK: - Tab Pinning & Selection

    func updatePinnedTabs(for threadId: UUID, pinnedSessions: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].pinnedTmuxSessions = pinnedSessions
        try? persistence.saveActiveThreads(threads)
    }

    func updatePersistedWebTabs(for threadId: UUID, webTabs: [PersistedWebTab]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].persistedWebTabs = webTabs
        try? persistence.saveActiveThreads(threads)
    }

    func updateLastSelectedSession(for threadId: UUID, sessionName: String?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        if threads[index].lastSelectedTmuxSessionName == sessionName { return }
        threads[index].lastSelectedTmuxSessionName = sessionName
        try? persistence.saveActiveThreads(threads)
    }

    @MainActor
    func setActiveThread(_ threadId: UUID?) {
        activeThreadId = threadId
    }

    // MARK: - Close Tab

    func removeTab(from thread: MagentThread, at tabIndex: Int) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        guard tabIndex >= 0, tabIndex < threads[index].tmuxSessionNames.count else {
            throw ThreadManagerError.invalidTabIndex
        }

        let sessionName = threads[index].tmuxSessionNames[tabIndex]
        try await removeTabBySessionName(threadIndex: index, sessionName: sessionName)
    }

    func removeTab(from thread: MagentThread, sessionName: String) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        guard threads[index].tmuxSessionNames.contains(sessionName) else {
            throw ThreadManagerError.invalidTabIndex
        }

        try await removeTabBySessionName(threadIndex: index, sessionName: sessionName)
    }

    @MainActor
    private func removeTabBySessionName(threadIndex index: Int, sessionName: String) async throws {
        NSLog("[TabClose] removeTabBySessionName start: index=\(index) session=\(sessionName)")
        try? await tmux.killSession(name: sessionName)
        NSLog("[TabClose] removeTabBySessionName: killSession done")

        // Guard re-checked after the async killSession suspension: another concurrent close
        // might have shifted or removed indices while killSession was running.
        guard index < threads.count else {
            NSLog("[TabClose] removeTabBySessionName: index \(index) out of bounds (threads.count=\(threads.count)), returning")
            return
        }

        // Notify the terminal detail view to remove the surface view immediately.
        // This is critical for the IPC path (which never calls removeFromSuperview directly):
        // without this, the Ghostty surface stays alive after the process dies, causing
        // ghostty_app_tick to crash on the zombie surface.  The observer runs synchronously
        // (same MainActor) so the view hierarchy is cleaned up before model state is mutated.
        let closingThreadId = threads[index].id
        NotificationCenter.default.post(
            name: .magentTabWillClose,
            object: nil,
            userInfo: ["threadId": closingThreadId, "sessionName": sessionName]
        )

        // Also remove from pinned, agent, unread completion, waiting, and custom tab names if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].agentTmuxSessions.removeAll { $0 == sessionName }
        threads[index].sessionConversationIDs.removeValue(forKey: sessionName)
        threads[index].sessionAgentTypes.removeValue(forKey: sessionName)
        threads[index].unreadCompletionSessions.remove(sessionName)
        threads[index].busySessions.remove(sessionName)
        threads[index].waitingForInputSessions.remove(sessionName)
        threads[index].rateLimitedSessions.removeValue(forKey: sessionName)
        notifiedWaitingSessions.remove(sessionName)
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].submittedPromptsBySession.removeValue(forKey: sessionName)
        threads[index].tmuxSessionNames.removeAll { $0 == sessionName }
        if threads[index].lastSelectedTmuxSessionName == sessionName {
            threads[index].lastSelectedTmuxSessionName = threads[index].tmuxSessionNames.first
        }
        NSLog("[TabClose] removeTabBySessionName: saving threads")
        try persistence.saveActiveThreads(threads)
        NSLog("[TabClose] removeTabBySessionName: calling delegate")
        delegate?.threadManager(self, didUpdateThreads: threads)
        NSLog("[TabClose] removeTabBySessionName: done")
    }
}
