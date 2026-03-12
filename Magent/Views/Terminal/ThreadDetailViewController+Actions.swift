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
        let currentIndex = currentTabIndex

        Task {
            do {
                switch action {
                case .pageUp:
                    try await TmuxService.shared.scrollPageUp(sessionName: sessionName)
                case .pageDown:
                    try await TmuxService.shared.scrollPageDown(sessionName: sessionName)
                case .bottom:
                    try await TmuxService.shared.scrollToBottom(sessionName: sessionName)
                    // Give tmux time to redraw the live pane after exiting copy-mode,
                    // then scroll ghostty's own viewport to the new bottom so that
                    // the most recent output is visible at the bottom of the viewport.
                    // Resolve the view by sessionName at execution time — the tab
                    // array may have changed (close/reorder) during the delay.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await MainActor.run {
                        if let i = self.thread.tmuxSessionNames.firstIndex(of: sessionName),
                           i < self.terminalViews.count {
                            self.terminalViews[i].bindingAction("scroll_to_bottom")
                        }
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

        if currentIndex < terminalViews.count {
            view.window?.makeFirstResponder(terminalViews[currentIndex])
        }
    }

    @objc func archiveThreadTapped() {
        guard !thread.isMain else { return }
        let threadToArchive = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread

        let baseBranch = threadManager.resolveBaseBranch(for: threadToArchive)

        Task {
            let git = GitService.shared
            let clean = await git.isClean(worktreePath: threadToArchive.worktreePath)
            let merged = await git.isMergedInto(worktreePath: threadToArchive.worktreePath, baseBranch: baseBranch)

            await MainActor.run {
                let agentBusy = threadToArchive.hasAgentBusy

                if agentBusy {
                    let alert = NSAlert()
                    alert.messageText = String(localized: .ThreadStrings.threadArchiveTitle)
                    alert.informativeText = String(
                        localized: .ThreadStrings.threadArchiveBusyMessage(
                            threadToArchive.name,
                            threadToArchive.branchName
                        )
                    )
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonArchiveAnyway))
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                } else if !clean || !merged {
                    let alert = NSAlert()
                    alert.messageText = String(localized: .ThreadStrings.threadArchiveTitle)
                    var reasons: [String] = []
                    if !clean { reasons.append(String(localized: .ThreadStrings.threadArchiveReasonUncommittedChanges)) }
                    if !merged { reasons.append(String(localized: .ThreadStrings.threadArchiveReasonCommitsNotIn(baseBranch))) }
                    alert.informativeText = String(
                        localized: .ThreadStrings.threadArchiveReasonsMessage(
                            threadToArchive.name,
                            reasons.joined(separator: String(localized: .CommonStrings.commonJoinAnd)),
                            threadToArchive.branchName
                        )
                    )
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonArchive))
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                }

                // Archive directly without a spinner sheet. The delegate-driven
                // reloadData()/showEmptyState() swaps the main content controller,
                // which has been unsafe while a sheet is presented on the same window.
                Task {
                    do {
                        _ = try await self.threadManager.archiveThread(
                            threadToArchive,
                            promptForLocalSyncConflicts: true
                        )
                    } catch ThreadManagerError.archiveCancelled {
                        return
                    } catch ThreadManagerError.localFileSyncFailed(let message) {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = String(localized: .ThreadStrings.threadArchiveLocalSyncFailedTitle)
                            alert.informativeText = String(localized: .ThreadStrings.threadArchiveLocalSyncFailedMessage(message))
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: String(localized: .CommonStrings.commonForceArchive))
                            alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                            let response = alert.runModal()
                            guard response == .alertFirstButtonReturn else { return }

                            Task {
                                do {
                                    _ = try await self.threadManager.archiveThread(
                                        threadToArchive,
                                        promptForLocalSyncConflicts: false,
                                        force: true
                                    )
                                } catch ThreadManagerError.archiveCancelled {
                                    return
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
        }
    }

    @objc func addTabTapped() {
        presentAddTabAgentMenu()
    }

    private func presentAddTabAgentMenu() {
        let settings = PersistenceService.shared.loadSettings()
        let menu = NSMenu()
        AgentMenuBuilder.populate(
            menu: menu,
            menuTitle: String(localized: .ThreadStrings.threadNewTabMenuTitle),
            defaultAgentName: threadManager.effectiveAgentType(for: thread.projectId)?.displayName,
            activeAgents: settings.availableActiveAgents,
            target: self,
            action: #selector(addTabMenuItemTapped(_:))
        )
        menu.popUp(positioning: nil, at: NSPoint(x: addTabButton.bounds.minX, y: addTabButton.bounds.minY), in: addTabButton)
    }

    @objc private func addTabMenuItemTapped(_ sender: NSMenuItem) {
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

    private func addTab(using agentType: AgentType?, useAgentCommand: Bool, initialPrompt: String? = nil) {
        Task {
            do {
                let tab = try await threadManager.addTab(
                    to: thread,
                    useAgentCommand: useAgentCommand,
                    requestedAgentType: agentType,
                    initialPrompt: initialPrompt
                )
                let latestThread = self.threadManager.threads.first(where: { $0.id == self.thread.id }) ?? self.thread
                _ = await self.threadManager.recreateSessionIfNeeded(
                    sessionName: tab.tmuxSessionName,
                    thread: latestThread
                )
                await MainActor.run {
                    self.hideEmptyState()
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }
                    let terminalView = self.makeTerminalView(for: tab.tmuxSessionName)
                    self.terminalViews.append(terminalView)

                    let index = self.tabItems.count
                    let title = self.thread.displayName(for: tab.tmuxSessionName, at: index)
                    self.createTabItem(title: title, closable: true)
                    self.rebuildTabBar()
                    self.selectTab(at: index)
                }
            } catch {
                await MainActor.run {
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
        addTabTapped()
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

        // Update onCopy closures to use the new (renamed) tmux session names
        for (i, terminalView) in terminalViews.enumerated() {
            if i < thread.tmuxSessionNames.count {
                let newSessionName = thread.tmuxSessionNames[i]
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

        // Refresh tab labels to reflect re-keyed custom names
        for (i, item) in tabItems.enumerated() where i < thread.tmuxSessionNames.count {
            item.titleLabel.stringValue = thread.displayName(for: thread.tmuxSessionNames[i], at: i)
        }
        refreshTabStatusIndicators()
        schedulePromptTOCRefresh()
    }

    private func refreshTabStatusIndicators() {
        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
            tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
            tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
            tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
            tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
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
        } else if currentTabIndex < thread.tmuxSessionNames.count {
            let resolvedSession = thread.tmuxSessionNames[currentTabIndex]
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

        addTab(using: agentType, useAgentCommand: true, initialPrompt: reviewPrompt())
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

    func continueTabInAgent(at index: Int, targetAgent: AgentType) {
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
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
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
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
