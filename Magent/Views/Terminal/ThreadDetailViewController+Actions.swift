import Cocoa
import GhosttyBridge

extension ThreadDetailViewController {

    // MARK: - Add Tab

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
                    alert.messageText = "Archive Thread"
                    alert.informativeText = "An agent in \"\(threadToArchive.name)\" is currently busy. Archiving will terminate the running agent and remove the worktree directory. The git branch \"\(threadToArchive.branchName)\" will be kept."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Archive Anyway")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                } else if !clean || !merged {
                    let alert = NSAlert()
                    alert.messageText = "Archive Thread"
                    var reasons: [String] = []
                    if !clean { reasons.append("uncommitted changes") }
                    if !merged { reasons.append("commits not in \(baseBranch)") }
                    alert.informativeText = "The thread \"\(threadToArchive.name)\" has \(reasons.joined(separator: " and ")). Archiving will remove its worktree directory but keep the git branch \"\(threadToArchive.branchName)\"."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Archive")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                }

                // Archive directly without a spinner sheet. The delegate-driven
                // reloadData()/showEmptyState() modifies split view items, which
                // crashes if a sheet is being presented on the same window.
                Task {
                    do {
                        try await self.threadManager.archiveThread(threadToArchive)
                    } catch {
                        await MainActor.run {
                            BannerManager.shared.show(
                                message: "Archive failed: \(error.localizedDescription)",
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
                    alert.messageText = "Error"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
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

        let previousThread = thread
        await threadManager.autoRenameThreadAfterFirstPromptIfNeeded(
            threadId: thread.id,
            sessionName: sessionName,
            prompt: trimmed
        )

        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else { return }
        if updated.name != previousThread.name || updated.worktreePath != previousThread.worktreePath {
            handleRename(updated)
        }
    }

    // MARK: - Review

    @objc func reviewButtonTapped() {
        let baseBranch = threadManager.resolveBaseBranch(for: thread)
        let prompt = "Review the changes on this branch compared to \(baseBranch). Run `git diff \(baseBranch)...HEAD` to see the changes, then provide a thorough code review covering correctness, potential bugs, code style, and any suggestions for improvement."
        addTab(using: nil, useAgentCommand: true, initialPrompt: prompt)
    }

    // MARK: - Context Transfer

    @objc func exportContextButtonTapped() {
        exportTabContext(at: currentTabIndex)
    }

    func continueTabInAgent(at index: Int, targetAgent: AgentType) {
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
        let sourceAgent = thread.agentTmuxSessions.contains(sessionName) ? thread.selectedAgentType : nil
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: "Failed to capture terminal content", style: .error)
                }
                return
            }

            let markdown = ContextExporter.formatAsMarkdown(
                rawContent: rawContent,
                sourceAgent: sourceAgent,
                threadName: thread.name,
                projectName: projectName
            )

            guard let contextPath = ContextExporter.writeContextFile(
                markdown: markdown,
                in: thread.worktreePath
            ) else {
                await MainActor.run {
                    BannerManager.shared.show(message: "Failed to write context file", style: .error)
                }
                return
            }

            let prompt = ContextExporter.transferPrompt(
                contextFilePath: contextPath,
                sourceAgent: sourceAgent,
                targetAgent: targetAgent
            )

            await MainActor.run {
                self.addTab(using: targetAgent, useAgentCommand: true, initialPrompt: prompt)
            }
        }
    }

    func exportTabContext(at index: Int) {
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
        let sourceAgent = thread.agentTmuxSessions.contains(sessionName) ? thread.selectedAgentType : nil
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: "Failed to capture terminal content", style: .error)
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
                panel.title = "Export Terminal Context"

                let response = panel.runModal()
                guard response == .OK, let url = panel.url else { return }

                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    BannerManager.shared.show(message: "Context exported to \(url.lastPathComponent)", style: .info)
                } catch {
                    BannerManager.shared.show(message: "Failed to export: \(error.localizedDescription)", style: .error)
                }
            }
        }
    }
}
