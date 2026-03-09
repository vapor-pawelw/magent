import Cocoa
import GhosttyBridge

extension ThreadDetailViewController {

    // MARK: - Close Tab

    func closeCurrentTab() {
        closeTab(at: currentTabIndex)
    }

    func closeTab(at index: Int) {
        guard index < thread.tmuxSessionNames.count else { return }

        let sessionName = thread.tmuxSessionNames[index]

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
                    alert.messageText = String(localized: .CommonStrings.commonError)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Close Multiple Tabs

    func closeTabsToTheRight(of index: Int) {
        let count = tabItems.count
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

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Collect session names for tabs to the right (before mutating)
        let sessionNames = (index + 1..<count).map { thread.tmuxSessionNames[$0] }
        batchCloseTabs(sessionNames: sessionNames)
    }

    func closeTabsToTheLeft(of index: Int) {
        guard index > 0 else { return }
        let tabCount = index

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.tabsCloseLeftTitle)
        alert.informativeText = tabCount == 1
            ? String(localized: .ThreadStrings.tabsCloseLeftMessageOne(tabCount))
            : String(localized: .ThreadStrings.tabsCloseLeftMessageMany(tabCount))
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: .CommonStrings.commonClose))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Collect session names for tabs to the left (before mutating)
        let sessionNames = (0..<index).map { thread.tmuxSessionNames[$0] }
        batchCloseTabs(sessionNames: sessionNames)
    }

    /// Closes multiple tabs by session name in a single sequential Task.
    private func batchCloseTabs(sessionNames: [String]) {
        // Capture old session-name-to-index mapping before async mutation
        let oldSessionNames = thread.tmuxSessionNames
        let removedSet = Set(sessionNames)

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

                // Determine which old indices were removed
                let indicesToRemove = oldSessionNames.enumerated()
                    .filter { removedSet.contains($0.element) }
                    .map(\.offset)

                // Remove in reverse order to keep indices stable
                for index in indicesToRemove.reversed() {
                    guard index < self.terminalViews.count, index < self.tabItems.count else { continue }
                    self.terminalViews[index].removeFromSuperview()
                    self.terminalViews.remove(at: index)
                    self.tabItems.remove(at: index)

                    if index < self.pinnedCount {
                        self.pinnedCount -= 1
                    }
                    if index == self.primaryTabIndex {
                        self.primaryTabIndex = 0
                    } else if self.primaryTabIndex > index {
                        self.primaryTabIndex -= 1
                    }
                }

                self.rebindTabActions()
                self.rebuildTabBar()

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
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
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

        let label = NSTextField(labelWithString: String(localized: .ThreadStrings.tabStartingAgent))
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

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

        let sessionName: String
        let settings = PersistenceService.shared.loadSettings()
        let slug = TmuxSessionNaming.repoSlug(from:
            settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
        )
        let overlaySelectedAgentType = thread.effectiveAgentType ?? threadManager.effectiveAgentType(for: thread.projectId)
        let firstTabSlug = TmuxSessionNaming.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: overlaySelectedAgentType))
        if thread.isMain {
            sessionName = thread.tmuxSessionNames.first ?? TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: nil, tabSlug: firstTabSlug)
        } else {
            sessionName = thread.tmuxSessionNames.first ?? TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: thread.name, tabSlug: firstTabSlug)
        }
        loadingOverlaySessionName = sessionName
        let startTime = Date()
        let maxWait: TimeInterval = 15
        let overlayAgentType = thread.sessionAgentTypes[sessionName] ?? thread.effectiveAgentType

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
                let ready = await self.isAgentReady(sessionName: sessionName, agentType: overlayAgentType)
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

    private func isAgentReady(sessionName: String, agentType: AgentType? = nil) async -> Bool {
        let result = await ShellExecutor.execute(
            "tmux capture-pane -t '\(sessionName)' -p 2>/dev/null"
        )
        guard result.exitCode == 0 else { return false }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ThreadManager.shared.isAgentContentReady(output, agentType: agentType)
    }

    private func dismissLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadingDetailLabel = nil
                self?.loadingOverlay?.removeFromSuperview()
                self?.loadingOverlay = nil
                self?.loadingOverlaySessionName = nil
            }
        }
    }

    @MainActor
    func updateLoadingOverlayDetail(_ detail: String?) {
        guard let label = loadingDetailLabel else { return }
        let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label.stringValue = trimmed
        label.isHidden = trimmed.isEmpty
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
