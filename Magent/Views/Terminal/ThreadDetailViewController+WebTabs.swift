import Cocoa
import MagentCore

/// Tracks a web tab that lives alongside terminal tabs in the tab bar.
/// The view is `nil` until the tab is first selected (lazy loading).
struct WebTabEntry {
    let identifier: String
    var url: URL
    let iconType: WebTabIconType
    var view: WebTabView?
}

extension ThreadDetailViewController {

    func prefersInAppExternalLinks() -> Bool {
        PersistenceService.shared.loadSettings().externalLinkOpenPreference == .inApp
    }

    func supportsInAppWebTab(for url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func openExternalWebDestination(
        url: URL,
        identifier: String,
        title: String,
        icon: NSImage? = nil,
        iconType: WebTabIconType = .web,
        forceInApp: Bool? = nil,
        resetExistingTabToURL: Bool = false
    ) {
        let shouldOpenInApp = (forceInApp ?? prefersInAppExternalLinks()) && supportsInAppWebTab(for: url)
        if shouldOpenInApp {
            openWebTab(
                url: url,
                identifier: identifier,
                title: title,
                icon: icon,
                iconType: iconType,
                resetExistingTabToURL: resetExistingTabToURL
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func externalLinkTooltip(clickDestinationInApp: Bool) -> String {
        let clickTarget = clickDestinationInApp ? "Magent" : "browser"
        let optionTarget = clickDestinationInApp ? "browser" : "Magent"
        return "Click: open in \(clickTarget) · Option-click: open in \(optionTarget)"
    }

    // MARK: - Restore from Persistence

    /// Recreates tab items for persisted web tabs without loading any pages.
    /// Pinned web tabs are inserted into the pinned section; unpinned are appended.
    func restoreWebTabItems() {
        for persisted in thread.persistedWebTabs {
            if webTabs.contains(where: { $0.identifier == persisted.identifier }) {
                continue
            }
            let entry = WebTabEntry(
                identifier: persisted.identifier,
                url: persisted.url,
                iconType: persisted.iconType,
                view: nil
            )
            webTabs.append(entry)

            let item = TabItemView(title: persisted.displayTitle)
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
        iconType: WebTabIconType = .none,
        resetExistingTabToURL: Bool = false
    ) {
        // Dedup: if a tab with this identifier already exists, select it.
        if let existingIndex = tabSlots.firstIndex(of: .web(identifier: identifier)) {
            if resetExistingTabToURL,
               let webIndex = webTabs.firstIndex(where: { $0.identifier == identifier }) {
                webTabs[webIndex].url = url
                webTabs[webIndex].view?.removeFromSuperview()
                webTabs[webIndex].view = nil
                if let persistedIndex = thread.persistedWebTabs.firstIndex(where: { $0.identifier == identifier }) {
                    thread.persistedWebTabs[persistedIndex].url = url
                    persistWebTabs()
                }
            }
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

            // Persist current URL on navigation so it survives app restart.
            let urlTabId = entry.identifier
            webTabView.onURLChange = { [weak self] url in
                guard let self,
                      let pIdx = self.thread.persistedWebTabs.firstIndex(where: { $0.identifier == urlTabId }),
                      self.thread.persistedWebTabs[pIdx].url != url else { return }
                self.thread.persistedWebTabs[pIdx].url = url
                self.persistWebTabs()
            }

            // Auto-update tab title from page host for user-created web tabs.
            // Skip if user has set a custom title via rename.
            if entry.iconType == .web {
                let tabId = entry.identifier
                webTabView.onTitleChange = { [weak self] _ in
                    guard let self,
                          let url = webTabView.webView.url,
                          url.absoluteString != "about:blank",
                          let shortHost = WebURLNormalizer.shortHost(from: url) else { return }
                    guard let pIdx = self.thread.persistedWebTabs.firstIndex(where: { $0.identifier == tabId }),
                          self.thread.persistedWebTabs[pIdx].customTitle == nil else { return }
                    guard let slotIndex = self.tabSlots.firstIndex(of: .web(identifier: tabId)),
                          slotIndex < self.tabItems.count else { return }
                    self.tabItems[slotIndex].titleLabel.stringValue = shortHost
                    // Persist the updated default title
                    self.thread.persistedWebTabs[pIdx].title = shortHost
                    self.persistWebTabs()
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
        hideActiveDraftTab()

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

        if thread.lastSelectedTabIdentifier != identifier {
            thread.lastSelectedTabIdentifier = identifier
            threadManager.updateLastSelectedTab(for: thread.id, identifier: identifier)
        }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(identifier, forKey: Self.lastOpenedTabDefaultsKey)

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

        guard let pIdx = thread.persistedWebTabs.firstIndex(where: { $0.identifier == identifier }) else { return }
        let persisted = thread.persistedWebTabs[pIdx]

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab, or leave empty to restore the default."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = persisted.customTitle ?? ""
        textField.placeholderString = persisted.title
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)

        if newName.isEmpty {
            // Restore default naming mechanism
            thread.persistedWebTabs[pIdx].customTitle = nil
            tabItems[displayIndex].titleLabel.stringValue = thread.persistedWebTabs[pIdx].title
        } else {
            thread.persistedWebTabs[pIdx].customTitle = newName
            tabItems[displayIndex].titleLabel.stringValue = newName
        }
        persistWebTabs()
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
