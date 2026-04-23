import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Restore from Persistence

    /// Recreates tab items for persisted draft tabs.
    func restoreDraftTabItems() {
        for persisted in thread.persistedDraftTabs {
            let entry = DraftTabEntry(
                identifier: persisted.identifier,
                agentType: persisted.agentType,
                prompt: persisted.prompt,
                modelId: persisted.modelId,
                reasoningLevel: persisted.reasoningLevel,
                viewController: nil
            )
            draftTabs.append(entry)

            let item = TabItemView(title: "Draft")
            item.showCloseButton = true
            attachDragGesture(to: item)
            applyDraftTabIcon(to: item)

            tabItems.append(item)
            tabSlots.append(.draft(identifier: persisted.identifier))
        }
    }

    func applyDraftTabIcon(to item: TabItemView) {
        item.typeIcon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Draft")
        item.typeIcon.contentTintColor = .secondaryLabelColor
        item.typeIcon.isHidden = false
    }

    // MARK: - Open Draft Tab

    func openDraftTab(
        identifier: String,
        agentType: AgentType,
        prompt: String,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) {
        // Dedup
        if let existingIndex = tabSlots.firstIndex(of: .draft(identifier: identifier)) {
            selectTab(at: existingIndex)
            return
        }

        hideEmptyState()

        let entry = DraftTabEntry(
            identifier: identifier,
            agentType: agentType,
            prompt: prompt,
            modelId: modelId,
            reasoningLevel: reasoningLevel,
            viewController: nil
        )
        draftTabs.append(entry)

        let item = TabItemView(title: "Draft")
        item.showCloseButton = true
        attachDragGesture(to: item)
        applyDraftTabIcon(to: item)

        tabItems.append(item)
        tabSlots.append(.draft(identifier: identifier))

        rebindAllTabActions()
        rebuildTabBar()

        persistDraftTabs()

        let newIndex = tabItems.count - 1
        selectTab(at: newIndex)
    }

    // MARK: - Select Draft Tab

    func selectDraftTab(identifier: String, displayIndex: Int) {
        // Hide terminals and web tabs
        for termView in terminalViews { termView.isHidden = true }
        hideActiveWebTab()
        hideActiveDraftTab()
        for (_, placeholder) in detachedTabPlaceholders {
            placeholder.isHidden = true
        }

        dismissLoadingOverlay()

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == displayIndex)
        }

        guard let entryIndex = draftTabs.firstIndex(where: { $0.identifier == identifier }) else { return }

        // Lazily create the view controller
        if draftTabs[entryIndex].viewController == nil {
            let entry = draftTabs[entryIndex]
            let vc = DraftTabViewController(
                draftIdentifier: identifier,
                agentType: entry.agentType,
                prompt: entry.prompt,
                modelId: entry.modelId,
                reasoningLevel: entry.reasoningLevel
            )

            vc.onProceed = { [weak self] agentType, prompt, modelId, reasoningLevel in
                self?.proceedWithDraft(
                    identifier: identifier,
                    agentType: agentType,
                    prompt: prompt,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
            }
            vc.onDiscard = { [weak self] in
                self?.removeDraftTab(identifier: identifier)
            }
            vc.onChanged = { [weak self] agentType, prompt, modelId, reasoningLevel in
                self?.draftContentChanged(
                    identifier: identifier,
                    agentType: agentType,
                    prompt: prompt,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
            }

            draftTabs[entryIndex].viewController = vc
        }

        guard let vc = draftTabs[entryIndex].viewController else { return }

        if vc.view.superview == nil {
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                vc.view.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                vc.view.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
        }

        vc.view.isHidden = false
        activeDraftTabId = identifier
        currentTabIndex = displayIndex
        postFocusedThreadContextChangedIfKeyWindow()

        if thread.lastSelectedTabIdentifier != identifier {
            thread.lastSelectedTabIdentifier = identifier
            threadManager.updateLastSelectedTab(for: thread.id, identifier: identifier)
        }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(identifier, forKey: Self.lastOpenedTabDefaultsKey)

        // Hide terminal overlays while draft tab is active
        scrollOverlay.isHidden = true
        setScrollFABVisible(false)
        promptTOCCanShowForCurrentTab = false
        applyPromptTOCVisibility()
    }

    // MARK: - Hide

    func hideActiveDraftTab() {
        guard let activeId = activeDraftTabId else { return }
        if let entry = draftTabs.first(where: { $0.identifier == activeId }) {
            entry.viewController?.view.isHidden = true
        }
        activeDraftTabId = nil
    }

    // MARK: - Close Draft Tab

    func closeDraftTab(identifier: String) {
        let alert = NSAlert()
        alert.messageText = "Close Draft Tab?"
        alert.informativeText = "This will discard the draft prompt. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        removeDraftTab(identifier: identifier)
    }

    func removeDraftTab(identifier: String) {
        guard let slotIndex = tabSlots.firstIndex(of: .draft(identifier: identifier)) else { return }

        var fallbackSnapshot: PersistedDraftTab?
        if let entryIndex = draftTabs.firstIndex(where: { $0.identifier == identifier }) {
            let entry = draftTabs[entryIndex]
            fallbackSnapshot = PersistedDraftTab(
                identifier: entry.identifier,
                agentType: entry.agentType,
                prompt: entry.prompt,
                modelId: entry.modelId,
                reasoningLevel: entry.reasoningLevel
            )
            draftTabs[entryIndex].viewController?.view.removeFromSuperview()
            draftTabs.remove(at: entryIndex)
        }
        if let persisted = thread.persistedDraftTabs.first(where: { $0.identifier == identifier }) ?? fallbackSnapshot {
            threadManager.pushClosedTabSnapshot(.draft(persisted), for: thread.id)
        }

        if activeDraftTabId == identifier {
            activeDraftTabId = nil
        }

        tabItems.remove(at: slotIndex)
        tabSlots.remove(at: slotIndex)
        rebindAllTabActions()
        rebuildTabBar()

        persistDraftTabs()

        // Strip "DRAFT: " prefix if no draft tabs remain.
        threadManager.stripDraftDescriptionPrefixIfNeeded(threadId: thread.id)

        if tabItems.isEmpty {
            showEmptyState()
        } else {
            let newIndex = min(currentTabIndex, tabItems.count - 1)
            selectTab(at: newIndex)
        }
    }

    // MARK: - Proceed (Convert Draft to Agent Tab)

    private func proceedWithDraft(
        identifier: String,
        agentType: AgentType,
        prompt: String,
        modelId: String?,
        reasoningLevel: String?
    ) {
        // Remove the draft tab UI
        guard let slotIndex = tabSlots.firstIndex(of: .draft(identifier: identifier)) else { return }

        if let entryIndex = draftTabs.firstIndex(where: { $0.identifier == identifier }) {
            draftTabs[entryIndex].viewController?.view.removeFromSuperview()
            draftTabs.remove(at: entryIndex)
        }

        if activeDraftTabId == identifier {
            activeDraftTabId = nil
        }

        tabItems.remove(at: slotIndex)
        tabSlots.remove(at: slotIndex)

        persistDraftTabs()

        rebindAllTabActions()
        rebuildTabBar()

        // Strip "DRAFT: " prefix from description now that the draft is consumed.
        threadManager.stripDraftDescriptionPrefixIfNeeded(threadId: thread.id)

        // Create actual agent tab with the prompt
        addTabFromDraft(agentType: agentType, prompt: prompt, modelId: modelId, reasoningLevel: reasoningLevel)
    }

    /// Creates an actual agent tab from a draft, injecting the prompt.
    private func addTabFromDraft(agentType: AgentType, prompt: String, modelId: String?, reasoningLevel: String?) {
        // Phase 1: Immediately add a tab item and show "Creating tab..." overlay.
        hideEmptyState()
        let pendingIndex = tabItems.count
        let item = TabItemView(title: "New Tab")
        item.showCloseButton = false
        attachDragGesture(to: item)
        tabItems.append(item)
        tabSlots.append(.terminal(sessionName: ""))
        rebindAllTabActions()
        rebuildTabBar()

        for (i, item) in tabItems.enumerated() { item.isSelected = (i == pendingIndex) }
        for termView in terminalViews { termView.isHidden = true }
        hideActiveWebTab()
        hideActiveDraftTab()

        ensureLoadingOverlay()
        loadingLabel?.stringValue = String(localized: .ThreadStrings.tabCreatingSession)
        loadingDetailLabel?.isHidden = true
        // Immediate reveal — tab creation always takes longer than the debounce window.
        revealLoadingOverlay(after: 0)

        // Phase 2: Create tmux session in background.
        Task {
            do {
                let tab = try await threadManager.addTab(
                    to: thread,
                    useAgentCommand: true,
                    requestedAgentType: agentType,
                    initialPrompt: prompt.isEmpty ? nil : prompt,
                    shouldSubmitInitialPrompt: true,
                    customTitle: nil,
                    tabNameSuffix: nil,
                    pendingPromptFileURL: nil,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }
                    let terminalView = self.makeTerminalView(for: tab.tmuxSessionName)
                    self.terminalViews.append(terminalView)

                    if pendingIndex < self.tabSlots.count {
                        self.tabSlots[pendingIndex] = .terminal(sessionName: tab.tmuxSessionName)
                    }
                    self.requireStartupOverlay(for: tab.tmuxSessionName)

                    let title = self.thread.displayName(for: tab.tmuxSessionName, at: pendingIndex)
                    if pendingIndex < self.tabItems.count {
                        self.tabItems[pendingIndex].titleLabel.stringValue = title
                        self.tabItems[pendingIndex].showCloseButton = true
                    }
                    self.rebindAllTabActions()
                    self.dismissLoadingOverlay()
                    self.selectTab(at: pendingIndex)
                }
            } catch {
                await MainActor.run {
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

    // MARK: - Content Changed

    private func draftContentChanged(
        identifier: String,
        agentType: AgentType,
        prompt: String,
        modelId: String?,
        reasoningLevel: String?
    ) {
        guard let entryIndex = draftTabs.firstIndex(where: { $0.identifier == identifier }) else { return }
        draftTabs[entryIndex].agentType = agentType
        draftTabs[entryIndex].prompt = prompt
        draftTabs[entryIndex].modelId = modelId
        draftTabs[entryIndex].reasoningLevel = reasoningLevel
        persistDraftTabs()
    }

    // MARK: - Persistence

    func persistDraftTabs() {
        thread.persistedDraftTabs = draftTabs.map { entry in
            PersistedDraftTab(
                identifier: entry.identifier,
                agentType: entry.agentType,
                prompt: entry.prompt,
                modelId: entry.modelId,
                reasoningLevel: entry.reasoningLevel
            )
        }
        threadManager.updatePersistedDraftTabs(for: thread.id, draftTabs: thread.persistedDraftTabs)
    }
}
