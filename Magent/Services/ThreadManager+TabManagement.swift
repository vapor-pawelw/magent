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
        resumeSessionID: String? = nil,
        startFresh: Bool = false,
        isForwardedContinuation: Bool = false,
        customTitle: String? = nil,
        tabNameSuffix: String? = nil,
        pendingPromptFileURL: URL? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) async throws -> Tab {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]
        let sessionCreatedAt = Date()

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
                    workingDirectory: projectPath,
                    resumeSessionID: resumeSessionID,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
                requestedTabBaseName = TmuxSessionNaming.defaultTabDisplayName(
                    for: selectedAgentType,
                    modelLabel: resolvedModelLabel(for: selectedAgentType, modelId: modelId),
                    reasoningLevel: reasoningLevel
                )
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
                    workingDirectory: currentThread.worktreePath,
                    resumeSessionID: resumeSessionID,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
                requestedTabBaseName = TmuxSessionNaming.defaultTabDisplayName(
                    for: selectedAgentType,
                    modelLabel: resolvedModelLabel(for: selectedAgentType, modelId: modelId),
                    reasoningLevel: reasoningLevel
                )
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
        sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt
        threads[index].customTabNames[tmuxSessionName] = tabDisplayName
        threads[index].sessionCreatedAts[tmuxSessionName] = sessionCreatedAt
        let shouldMarkAsAgentTab = (currentThread.isMain || useAgentCommand) && selectedAgentType != nil
        if shouldMarkAsAgentTab {
            threads[index].agentTmuxSessions.append(tmuxSessionName)
            if let selectedAgentType {
                threads[index].sessionAgentTypes[tmuxSessionName] = selectedAgentType
            }
            if startFresh {
                threads[index].freshAgentSessions.insert(tmuxSessionName)
            }
            if let resumeSessionID {
                let trimmedResumeSessionID = resumeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedResumeSessionID.isEmpty {
                    threads[index].sessionConversationIDs[tmuxSessionName] = trimmedResumeSessionID
                }
            }
            threads[index].agentHasRun = true
        }
        if isForwardedContinuation {
            threads[index].forwardedTmuxSessions.insert(tmuxSessionName)
        }
        // Mark session as magent-busy until injection/readiness completes.
        threads[index].magentBusySessions.insert(tmuxSessionName)
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
        if initialPrompt?.isEmpty == false, isAgentTab, shouldSubmitInitialPrompt, !startFresh {
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
        sessionLastVisitedAt[sessionName] = Date()
        if agentType != nil {
            threads[index].agentTmuxSessions.append(sessionName)
            if let agentType {
                threads[index].sessionAgentTypes[sessionName] = agentType
            }
            threads[index].agentHasRun = true
        }
        threads[index].customTabNames[sessionName] = TmuxSessionNaming.defaultTabDisplayName(for: agentType)
        threads[index].lastSelectedTabIdentifier = sessionName
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

    func updatePersistedDraftTabs(for threadId: UUID, draftTabs: [PersistedDraftTab]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].persistedDraftTabs = draftTabs
        try? persistence.saveActiveThreads(threads)
    }

    func updateLastSelectedTab(for threadId: UUID, identifier: String?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        if let identifier {
            sessionLastVisitedAt[identifier] = Date()
            evictedIdleSessions.remove(identifier)
        }
        if threads[index].lastSelectedTabIdentifier == identifier { return }
        threads[index].lastSelectedTabIdentifier = identifier
        try? persistence.saveActiveThreads(threads)
    }

    @MainActor
    func setActiveThread(_ threadId: UUID?) {
        activeThreadId = threadId
        if let threadId,
           let thread = threads.first(where: { $0.id == threadId }) {
            let now = Date()
            for session in thread.tmuxSessionNames {
                sessionLastVisitedAt[session] = now
                evictedIdleSessions.remove(session)
            }
        }
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

        // Destroy the Ghostty surface BEFORE killing the tmux session.
        // killSession is async and suspends the MainActor; while suspended, the terminal
        // process exits and ghostty_app_tick can run on the freed MainActor, crashing on
        // the zombie surface.  By posting the notification first, the observer
        // (handleTabWillCloseNotification) runs synchronously on the MainActor, removing
        // the surface view and calling ghostty_surface_free before any tick can see it.
        let closingThreadId = threads[index].id
        NotificationCenter.default.post(
            name: .magentTabWillClose,
            object: nil,
            userInfo: ["threadId": closingThreadId, "sessionName": sessionName]
        )

        try? await tmux.killSession(name: sessionName)
        NSLog("[TabClose] removeTabBySessionName: killSession done")

        // Re-resolve thread index by ID after the async suspension: another concurrent
        // close might have shifted or removed indices while killSession was running.
        guard let idx = threads.firstIndex(where: { $0.id == closingThreadId }) else {
            NSLog("[TabClose] removeTabBySessionName: thread \(closingThreadId) gone after killSession, returning")
            return
        }

        // Also remove from pinned, agent, unread completion, waiting, and custom tab names if present
        threads[idx].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[idx].protectedTmuxSessions.remove(sessionName)
        threads[idx].agentTmuxSessions.removeAll { $0 == sessionName }
        threads[idx].sessionConversationIDs.removeValue(forKey: sessionName)
        threads[idx].sessionAgentTypes.removeValue(forKey: sessionName)
        threads[idx].sessionCreatedAts.removeValue(forKey: sessionName)
        threads[idx].freshAgentSessions.remove(sessionName)
        threads[idx].forwardedTmuxSessions.remove(sessionName)
        threads[idx].unreadCompletionSessions.remove(sessionName)
        threads[idx].busySessions.remove(sessionName)
        threads[idx].magentBusySessions.remove(sessionName)
        threads[idx].waitingForInputSessions.remove(sessionName)
        threads[idx].hasUnsubmittedInputSessions.remove(sessionName)
        threads[idx].rateLimitedSessions.removeValue(forKey: sessionName)
        notifiedWaitingSessions.remove(sessionName)
        sessionLastVisitedAt.removeValue(forKey: sessionName)
        sessionLastBusyAt.removeValue(forKey: sessionName)
        evictedIdleSessions.remove(sessionName)
        clearTrackedInitialPromptInjection(for: sessionName)
        threads[idx].customTabNames.removeValue(forKey: sessionName)
        threads[idx].submittedPromptsBySession.removeValue(forKey: sessionName)
        threads[idx].tmuxSessionNames.removeAll { $0 == sessionName }
        if threads[idx].lastSelectedTabIdentifier == sessionName {
            threads[idx].lastSelectedTabIdentifier = threads[idx].tmuxSessionNames.first
        }
        NSLog("[TabClose] removeTabBySessionName: saving threads")
        try persistence.saveActiveThreads(threads)
        NSLog("[TabClose] removeTabBySessionName: calling delegate")
        delegate?.threadManager(self, didUpdateThreads: threads)
        NSLog("[TabClose] removeTabBySessionName: done")
    }
}
