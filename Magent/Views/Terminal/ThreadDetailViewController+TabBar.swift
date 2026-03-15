import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Tab Bar Layout

    func rebuildTabBar() {
        for sv in tabBarStack.arrangedSubviews {
            tabBarStack.removeArrangedSubview(sv)
            sv.removeFromSuperview()
        }

        for i in 0..<pinnedCount where i < tabItems.count {
            tabItems[i].showPinIcon = true
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        if pinnedCount > 0 && pinnedCount < tabItems.count {
            tabBarStack.addArrangedSubview(pinSeparator)
        }

        for i in pinnedCount..<tabItems.count {
            tabItems[i].showPinIcon = false
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        // Flexible spacer so tabs stay compact and don't stretch
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabBarStack.addArrangedSubview(spacer)
    }

    // MARK: - Tab Management

    func createTabItem(title: String, closable: Bool, pinned: Bool = false) {
        let index = tabItems.count
        let settings = PersistenceService.shared.loadSettings()
        let item = TabItemView(title: title)
        item.showCloseButton = closable
        item.showPinIcon = pinned
        item.onSelect = { [weak self] in self?.selectTab(at: index) }
        item.onClose = { [weak self] in self?.closeTab(at: index) }
        item.onRename = { [weak self] in self?.showTabRenameDialog(at: index) }
        item.onPin = { [weak self] in self?.togglePin(at: index) }
        item.onContinueIn = { [weak self] agent in self?.continueTabInAgent(at: index, targetAgent: agent) }
        item.onExportContext = { [weak self] in self?.exportTabContext(at: index) }
        item.availableAgentsForContinue = settings.availableActiveAgents

        // Pan gesture for drag-to-reorder
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:)))
        pan.delaysPrimaryMouseButtonEvents = false
        pan.delegate = self
        item.addGestureRecognizer(pan)

        tabItems.append(item)
    }

    func selectTab(at index: Int) {
        guard index < terminalViews.count else { return }
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]

        guard preparedSessions.contains(sessionName) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let sessionAgentType = await self.threadManager.loadingOverlayAgentType(
                    for: self.thread,
                    sessionName: sessionName
                )
                self.startLoadingOverlayTracking(sessionName: sessionName, agentType: sessionAgentType)
                await self.ensureSessionPrepared(sessionName: sessionName) { [weak self] action in
                    guard let self,
                          sessionName == self.loadingOverlaySessionName else { return }
                    self.updateLoadingOverlayDetail(action?.loadingOverlayDetail)
                }
                guard index < self.terminalViews.count else { return }
                self.selectPreparedTab(at: index)
            }
            return
        }

        selectPreparedTab(at: index)
    }

    func selectPreparedTab(at index: Int) {
        guard index < terminalViews.count else { return }
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        let terminalView = terminalViews[index]

        // Lazily add the view to the container on first selection (creates the surface).
        // On subsequent selections just show/hide to avoid destroying and recreating
        // the ghostty surface, which causes a visible tmux re-attach scroll animation.
        if terminalView.superview == nil {
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
        }
        bringPromptTOCOverlayToFront()
        bringScrollOverlaysToFront()

        for (i, tv) in terminalViews.enumerated() {
            tv.isHidden = (i != index)
        }

        view.window?.makeFirstResponder(terminalView)
        currentTabIndex = index
        updateTerminalScrollControlsState()

        let canShowTOC = thread.agentTmuxSessions.contains(sessionName)
        promptTOCCanShowForCurrentTab = canShowTOC
        applyPromptTOCVisibility()
        if thread.lastSelectedTmuxSessionName != sessionName {
            thread.lastSelectedTmuxSessionName = sessionName
            threadManager.updateLastSelectedSession(for: thread.id, sessionName: sessionName)
        }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(sessionName, forKey: Self.lastOpenedSessionDefaultsKey)

        // Clear unread completion and waiting dots for this tab
        guard index < tabItems.count else { return }
        tabItems[index].hasUnreadCompletion = false
        tabItems[index].hasWaitingForInput = false
        threadManager.markSessionCompletionSeen(threadId: thread.id, sessionName: sessionName)
        threadManager.markSessionWaitingSeen(threadId: thread.id, sessionName: sessionName)

        schedulePromptTOCRefresh()
    }

    func rateLimitTooltip(for sessionName: String) -> String? {
        guard let info = thread.rateLimitedSessions[sessionName] else { return nil }
        if info.isPromptBased { return "Rate limit reached" }
        return "Rate limit reached. Resets \(info.resetAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func showEmptyState() {
        guard emptyStateView == nil else { return }
        promptTOCCanShowForCurrentTab = false
        applyPromptTOCVisibility()
        updateTerminalScrollControlsState()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "plus.message", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .thin)

        let label = NSTextField(labelWithString: String(localized: .ThreadStrings.tabsNoOpenTabs))
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: String(localized: .ThreadStrings.tabsNoOpenTabsHint))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label, hint])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        terminalContainer.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            container.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        emptyStateView = container
    }

    func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        updateTerminalScrollControlsState()
        schedulePromptTOCRefresh()
    }

    func rebindTabActions() {
        let settings = PersistenceService.shared.loadSettings()
        let count = tabItems.count
        for (i, item) in tabItems.enumerated() {
            item.onSelect = { [weak self] in self?.selectTab(at: i) }
            item.onClose = { [weak self] in self?.closeTab(at: i) }
            item.onRename = { [weak self] in self?.showTabRenameDialog(at: i) }
            item.onPin = { [weak self] in self?.togglePin(at: i) }
            item.onContinueIn = { [weak self] agent in self?.continueTabInAgent(at: i, targetAgent: agent) }
            item.onExportContext = { [weak self] in self?.exportTabContext(at: i) }
            item.onCloseTabsToTheRight = { [weak self] in self?.closeTabsToTheRight(of: i) }
            item.onCloseTabsToTheLeft = { [weak self] in self?.closeTabsToTheLeft(of: i) }
            item.availableAgentsForContinue = settings.availableActiveAgents
            item.tabIndex = i
            item.totalTabCount = count
            item.showCloseButton = true
            item.showPinIcon = (i < pinnedCount)
        }
    }
}
