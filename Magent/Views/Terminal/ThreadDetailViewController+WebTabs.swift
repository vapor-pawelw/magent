import Cocoa
import MagentCore

/// Tracks a web tab that lives alongside terminal tabs in the tab bar.
/// The view is `nil` until the tab is first selected (lazy loading).
struct WebTabEntry {
    let identifier: String
    let url: URL
    let iconType: WebTabIconType
    var view: WebTabView?
}

extension ThreadDetailViewController {

    // MARK: - Restore from Persistence

    /// Recreates tab items for persisted web tabs without loading any pages.
    /// Pinned web tabs are inserted into the pinned section; unpinned are appended.
    func restoreWebTabItems() {
        for persisted in thread.persistedWebTabs {
            let entry = WebTabEntry(
                identifier: persisted.identifier,
                url: persisted.url,
                iconType: persisted.iconType,
                view: nil
            )
            webTabs.append(entry)

            let item = TabItemView(title: persisted.title)
            item.showCloseButton = true
            attachDragGesture(to: item)
            applyWebTabIcon(to: item, iconType: persisted.iconType)

            if persisted.isPinned {
                // Insert at the end of the pinned section
                tabItems.insert(item, at: pinnedCount)
                tabSlots.insert(.web(identifier: persisted.identifier), at: pinnedCount)
                pinnedCount += 1
            } else {
                tabItems.append(item)
                tabSlots.append(.web(identifier: persisted.identifier))
            }
        }
    }

    // MARK: - Open / Focus

    /// Open (or focus) a web tab for the given URL.
    func openWebTab(
        url: URL,
        identifier: String,
        title: String,
        icon: NSImage? = nil,
        iconType: WebTabIconType = .none
    ) {
        // Dedup: if a tab with this identifier already exists, select it.
        if let existingIndex = tabSlots.firstIndex(of: .web(identifier: identifier)) {
            selectTab(at: existingIndex)
            return
        }

        hideEmptyState()

        let entry = WebTabEntry(identifier: identifier, url: url, iconType: iconType, view: nil)
        webTabs.append(entry)

        let item = TabItemView(title: title)
        item.showCloseButton = true
        attachDragGesture(to: item)

        if let icon {
            item.typeIcon.image = icon
            item.typeIcon.isHidden = false
        } else {
            applyWebTabIcon(to: item, iconType: iconType)
        }

        tabItems.append(item)
        tabSlots.append(.web(identifier: identifier))

        // Persist
        let persisted = PersistedWebTab(identifier: identifier, url: url, title: title, iconType: iconType)
        thread.persistedWebTabs.append(persisted)
        persistWebTabs()

        rebuildTabBar()
        rebindAllTabActions()
        selectTab(at: tabSlots.count - 1)
    }

    // MARK: - Select (Lazy Load)

    /// Select a web tab by identifier. Creates the WKWebView on first selection.
    func selectWebTabByIdentifier(_ identifier: String, displayIndex: Int) {
        guard let webIndex = webTabs.firstIndex(where: { $0.identifier == identifier }) else { return }

        // Lazy-create WebTabView if needed
        if webTabs[webIndex].view == nil {
            let entry = webTabs[webIndex]
            let webTabView = WebTabView(url: entry.url, identifier: entry.identifier)
            webTabView.onOpenInNewTab = { [weak self] url in
                guard let self else { return }
                self.openWebTab(
                    url: url,
                    identifier: "web:\(UUID().uuidString)",
                    title: WebURLNormalizer.shortHost(from: url) ?? "Web",
                    iconType: .web
                )
            }

            // Auto-update tab title from page host for user-created web tabs.
            if entry.iconType == .web {
                let tabId = entry.identifier
                webTabView.onTitleChange = { [weak self] _ in
                    guard let self,
                          let url = webTabView.webView.url,
                          url.absoluteString != "about:blank",
                          let shortHost = WebURLNormalizer.shortHost(from: url) else { return }
                    guard let slotIndex = self.tabSlots.firstIndex(of: .web(identifier: tabId)),
                          slotIndex < self.tabItems.count else { return }
                    self.tabItems[slotIndex].titleLabel.stringValue = shortHost
                    // Persist the updated title
                    if let pIdx = self.thread.persistedWebTabs.firstIndex(where: { $0.identifier == tabId }) {
                        self.thread.persistedWebTabs[pIdx].title = shortHost
                        self.persistWebTabs()
                    }
                }
            }

            webTabs[webIndex].view = webTabView
        }

        guard let selectedView = webTabs[webIndex].view else { return }

        // Deselect all tab items
        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == displayIndex)
        }

        // Hide all terminal views
        for tv in terminalViews {
            tv.isHidden = true
        }

        // Hide all web tab views except the selected one
        for wt in webTabs {
            wt.view?.isHidden = (wt.identifier != identifier)
        }

        // Add to container if needed
        if selectedView.superview == nil {
            selectedView.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(selectedView)
            NSLayoutConstraint.activate([
                selectedView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                selectedView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                selectedView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                selectedView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
        }

        currentTabIndex = displayIndex
        activeWebTabId = identifier

        // Hide terminal overlays while web tab is active
        dismissLoadingOverlay()
        refreshPendingPromptBanner()
        refreshInitialPromptFailureBanner()
        refreshPendingPromptBanner()
        scrollOverlay.isHidden = true
        setScrollFABVisible(false)
        promptTOCCanShowForCurrentTab = false
        applyPromptTOCVisibility()
    }

    // MARK: - Close

    /// Close a web tab by its identifier.
    func closeWebTab(identifier: String) {
        guard let webIndex = webTabs.firstIndex(where: { $0.identifier == identifier }) else { return }
        guard let displayIndex = tabSlots.firstIndex(of: .web(identifier: identifier)) else { return }

        webTabs[webIndex].view?.removeFromSuperview()
        webTabs.remove(at: webIndex)

        tabItems.remove(at: displayIndex)
        tabSlots.remove(at: displayIndex)

        if displayIndex < pinnedCount { pinnedCount -= 1 }

        thread.persistedWebTabs.removeAll { $0.identifier == identifier }
        persistWebTabs()

        rebuildTabBar()
        rebindAllTabActions()

        if currentTabIndex == displayIndex || activeWebTabId == identifier {
            activeWebTabId = nil
            if !tabItems.isEmpty {
                selectTab(at: min(displayIndex, tabItems.count - 1))
            } else {
                showEmptyState()
            }
        } else if currentTabIndex > displayIndex {
            currentTabIndex -= 1
        }
    }

    // MARK: - Rename

    func showWebTabRenameDialog(at displayIndex: Int) {
        guard displayIndex < tabSlots.count, displayIndex < tabItems.count,
              case .web(let identifier) = tabSlots[displayIndex] else { return }

        let currentName = tabItems[displayIndex].titleLabel.stringValue

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentName
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return }

        tabItems[displayIndex].titleLabel.stringValue = newName

        if let pIdx = thread.persistedWebTabs.firstIndex(where: { $0.identifier == identifier }) {
            thread.persistedWebTabs[pIdx].title = newName
            persistWebTabs()
        }
    }

    /// Called when selecting a terminal tab — ensures web tabs are hidden.
    func hideActiveWebTab() {
        guard activeWebTabId != nil else { return }
        activeWebTabId = nil
        for wt in webTabs {
            wt.view?.isHidden = true
        }
        refreshOverlayVisibilitySettings()
    }

    // MARK: - Helpers

    private func persistWebTabs() {
        threadManager.updatePersistedWebTabs(for: thread.id, webTabs: thread.persistedWebTabs)
    }

    func applyWebTabIcon(to item: TabItemView, iconType: WebTabIconType) {
        switch iconType {
        case .jira:
            item.typeIcon.image = jiraButtonImage()
            item.typeIcon.isHidden = false
        case .pullRequest:
            let provider = threadManager._cachedRemoteByProjectId[thread.projectId]?.provider ?? .unknown
            item.typeIcon.image = openPRButtonImage(for: provider)
            item.typeIcon.isHidden = false
        case .web:
            item.typeIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Web")
            item.typeIcon.contentTintColor = .secondaryLabelColor
            item.typeIcon.isHidden = false
        case .none:
            break
        }
    }
}
