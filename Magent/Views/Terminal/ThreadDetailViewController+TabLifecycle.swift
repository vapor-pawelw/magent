import Cocoa
import GhosttyBridge
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Close Tab

    func closeCurrentTab() {
        closeTab(at: currentTabIndex)
    }

    func closeTab(at index: Int) {
        guard index < tabSlots.count else { return }

        switch tabSlots[index] {
        case .terminal(let sessionName):
            GhosttyAppManager.log("closeTab: terminal session=\(sessionName) displayIndex=\(index)")

            let alert = NSAlert()
            alert.messageText = String(localized: .ThreadStrings.tabCloseTitle)
            alert.informativeText = String(localized: .ThreadStrings.tabCloseMessage)
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: .CommonStrings.commonClose))
            alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            Task {
                do {
                    try await threadManager.removeTab(from: thread, sessionName: sessionName)
                    if let updated = threadManager.threads.first(where: { $0.id == thread.id }) {
                        thread = updated
                    }
                } catch {
                    let alert = NSAlert()
                    alert.messageText = String(localized: .CommonStrings.commonError)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    alert.runModal()
                }
            }

        case .web(let identifier):
            let alert = NSAlert()
            alert.messageText = String(localized: .ThreadStrings.tabCloseTitle)
            alert.informativeText = String(localized: .ThreadStrings.webTabCloseMessage)
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: .CommonStrings.commonClose))
            alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            closeWebTab(identifier: identifier)
        }
    }

    // MARK: - Close Multiple Tabs

    func closeTabsToTheRight(of index: Int) {
        let count = tabSlots.count
        guard index < count - 1 else { return }
        let tabCount = count - index - 1

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.tabsCloseRightTitle)
        alert.informativeText = tabCount == 1
            ? String(localized: .ThreadStrings.tabsCloseRightMessageOne(tabCount))
            : String(localized: .ThreadStrings.tabsCloseRightMessageMany(tabCount))
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: .CommonStrings.commonClose))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let slotsToClose = Array(tabSlots[(index + 1)...])
        batchCloseSlots(slotsToClose)
    }

    func closeTabsToTheLeft(of index: Int) {
        guard index > 0 else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.tabsCloseLeftTitle)
        alert.informativeText = index == 1
            ? String(localized: .ThreadStrings.tabsCloseLeftMessageOne(index))
            : String(localized: .ThreadStrings.tabsCloseLeftMessageMany(index))
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: .CommonStrings.commonClose))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let slotsToClose = Array(tabSlots[..<index])
        batchCloseSlots(slotsToClose)
    }

    /// Close a batch of slots (terminal + web).
    private func batchCloseSlots(_ slots: [TabSlot]) {
        var terminalSessionsToClose: [String] = []
        var webIdsToClose: [String] = []
        for slot in slots {
            switch slot {
            case .terminal(let name): terminalSessionsToClose.append(name)
            case .web(let id): webIdsToClose.append(id)
            }
        }
        // Close web tabs first (synchronous)
        for id in webIdsToClose {
            closeWebTab(identifier: id)
        }
        // Close terminal tabs (async, handled by handleTabWillCloseNotification)
        if !terminalSessionsToClose.isEmpty {
            batchCloseTabs(sessionNames: terminalSessionsToClose)
        }
    }

    /// Closes multiple terminal tabs by session name in a single sequential Task.
    /// UI cleanup for each tab is handled synchronously by `handleTabWillCloseNotification`.
    func batchCloseTabs(sessionNames: [String]) {
        Task {
            for sessionName in sessionNames {
                do {
                    try await threadManager.removeTab(from: thread, sessionName: sessionName)
                } catch {
                    // Skip tabs that fail to close
                }
            }
            await MainActor.run {
                if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                    self.thread = updated
                }
                if self.tabItems.isEmpty {
                    self.showEmptyState()
                } else {
                    let newIndex = min(self.currentTabIndex, self.tabItems.count - 1)
                    self.selectTab(at: newIndex)
                }
            }
        }
    }

    // MARK: - Rename Dialog

    func showTabRenameDialog(at index: Int) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        let currentCustomName = thread.customTabNames[sessionName]
        let defaultName = MagentThread.defaultDisplayName(at: index)

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.tabRenameTitle)
        alert.informativeText = String(localized: .ThreadStrings.tabRenameMessage)
        alert.addButton(withTitle: String(localized: .CommonStrings.commonRename))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

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
                        // Re-bind closures and labels in case session name changed
                        self.handleRename(updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: .CommonStrings.commonRenameFailed)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Loading Overlay

    func ensureLoadingOverlay() {
        guard loadingOverlay == nil else { return }

        let overlay = AppBackgroundView()
        overlay.wantsLayer = true
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: String(localized: .ThreadStrings.tabStartingAgent))
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel = label

        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.isHidden = true

        let stack = NSStackView(views: [spinner, label, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 8
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
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -40),
        ])

        loadingOverlay = overlay
        loadingDetailLabel = detailLabel
    }

    @MainActor
    func startLoadingOverlayTracking(sessionName: String, agentType: AgentType?) {
        loadingPollTimer?.invalidate()
        loadingPollTimer = nil

        // Clean up any previous injection observers
        for obs in loadingOverlayInjectionObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        loadingOverlayInjectionObservers.removeAll()
        loadingOverlayWaitingForInjection = false

        ensureLoadingOverlay()
        loadingLabel?.stringValue = String(localized: .ThreadStrings.tabStartingAgent)

        guard thread.agentTmuxSessions.contains(sessionName), let agentType else {
            dismissLoadingOverlay()
            return
        }

        loadingOverlay?.alphaValue = 1
        loadingOverlay?.isHidden = false
        loadingDetailLabel?.stringValue = ""
        loadingDetailLabel?.isHidden = true
        loadingOverlaySessionName = sessionName

        // Observe injection lifecycle: keep overlay alive until keys are actually sent
        let startedObs = NotificationCenter.default.addObserver(
            forName: .magentAgentInjectionStarted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard (notification.userInfo?["sessionName"] as? String) == sessionName else { return }
            self.loadingOverlayWaitingForInjection = true
        }

        let injectedObs = NotificationCenter.default.addObserver(
            forName: .magentAgentKeysInjected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard (notification.userInfo?["sessionName"] as? String) == sessionName else { return }
            self.dismissLoadingOverlay()
        }

        loadingOverlayInjectionObservers = [startedObs, injectedObs]

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
                let ready = await self.isAgentReady(sessionName: sessionName, agentType: agentType)
                if ready {
                    await MainActor.run {
                        guard !self.loadingOverlayWaitingForInjection else { return }
                        self.loadingPollTimer?.invalidate()
                        self.loadingPollTimer = nil
                        self.dismissLoadingOverlay()
                    }
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let ready = await self.isAgentReady(sessionName: sessionName, agentType: agentType)
            if ready {
                await MainActor.run {
                    guard self.loadingOverlaySessionName == sessionName else { return }
                    guard !self.loadingOverlayWaitingForInjection else { return }
                    self.dismissLoadingOverlay()
                }
            }
        }
    }

    private func isAgentReady(sessionName: String, agentType: AgentType? = nil) async -> Bool {
        let result = await ShellExecutor.execute(
            "tmux capture-pane -t '\(sessionName)' -p 2>/dev/null"
        )
        guard result.exitCode == 0 else { return false }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThreadManager.shared.isAgentContentReady(output, agentType: agentType)
    }

    func dismissLoadingOverlay() {
        loadingPollTimer?.invalidate()
        loadingPollTimer = nil

        loadingOverlayWaitingForInjection = false
        for obs in loadingOverlayInjectionObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        loadingOverlayInjectionObservers.removeAll()

        guard let overlay = loadingOverlay else { return }
        overlay.animator().alphaValue = 0
        overlay.isHidden = true
        loadingOverlaySessionName = nil

        // Restore first responder to the current terminal so it can accept keyboard input.
        if let tv = currentTerminalView(), tv.superview != nil, !tv.isHidden {
            view.window?.makeFirstResponder(tv)
        }
    }

    @MainActor
    func updateLoadingOverlayDetail(_ detail: String?) {
        guard let label = loadingDetailLabel else { return }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label.stringValue = trimmed
        label.isHidden = trimmed.isEmpty
    }

    @MainActor
    func ensureSessionPrepared(
        sessionName: String,
        forceRevalidate: Bool = false,
        onAction: (@MainActor @Sendable (ThreadManager.SessionRecreationAction?) -> Void)? = nil
    ) async -> Bool {
        if preparedSessions.contains(sessionName), !forceRevalidate { return false }

        if forceRevalidate, let existingTask = sessionPreparationTasks[sessionName] {
            existingTask.cancel()
            sessionPreparationTasks.removeValue(forKey: sessionName)
            sessionPreparationTaskTokens.removeValue(forKey: sessionName)
        }

        if let existingTask = sessionPreparationTasks[sessionName] {
            return await existingTask.value
        }

        let taskToken = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            let latestThread = self.threadManager.threads.first(where: { $0.id == self.thread.id }) ?? self.thread
            return await self.threadManager.recreateSessionIfNeeded(
                sessionName: sessionName,
                thread: latestThread,
                onAction: onAction
            )
        }
        sessionPreparationTasks[sessionName] = task
        sessionPreparationTaskTokens[sessionName] = taskToken
        let recreated = await task.value

        guard sessionPreparationTaskTokens[sessionName] == taskToken else {
            return recreated
        }
        preparedSessions.insert(sessionName)
        sessionPreparationTasks.removeValue(forKey: sessionName)
        sessionPreparationTaskTokens.removeValue(forKey: sessionName)
        return recreated
    }

    @MainActor
    func prepareSessionsInBackground(_ sessionNames: [String]) {
        backgroundSessionPreparationTask?.cancel()
        guard !sessionNames.isEmpty else { return }

        backgroundSessionPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for sessionName in sessionNames {
                if Task.isCancelled { break }
                _ = await self.ensureSessionPrepared(sessionName: sessionName)
            }
        }
    }

    @MainActor
    func requireStartupOverlay(for sessionName: String) {
        startupOverlayRequiredSessions.insert(sessionName)
    }

    @MainActor
    func consumeStartupOverlayRequirement(for sessionName: String) -> Bool {
        startupOverlayRequiredSessions.remove(sessionName) != nil
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
        rebindAllTabActions()
        rebuildTabBar()
        persistTabOrder()
    }

    private func unpinTab(at index: Int) {
        guard index < pinnedCount else { return }
        pinnedCount -= 1
        moveTab(from: index, to: pinnedCount)
        rebindAllTabActions()
        rebuildTabBar()
        persistTabOrder()
    }
}
