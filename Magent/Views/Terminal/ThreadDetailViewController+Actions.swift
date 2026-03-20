import Cocoa
import GhosttyBridge
import MagentCore

extension ThreadDetailViewController {

    private enum TerminalScrollAction {
        case pageUp
        case pageDown
        case bottom
    }

    // MARK: - Add Tab

    @objc func scrollTerminalPageUpTapped() {
        scrollCurrentTerminal(.pageUp)
    }

    @objc func scrollTerminalPageDownTapped() {
        scrollCurrentTerminal(.pageDown)
    }

    @objc func scrollTerminalToBottomTapped() {
        scrollCurrentTerminal(.bottom)
    }

    private func scrollCurrentTerminal(_ action: TerminalScrollAction) {
        guard let sessionName = currentSessionName() else { return }

        Task {
            do {
                switch action {
                case .pageUp:
                    try await TmuxService.shared.scrollPageUp(sessionName: sessionName)
                case .pageDown:
                    try await TmuxService.shared.scrollPageDown(sessionName: sessionName)
                case .bottom:
                    try await TmuxService.shared.scrollToBottom(sessionName: sessionName)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await MainActor.run {
                        self.terminalView(forSession: sessionName)?.bindingAction("scroll_to_bottom")
                    }
                }
                await MainActor.run {
                    self.scheduleScrollFABVisibilityRefresh()
                }
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.terminalScrollFailed(error.localizedDescription)),
                        style: .error
                    )
                }
            }
        }

        if let tv = currentTerminalView() {
            view.window?.makeFirstResponder(tv)
        }
    }

    @objc func archiveThreadTapped() {
        guard !thread.isMain else { return }
        let threadToArchive = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        guard !threadToArchive.isArchiving else { return }

        threadManager.markThreadArchiving(id: threadToArchive.id)
        Task {
            do {
                _ = try await threadManager.archiveThread(threadToArchive, force: true)
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.threadArchiveFailed(error.localizedDescription)),
                        style: .error
                    )
                }
            }
        }
    }

    @objc func resyncLocalPathsTapped() {
        guard !thread.isMain else { return }
        guard let event = NSApp.currentEvent else { return }

        let menu = NSMenu()
        let intoWorktreeItem = NSMenuItem(
            title: "Project → Worktree",
            action: #selector(resyncProjectIntoWorktreeTapped),
            keyEquivalent: ""
        )
        intoWorktreeItem.target = self
        let intoRepoItem = NSMenuItem(
            title: "Worktree → Project",
            action: #selector(resyncWorktreeIntoProjectTapped),
            keyEquivalent: ""
        )
        intoRepoItem.target = self
        menu.addItem(intoWorktreeItem)
        menu.addItem(intoRepoItem)
        NSMenu.popUpContextMenu(menu, with: event, for: resyncLocalPathsButton)
    }

    @objc private func resyncProjectIntoWorktreeTapped() {
        guard !thread.isMain else { return }

        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }

        let syncPaths = threadManager.effectiveLocalSyncPaths(for: currentThread, project: project)
        guard !syncPaths.isEmpty else {
            BannerManager.shared.show(message: "No Local Sync Paths are configured for this thread.", style: .warning)
            return
        }

        startResyncSpinner()
        Task {
            defer { Task { @MainActor in self.stopResyncSpinner() } }
            do {
                let missingPaths = try await self.threadManager.syncConfiguredLocalPathsIntoWorktree(
                    project: project,
                    worktreePath: currentThread.worktreePath,
                    syncPaths: syncPaths,
                    promptForConflicts: true
                )

                await MainActor.run {
                    if missingPaths.isEmpty {
                        BannerManager.shared.show(
                            message: "Local Sync Paths refreshed from the main repo.",
                            style: .info
                        )
                    } else {
                        let noun = missingPaths.count == 1 ? "path was" : "paths were"
                        BannerManager.shared.show(
                            message: "Local Sync refresh finished, but \(missingPaths.count) configured \(noun) missing in the main repo.",
                            style: .warning,
                            duration: 8.0,
                            details: missingPaths.joined(separator: "\n"),
                            detailsCollapsedTitle: "Show missing paths",
                            detailsExpandedTitle: "Hide missing paths"
                        )
                    }
                }
            } catch ThreadManagerError.archiveCancelled {
                return
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Failed to resync Local Sync Paths: \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

    @objc private func resyncWorktreeIntoProjectTapped() {
        guard !thread.isMain else { return }

        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }

        let syncPaths = threadManager.effectiveLocalSyncPaths(for: currentThread, project: project)
        guard !syncPaths.isEmpty else {
            BannerManager.shared.show(message: "No Local Sync Paths are configured for this thread.", style: .warning)
            return
        }

        startResyncSpinner()
        Task {
            defer { Task { @MainActor in self.stopResyncSpinner() } }
            do {
                try await self.threadManager.syncConfiguredLocalPathsFromWorktree(
                    project: project,
                    worktreePath: currentThread.worktreePath,
                    syncPaths: syncPaths,
                    promptForConflicts: true
                )
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Local Sync Paths pushed back to the main repo.",
                        style: .info
                    )
                }
            } catch ThreadManagerError.archiveCancelled {
                return
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Failed to sync Local Sync Paths to main repo: \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

    private func startResyncSpinner() {
        resyncLocalPathsButton.isEnabled = false
        resyncLocalPathsButton.image = NSImage(
            systemSymbolName: "progress.indicator",
            accessibilityDescription: "Syncing"
        )
    }

    private func stopResyncSpinner() {
        resyncLocalPathsButton.isEnabled = true
        resyncLocalPathsButton.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Resync Local Paths"
        )
        resyncLocalPathsButton.isHidden = resyncLocalPathsButtonShouldBeHidden()
    }

    @objc func addTabTapped() {
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            addTab(using: nil, useAgentCommand: true)
        } else {
            presentNewTabSheet()
        }
    }

    private func presentNewTabSheet() {
        guard let window = view.window else { return }
        let settings = PersistenceService.shared.loadSettings()
        let injection = threadManager.effectiveInjection(for: thread.projectId)
        let config = AgentLaunchSheetConfig(
            title: "New Tab",
            acceptButtonTitle: "Add Tab",
            draftScope: .newTab(threadId: thread.id),
            availableAgents: settings.availableActiveAgents,
            defaultAgentType: threadManager.effectiveAgentType(for: thread.projectId),
            subtitle: "Thread: \(thread.isMain ? "Main" : (thread.taskDescription.map { "\($0) (\(thread.branchName))" } ?? thread.branchName))",
            showDescriptionAndBranchFields: false,
            showTitleField: true,
            autoGenerateHint: nil,
            terminalInjectionPrefill: injection.terminalCommand.isEmpty ? nil : injection.terminalCommand,
            agentContextPrefill: injection.agentContext.isEmpty ? nil : injection.agentContext
        )
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            guard let self, let result else { return }
            self.addTab(
                using: result.agentType,
                useAgentCommand: result.useAgentCommand,
                initialPrompt: result.prompt,
                shouldSubmitInitialPrompt: true,
                customTitle: result.tabTitle,
                pendingPromptFileURL: result.pendingPromptFileURL
            )
        }
    }

    private func addTab(
        using agentType: AgentType?,
        useAgentCommand: Bool,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        customTitle: String? = nil,
        pendingPromptFileURL: URL? = nil,
        tabNameSuffix: String? = nil
    ) {
        // Phase 1: Immediately add a tab item and show "Creating tab..." overlay so
        // the tab appears in the bar without waiting for tmux session creation.
        hideEmptyState()
        let pendingIndex = tabItems.count
        let item = TabItemView(title: "New Tab")
        item.showCloseButton = false
        attachDragGesture(to: item)
        tabItems.append(item)
        tabSlots.append(.terminal(sessionName: ""))
        rebindAllTabActions()
        rebuildTabBar()

        // Mark the new tab as selected in the tab bar.
        for (i, item) in tabItems.enumerated() { item.isSelected = (i == pendingIndex) }

        // Hide current terminal/web content so the old tab doesn't show through.
        for termView in terminalViews { termView.isHidden = true }
        hideActiveWebTab()

        // Show "Creating tab..." overlay immediately.
        ensureLoadingOverlay()
        loadingLabel?.stringValue = String(localized: .ThreadStrings.tabCreatingSession)
        loadingOverlay?.alphaValue = 1
        loadingOverlay?.isHidden = false
        loadingDetailLabel?.isHidden = true

        // Phase 2: Run tmux setup in the background; overlay stays visible throughout.
        Task {
            do {
                let tab = try await threadManager.addTab(
                    to: thread,
                    useAgentCommand: useAgentCommand,
                    requestedAgentType: agentType,
                    initialPrompt: initialPrompt,
                    shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                    customTitle: customTitle,
                    tabNameSuffix: tabNameSuffix,
                    pendingPromptFileURL: pendingPromptFileURL
                )
                // Skip recreateSessionIfNeeded — the session was just created by addTab().
                // Calling it here risks a race: the pane path check can fail during shell
                // startup (before ZDOTDIR cd completes), causing the session to be killed
                // and recreated without the initial prompt. Bell monitoring is set up
                // separately by createSession → configureBellMonitoring.
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }
                    let terminalView = self.makeTerminalView(for: tab.tmuxSessionName)
                    self.terminalViews.append(terminalView)

                    // Fix the placeholder slot with the real session name.
                    if pendingIndex < self.tabSlots.count {
                        self.tabSlots[pendingIndex] = .terminal(sessionName: tab.tmuxSessionName)
                    }
                    self.requireStartupOverlay(for: tab.tmuxSessionName)

                    // Update tab title and make it closable.
                    let title = self.thread.displayName(for: tab.tmuxSessionName, at: pendingIndex)
                    if pendingIndex < self.tabItems.count {
                        self.tabItems[pendingIndex].titleLabel.stringValue = title
                        self.tabItems[pendingIndex].showCloseButton = true
                    }
                    self.rebindAllTabActions()

                    // Dismiss the "Creating tab..." overlay before handing off to selectTab,
                    // which will show its own "Starting agent..." overlay if needed.
                    self.dismissLoadingOverlay()

                    // Hand off to normal selectTab flow, which shows "Starting agent..." overlay.
                    self.selectTab(at: pendingIndex)
                }
            } catch {
                await MainActor.run {
                    // Remove the pending tab on error.
                    if pendingIndex < self.tabItems.count {
                        self.tabItems.remove(at: pendingIndex)
                    }
                    if pendingIndex < self.tabSlots.count {
                        self.tabSlots.remove(at: pendingIndex)
                    }
                    self.rebindAllTabActions()
                    self.rebuildTabBar()
                    self.dismissLoadingOverlay()
                    if self.tabItems.isEmpty {
                        self.showEmptyState()
                    } else {
                        self.selectTab(at: max(0, pendingIndex - 1))
                    }
                    let alert = NSAlert()
                    alert.messageText = String(localized: .CommonStrings.commonError)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    alert.runModal()
                }
            }
        }
    }

    func addTabFromKeyboard() {
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            addTab(using: nil, useAgentCommand: true)
        } else {
            presentNewTabSheet()
        }
    }

    // MARK: - Update & Rename

    func updateThread(_ updated: MagentThread) {
        thread = updated
        refreshTabStatusIndicators()
        refreshReviewButtonVisibility()
        schedulePromptTOCRefresh()
    }

    func handleRename(_ updated: MagentThread) {
        thread = updated

        // Update onCopy/onSubmitLine closures to use the new (renamed) tmux session names.
        // terminalViews are indexed by thread.tmuxSessionNames (creation order).
        for (termIdx, terminalView) in terminalViews.enumerated() {
            if termIdx < thread.tmuxSessionNames.count {
                let newSessionName = thread.tmuxSessionNames[termIdx]
                terminalView.onCopy = {
                    Task { await TmuxService.shared.copySelectionToClipboard(sessionName: newSessionName) }
                }
                terminalView.onSubmitLine = { [weak self, sessionName = newSessionName] line in
                    Task { @MainActor [weak self] in
                        await self?.handleSubmittedLine(line, sessionName: sessionName)
                    }
                }
            }
        }

        // Rebuild tabSlots with updated session names (rename may have changed them).
        for (displayIdx, slot) in tabSlots.enumerated() {
            if case .terminal = slot, displayIdx < tabItems.count {
                // Find the new session name for this display position.
                // After rename, the session order in tmuxSessionNames corresponds to terminalViews order.
                // We need to map old slot session name → new session name via the rename map
                // that ThreadManager already applied. Just rebuild from thread state.
            }
        }
        // Simpler: rebuild tabSlots terminal entries from the current thread.tmuxSessionNames
        // preserving the display order. Match by position in the terminal-only subsequence.
        var terminalSlotPositions: [Int] = []
        for (i, slot) in tabSlots.enumerated() {
            if case .terminal = slot { terminalSlotPositions.append(i) }
        }
        for (seqIdx, displayIdx) in terminalSlotPositions.enumerated() {
            if seqIdx < thread.tmuxSessionNames.count {
                let newName = thread.tmuxSessionNames[seqIdx]
                tabSlots[displayIdx] = .terminal(sessionName: newName)
                if displayIdx < tabItems.count {
                    tabItems[displayIdx].titleLabel.stringValue = thread.displayName(for: newName, at: displayIdx)
                }
            }
        }

        refreshTabStatusIndicators()
        schedulePromptTOCRefresh()
    }

    private func refreshTabStatusIndicators() {
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
                tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
                tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
            } else {
                tabItems[i].hasUnreadCompletion = false
                tabItems[i].hasWaitingForInput = false
                tabItems[i].hasBusy = false
                tabItems[i].hasRateLimit = false
            }
        }
    }

    @MainActor
    func handleSubmittedLine(_ line: String, sessionName: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if thread.agentTmuxSessions.contains(sessionName) {
            threadManager.markSessionBusy(threadId: thread.id, sessionName: sessionName)
        }

        if thread.agentTmuxSessions.contains(sessionName) {
            threadManager.scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: sessionName)
        } else if let resolvedSession = currentSessionName() {
            if thread.agentTmuxSessions.contains(resolvedSession) {
                threadManager.scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: resolvedSession)
            }
        }

        let threadId = thread.id
        Task {
            await threadManager.generateTaskDescriptionIfNeeded(threadId: threadId, prompt: trimmed)
        }

        if thread.lastSelectedTmuxSessionName == sessionName {
            schedulePromptTOCRefresh(after: 0.2)
        }
    }

    // MARK: - Review

    @objc func reviewButtonTapped() {
        let settings = PersistenceService.shared.loadSettings()
        let activeAgents = settings.availableActiveAgents
        guard !activeAgents.isEmpty else {
            BannerManager.shared.show(message: String(localized: .NotificationStrings.reviewEnableAgentWarning), style: .warning)
            return
        }

        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            startReview(using: defaultReviewAgentType(from: settings))
            return
        }

        let menu = NSMenu()
        AgentMenuBuilder.populate(
            menu: menu,
            menuTitle: "Review Changes",
            defaultAgentName: defaultReviewAgentType(from: settings)?.displayName,
            activeAgents: activeAgents,
            includeTerminal: false,
            target: self,
            action: #selector(reviewMenuItemTapped(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: reviewButton.bounds.minX, y: reviewButton.bounds.minY), in: reviewButton)
    }

    @objc private func reviewMenuItemTapped(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender) else { return }

        switch selection.mode {
        case .agent(let agentType):
            startReview(using: agentType)
        case .projectDefault:
            let settings = PersistenceService.shared.loadSettings()
            startReview(using: defaultReviewAgentType(from: settings))
        case .terminal:
            return
        }
    }

    private func startReview(using agentType: AgentType?) {
        guard let agentType else {
            BannerManager.shared.show(message: String(localized: .NotificationStrings.reviewEnableAgentWarning), style: .warning)
            return
        }

        addTab(using: agentType, useAgentCommand: true, initialPrompt: reviewPrompt(), tabNameSuffix: "-review")
    }

    private func defaultReviewAgentType(from settings: AppSettings) -> AgentType? {
        threadManager.resolveAgentType(for: thread.projectId, requestedAgentType: nil, settings: settings)
    }

    private func reviewPrompt() -> String {
        let baseBranch = threadManager.resolveBaseBranch(for: thread)
        let settings = PersistenceService.shared.loadSettings()
        return settings.reviewPrompt.replacingOccurrences(of: "{baseBranch}", with: baseBranch)
    }

    // MARK: - Context Transfer

    @objc func exportContextButtonTapped() {
        exportTabContext(at: currentTabIndex)
    }

    @objc func togglePromptTOCTapped() {
        togglePromptTOCVisibility()
    }

    @objc func continueInButtonTapped(_ sender: NSButton) {
        let settings = PersistenceService.shared.loadSettings()
        let agents = settings.availableActiveAgents
        guard !agents.isEmpty else { return }

        let menu = NSMenu()
        for agent in agents {
            let item = NSMenuItem(
                title: agent.displayName,
                action: #selector(continueInAgentMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = agent
            menu.addItem(item)
        }

        let point = NSPoint(x: 0, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc func continueInAgentMenuItemTapped(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentType else { return }
        continueTabInAgent(at: currentTabIndex, targetAgent: agent)
    }

    func continueTabInAgent(at index: Int, targetAgent: AgentType) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        let sourceAgent = threadManager.effectiveAgentType(for: thread.projectId)
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"
        let contextBasePath = project?.resolvedWorktreesBasePath()

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextCaptureTerminalFailed), style: .error)
                }
                return
            }

            let markdown = ContextExporter.formatAsMarkdown(
                rawContent: rawContent,
                sourceAgent: sourceAgent,
                threadName: thread.name,
                projectName: projectName
            )

            guard let contextBasePath else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextWriteFileFailed), style: .error)
                }
                return
            }

            guard let contextPath = ContextExporter.writeContextFile(
                markdown: markdown,
                inWorktreesBasePath: contextBasePath
            ) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextWriteFileFailed), style: .error)
                }
                return
            }

            let prompt = ContextExporter.transferPrompt(contextFilePath: contextPath)

            await MainActor.run {
                self.addTab(using: targetAgent, useAgentCommand: true, initialPrompt: prompt)
            }
        }
    }

    func exportTabContext(at index: Int) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        let sourceAgent = threadManager.effectiveAgentType(for: thread.projectId)
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextCaptureTerminalFailed), style: .error)
                }
                return
            }

            let markdown = ContextExporter.formatAsMarkdown(
                rawContent: rawContent,
                sourceAgent: sourceAgent,
                threadName: thread.name,
                projectName: projectName
            )

            await MainActor.run {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.init(filenameExtension: "md")!]
                panel.nameFieldStringValue = "context-\(self.thread.name).md"
                panel.title = String(localized: .NotificationStrings.contextExportPanelTitle)

                let response = panel.runModal()
                guard response == .OK, let url = panel.url else { return }

                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextExported(url.lastPathComponent)), style: .info)
                } catch {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextExportFailed(error.localizedDescription)), style: .error)
                }
            }
        }
    }

}

// MARK: - Add Tab Context Menu

extension ThreadDetailViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === addTabButton.menu else { return }
        menu.removeAllItems()
        let settings = PersistenceService.shared.loadSettings()
        AgentMenuBuilder.populate(
            menu: menu,
            menuTitle: "New Tab",
            defaultAgentName: threadManager.effectiveAgentType(for: thread.projectId)?.displayName,
            activeAgents: settings.availableActiveAgents,
            target: self,
            action: #selector(addTabContextMenuItemSelected(_:))
        )
    }

    @objc private func addTabContextMenuItemSelected(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender) else { return }
        switch selection.mode {
        case .terminal:
            addTab(using: nil, useAgentCommand: false)
        case .agent(let agentType):
            addTab(using: agentType, useAgentCommand: true)
        case .projectDefault:
            addTab(using: nil, useAgentCommand: true)
        }
    }

}
