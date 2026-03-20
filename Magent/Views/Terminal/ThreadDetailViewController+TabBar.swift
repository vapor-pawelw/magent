import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Tab Bar Layout

    func rebuildTabBar() {
        for sv in tabBarStack.arrangedSubviews {
            tabBarStack.removeArrangedSubview(sv)
            sv.removeFromSuperview()
        }

        // Pinned tabs (any type)
        for i in 0..<pinnedCount where i < tabItems.count {
            tabItems[i].showPinIcon = true
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        if pinnedCount > 0 && pinnedCount < tabItems.count {
            tabBarStack.addArrangedSubview(pinSeparator)
        }

        // Unpinned tabs (any type)
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
        let item = TabItemView(title: title)
        item.showCloseButton = closable
        item.showPinIcon = pinned
        attachDragGesture(to: item)
        tabItems.append(item)
    }

    func attachDragGesture(to item: TabItemView) {
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:)))
        pan.delegate = self
        // Allow mouseDown to fire immediately so tab selection isn't
        // swallowed when the gesture recognizer is deciding if this is a drag.
        pan.delaysPrimaryMouseButtonEvents = false
        item.addGestureRecognizer(pan)
    }

    // MARK: - Unified Tab Selection

    func selectTab(at index: Int) {
        guard index >= 0, index < tabSlots.count, index < tabItems.count else { return }

        switch tabSlots[index] {
        case .terminal(let sessionName):
            selectTerminalTab(at: index, sessionName: sessionName)
        case .web(let identifier):
            selectWebTabByIdentifier(identifier, displayIndex: index)
        }
    }

    private func selectTerminalTab(at index: Int, sessionName: String) {
        guard preparedSessions.contains(sessionName) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Hide current terminal/web content so the old tab doesn't show through.
                for termView in self.terminalViews { termView.isHidden = true }
                self.hideActiveWebTab()

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
                // Re-resolve display index (may have shifted — tab may have been closed).
                guard let currentDisplayIndex = self.displayIndex(forSession: sessionName) else {
                    self.dismissLoadingOverlay()
                    // Tab was removed while preparing; fall back to the nearest valid tab.
                    if !self.tabSlots.isEmpty {
                        self.selectTab(at: max(0, (self.currentTabIndex ?? 1) - 1))
                    }
                    return
                }
                self.selectPreparedTab(at: currentDisplayIndex)
            }
            return
        }

        selectPreparedTab(at: index)
    }

    func selectPreparedTab(at index: Int) {
        guard index < tabSlots.count else { return }
        guard case .terminal(let sessionName) = tabSlots[index] else { return }
        guard let tv = terminalView(forSession: sessionName) else { return }

        hideActiveWebTab()

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        // Lazily add the view to the container on first selection (creates the surface).
        if tv.superview == nil {
            tv.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(tv)
            NSLayoutConstraint.activate([
                tv.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                tv.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                tv.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
        }
        bringPromptTOCOverlayToFront()
        bringScrollOverlaysToFront()

        // Hide all terminal views, show selected
        for termView in terminalViews {
            termView.isHidden = (termView !== tv)
        }
        view.window?.makeFirstResponder(tv)
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
        refreshInitialPromptFailureBanner()

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

    // MARK: - Unified Rebind

    func rebindAllTabActions() {
        let settings = PersistenceService.shared.loadSettings()
        let count = tabItems.count

        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            let item = tabItems[i]
            item.onSelect = { [weak self] in self?.selectTab(at: i) }
            item.onClose = { [weak self] in self?.closeTab(at: i) }
            item.onPin = { [weak self] in self?.togglePin(at: i) }
            item.onCloseTabsToTheRight = { [weak self] in self?.closeTabsToTheRight(of: i) }
            item.onCloseTabsToTheLeft = { [weak self] in self?.closeTabsToTheLeft(of: i) }
            item.tabIndex = i
            item.totalTabCount = count
            item.showCloseButton = true
            item.showPinIcon = (i < pinnedCount)

            switch slot {
            case .terminal:
                item.onRename = { [weak self] in self?.showTabRenameDialog(at: i) }
                item.onContinueIn = { [weak self] agent in self?.continueTabInAgent(at: i, targetAgent: agent) }
                item.onExportContext = { [weak self] in self?.exportTabContext(at: i) }
                item.availableAgentsForContinue = settings.availableActiveAgents
            case .web:
                item.onRename = { [weak self] in self?.showWebTabRenameDialog(at: i) }
                item.onContinueIn = nil
                item.onExportContext = nil
                item.availableAgentsForContinue = []
            }
        }
    }
}
