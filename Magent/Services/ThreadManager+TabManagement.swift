import Foundation

extension ThreadManager {

    // MARK: - Add Tab

    func addTab(
        to thread: MagentThread,
        useAgentCommand: Bool = false,
        requestedAgentType: AgentType? = nil,
        initialPrompt: String? = nil
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

        var selectedAgentType = currentThread.selectedAgentType
        let requestedTabBaseName: String
        let repoSlug = Self.repoSlug(from:
            settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
        )
        if currentThread.isMain {
            let projectPath = currentThread.worktreePath
            let projectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            let envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType,
                    settings: settings
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    agentType: selectedAgentType,
                    envExports: envExports,
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

            tabDisplayName = uniqueTabDisplayName(
                baseName: requestedTabBaseName,
                in: currentThread
            )
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
            let envExports = "export MAGENT_WORKTREE_PATH=\(currentThread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(currentThread.name) && export MAGENT_PROJECT_NAME=\(project?.name ?? "project") && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType ?? currentThread.selectedAgentType,
                    settings: settings
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    agentType: selectedAgentType,
                    envExports: envExports,
                    workingDirectory: currentThread.worktreePath
                )
                requestedTabBaseName = TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
            } else {
                startCmd = terminalStartCommand(
                    envExports: envExports,
                    workingDirectory: currentThread.worktreePath
                )
                requestedTabBaseName = "Terminal"
            }

            tabDisplayName = uniqueTabDisplayName(
                baseName: requestedTabBaseName,
                in: currentThread
            )
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

        if currentThread.isMain {
            let mainProjectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: currentThread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: "main")
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: mainProjectName)
        } else {
            let tabProject = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = tabProject?.repoPath ?? currentThread.worktreePath
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_PATH", value: currentThread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: currentThread.name)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: tabProject?.name ?? "project")
        }
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
        if useAgentCommand, let selectedAgentType {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_AGENT_TYPE", value: selectedAgentType.rawValue)
        }

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
        if selectedAgentType != nil {
            threads[index].selectedAgentType = selectedAgentType
        }
        try persistence.saveThreads(threads)

        let tab = Tab(
            threadId: currentThread.id,
            tmuxSessionName: tmuxSessionName,
            index: tabIndex
        )

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        // Inject terminal command (always) and agent context (only for agent tabs)
        let injection = effectiveInjection(for: currentThread.projectId)
        let isAgentTab = shouldMarkAsAgentTab
        injectAfterStart(
            sessionName: tmuxSessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentTab ? injection.agentContext : "",
            initialPrompt: initialPrompt,
            agentType: selectedAgentType
        )

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
        try? persistence.saveThreads(threads)
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
            threads[index].sessionAgentTypes[sessionName] = agentType
            threads[index].agentHasRun = true
        }
        threads[index].lastSelectedTmuxSessionName = sessionName
        try? persistence.saveThreads(threads)
    }

    // MARK: - Tab Pinning & Selection

    func updatePinnedTabs(for threadId: UUID, pinnedSessions: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].pinnedTmuxSessions = pinnedSessions
        try? persistence.saveThreads(threads)
    }

    func updateLastSelectedSession(for threadId: UUID, sessionName: String?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        if threads[index].lastSelectedTmuxSessionName == sessionName { return }
        threads[index].lastSelectedTmuxSessionName = sessionName
        try? persistence.saveThreads(threads)
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

    private func removeTabBySessionName(threadIndex index: Int, sessionName: String) async throws {
        try? await tmux.killSession(name: sessionName)

        // Also remove from pinned, agent, unread completion, waiting, and custom tab names if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].agentTmuxSessions.removeAll { $0 == sessionName }
        threads[index].sessionAgentTypes.removeValue(forKey: sessionName)
        threads[index].unreadCompletionSessions.remove(sessionName)
        threads[index].busySessions.remove(sessionName)
        threads[index].waitingForInputSessions.remove(sessionName)
        threads[index].rateLimitedSessions.removeValue(forKey: sessionName)
        notifiedWaitingSessions.remove(sessionName)
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].tmuxSessionNames.removeAll { $0 == sessionName }
        if threads[index].lastSelectedTmuxSessionName == sessionName {
            threads[index].lastSelectedTmuxSessionName = threads[index].tmuxSessionNames.first
        }
        try persistence.saveThreads(threads)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }
}
