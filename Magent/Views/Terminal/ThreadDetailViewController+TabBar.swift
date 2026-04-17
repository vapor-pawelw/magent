import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Tab Bar Scroll View

    /// Wraps `tabBarStack` inside `tabBarScrollView` so the tab strip can
    /// overflow horizontally instead of compressing tabs when space is tight.
    func configureTabBarScrollView() {
        let documentContainer = NSView()
        documentContainer.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(tabBarStack)

        NSLayoutConstraint.activate([
            tabBarStack.topAnchor.constraint(equalTo: documentContainer.topAnchor),
            tabBarStack.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor),
            tabBarStack.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            tabBarStack.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
        ])

        tabBarScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabBarScrollView.documentView = documentContainer

        // Pin the document view height to the scroll view's clip view so the
        // scroll view only scrolls horizontally, never vertically.
        NSLayoutConstraint.activate([
            documentContainer.heightAnchor.constraint(equalTo: tabBarScrollView.contentView.heightAnchor),
            tabBarScrollView.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Take all leftover horizontal space inside topBar so the scroll region
        // grows/shrinks with window width before other buttons compress.
        tabBarScrollView.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        tabBarScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Refresh arrow button visibility whenever the user scrolls (so edge-dimming
        // tracks the current offset) or the clip view resizes.
        tabBarScrollView.contentView.postsBoundsChangedNotifications = true
        tabBarScrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabBarScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: tabBarScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabBarScrollBoundsChanged),
            name: NSView.frameDidChangeNotification,
            object: tabBarScrollView.contentView
        )
    }

    // MARK: - Tab Scroll Arrows

    @objc func handleTabBarScrollBoundsChanged() {
        refreshTabScrollArrowsVisibility()
    }

    /// Show arrow buttons only when tabs overflow the visible scroll area; when
    /// shown, disable whichever arrow is at its edge so the state matches what
    /// clicking would actually do.
    func refreshTabScrollArrowsVisibility() {
        guard let documentContainer = tabBarScrollView.documentView else { return }
        let clipBounds = tabBarScrollView.contentView.bounds
        let overflow = documentContainer.bounds.width > clipBounds.width + 0.5

        tabScrollLeftButton.isHidden = !overflow
        tabScrollRightButton.isHidden = !overflow

        if overflow {
            let epsilon: CGFloat = 0.5
            tabScrollLeftButton.isEnabled = clipBounds.origin.x > epsilon
            let maxOffset = documentContainer.bounds.width - clipBounds.width
            tabScrollRightButton.isEnabled = clipBounds.origin.x < maxOffset - epsilon
        }
    }

    @objc func tabScrollLeftTapped() {
        scrollTabBar(by: -tabScrollStep())
    }

    @objc func tabScrollRightTapped() {
        scrollTabBar(by: tabScrollStep())
    }

    private func tabScrollStep() -> CGFloat {
        // Prefer one tab width when available, otherwise a sensible default.
        let width = tabItems.first?.frame.width ?? 120
        return max(80, width + tabBarStack.spacing)
    }

    private func scrollTabBar(by delta: CGFloat) {
        guard let documentContainer = tabBarScrollView.documentView else { return }
        let clipView = tabBarScrollView.contentView
        let maxOffset = max(0, documentContainer.bounds.width - clipView.bounds.width)
        let targetX = max(0, min(maxOffset, clipView.bounds.origin.x + delta))
        let targetOrigin = NSPoint(x: targetX, y: clipView.bounds.origin.y)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(targetOrigin)
            tabBarScrollView.reflectScrolledClipView(clipView)
        }
    }

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
            // Extra 4 pt padding on each side of the separator (stack spacing = 4, so total gap = 8)
            tabBarStack.setCustomSpacing(tabBarStack.spacing + 4, after: tabItems[pinnedCount - 1])
            tabBarStack.addArrangedSubview(pinSeparator)
            tabBarStack.setCustomSpacing(tabBarStack.spacing + 4, after: pinSeparator)
        }

        // Unpinned tabs (any type)
        for i in pinnedCount..<tabItems.count {
            tabItems[i].showPinIcon = false
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        // Tab set just changed — defer the arrow refresh until the new layout
        // settles so we read the correct document/clip widths.
        DispatchQueue.main.async { [weak self] in
            self?.refreshTabScrollArrowsVisibility()
        }
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
            if sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectPendingTerminalTab(at: index)
                return
            }
            if PopoutWindowManager.shared.isTabDetached(sessionName: sessionName) {
                selectDetachedTab(at: index, sessionName: sessionName)
            } else {
                selectTerminalTab(at: index, sessionName: sessionName)
            }
        case .web(let identifier):
            selectWebTabByIdentifier(identifier, displayIndex: index)
        case .draft(let identifier):
            selectDraftTab(identifier: identifier, displayIndex: index)
        }
    }

    private func selectPendingTerminalTab(at index: Int) {
        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        for termView in terminalViews where termView.superview != nil {
            termView.isHidden = true
        }

        hideActiveWebTab()
        hideActiveDraftTab()
        hideEmptyState()
        for (_, placeholder) in detachedTabPlaceholders {
            placeholder.isHidden = true
        }

        ensureLoadingOverlay()
        loadingLabel?.stringValue = String(localized: .ThreadStrings.tabCreatingSession)
        loadingDetailLabel?.isHidden = true
        revealLoadingOverlay(after: 0)

        currentTabIndex = index
        postFocusedThreadContextChangedIfKeyWindow()
    }

    private func selectTerminalTab(at index: Int, sessionName: String) {
        // If this session was evicted by idle eviction, clear the eviction marker
        // and force through the slow path so the session is recreated.
        let wasEvicted = threadManager.evictedIdleSessions.contains(sessionName)
        if wasEvicted {
            threadManager.evictedIdleSessions.remove(sessionName)
            preparedSessions.remove(sessionName)
        }

        let needsLazyAttachRevalidation = preparedSessions.contains(sessionName)
            && terminalView(forSession: sessionName)?.superview == nil

        guard preparedSessions.contains(sessionName) && !needsLazyAttachRevalidation else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Hide current terminal/web/draft content so the old tab doesn't show through.
                for termView in self.terminalViews { termView.isHidden = true }
                self.hideActiveWebTab()
                self.hideActiveDraftTab()

                let sessionAgentType = await self.threadManager.loadingOverlayAgentType(
                    for: self.thread,
                    sessionName: sessionName
                )
                self.startLoadingOverlayTracking(sessionName: sessionName, agentType: sessionAgentType)
                let recreated = await self.ensureSessionPrepared(
                    sessionName: sessionName,
                    forceRevalidate: needsLazyAttachRevalidation
                ) { [weak self] action in
                    guard let self,
                          sessionName == self.loadingOverlaySessionName else { return }
                    self.updateLoadingOverlayDetail(action?.loadingOverlayDetail)
                }
                if needsLazyAttachRevalidation {
                    self.rebuildDetachedTerminalView(for: sessionName)
                }
                // Re-resolve display index (may have shifted — tab may have been closed).
                guard let currentDisplayIndex = self.displayIndex(forSession: sessionName) else {
                    self.dismissLoadingOverlay()
                    // Tab was removed while preparing; fall back to the nearest valid tab.
                    if !self.tabSlots.isEmpty {
                        self.selectTab(at: max(0, self.currentTabIndex - 1))
                    }
                    return
                }
                let selected = self.selectPreparedTab(at: currentDisplayIndex)
                if !selected {
                    // Keep the loading UI visible and fall back to the full select path
                    // instead of leaving the terminal area blank on a missed attach.
                    self.loadingLabel?.stringValue = "Preparing terminal session..."
                    self.updateLoadingOverlayDetail("Terminal view attach failed; retrying tmux/session validation.")
                    self.selectTab(at: currentDisplayIndex)
                    return
                }
                // After session recreation the tmux pane may not have rendered
                // its full scrollback yet, so the immediate TOC refresh inside
                // selectPreparedTab can capture an empty pane (showing 0 entries).
                // Schedule a second refresh with a short delay to pick up content
                // once the pane has settled.
                if recreated || wasEvicted {
                    self.schedulePromptTOCRefresh(after: 0.5)
                }
                let keepStartupOverlay = sessionAgentType != nil
                    && (recreated || self.consumeStartupOverlayRequirement(for: sessionName))
                if !keepStartupOverlay {
                    self.dismissLoadingOverlay()
                }
            }
            return
        }

        _ = selectPreparedTab(at: index)
    }

    private func selectDetachedTab(at index: Int, sessionName: String) {
        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        // Hide all terminal views
        for tv in terminalViews where tv.superview != nil {
            tv.isHidden = true
        }

        hideActiveWebTab()
        hideActiveDraftTab()
        hideEmptyState()

        // Hide all existing placeholders first
        for (_, placeholder) in detachedTabPlaceholders {
            placeholder.isHidden = true
        }

        // Show or create detached tab placeholder
        if let placeholder = detachedTabPlaceholders[sessionName] {
            placeholder.isHidden = false
        } else {
            let placeholder = DetachedTabPlaceholderView(sessionName: sessionName)
            placeholder.onShowWindow = {
                PopoutWindowManager.shared.bringToFront(sessionName: sessionName)
            }
            placeholder.onReturnToTab = {
                PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
            }
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                placeholder.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                placeholder.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                placeholder.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
            detachedTabPlaceholders[sessionName] = placeholder
        }

        currentTabIndex = index
        dismissLoadingOverlay()
        scrollOverlay.isHidden = true
        setScrollFABVisible(false)
        promptTOCCanShowForCurrentTab = false
        applyPromptTOCVisibility()
        postFocusedThreadContextChangedIfKeyWindow()
    }

    @discardableResult
    func selectPreparedTab(at index: Int) -> Bool {
        guard index < tabSlots.count else { return false }
        guard case .terminal(let sessionName) = tabSlots[index] else { return false }
        guard let tv = terminalView(forSession: sessionName) else { return false }

        hideActiveWebTab()
        hideActiveDraftTab()

        // Hide detached tab placeholders when switching to a live terminal tab
        for (_, placeholder) in detachedTabPlaceholders {
            placeholder.isHidden = true
        }

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        // Session was recreated — clear dead styling.
        if index < tabItems.count {
            tabItems[index].isSessionDead = false
        }

        // Suppress implicit Core Animation on the CAMetalLayer-backed terminal views.
        // Without this, toggling isHidden / adding subviews can trigger a slow
        // bounds/position animation that visually scrolls the content from the top.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

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
        bringTerminalBannerOverlayToFront()

        // Hide all terminal views, show selected
        for termView in terminalViews {
            termView.isHidden = (termView !== tv)
        }

        CATransaction.commit()
        view.window?.makeFirstResponder(tv)
        currentTabIndex = index
        updateTerminalScrollControlsState()
        postFocusedThreadContextChangedIfKeyWindow()

        let canShowTOC = thread.agentTmuxSessions.contains(sessionName)
        promptTOCCanShowForCurrentTab = canShowTOC
        applyPromptTOCVisibility()
        if thread.lastSelectedTabIdentifier != sessionName {
            thread.lastSelectedTabIdentifier = sessionName
            threadManager.updateLastSelectedTab(for: thread.id, identifier: sessionName)
        }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(sessionName, forKey: Self.lastOpenedTabDefaultsKey)
        refreshPendingPromptBanner()
        refreshInitialPromptFailureBanner()
        refreshPendingPromptBanner()

        // Clear unread completion, waiting, and rate limit indicators for this tab
        guard index < tabItems.count else { return true }
        tabItems[index].hasUnreadCompletion = false
        tabItems[index].hasWaitingForInput = false
        tabItems[index].hasUnreadRateLimit = false
        threadManager.markSessionCompletionSeen(threadId: thread.id, sessionName: sessionName)
        threadManager.markSessionWaitingSeen(threadId: thread.id, sessionName: sessionName)
        threadManager.markSessionRateLimitSeen(threadId: thread.id, sessionName: sessionName)
        refreshTabTooltips()

        schedulePromptTOCRefresh()
        return true
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
        let isTabDetachEnabled = settings.isTabDetachFeatureEnabled
        let count = tabItems.count

        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            let item = tabItems[i]
            item.onSelect = { [weak self] in self?.selectTab(at: i) }
            item.onClose = { [weak self] in self?.closeTab(at: i) }
            item.onForceClose = { [weak self] in self?.forceCloseTab(at: i) }
            item.onPin = { [weak self] in self?.togglePin(at: i) }
            item.onCloseTabsToTheRight = { [weak self] in self?.closeTabsToTheRight(of: i) }
            item.onCloseTabsToTheLeft = { [weak self] in self?.closeTabsToTheLeft(of: i) }
            item.tabIndex = i
            item.totalTabCount = count
            item.showCloseButton = true
            item.showPinIcon = (i < pinnedCount)

            switch slot {
            case .terminal(let sessionName):
                let isPending = sessionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isPending {
                    item.showCloseButton = false
                    item.isDetached = false
                    item.onDetach = nil
                    item.onShowDetachedWindow = nil
                    item.onReturnDetachedTab = nil
                    item.onRename = nil
                    item.allowsDoubleClickRename = false
                    item.onResumeAgentInNewTab = nil
                    item.canResumeAgentInNewTab = false
                    item.onContinueIn = nil
                    item.onExportContext = nil
                    item.onKeepAlive = nil
                    item.onKillSession = nil
                    item.onKillAllSessions = nil
                    item.onCopyTmuxSessionName = nil
                    item.tmuxSessionNameForMenu = nil
                    item.availableAgentsForContinue = []
                    item.showKeepAliveIcon = false
                    item.typeIcon.isHidden = true
                } else {
                    let agentType = threadManager.agentType(for: thread, sessionName: sessionName)
                    let resumeID = threadManager.conversationID(for: thread.id, sessionName: sessionName)
                    let isForwardedContinuation = thread.forwardedTmuxSessions.contains(sessionName)
                    item.isDetached = PopoutWindowManager.shared.isTabDetached(sessionName: sessionName)
                    // Tab detaching is production-disabled and can be enabled only via
                    // the debug Experimental setting.
                    item.onDetach = isTabDetachEnabled ? { [weak self] in self?.detachTab(at: i) } : nil
                    item.onShowDetachedWindow = {
                        PopoutWindowManager.shared.bringToFront(sessionName: sessionName)
                    }
                    item.onReturnDetachedTab = {
                        PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
                    }
                    item.onRename = { [weak self] in self?.showTabRenameDialog(at: i) }
                    item.allowsDoubleClickRename = true
                    item.onResumeAgentInNewTab = agentType?.supportsResume == true
                        ? { [weak self] in self?.resumeAgentSessionInNewTab(at: i) }
                        : nil
                    item.canResumeAgentInNewTab = !(resumeID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    item.onContinueIn = { [weak self] in self?.presentContinueTabSheet(for: i) }
                    item.onExportContext = { [weak self] in self?.exportTabContext(at: i) }
                    // Hide per-tab Keep Alive controls when the thread itself is keep-alive.
                    item.onKeepAlive = thread.isKeepAlive ? nil : { [weak self] in self?.toggleKeepAlive(at: i) }
                    item.onKillSession = { [weak self] in self?.killSession(at: i) }
                    item.onKillAllSessions = { [weak self] in self?.killAllSessions() }
                    item.onCopyTmuxSessionName = {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(sessionName, forType: .string)
                    }
                    item.tmuxSessionNameForMenu = sessionName
                    item.availableAgentsForContinue = settings.availableActiveAgents
                    item.showKeepAliveIcon = !thread.isKeepAlive
                        && thread.protectedTmuxSessions.contains(sessionName)
                    item.typeIcon.image = isForwardedContinuation
                        ? NSImage(systemSymbolName: "arrowshape.turn.up.forward", accessibilityDescription: "Forwarded continuation")
                        : nil
                    item.typeIcon.contentTintColor = .secondaryLabelColor
                    item.typeIcon.isHidden = !isForwardedContinuation
                }
            case .web:
                item.onRename = { [weak self] in self?.showWebTabRenameDialog(at: i) }
                item.allowsDoubleClickRename = false
                item.onResumeAgentInNewTab = nil
                item.canResumeAgentInNewTab = false
                item.onContinueIn = nil
                item.onExportContext = nil
                item.onKeepAlive = nil
                item.onKillSession = nil
                item.onKillAllSessions = nil
                item.onCopyTmuxSessionName = nil
                item.tmuxSessionNameForMenu = nil
                item.availableAgentsForContinue = []
                item.showKeepAliveIcon = false
            case .draft:
                item.onRename = nil
                item.allowsDoubleClickRename = false
                item.onResumeAgentInNewTab = nil
                item.canResumeAgentInNewTab = false
                item.onContinueIn = nil
                item.onExportContext = nil
                item.onKeepAlive = nil
                item.onKillSession = nil
                item.onKillAllSessions = nil
                item.onCopyTmuxSessionName = nil
                item.tmuxSessionNameForMenu = nil
                item.availableAgentsForContinue = []
                item.showKeepAliveIcon = false
            }
        }

        refreshTabTooltips()
    }

    func refreshTabTooltips() {
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            tabItems[i].toolTip = tooltipText(for: slot, displayIndex: i)
        }
    }

    private func tooltipText(for slot: TabSlot, displayIndex: Int) -> String {
        let pinned = displayIndex < pinnedCount ? "Yes" : "No"

        switch slot {
        case .terminal(let sessionName):
            let agentType = threadManager.agentType(for: thread, sessionName: sessionName)
            let typeText = agentType.map { "Terminal (\($0.displayName))" } ?? "Terminal"
            var statusBits: [String] = []

            if thread.deadSessions.contains(sessionName) { statusBits.append("dead session") }
            if thread.busySessions.contains(sessionName) { statusBits.append("agent busy") }
            if thread.magentBusySessions.contains(sessionName) { statusBits.append("Magent busy") }
            if thread.waitingForInputSessions.contains(sessionName) { statusBits.append("waiting for input") }
            if thread.hasUnsubmittedInputSessions.contains(sessionName) { statusBits.append("input typed") }
            if let rateLimitInfo = thread.rateLimitedSessions[sessionName] {
                var rateLimitText = "rate limited"
                if rateLimitInfo.isPropagated {
                    rateLimitText += " (propagated)"
                }
                if !rateLimitInfo.isPromptBased {
                    rateLimitText += " until \(rateLimitInfo.resetAt.formatted(date: .abbreviated, time: .shortened))"
                }
                statusBits.append(rateLimitText)
            }
            if thread.unreadCompletionSessions.contains(sessionName) { statusBits.append("unread completion") }
            if thread.unreadRateLimitSessions.contains(sessionName) { statusBits.append("unread rate-limit notice") }
            if statusBits.isEmpty { statusBits.append("idle") }

            let keepAlive: String
            if thread.isKeepAlive {
                keepAlive = "Thread-level"
            } else if thread.protectedTmuxSessions.contains(sessionName) {
                keepAlive = "Tab-level"
            } else {
                keepAlive = "No"
            }

            return [
                "Type: \(typeText)",
                "Session: \(sessionName)",
                "Pinned: \(pinned)",
                "Keep Alive: \(keepAlive)",
                "Status: \(statusBits.joined(separator: ", "))",
            ].joined(separator: "\n")

        case .web(let identifier):
            let persisted = thread.persistedWebTabs.first(where: { $0.identifier == identifier })
            let typeText: String = {
                switch persisted?.iconType ?? .web {
                case .jira: return "Web (Jira)"
                case .pullRequest: return "Web (Pull Request)"
                case .web, .none: return "Web"
                }
            }()
            let urlText = persisted?.url.absoluteString ?? "Unknown"

            return [
                "Type: \(typeText)",
                "Identifier: \(identifier)",
                "Pinned: \(pinned)",
                "URL: \(urlText)",
                "Status: content tab",
            ].joined(separator: "\n")

        case .draft(let identifier):
            let draft = draftTabs.first(where: { $0.identifier == identifier })
            let agentText = draft?.agentType.displayName ?? "Unknown"
            let modelText = draft?.modelId ?? "Default"
            let reasoningText = draft?.reasoningLevel ?? "Default"

            return [
                "Type: Draft (\(agentText))",
                "Identifier: \(identifier)",
                "Pinned: \(pinned)",
                "Model: \(modelText)",
                "Reasoning: \(reasoningText)",
                "Status: saved draft",
            ].joined(separator: "\n")
        }
    }
}
