import Cocoa
import GhosttyBridge
import MagentCore

private final class ArchiveCommitMessageTextFieldDelegate: NSObject, NSTextFieldDelegate {
    let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }
}

private struct ManualLocalSyncTarget {
    let path: String
    let label: String
}

private enum ManualLocalSyncDirection: Int {
    case reconcileBothWays = 0
    case intoCurrentWorktree = 1
    case fromCurrentWorktree = 2
}

extension ThreadDetailViewController {

    private enum TerminalScrollAction {
        case pageUp
        case pageDown
        case bottom
    }

    // MARK: - Add Tab

    @objc func scrollTerminalPageUpTapped() {
        scrollCurrentTerminal(.pageUp)
    }

    @objc func scrollTerminalPageDownTapped() {
        scrollCurrentTerminal(.pageDown)
    }

    @objc func scrollTerminalToBottomTapped() {
        scrollCurrentTerminal(.bottom)
    }

    private func scrollCurrentTerminal(_ action: TerminalScrollAction) {
        guard let sessionName = currentSessionName() else { return }

        Task {
            do {
                switch action {
                case .pageUp:
                    try await TmuxService.shared.scrollPageUp(sessionName: sessionName)
                case .pageDown:
                    try await TmuxService.shared.scrollPageDown(sessionName: sessionName)
                case .bottom:
                    try await TmuxService.shared.scrollToBottom(sessionName: sessionName)
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await MainActor.run {
                        _ = self.terminalView(forSession: sessionName)?.bindingAction("scroll_to_bottom")
                    }
                }
                await MainActor.run {
                    self.scheduleScrollFABVisibilityRefresh()
                }
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.terminalScrollFailed(error.localizedDescription)),
                        style: .error
                    )
                }
            }
        }

        if let tv = currentTerminalView() {
            view.window?.makeFirstResponder(tv)
        }
    }

    @objc func archiveThreadTapped() {
        guard !thread.isMain else { return }
        let threadToArchive = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        guard !threadToArchive.isArchiving else { return }

        threadManager.markThreadArchiving(id: threadToArchive.id)
        Task {
            do {
                _ = try await threadManager.archiveThread(
                    threadToArchive,
                    promptForLocalSyncConflicts: true,
                    force: false
                )
            } catch ThreadManagerError.dirtyWorktree(let worktreePath) {
                await MainActor.run {
                    guard self.confirmDestructiveArchive(
                        worktreePath: worktreePath,
                        threadName: threadToArchive.name
                    ) else { return }
                    self.promptForArchiveCommitMessageAndRetry(thread: threadToArchive)
                }
            } catch ThreadManagerError.archiveCancelled {
                // User cancelled a local-sync conflict prompt — leave thread unchanged.
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.threadArchiveFailed(error.localizedDescription)),
                        style: .error
                    )
                }
            }
        }
    }

    @MainActor
    private func promptForArchiveCommitMessageAndRetry(thread: MagentThread) {
        Task {
            let defaultCommitMessage = await threadManager.suggestedArchiveCommitMessage(for: thread)
            await MainActor.run {
                guard let commitMessage = self.promptForArchiveCommitMessage(defaultValue: defaultCommitMessage) else {
                    self.threadManager.clearThreadArchivingState(id: thread.id)
                    return
                }
                self.retryArchiveForced(thread: thread, commitMessage: commitMessage)
            }
        }
    }

    @MainActor
    private func retryArchiveForced(thread: MagentThread, commitMessage: String) {
        threadManager.markThreadArchiving(id: thread.id)
        Task {
            do {
                _ = try await threadManager.archiveThread(
                    thread,
                    promptForLocalSyncConflicts: true,
                    force: true,
                    forceCommitMessage: commitMessage
                )
            } catch ThreadManagerError.archiveCancelled {
                // User cancelled a local-sync conflict prompt during forced retry.
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.threadArchiveFailed(error.localizedDescription)),
                        style: .error
                    )
                }
            }
        }
    }

    @MainActor
    private func confirmDestructiveArchive(
        worktreePath: String,
        threadName: String
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: .ThreadStrings.threadArchiveDestructiveDirtyTitle(threadName))
        alert.informativeText = String(localized: .ThreadStrings.threadArchiveDestructiveDirtyInfoDetail(worktreePath))
        alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveDestructiveDirtyConfirm))

        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func promptForArchiveCommitMessage(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: .ThreadStrings.threadArchiveCommitMessageTitle)
        alert.informativeText = String(localized: .ThreadStrings.threadArchiveCommitMessageInfo)
        alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveCommitAndArchiveButton))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))
        let commitButton = alert.buttons.first

        let textField = NSTextField(string: defaultValue)
        textField.placeholderString = String(localized: .ThreadStrings.threadArchiveCommitMessagePlaceholder)
        textField.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        let delegate = ArchiveCommitMessageTextFieldDelegate {
            commitButton?.isEnabled = !textField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        textField.delegate = delegate
        alert.accessoryView = textField

        commitButton?.isEnabled = !textField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let message = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    @objc func popOutThreadTapped() {
        guard !thread.isMain else { return }
        guard showsHeaderInfoStrip else { return }
        guard !PopoutWindowManager.shared.isThreadPoppedOut(thread.id) else { return }
        NotificationCenter.default.post(
            name: .magentPopOutThreadRequested,
            object: self,
            userInfo: ["threadId": thread.id]
        )
    }

    @objc func resyncLocalPathsTapped() {
        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else { return }
        guard project.hasCopyLocalFileSyncEntries else {
            BannerManager.shared.show(
                message: "Local Sync is only available when the project has at least one Copy path.",
                style: .warning
            )
            return
        }

        if currentThread.isMain {
            presentManualLocalSyncPicker(for: currentThread, project: project)
            return
        }
        guard let event = NSApp.currentEvent else { return }

        let thisName = (currentThread.worktreePath as NSString).lastPathComponent

        // Default target: base-branch worktree (falls back to repo root).
        let defaultSyncPath: String?
        let defaultSyncLabel: String
        let (resolvedPath, resolvedLabel) = threadManager.resolveBaseBranchSyncTarget(for: currentThread, project: project)
        if resolvedPath != project.repoPath {
            defaultSyncPath = resolvedPath
            defaultSyncLabel = resolvedLabel
        } else {
            defaultSyncPath = nil
            defaultSyncLabel = "Repo root"
        }
        // Option target: always repo root.
        let optionSyncPath: String? = nil
        let optionSyncLabel = "Repo root"
        let optionDiffersFromDefault = defaultSyncPath != optionSyncPath || defaultSyncLabel != optionSyncLabel

        let menu = NSMenu()

        let reconcileItem = NSMenuItem(
            title: "Reconcile \(thisName) with \(defaultSyncLabel)\u{2026}",
            action: #selector(agenticReconcileTapped(_:)),
            keyEquivalent: ""
        )
        reconcileItem.target = self
        reconcileItem.representedObject = defaultSyncPath
        menu.addItem(reconcileItem)

        if optionDiffersFromDefault {
            let reconcileAltItem = NSMenuItem(
                title: "Reconcile \(thisName) with \(optionSyncLabel)\u{2026}",
                action: #selector(agenticReconcileTapped(_:)),
                keyEquivalent: ""
            )
            reconcileAltItem.target = self
            reconcileAltItem.representedObject = optionSyncPath
            reconcileAltItem.isAlternate = true
            reconcileAltItem.keyEquivalentModifierMask = .option
            menu.addItem(reconcileAltItem)
        }

        menu.addItem(.separator())

        let intoWorktreeItem = NSMenuItem(
            title: "Pull into this worktree",
            action: #selector(resyncIntoWorktreeTapped(_:)),
            keyEquivalent: ""
        )
        intoWorktreeItem.target = self
        intoWorktreeItem.representedObject = defaultSyncPath

        let fromWorktreeItem = NSMenuItem(
            title: "Push from this worktree",
            action: #selector(resyncFromWorktreeTapped(_:)),
            keyEquivalent: ""
        )
        fromWorktreeItem.target = self
        fromWorktreeItem.representedObject = defaultSyncPath

        menu.addItem(intoWorktreeItem)
        menu.addItem(fromWorktreeItem)

        if optionDiffersFromDefault {
            let intoWorktreeAltItem = NSMenuItem(
                title: "Pull into this worktree",
                action: #selector(resyncIntoWorktreeTapped(_:)),
                keyEquivalent: ""
            )
            intoWorktreeAltItem.target = self
            intoWorktreeAltItem.representedObject = optionSyncPath
            intoWorktreeAltItem.isAlternate = true
            intoWorktreeAltItem.keyEquivalentModifierMask = .option
            menu.addItem(intoWorktreeAltItem)

            let fromWorktreeAltItem = NSMenuItem(
                title: "Push from this worktree",
                action: #selector(resyncFromWorktreeTapped(_:)),
                keyEquivalent: ""
            )
            fromWorktreeAltItem.target = self
            fromWorktreeAltItem.representedObject = optionSyncPath
            fromWorktreeAltItem.isAlternate = true
            fromWorktreeAltItem.keyEquivalentModifierMask = .option
            menu.addItem(fromWorktreeAltItem)
        }

        // Only show "Choose another worktree…" if there are additional worktrees beyond the default sync target
        let otherWorktreeCount = threadManager.threads.filter { thread in
            thread.projectId == currentThread.projectId
            && thread.id != currentThread.id
            && !thread.isArchived
        }.count
        if otherWorktreeCount > 1 {
            menu.addItem(.separator())
            let otherItem = NSMenuItem(
                title: "Choose another worktree…",
                action: #selector(resyncOtherLocalPathsTapped(_:)),
                keyEquivalent: ""
            )
            otherItem.target = self
            otherItem.representedObject = currentThread.id
            menu.addItem(otherItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: resyncLocalPathsButton)
    }

    // MARK: - Local Sync Actions

    /// Syncs configured local paths into this worktree.
    /// `sender.representedObject` optionally carries a source root override (base worktree path);
    /// when nil, the project repo root is used.
    @objc private func resyncIntoWorktreeTapped(_ sender: NSMenuItem) {
        let sourceRootOverride = sender.representedObject as? String
        let sourceLabel = sourceRootOverride.map { ($0 as NSString).lastPathComponent } ?? "repo root"
        performResyncIntoWorktree(sourceLabel: sourceLabel, sourceRootOverride: sourceRootOverride)
    }

    /// Syncs configured local paths from this worktree back to the project or base worktree.
    /// `sender.representedObject` optionally carries a destination root override (base worktree path);
    /// when nil, the project repo root is used.
    @objc private func resyncFromWorktreeTapped(_ sender: NSMenuItem) {
        let destinationRootOverride = sender.representedObject as? String
        let destLabel = destinationRootOverride.map { ($0 as NSString).lastPathComponent } ?? "repo root"
        performResyncFromWorktree(destLabel: destLabel, destinationRootOverride: destinationRootOverride)
    }

    @objc private func agenticReconcileTapped(_ sender: NSMenuItem) {
        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }
        let targetPath = (sender.representedObject as? String) ?? project.repoPath
        openAgenticReconcile(
            currentThread: currentThread,
            project: project,
            targetPath: targetPath,
            targetLabel: localSyncTargetLabel(for: targetPath, projectRepoPath: project.repoPath)
        )
    }

    @objc private func resyncOtherLocalPathsTapped(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID,
              let currentThread = threadManager.threads.first(where: { $0.id == threadId }) else { return }

        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }

        presentManualLocalSyncPicker(for: currentThread, project: project)
    }

    private func presentManualLocalSyncPicker(for currentThread: MagentThread, project: Project) {
        Task {
            do {
                let targets = try await manualLocalSyncTargets(for: currentThread, project: project)
                guard !targets.isEmpty else {
                    await MainActor.run {
                        BannerManager.shared.show(
                            message: "No other worktrees are available for Local Sync.",
                            style: .warning
                        )
                    }
                    return
                }

                await MainActor.run {
                    self.presentManualLocalSyncAlert(for: currentThread, project: project, targets: targets)
                }
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Failed to load worktrees for Local Sync: \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

    private func presentManualLocalSyncAlert(
        for currentThread: MagentThread,
        project: Project,
        targets: [ManualLocalSyncTarget]
    ) {
        let alert = NSAlert()
        alert.messageText = "Choose Worktree"
        alert.informativeText = "Choose a source or destination worktree, or use the agent to reconcile both sides."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let controlWidth: CGFloat = 280

        let directionLabel = NSTextField(labelWithString: "Direction:")
        directionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        directionLabel.textColor = .secondaryLabelColor

        let directionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        directionPopup.addItems(withTitles: [
            "Reconcile with agent",
            "Pull into this worktree",
            "Push from this worktree"
        ])
        directionPopup.selectItem(at: ManualLocalSyncDirection.reconcileBothWays.rawValue)

        let targetLabel = NSTextField(labelWithString: "Worktree:")
        targetLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetLabel.textColor = .secondaryLabelColor

        let targetComboBox = NSComboBox(frame: .zero)
        targetComboBox.isEditable = false
        targetComboBox.completes = true
        targetComboBox.numberOfVisibleItems = min(12, targets.count)
        targetComboBox.addItems(withObjectValues: targets.map(\.label))

        let (defaultPath, _) = threadManager.resolveBaseBranchSyncTarget(for: currentThread, project: project)
        let defaultIndex = targets.firstIndex(where: { $0.path == defaultPath }) ?? 0
        targetComboBox.selectItem(at: defaultIndex)

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .vertical
        accessoryStack.alignment = .leading
        accessoryStack.spacing = 4
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.addArrangedSubview(directionLabel)
        accessoryStack.addArrangedSubview(directionPopup)
        accessoryStack.setCustomSpacing(12, after: directionPopup)
        accessoryStack.addArrangedSubview(targetLabel)
        accessoryStack.addArrangedSubview(targetComboBox)

        NSLayoutConstraint.activate([
            accessoryStack.widthAnchor.constraint(equalToConstant: controlWidth),
            directionPopup.widthAnchor.constraint(equalTo: accessoryStack.widthAnchor),
            targetComboBox.widthAnchor.constraint(equalTo: accessoryStack.widthAnchor),
        ])

        // Force layout so the alert gets the correct intrinsic size
        accessoryStack.layoutSubtreeIfNeeded()
        let fittingSize = accessoryStack.fittingSize
        accessoryStack.setFrameSize(fittingSize)

        alert.accessoryView = accessoryStack
        alert.window.initialFirstResponder = targetComboBox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let targetIndex = targetComboBox.indexOfSelectedItem
        guard targets.indices.contains(targetIndex) else {
            BannerManager.shared.show(message: "Select a target worktree for Local Sync.", style: .warning)
            return
        }

        let target = targets[targetIndex]
        let direction = ManualLocalSyncDirection(rawValue: directionPopup.indexOfSelectedItem) ?? .intoCurrentWorktree

        switch direction {
        case .reconcileBothWays:
            openAgenticReconcile(
                currentThread: currentThread,
                project: project,
                targetPath: target.path,
                targetLabel: target.label
            )
        case .intoCurrentWorktree:
            performResyncIntoWorktree(sourceLabel: target.label, sourceRootOverride: target.path)
        case .fromCurrentWorktree:
            performResyncFromWorktree(destLabel: target.label, destinationRootOverride: target.path)
        }
    }

    private func manualLocalSyncTargets(
        for currentThread: MagentThread,
        project: Project
    ) async throws -> [ManualLocalSyncTarget] {
        let worktrees = try await GitService.shared.listWorktrees(repoPath: project.repoPath)
        var targets: [ManualLocalSyncTarget] = []
        var seenPaths = Set<String>()

        for worktree in worktrees {
            guard !worktree.isBareStem, worktree.path != currentThread.worktreePath else { continue }
            guard seenPaths.insert(worktree.path).inserted else { continue }

            let worktreeName = (worktree.path as NSString).lastPathComponent
            let branch = worktree.branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = branch.isEmpty ? worktreeName : "\(worktreeName) (\(branch))"
            targets.append(ManualLocalSyncTarget(path: worktree.path, label: label))
        }

        return targets
    }

    private func performResyncIntoWorktree(sourceLabel: String, sourceRootOverride: String? = nil) {
        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }

        let syncEntries = threadManager.effectiveLocalSyncEntries(for: currentThread, project: project)
        guard !syncEntries.isEmpty else {
            BannerManager.shared.show(message: "No Local Sync Paths are configured for this thread.", style: .warning)
            return
        }

        startResyncSpinner()
        BannerManager.shared.show(
            message: "Syncing Local Paths from \(sourceLabel)\u{2026}",
            style: .info,
            duration: nil,
            isDismissible: false,
            showsSpinner: true
        )
        let projectSnapshot = project
        let worktreePath = currentThread.worktreePath
        let syncEntriesSnapshot = syncEntries
        Task {
            defer { Task { @MainActor in self.stopResyncSpinner() } }
            do {
                let missingPaths = try await ThreadManager.shared.syncConfiguredLocalPathsIntoWorktree(
                    project: projectSnapshot,
                    worktreePath: worktreePath,
                    syncEntries: syncEntriesSnapshot,
                    promptForConflicts: true,
                    sourceRootOverride: sourceRootOverride
                )

                await MainActor.run {
                    if missingPaths.isEmpty {
                        BannerManager.shared.show(
                            message: "Local Sync Paths refreshed from \(sourceLabel).",
                            style: .info
                        )
                    } else {
                        let noun = missingPaths.count == 1 ? "path was" : "paths were"
                        BannerManager.shared.show(
                            message: "Local Sync refresh finished, but \(missingPaths.count) configured \(noun) missing in \(sourceLabel).",
                            style: .warning,
                            duration: 8.0,
                            details: missingPaths.joined(separator: "\n"),
                            detailsCollapsedTitle: "Show missing paths",
                            detailsExpandedTitle: "Hide missing paths"
                        )
                    }
                }
            } catch ThreadManagerError.archiveCancelled {
                await MainActor.run {
                    BannerManager.shared.dismissCurrent()
                }
                return
            } catch ThreadManagerError.agenticMergeReady(let context) {
                await MainActor.run {
                    BannerManager.shared.dismissCurrent()
                    self.openAgenticMergeTab(context: context)
                }
                return
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Failed to resync Local Sync Paths: \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

    private func performResyncFromWorktree(destLabel: String, destinationRootOverride: String? = nil) {
        let currentThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            BannerManager.shared.show(message: "Could not find the project for this thread.", style: .error)
            return
        }

        let syncEntries = threadManager.effectiveLocalSyncEntries(for: currentThread, project: project)
        guard syncEntries.contains(where: { $0.mode == .copy }) else {
            BannerManager.shared.show(message: "No copy-mode Local Sync Paths are configured for this thread.", style: .warning)
            return
        }

        startResyncSpinner()
        BannerManager.shared.show(
            message: "Syncing Local Paths back to \(destLabel)\u{2026}",
            style: .info,
            duration: nil,
            isDismissible: false,
            showsSpinner: true
        )
        let projectSnapshot = project
        let worktreePath = currentThread.worktreePath
        let syncEntriesSnapshot = syncEntries
        Task {
            defer { Task { @MainActor in self.stopResyncSpinner() } }
            do {
                try await ThreadManager.shared.syncConfiguredLocalPathsFromWorktree(
                    project: projectSnapshot,
                    worktreePath: worktreePath,
                    syncEntries: syncEntriesSnapshot,
                    promptForConflicts: true,
                    destinationRootOverride: destinationRootOverride
                )
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Local Sync Paths pushed back to \(destLabel).",
                        style: .info
                    )
                }
            } catch ThreadManagerError.archiveCancelled {
                await MainActor.run {
                    BannerManager.shared.dismissCurrent()
                }
                return
            } catch ThreadManagerError.agenticMergeReady(let context) {
                await MainActor.run {
                    BannerManager.shared.dismissCurrent()
                    self.openAgenticMergeTab(context: context)
                }
                return
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Failed to sync Local Sync Paths to \(destLabel): \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

    // MARK: - Agentic Sync

    private func openAgenticMergeTab(context: LocalSyncAgenticMergeContext) {
        let pathsList = context.syncPaths.map { "  - \($0)" }.joined(separator: "\n")
        let prompt: String
        let customTitle: String
        switch context.operation {
        case .syncSourceToDestination:
            customTitle = "Local Sync Resolve"
            prompt = """
            I need you to complete a one-way local sync and resolve any conflicts.

            **Authoritative Source:** \(context.sourceRoot) (\(context.sourceLabel))
            **Destination to update:** \(context.destinationRoot) (\(context.destinationLabel))

            **Paths to sync:**
            \(pathsList)

            For each path listed above:
            1. Make Destination reflect Source
            2. If the destination already has a different version, read both sides and resolve the conflict intelligently
            3. Preserve meaningful changes when possible, but treat Source as the authoritative side for the final result
            4. Do not modify Source

            If you are unsure which change to keep, ask me before proceeding.

            After syncing, confirm what you changed in Destination and list any files where you merged or made a judgment call.
            """
        case .reconcileBothWays:
            customTitle = "Local Sync Reconcile"
            prompt = """
            I need you to reconcile local files between two directories.

            **Side A:** \(context.sourceRoot) (\(context.sourceLabel))
            **Side B:** \(context.destinationRoot) (\(context.destinationLabel))

            **Paths to reconcile:**
            \(pathsList)

            For each path listed above:
            1. Read the current state on both sides
            2. Reconcile differences intelligently so both sides end up consistent
            3. You may update either side when needed
            4. Preserve meaningful changes from both sides whenever possible

            If you are unsure which change to keep, ask me before proceeding.

            After reconciling, confirm what changed on each side and list any files where you merged or made a judgment call.
            """
        }
        let agentType = threadManager.effectiveAgentTypeAvoidingRateLimit(for: thread.projectId)

        addTab(
            using: agentType,
            useAgentCommand: true,
            initialPrompt: prompt,
            shouldSubmitInitialPrompt: true,
            customTitle: customTitle,
            tabNameSuffix: "sync"
        )
    }

    private func openAgenticReconcile(
        currentThread: MagentThread,
        project: Project,
        targetPath: String,
        targetLabel: String
    ) {
        let syncPaths = effectiveAgenticSyncPaths(for: currentThread, project: project)
        guard !syncPaths.isEmpty else {
            BannerManager.shared.show(message: "No Local Sync Paths are configured for this thread.", style: .warning)
            return
        }

        openAgenticMergeTab(context: LocalSyncAgenticMergeContext(
            operation: .reconcileBothWays,
            sourceRoot: currentThread.worktreePath,
            destinationRoot: targetPath,
            syncPaths: syncPaths,
            sourceLabel: (currentThread.worktreePath as NSString).lastPathComponent,
            destinationLabel: targetLabel
        ))
    }

    private func effectiveAgenticSyncPaths(for currentThread: MagentThread, project: Project) -> [String] {
        threadManager.effectiveLocalSyncEntries(for: currentThread, project: project).map(\.path)
    }

    private func localSyncTargetLabel(for path: String, projectRepoPath: String) -> String {
        if path == projectRepoPath {
            return "Repo root"
        }
        return (path as NSString).lastPathComponent
    }

    private func startResyncSpinner() {
        resyncLocalPathsButton.isEnabled = false
        resyncLocalPathsButton.image = NSImage(
            systemSymbolName: "progress.indicator",
            accessibilityDescription: "Syncing"
        )
    }

    private func stopResyncSpinner() {
        resyncLocalPathsButton.isEnabled = true
        resyncLocalPathsButton.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Sync local-only files"
        )
        resyncLocalPathsButton.isHidden = resyncLocalPathsButtonShouldBeHidden()
    }

    @objc func addTabTapped() {
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            // Fast path: use last-selected model/reasoning for the resolved agent type
            let resolvedAgent = threadManager.effectiveAgentType(for: thread.projectId)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            addTab(using: nil, useAgentCommand: true, modelId: modelId, reasoningLevel: reasoning)
        } else {
            presentNewTabSheet()
        }
    }

    private func tabSheetSubtitle() -> String {
        if thread.isMain {
            return "Thread: Main"
        }
        if let description = thread.taskDescription {
            return "Thread: \(description) (\(thread.branchName))"
        }
        return "Thread: \(thread.branchName)"
    }

    private func presentNewTabSheet() {
        guard let window = view.window else { return }
        let settings = PersistenceService.shared.loadSettings()
        let injection = threadManager.effectiveInjection(for: thread.projectId)
        let config = AgentLaunchSheetConfig(
            title: "New Tab",
            acceptButtonTitle: "Add Tab",
            draftScope: .newTab(threadId: thread.id),
            availableAgents: settings.availableActiveAgents,
            defaultAgentType: threadManager.effectiveAgentType(for: thread.projectId),
            subtitle: tabSheetSubtitle(),
            showDescriptionAndBranchFields: false,
            showTitleField: true,
            autoGenerateHint: nil,
            terminalInjectionPrefill: injection.terminalCommand.isEmpty ? nil : injection.terminalCommand,
            agentContextPrefill: injection.agentContext.isEmpty ? nil : injection.agentContext,
            showDraftCheckbox: true
        )
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            guard let self, let result else { return }
            if result.isDraft, let agentType = result.agentType {
                let identifier = "draft:\(UUID().uuidString)"
                self.openDraftTab(
                    identifier: identifier,
                    agentType: agentType,
                    prompt: result.prompt ?? "",
                    modelId: result.modelId,
                    reasoningLevel: result.reasoningLevel
                )
            } else if let webURL = result.initialWebURL {
                let title = result.tabTitle ?? webURL.host ?? "Web"
                self.openWebTab(url: webURL, identifier: "web:\(UUID().uuidString)", title: title, iconType: .web)
            } else {
                let switchToTab = PersistenceService.shared.loadSettings().switchToNewlyCreatedTab
                self.addTab(
                    using: result.agentType,
                    useAgentCommand: result.useAgentCommand,
                    initialPrompt: result.prompt,
                    shouldSubmitInitialPrompt: true,
                    customTitle: result.tabTitle,
                    pendingPromptFileURL: result.pendingPromptFileURL,
                    modelId: result.modelId,
                    reasoningLevel: result.reasoningLevel,
                    switchToTab: switchToTab
                )
            }
        }
    }

    func presentContinueTabSheet(for index: Int) {
        guard index < tabSlots.count, case .terminal = tabSlots[index] else { return }
        guard let window = view.window else { return }

        let settings = PersistenceService.shared.loadSettings()
        let agents = settings.availableActiveAgents
        guard !agents.isEmpty else { return }

        let config = AgentLaunchSheetConfig(
            title: "Continue In",
            acceptButtonTitle: "Continue",
            draftScope: .newTab(threadId: thread.id),
            availableAgents: agents,
            defaultAgentType: threadManager.effectiveAgentType(for: thread.projectId),
            isAgentOnly: true,
            subtitle: tabSheetSubtitle(),
            showDescriptionAndBranchFields: false,
            showTitleField: true,
            autoGenerateHint: nil,
            terminalInjectionPrefill: nil,
            agentContextPrefill: nil,
            showPromptInputArea: true,
            showDraftCheckbox: false,
            promptLabelOverride: "Extra context"
        )
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            guard let self, let result, let agentType = result.agentType else { return }
            let switchToTab = PersistenceService.shared.loadSettings().switchToNewlyCreatedTab
            let extraContext = result.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.continueTabInAgent(
                at: index,
                targetAgent: agentType,
                extraContext: extraContext?.isEmpty == false ? extraContext : nil,
                customTitle: result.tabTitle,
                modelId: result.modelId,
                reasoningLevel: result.reasoningLevel,
                switchToTab: switchToTab
            )
        }
    }

    private func addTab(
        using agentType: AgentType?,
        useAgentCommand: Bool,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        resumeSessionID: String? = nil,
        isForwardedContinuation: Bool = false,
        customTitle: String? = nil,
        pendingPromptFileURL: URL? = nil,
        tabNameSuffix: String? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        switchToTab: Bool = true
    ) {
        // Phase 1: Immediately add a tab item and show "Creating tab..." overlay so
        // the tab appears in the bar without waiting for tmux session creation.
        hideEmptyState()
        let pendingIndex = tabItems.count
        let item = TabItemView(title: "New Tab")
        item.showCloseButton = false
        attachDragGesture(to: item)
        tabItems.append(item)
        tabSlots.append(.terminal(sessionName: ""))
        rebindAllTabActions()
        rebuildTabBar()

        if switchToTab {
            // Mark the new tab as selected in the tab bar.
            for (i, item) in tabItems.enumerated() { item.isSelected = (i == pendingIndex) }

            // Hide current terminal/web content so the old tab doesn't show through.
            for termView in terminalViews { termView.isHidden = true }
            hideActiveWebTab()

            // Show "Creating tab..." overlay immediately — tmux session creation
            // always takes long enough to warrant the feedback, so skip the debounce.
            ensureLoadingOverlay()
            loadingLabel?.stringValue = String(localized: .ThreadStrings.tabCreatingSession)
            loadingDetailLabel?.isHidden = true
            revealLoadingOverlay(after: 0)
        }

        // Phase 2: Run tmux setup in the background; overlay stays visible throughout.
        Task {
            do {
                let tab = try await threadManager.addTab(
                    to: thread,
                    useAgentCommand: useAgentCommand,
                    requestedAgentType: agentType,
                    initialPrompt: initialPrompt,
                    shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                    resumeSessionID: resumeSessionID,
                    isForwardedContinuation: isForwardedContinuation,
                    customTitle: customTitle,
                    tabNameSuffix: tabNameSuffix,
                    pendingPromptFileURL: pendingPromptFileURL,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
                // Skip recreateSessionIfNeeded — the session was just created by addTab().
                // Calling it here risks a race: the pane path check can fail during shell
                // startup (before ZDOTDIR cd completes), causing the session to be killed
                // and recreated without the initial prompt. Bell monitoring is set up
                // separately by createSession → configureBellMonitoring.
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }
                    let terminalView = self.makeTerminalView(for: tab.tmuxSessionName)
                    self.terminalViews.append(terminalView)

                    // Fix the placeholder slot with the real session name.
                    if pendingIndex < self.tabSlots.count {
                        self.tabSlots[pendingIndex] = .terminal(sessionName: tab.tmuxSessionName)
                    }
                    self.requireStartupOverlay(for: tab.tmuxSessionName)

                    // Update tab title and make it closable.
                    let title = self.thread.displayName(for: tab.tmuxSessionName, at: pendingIndex)
                    if pendingIndex < self.tabItems.count {
                        self.tabItems[pendingIndex].titleLabel.stringValue = title
                        self.tabItems[pendingIndex].showCloseButton = true
                    }
                    self.rebindAllTabActions()

                    if switchToTab {
                        // Dismiss the "Creating tab..." overlay before handing off to selectTab,
                        // which will show its own "Starting agent..." overlay if needed.
                        self.dismissLoadingOverlay()

                        // Hand off to normal selectTab flow, which shows "Starting agent..." overlay.
                        self.selectTab(at: pendingIndex)
                    }
                }
            } catch {
                await MainActor.run {
                    // Remove the pending tab on error.
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

    func addTabFromKeyboard() {
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            let resolvedAgent = threadManager.effectiveAgentType(for: thread.projectId)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            addTab(using: nil, useAgentCommand: true, modelId: modelId, reasoningLevel: reasoning)
        } else {
            presentNewTabSheet()
        }
    }

    // MARK: - Tab Detach

    /// Keyboard entry point for detaching the current tab (Cmd+Shift+D).
    /// Full implementation wired by the parallel popout-integration agent.
    func detachCurrentTabFromKeyboard() {
        let settings = PersistenceService.shared.loadSettings()
        guard settings.isTabDetachFeatureEnabled else { return }
        let index = currentTabIndex
        guard index >= 0, index < tabSlots.count else { return }
        guard case .terminal = tabSlots[index] else { return }
        detachTab(at: index)
    }

    /// Detach a terminal tab at the given index into a separate pop-out window.
    /// Stores the terminal view in cache, shows a placeholder, and creates the pop-out.
    func detachTab(at index: Int) {
        let settings = PersistenceService.shared.loadSettings()
        guard settings.isTabDetachFeatureEnabled else { return }
        guard index >= 0, index < tabSlots.count else { return }
        guard case .terminal(let sessionName) = tabSlots[index] else { return }
        guard let terminalIndex = thread.tmuxSessionNames.firstIndex(of: sessionName),
              terminalIndex < terminalViews.count else { return }

        let tv = terminalViews[terminalIndex]
        let reuseKey = terminalReuseKey(for: sessionName)
        ReusableTerminalViewCache.shared.store(tv, sessionName: sessionName, reuseKey: reuseKey)

        // Hide the terminal view (it's now in the cache)
        tv.removeFromSuperview()

        // Update tab item indicator
        if index < tabItems.count {
            tabItems[index].isDetached = true
        }

        // Create the pop-out window
        PopoutWindowManager.shared.detachTab(
            sessionName: sessionName,
            thread: thread,
            from: view.window
        )

        if index == currentTabIndex {
            selectTab(at: index)
        }
    }

    /// Return a detached tab from its pop-out window back to this thread's tab bar.
    func returnDetachedTab(sessionName: String) {
        if let placeholder = detachedTabPlaceholders.removeValue(forKey: sessionName) {
            placeholder.removeFromSuperview()
        }

        // Find the tab slot index for this session
        guard let slotIndex = tabSlots.firstIndex(where: {
            if case .terminal(let name) = $0 { return name == sessionName }
            return false
        }) else { return }

        // Retrieve terminal view from cache
        let reuseKey = terminalReuseKey(for: sessionName)
        if let tv = ReusableTerminalViewCache.shared.take(sessionName: sessionName, reuseKey: reuseKey) {
            // Replace the terminal view at this index
            if let terminalIndex = thread.tmuxSessionNames.firstIndex(of: sessionName),
               terminalIndex < terminalViews.count {
                terminalViews[terminalIndex] = tv
            }

            // If this tab is currently selected, show it
            if slotIndex == currentTabIndex {
                tv.translatesAutoresizingMaskIntoConstraints = false
                terminalContainer.addSubview(tv)
                NSLayoutConstraint.activate([
                    tv.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                    tv.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                    tv.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                    tv.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
                ])
                for termView in terminalViews {
                    termView.isHidden = (termView !== tv)
                }
                view.window?.makeFirstResponder(tv)
                updateTerminalScrollControlsState()
                schedulePromptTOCRefresh()
            }
        }

        // Update tab item indicator
        if slotIndex < tabItems.count {
            tabItems[slotIndex].isDetached = false
        }
    }

    // MARK: - Update & Rename

    func updateThread(_ updated: MagentThread) {
        thread = updated
        refreshTabStatusIndicators()
        refreshReviewButtonVisibility()
        schedulePromptTOCRefresh()
    }

    func handleRename(_ updated: MagentThread) {
        // Capture old terminal session names (in slot order) before updating thread state.
        var oldTerminalNames: [String] = []
        for slot in tabSlots {
            if case .terminal(let name) = slot { oldTerminalNames.append(name) }
        }

        thread = updated

        // Build old→new rename map from positional correspondence.
        var renameMap: [String: String] = [:]
        for (seqIdx, newName) in thread.tmuxSessionNames.enumerated() {
            if seqIdx < oldTerminalNames.count, oldTerminalNames[seqIdx] != newName {
                renameMap[oldTerminalNames[seqIdx]] = newName
            }
        }

        // Re-key all session-keyed VC state in one place so no cache is missed.
        rekeySessionState(renameMap)

        // Update onCopy/onSubmitLine closures to use the new (renamed) tmux session names.
        // terminalViews are indexed by thread.tmuxSessionNames (creation order).
        for (termIdx, terminalView) in terminalViews.enumerated() {
            if termIdx < thread.tmuxSessionNames.count {
                let newSessionName = thread.tmuxSessionNames[termIdx]
                // Keep the view's tmux session tag aligned with the renamed
                // session so the `TmuxService` pre-kill hook can still find
                // and free this surface before the new-named session dies
                // (prevents libghostty's PTY-close `_exit()`).
                terminalView.tmuxSessionName = newSessionName
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

        // Rebuild tabSlots terminal entries from the current thread.tmuxSessionNames
        // preserving the display order. Match by position in the terminal-only subsequence.
        var terminalSlotPositions: [Int] = []
        for (i, slot) in tabSlots.enumerated() {
            if case .terminal = slot { terminalSlotPositions.append(i) }
        }
        for (seqIdx, displayIdx) in terminalSlotPositions.enumerated() {
            if seqIdx < thread.tmuxSessionNames.count {
                let newName = thread.tmuxSessionNames[seqIdx]
                tabSlots[displayIdx] = .terminal(sessionName: newName)
                if displayIdx < tabItems.count {
                    tabItems[displayIdx].titleLabel.stringValue = thread.displayName(for: newName, at: displayIdx)
                }
            }
        }

        refreshTabStatusIndicators()
        schedulePromptTOCRefresh()
    }

    /// Re-keys all session-name-keyed VC state after a rename.
    /// Centralised so that future session-keyed caches cannot be forgotten.
    private func rekeySessionState(_ renameMap: [String: String]) {
        guard !renameMap.isEmpty else { return }

        // preparedSessions
        for (oldName, newName) in renameMap {
            if preparedSessions.remove(oldName) != nil {
                preparedSessions.insert(newName)
            }
        }

        // In-flight preparation tasks: cancel the old-name task (its completion
        // path would use displayIndex(forSession: oldName) which now fails) and
        // let the new name be prepared lazily on next tab selection.
        for (oldName, _) in renameMap {
            if let task = sessionPreparationTasks.removeValue(forKey: oldName) {
                task.cancel()
            }
            sessionPreparationTaskTokens.removeValue(forKey: oldName)
        }

        // Loading overlay tracks which session it is waiting for.
        if let current = loadingOverlaySessionName, let newName = renameMap[current] {
            loadingOverlaySessionName = newName
        }

        // Startup overlay requirements
        for (oldName, newName) in renameMap {
            if startupOverlayRequiredSessions.remove(oldName) != nil {
                startupOverlayRequiredSessions.insert(newName)
            }
        }
    }

    func refreshTabStatusIndicators() {
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
                tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
                tabItems[i].isRateLimitPropagated = thread.rateLimitedSessions[sessionName]?.isPropagated ?? false
                tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
                tabItems[i].hasTerminalCorruption = threadManager.isTerminalCorrupted(sessionName: sessionName)
                tabItems[i].showKeepAliveIcon = !thread.isKeepAlive
                    && thread.protectedTmuxSessions.contains(sessionName)
            } else {
                tabItems[i].hasUnreadCompletion = false
                tabItems[i].hasWaitingForInput = false
                tabItems[i].hasBusy = false
                tabItems[i].hasRateLimit = false
                tabItems[i].isRateLimitPropagated = false
                tabItems[i].hasTerminalCorruption = false
                tabItems[i].showKeepAliveIcon = false
            }
        }
        refreshTabTooltips()
    }

    @MainActor
    func handleSubmittedLine(_ line: String, sessionName: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if thread.agentTmuxSessions.contains(sessionName) {
            threadManager.markSessionBusy(threadId: thread.id, sessionName: sessionName)
        }

        if thread.agentTmuxSessions.contains(sessionName) {
            threadManager.scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: sessionName)
        } else if let resolvedSession = currentSessionName() {
            if thread.agentTmuxSessions.contains(resolvedSession) {
                threadManager.scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: resolvedSession)
            }
        }

        let threadId = thread.id
        Task {
            await threadManager.generateTaskDescriptionIfNeeded(threadId: threadId, prompt: trimmed)
        }

        if thread.lastSelectedTabIdentifier == sessionName {
            schedulePromptTOCRefresh(after: 0.2)
        }
    }

    // MARK: - Review

    @objc func reviewButtonTapped() {
        let settings = PersistenceService.shared.loadSettings()
        let activeAgents = settings.availableActiveAgents
        guard !activeAgents.isEmpty else {
            BannerManager.shared.show(message: String(localized: .NotificationStrings.reviewEnableAgentWarning), style: .warning)
            return
        }

        let menu = NSMenu()
        populateReviewMenu(
            menu: menu,
            activeAgents: activeAgents,
            defaultAgentType: defaultReviewAgentType(from: settings)
        )
        menu.popUp(positioning: nil, at: NSPoint(x: reviewButton.bounds.minX, y: reviewButton.bounds.minY), in: reviewButton)
    }

    @objc private func reviewMenuItemTapped(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender) else { return }
        let usesMaxReasoning = selection.data["reviewReasoningMode"] == "max"

        switch selection.mode {
        case .agent(let agentType):
            startReview(using: agentType, usesMaxReasoning: usesMaxReasoning)
        case .projectDefault:
            let settings = PersistenceService.shared.loadSettings()
            startReview(using: defaultReviewAgentType(from: settings), usesMaxReasoning: usesMaxReasoning)
        case .terminal, .web:
            return
        }
    }

    private func startReview(using agentType: AgentType?, usesMaxReasoning: Bool = false) {
        guard let agentType else {
            BannerManager.shared.show(message: String(localized: .NotificationStrings.reviewEnableAgentWarning), style: .warning)
            return
        }

        let settings = PersistenceService.shared.loadSettings()
        let overrides = reviewLaunchOverrides(for: agentType, usesMaxReasoning: usesMaxReasoning)
        addTab(
            using: agentType,
            useAgentCommand: true,
            initialPrompt: reviewPrompt(),
            customTitle: TmuxSessionNaming.reviewTabDisplayName(
                for: agentType,
                showAgentName: settings.availableActiveAgents.count > 1
            ),
            modelId: overrides.modelId,
            reasoningLevel: overrides.reasoningLevel
        )
    }

    private func defaultReviewAgentType(from settings: AppSettings) -> AgentType? {
        threadManager.resolveAgentType(for: thread.projectId, requestedAgentType: nil, settings: settings)
    }

    private func populateReviewMenu(
        menu: NSMenu,
        activeAgents: [AgentType],
        defaultAgentType: AgentType?
    ) {
        let title = "Review Changes"
        let headerItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        headerItem.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        menu.addItem(headerItem)
        menu.addItem(.separator())

        var orderedAgents = activeAgents
        if let defaultAgentType, let idx = orderedAgents.firstIndex(of: defaultAgentType) {
            orderedAgents.remove(at: idx)
            orderedAgents.insert(defaultAgentType, at: 0)
        }

        for agent in orderedAgents {
            let isDefault = agent == defaultAgentType
            let normalItem = NSMenuItem(
                title: reviewMenuTitle(for: agent, usesMaxReasoning: false, isDefault: isDefault),
                action: #selector(reviewMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            normalItem.target = self
            normalItem.representedObject = [
                "mode": "agent",
                "agentRaw": agent.rawValue,
                "reviewReasoningMode": "high",
            ]
            menu.addItem(normalItem)

            // Option-alternate: swap to max-reasoning launch while menu is open.
            let maxItem = NSMenuItem(
                title: reviewMenuTitle(for: agent, usesMaxReasoning: true, isDefault: isDefault),
                action: #selector(reviewMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            maxItem.target = self
            maxItem.representedObject = [
                "mode": "agent",
                "agentRaw": agent.rawValue,
                "reviewReasoningMode": "max",
            ]
            maxItem.isAlternate = true
            maxItem.keyEquivalentModifierMask = .option
            menu.addItem(maxItem)
        }
    }

    private func reviewMenuTitle(for agentType: AgentType, usesMaxReasoning: Bool, isDefault: Bool) -> String {
        let baseTitle: String
        if usesMaxReasoning, reviewLaunchOverrides(for: agentType, usesMaxReasoning: true).reasoningLevel != nil {
            baseTitle = "\(agentType.displayName) (Max reasoning)"
        } else {
            baseTitle = agentType.displayName
        }
        return isDefault ? "\(baseTitle) (Default)" : baseTitle
    }

    private func reviewLaunchOverrides(for agentType: AgentType, usesMaxReasoning: Bool) -> (modelId: String?, reasoningLevel: String?) {
        switch agentType {
        case .claude:
            return (
                AgentModelsService.shared.validatedModelId("opus", for: .claude) ?? "opus",
                AgentModelsService.shared.validatedReasoningLevel(usesMaxReasoning ? "max" : "high", for: .claude, modelId: "opus")
            )
        case .codex:
            return (
                AgentModelsService.shared.validatedModelId("gpt-5.4", for: .codex) ?? "gpt-5.4",
                AgentModelsService.shared.validatedReasoningLevel(usesMaxReasoning ? "xhigh" : "high", for: .codex, modelId: "gpt-5.4")
            )
        case .custom:
            return (nil, nil)
        }
    }

    private func reviewPrompt() -> String {
        let baseBranch = threadManager.resolveBaseBranch(for: thread)
        let settings = PersistenceService.shared.loadSettings()
        return settings.reviewPrompt.replacingOccurrences(of: "{baseBranch}", with: baseBranch)
    }

    // MARK: - Context Transfer

    @objc func exportContextButtonTapped() {
        exportTabContext(at: currentTabIndex)
    }

    @objc func togglePromptTOCTapped() {
        togglePromptTOCVisibility()
    }

    @objc func continueInButtonTapped(_ sender: NSButton) {
        presentContinueTabSheet(for: currentTabIndex)
    }

    func continueTabInAgent(
        at index: Int,
        targetAgent: AgentType,
        extraContext: String? = nil,
        customTitle: String? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        switchToTab: Bool = true
    ) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        let sourceAgent = threadManager.agentType(for: thread, sessionName: sessionName)
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"
        let contextBasePath = project?.resolvedWorktreesBasePath()

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextCaptureTerminalFailed), style: .error)
                }
                return
            }

            let markdown = ContextExporter.formatAsMarkdown(
                rawContent: rawContent,
                sourceAgent: sourceAgent,
                threadName: thread.name,
                projectName: projectName
            )

            guard let contextBasePath else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextWriteFileFailed), style: .error)
                }
                return
            }

            guard let contextPath = ContextExporter.writeContextFile(
                markdown: markdown,
                inWorktreesBasePath: contextBasePath
            ) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextWriteFileFailed), style: .error)
                }
                return
            }

            let prompt = ContextExporter.transferPrompt(contextFilePath: contextPath, extraContext: extraContext)

            await MainActor.run {
                self.addTab(
                    using: targetAgent,
                    useAgentCommand: true,
                    initialPrompt: prompt,
                    isForwardedContinuation: true,
                    customTitle: customTitle,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel,
                    switchToTab: switchToTab
                )
            }
        }
    }

    func resumeAgentSessionInNewTab(at index: Int) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        guard let agentType = threadManager.agentType(for: thread, sessionName: sessionName), agentType.supportsResume else { return }
        guard let resumeSessionID = threadManager.conversationID(for: thread.id, sessionName: sessionName)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !resumeSessionID.isEmpty else {
            BannerManager.shared.show(
                message: "This tab does not have a resumable agent session yet.",
                style: .warning
            )
            return
        }

        addTab(
            using: agentType,
            useAgentCommand: true,
            resumeSessionID: resumeSessionID,
            customTitle: thread.displayName(for: sessionName, at: index)
        )
    }

    func exportTabContext(at index: Int) {
        guard index < tabSlots.count, case .terminal(let sessionName) = tabSlots[index] else { return }
        let sourceAgent = threadManager.agentType(for: thread, sessionName: sessionName)
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"

        Task {
            guard let rawContent = await TmuxService.shared.captureFullPane(sessionName: sessionName) else {
                await MainActor.run {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextCaptureTerminalFailed), style: .error)
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
                panel.title = String(localized: .NotificationStrings.contextExportPanelTitle)

                let response = panel.runModal()
                guard response == .OK, let url = panel.url else { return }

                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextExported(url.lastPathComponent)), style: .info)
                } catch {
                    BannerManager.shared.show(message: String(localized: .NotificationStrings.contextExportFailed(error.localizedDescription)), style: .error)
                }
            }
        }
    }

}

// MARK: - Add Tab Context Menu

extension ThreadDetailViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === addTabButton.menu else { return }
        menu.removeAllItems()
        let settings = PersistenceService.shared.loadSettings()
        AgentMenuBuilder.populate(
            menu: menu,
            menuTitle: "New Tab",
            defaultAgentType: threadManager.effectiveAgentType(for: thread.projectId),
            activeAgents: settings.availableActiveAgents,
            target: self,
            action: #selector(addTabContextMenuItemSelected(_:))
        )
    }

    @objc private func addTabContextMenuItemSelected(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender) else { return }
        switch selection.mode {
        case .terminal:
            addTab(using: nil, useAgentCommand: false)
        case .agent(let agentType):
            let modelId = AgentLastSelectionStore.lastModel(for: agentType)
            let reasoning = AgentLastSelectionStore.lastReasoning(for: agentType, modelId: modelId)
            addTab(using: agentType, useAgentCommand: true, modelId: modelId, reasoningLevel: reasoning)
        case .projectDefault:
            let resolvedAgent = threadManager.effectiveAgentType(for: thread.projectId)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            addTab(using: nil, useAgentCommand: true, modelId: modelId, reasoningLevel: reasoning)
        case .web:
            let blankURL = URL(string: "about:blank")!
            openWebTab(url: blankURL, identifier: "web:\(UUID().uuidString)", title: "Web", iconType: .web)
        }
    }

}
