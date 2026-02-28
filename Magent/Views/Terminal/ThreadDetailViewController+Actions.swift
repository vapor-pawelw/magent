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
                if clean && merged {
                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(threadToArchive)
                    }
                } else {
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

                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(threadToArchive)
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
        let activeAgents = settings.availableActiveAgents

        let menu = NSMenu()

        if let defaultAgent = threadManager.effectiveAgentType(for: thread.projectId) {
            let defaultItem = NSMenuItem(
                title: "Use Project Default (\(defaultAgent.displayName))",
                action: #selector(addTabMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            defaultItem.target = self
            defaultItem.representedObject = ["mode": "default"] as [String: String]
            menu.addItem(defaultItem)
        }

        for agent in activeAgents {
            let item = NSMenuItem(title: agent.displayName, action: #selector(addTabMenuItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["mode": "agent", "agentRaw": agent.rawValue] as [String: String]
            menu.addItem(item)
        }

        if menu.items.count > 0 {
            menu.addItem(.separator())
        }

        let terminalItem = NSMenuItem(
            title: "Terminal",
            action: #selector(addTabMenuItemTapped(_:)),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.representedObject = ["mode": "terminal"] as [String: String]
        menu.addItem(terminalItem)

        menu.popUp(positioning: nil, at: NSPoint(x: addTabButton.bounds.minX, y: addTabButton.bounds.minY), in: addTabButton)
    }

    @objc private func addTabMenuItemTapped(_ sender: NSMenuItem) {
        let data = sender.representedObject as? [String: String]
        let mode = data?["mode"] ?? "default"
        switch mode {
        case "terminal":
            addTab(using: nil, useAgentCommand: false)
        case "agent":
            let raw = data?["agentRaw"] ?? ""
            addTab(using: AgentType(rawValue: raw), useAgentCommand: true)
        default:
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
                    self.createTabItem(title: "Tab \(index)", closable: true)
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

    // MARK: - Close Tab

    func closeCurrentTab() {
        closeTab(at: currentTabIndex)
    }

    func closeTab(at index: Int) {
        guard index < thread.tmuxSessionNames.count else { return }

        let sessionName = thread.tmuxSessionNames[index]

        let alert = NSAlert()
        alert.messageText = "Close Tab"
        alert.informativeText = "This will close the terminal session. Are you sure?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await threadManager.removeTab(from: thread, sessionName: sessionName)
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }

                    self.terminalViews[index].removeFromSuperview()
                    self.terminalViews.remove(at: index)

                    self.tabItems.remove(at: index)

                    // Adjust pinnedCount and primaryTabIndex
                    if index < self.pinnedCount {
                        self.pinnedCount -= 1
                    }
                    if index == self.primaryTabIndex {
                        // Primary tab was closed — assign to first remaining tab
                        self.primaryTabIndex = 0
                    } else if self.primaryTabIndex > index {
                        self.primaryTabIndex -= 1
                    }

                    self.rebindTabActions()
                    self.rebuildTabBar()

                    if self.tabItems.isEmpty {
                        self.showEmptyState()
                    } else {
                        let newIndex = min(index, self.tabItems.count - 1)
                        self.selectTab(at: newIndex)
                    }
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

    // MARK: - Rename Dialog

    func showTabRenameDialog(at index: Int) {
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
        let currentCustomName = thread.customTabNames[sessionName]
        let defaultName = index == 0 ? "Main" : "Tab \(index)"

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentCustomName ?? ""
        textField.placeholderString = defaultName
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != currentCustomName else { return }

        Task {
            do {
                try await threadManager.renameTab(
                    threadId: thread.id,
                    sessionName: sessionName,
                    newDisplayName: newName
                )
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                        // Update tab label
                        if index < self.tabItems.count {
                            self.tabItems[index].titleLabel.stringValue = updated.displayName(
                                for: updated.tmuxSessionNames[index],
                                at: index
                            )
                        }
                        // Re-bind closures in case session name changed
                        self.handleRename(updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Rename Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Loading Overlay

    func setupLoadingOverlay() {
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Starting agent...")
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        loadingOverlay = overlay

        let sessionName: String
        if thread.isMain {
            let settings = PersistenceService.shared.loadSettings()
            let slug = ThreadManager.repoSlug(from:
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            let firstTabSlug = ThreadManager.sanitizeForTmux(MagentThread.defaultDisplayName(at: 0))
            sessionName = thread.tmuxSessionNames.first ?? ThreadManager.buildSessionName(repoSlug: slug, threadName: nil, tabSlug: firstTabSlug)
        } else {
            let settings = PersistenceService.shared.loadSettings()
            let slug = ThreadManager.repoSlug(from:
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            let firstTabSlug = ThreadManager.sanitizeForTmux(MagentThread.defaultDisplayName(at: 0))
            sessionName = thread.tmuxSessionNames.first ?? ThreadManager.buildSessionName(repoSlug: slug, threadName: thread.name, tabSlug: firstTabSlug)
        }
        let startTime = Date()
        let maxWait: TimeInterval = 15

        loadingPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= maxWait {
                timer.invalidate()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.loadingPollTimer = nil
                    self.dismissLoadingOverlay()
                }
                return
            }

            Task {
                let ready = await self.isAgentReady(sessionName: sessionName)
                if ready {
                    await MainActor.run {
                        self.loadingPollTimer?.invalidate()
                        self.loadingPollTimer = nil
                        self.dismissLoadingOverlay()
                    }
                }
            }
        }
    }

    private func isAgentReady(sessionName: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "tmux capture-pane -t '\(sessionName)' -p 2>/dev/null"
        )
        guard result.exitCode == 0 else { return false }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains("╭") || output.contains("Claude") || output.count > 50
    }

    private func dismissLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadingOverlay?.removeFromSuperview()
                self?.loadingOverlay = nil
            }
        }
    }

    private func performWithSpinner(message: String, errorTitle: String, work: @escaping () async throws -> Void) {
        guard let window = view.window else { return }

        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: sheetVC.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: sheetVC.view.centerYAnchor),
        ])

        window.contentViewController?.presentAsSheet(sheetVC)

        Task {
            do {
                try await work()
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                }
            } catch {
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                    let alert = NSAlert()
                    alert.messageText = errorTitle
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Pin/Unpin

    func togglePin(at index: Int) {
        if index < pinnedCount {
            unpinTab(at: index)
        } else {
            pinTab(at: index)
        }
    }

    private func pinTab(at index: Int) {
        guard index >= pinnedCount else { return }
        moveTab(from: index, to: pinnedCount)
        pinnedCount += 1
        rebindTabActions()
        rebuildTabBar()
        persistTabOrder()
    }

    private func unpinTab(at index: Int) {
        guard index < pinnedCount else { return }
        pinnedCount -= 1
        moveTab(from: index, to: pinnedCount)
        rebindTabActions()
        rebuildTabBar()
        persistTabOrder()
    }
}

// MARK: - NSGestureRecognizerDelegate

extension ThreadDetailViewController: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? NSPanGestureRecognizer,
              let tabView = pan.view as? TabItemView else { return true }

        let location = pan.location(in: tabView)
        let closeBounds = tabView.closeButton.convert(tabView.closeButton.bounds, to: tabView)
        if closeBounds.contains(location) { return false }

        return true
    }
}
