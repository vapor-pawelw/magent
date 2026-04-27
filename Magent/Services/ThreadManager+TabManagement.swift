import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Add Tab
    // Complex session creation logic — stays on ThreadManager (coupled to agentStartCommand,
    // terminalStartCommand, injectAfterStart, registerPendingPromptCleanup, etc.).

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

            tabDisplayName = customTitle.map { allocateUniqueTabDisplayName(requestedName: $0, threadIndex: index) }
                ?? allocateUniqueTabDisplayName(
                    requestedName: requestedTabBaseName + (tabNameSuffix ?? ""),
                    threadIndex: index
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

            tabDisplayName = customTitle.map { allocateUniqueTabDisplayName(requestedName: $0, threadIndex: index) }
                ?? allocateUniqueTabDisplayName(
                    requestedName: requestedTabBaseName + (tabNameSuffix ?? ""),
                    threadIndex: index
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
        sessionLifecycleService.sessionTracker.sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt
        threads[index].customTabNames[tmuxSessionName] = tabDisplayName
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Treat explicit custom titles from creation as manual renames so
            // model-detection sync does not replace them with generic defaults.
            threads[index].manuallyRenamedTabs.insert(tmuxSessionName)
        }
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

    /// Returns a unique tab display name using per-thread monotonic suffix counters.
    /// If `requestedName` already exists, append/increment `-N` where N only increases.
    /// Examples: "Codex" -> "Codex-1", "Codex-1" -> "Codex-2".
    func allocateUniqueTabDisplayName(
        requestedName: String,
        threadIndex: Int,
        excludingSessionName: String? = nil
    ) -> String {
        guard threadIndex >= 0, threadIndex < threads.count else {
            let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Tab" : trimmed
        }

        let thread = threads[threadIndex]
        let usedNames = thread.tmuxSessionNames.enumerated().compactMap { index, sessionName -> String? in
            if let excludingSessionName, sessionName == excludingSessionName {
                return nil
            }
            return thread.displayName(for: sessionName, at: index)
        }

        let result = TabNameAllocator.allocate(
            requestedName: requestedName,
            usedNames: usedNames,
            counters: thread.tabNameSuffixCounters
        )

        if let update = result.counterUpdate {
            threads[threadIndex].tabNameSuffixCounters[update.normalizedBase] = update.suffix
        }

        return result.displayName
    }

    // MARK: - Tab Ordering & Registration
    // Forwarded to SessionLifecycleService.

    func reorderTabs(for threadId: UUID, newOrder: [String]) {
        sessionLifecycleService.reorderTabs(for: threadId, newOrder: newOrder)
    }

    func registerFallbackSession(_ sessionName: String, for threadId: UUID, agentType: AgentType?) {
        sessionLifecycleService.registerFallbackSession(sessionName, for: threadId, agentType: agentType)
    }

    // MARK: - Tab Pinning & Selection
    // Forwarded to SessionLifecycleService.

    func updatePinnedTabs(for threadId: UUID, pinnedSessions: [String]) {
        sessionLifecycleService.updatePinnedTabs(for: threadId, pinnedSessions: pinnedSessions)
    }

    func updatePersistedWebTabs(for threadId: UUID, webTabs: [PersistedWebTab]) {
        sessionLifecycleService.updatePersistedWebTabs(for: threadId, webTabs: webTabs)
    }

    func updatePersistedDraftTabs(for threadId: UUID, draftTabs: [PersistedDraftTab]) {
        sessionLifecycleService.updatePersistedDraftTabs(for: threadId, draftTabs: draftTabs)
    }

    func updateLastSelectedTab(for threadId: UUID, identifier: String?) {
        sessionLifecycleService.updateLastSelectedTab(for: threadId, identifier: identifier)
    }

    // MARK: - Closed Tab History

    func pushClosedTabSnapshot(_ snapshot: ClosedTabSnapshot, for threadId: UUID) {
        pruneClosedTabHistoryForMissingThreads()
        var buffer = closedTabHistoryByThreadId[threadId] ?? ClosedTabHistoryBuffer()
        buffer.push(snapshot)
        closedTabHistoryByThreadId[threadId] = buffer
    }

    func popLastClosedTabSnapshot(for threadId: UUID) -> ClosedTabSnapshot? {
        pruneClosedTabHistoryForMissingThreads()
        guard var buffer = closedTabHistoryByThreadId[threadId] else { return nil }
        let popped = buffer.popLast()
        if buffer.isEmpty {
            closedTabHistoryByThreadId.removeValue(forKey: threadId)
        } else {
            closedTabHistoryByThreadId[threadId] = buffer
        }
        return popped
    }

    func hasClosedTabSnapshot(for threadId: UUID) -> Bool {
        pruneClosedTabHistoryForMissingThreads()
        return !(closedTabHistoryByThreadId[threadId]?.isEmpty ?? true)
    }

    private func pruneClosedTabHistoryForMissingThreads() {
        let liveThreadIds = Set(threads.map(\.id))
        closedTabHistoryByThreadId = closedTabHistoryByThreadId.filter { liveThreadIds.contains($0.key) }
    }

    @MainActor
    func setActiveThread(_ threadId: UUID?) {
        sessionLifecycleService.setActiveThread(threadId)
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

        if let sessionIndex = threads[index].tmuxSessionNames.firstIndex(of: sessionName) {
            let snapshot = ClosedTerminalTabSnapshot(
                displayName: threads[index].displayName(for: sessionName, at: sessionIndex),
                isAgentTab: threads[index].agentTmuxSessions.contains(sessionName),
                agentType: threads[index].sessionAgentTypes[sessionName],
                resumeSessionID: threads[index].sessionConversationIDs[sessionName],
                startFresh: threads[index].freshAgentSessions.contains(sessionName),
                isForwardedContinuation: threads[index].forwardedTmuxSessions.contains(sessionName),
                isPinned: threads[index].pinnedTmuxSessions.contains(sessionName)
            )
            pushClosedTabSnapshot(.terminal(snapshot), for: threads[index].id)
        }

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
        // Tab-close can be initiated while this thread is not currently displayed.
        // In that case no ThreadDetailViewController is around to free/evict the view.
        // Evict any cached surface before killing tmux so libghostty cannot terminate
        // the app when the PTY closes on a detached cached terminal.
        ReusableTerminalViewCache.shared.evictSessions([sessionName])

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
        rateLimitLiftPendingResumeSessions.remove(sessionName)
        sessionLastVisitedAt.removeValue(forKey: sessionName)
        sessionLastBusyAt.removeValue(forKey: sessionName)
        lastRuntimeDetectedAgentBySession.removeValue(forKey: sessionName)
        rendererUnhealthySessions.remove(sessionName)
        replayCorruptedSessions.remove(sessionName)
        evictedIdleSessions.remove(sessionName)
        clearTrackedInitialPromptInjection(for: sessionName)
        threads[idx].customTabNames.removeValue(forKey: sessionName)
        threads[idx].manuallyRenamedTabs.remove(sessionName)
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
