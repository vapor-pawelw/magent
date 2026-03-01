import Cocoa

extension ThreadListViewController {

    // MARK: - Context Menu

    private func buildContextMenu(for thread: MagentThread) -> NSMenu {
        let menu = NSMenu()

        // Main threads: no context menu
        if thread.isMain { return menu }

        // Pin/Unpin
        let pinTitle = thread.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleThreadPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: thread.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = thread.id
        menu.addItem(pinItem)

        // Move to... submenu
        let settings = persistence.loadSettings()
        let visibleSections = settings.visibleSections.filter { $0.id != thread.sectionId }

        let moveSubmenu = NSMenu()
        for section in visibleSections {
            let item = NSMenuItem(title: section.name, action: #selector(moveThreadToSection(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.colorDotImage(color: section.color, size: 8)
            item.representedObject = ["thread": thread, "sectionId": section.id] as [String: Any]
            moveSubmenu.addItem(item)
        }

        let moveItem = NSMenuItem(title: "Move to...", action: nil, keyEquivalent: "")
        moveItem.submenu = moveSubmenu
        moveItem.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        menu.addItem(moveItem)

        // Rename
        let renameItem = NSMenuItem(title: "Rename...", action: #selector(renameThread(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = thread
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        // Open in Finder
        let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openThreadInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        finderItem.representedObject = thread
        menu.addItem(finderItem)

        // Show Pull Request (only for projects with a recognized hosting provider)
        if projectsWithValidRemotes.contains(thread.projectId) {
            let prItem = NSMenuItem(title: "Show Pull Request", action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            prItem.representedObject = thread
            menu.addItem(prItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Archive
        let archiveItem = NSMenuItem(title: "Archive...", action: #selector(archiveThread(_:)), keyEquivalent: "")
        archiveItem.target = self
        archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        archiveItem.representedObject = thread
        menu.addItem(archiveItem)

        // Delete (destructive)
        let deleteItem = NSMenuItem(title: "Delete...", action: #selector(deleteThread(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteItem.representedObject = thread
        menu.addItem(deleteItem)

        return menu
    }

    private func buildProjectContextMenu(for project: SidebarProject) -> NSMenu {
        let menu = NSMenu()
        let pinTitle = project.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleProjectPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: project.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = project.projectId
        menu.addItem(pinItem)
        return menu
    }

    @objc private func toggleProjectPin(_ sender: NSMenuItem) {
        guard let projectId = sender.representedObject as? UUID else { return }
        var settings = persistence.loadSettings()
        guard let index = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }
        settings.projects[index].isPinned.toggle()
        try? persistence.saveSettings(settings)
        reloadData()
    }

    @objc private func toggleThreadPin(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        threadManager.toggleThreadPin(threadId: threadId)
    }

    @objc private func moveThreadToSection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let sectionId = info["sectionId"] as? UUID else { return }
        threadManager.moveThread(thread, toSection: sectionId)
        reloadData()
    }

    @objc private func renameThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Thread"
        alert.informativeText = "Enter new name for the thread"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = thread.name
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != thread.name else { return }

        Task {
            do {
                try await threadManager.renameThread(thread, to: newName)
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == thread.id }) {
                        self.delegate?.threadList(self, didRenameThread: updated)
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

    @objc private func openThreadInFinder(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let targetPath: String
        if thread.isMain {
            let settings = persistence.loadSettings()
            targetPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath ?? thread.worktreePath
        } else {
            targetPath = thread.worktreePath
        }

        let path = NSString(string: targetPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue else {
            let targetName = thread.isMain ? "project root" : "worktree"
            BannerManager.shared.show(message: "Could not open \(targetName) in Finder because the directory is missing.", style: .warning)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openThreadPullRequest(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

        Task {
            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            guard !remotes.isEmpty else {
                await MainActor.run {
                    BannerManager.shared.show(message: "No git remotes found", style: .warning)
                }
                return
            }

            let branch = thread.branchName
            let defaultBranch: String?
            if let projectDefaultBranch = project.defaultBranch {
                defaultBranch = projectDefaultBranch
            } else {
                defaultBranch = await GitService.shared.detectDefaultBranch(repoPath: project.repoPath)
            }

            await MainActor.run {
                // Find the best remote — prefer origin
                let remote: GitRemote
                if remotes.count == 1 {
                    remote = remotes[0]
                } else if let origin = remotes.first(where: { $0.name == "origin" }) {
                    remote = origin
                } else {
                    remote = remotes[0]
                }

                guard let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL else {
                    BannerManager.shared.show(message: "Could not construct URL for remote \(remote.name)", style: .warning)
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func archiveThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }
        triggerArchive(for: thread)
    }

    func triggerArchive(for thread: MagentThread) {
        let baseBranch = threadManager.resolveBaseBranch(for: thread)

        Task {
            let git = GitService.shared
            let clean = await git.isClean(worktreePath: thread.worktreePath)
            let merged = await git.isMergedInto(worktreePath: thread.worktreePath, baseBranch: baseBranch)

            await MainActor.run {
                if clean && merged {
                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(thread)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Archive Thread"
                    var reasons: [String] = []
                    if !clean { reasons.append("uncommitted changes") }
                    if !merged { reasons.append("commits not in \(baseBranch)") }
                    alert.informativeText = "The thread \"\(thread.name)\" has \(reasons.joined(separator: " and ")). Archiving will remove its worktree directory but keep the git branch \"\(thread.branchName)\"."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Archive")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }

                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(thread)
                    }
                }
            }
        }
    }

    @objc private func deleteThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Thread"
        alert.informativeText = "This will permanently delete the thread \"\(thread.name)\", including its worktree directory and git branch \"\(thread.branchName)\". This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performWithSpinner(message: "Deleting thread...", errorTitle: "Delete Failed") {
            try await self.threadManager.deleteThread(thread)
        }
    }

    func performWithSpinner(message: String, errorTitle: String, work: @escaping () async throws -> Void) {
        guard let window = view.window else { return }

        // Build a small sheet with a spinner and label
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
}

// MARK: - NSOutlineViewDataSource

extension ThreadListViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sidebarProjects.count }
        if let project = item as? SidebarProject { return project.children.count }
        if let section = item as? SidebarSection {
            return isSectionCollapsed(section) ? 0 : section.threads.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sidebarProjects[index] }
        if let project = item as? SidebarProject { return project.children[index] }
        if let section = item as? SidebarSection { return section.threads[index] }
        fatalError("Unexpected item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is SidebarProject { return true }
        if let section = item as? SidebarSection { return !section.threads.isEmpty }
        return false
    }

    // MARK: Drag & Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let thread = item as? MagentThread, !thread.isMain else { return nil }
        return thread.id.uuidString as NSString
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard item is SidebarSection else { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let section = item as? SidebarSection,
              let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
              let uuidString = pasteboardItem.string(forType: .string),
              let threadId = UUID(uuidString: uuidString),
              let thread = threadManager.threads.first(where: { $0.id == threadId }) else {
            return false
        }

        threadManager.moveThread(thread, toSection: section.sectionId)
        reloadData()
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension ThreadListViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = AlwaysEmphasizedRowView()
        if let thread = item as? MagentThread {
            rowView.showsCompletionHighlight = thread.hasUnreadAgentCompletion
        } else {
            rowView.showsCompletionHighlight = false
        }
        return rowView
    }

    private func shouldShowTopSeparator(for project: SidebarProject) -> Bool {
        guard sidebarProjects.count > 1 else { return false }
        guard let index = sidebarProjects.firstIndex(where: { $0.projectId == project.projectId }) else { return false }
        return index > 0
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let project = item as? SidebarProject {
            return shouldShowTopSeparator(for: project) ? 60 : 34
        }
        if item is SidebarSection {
            return 28
        }
        return 26
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let project = item as? SidebarProject {
            if suppressNextProjectRowToggle {
                return false
            }
            setProjectCollapsed(project, isCollapsed: !isProjectCollapsed(project))
            reloadData()
            return false
        }

        if let section = item as? SidebarSection {
            if suppressNextSectionRowToggle {
                return false
            }
            guard !section.threads.isEmpty else { return false }
            toggleSection(section, animatedDisclosureButton: sectionDisclosureButton(for: section))
            return false
        }
        return item is MagentThread
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        // Level 0: Project header
        if let project = item as? SidebarProject {
            let identifier = NSUserInterfaceItemIdentifier("ProjectCellV2")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? {
                    let c = NSTableCellView()
                    c.identifier = identifier

                    let iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(iv)
                    c.imageView = iv

                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(tf)
                    c.textField = tf

                    let disclosureButton = NSButton()
                    disclosureButton.identifier = Self.projectDisclosureButtonIdentifier
                    disclosureButton.translatesAutoresizingMaskIntoConstraints = false
                    disclosureButton.isBordered = false
                    disclosureButton.imagePosition = .imageOnly
                    disclosureButton.focusRingType = .none
                    disclosureButton.setButtonType(.momentaryChange)
                    disclosureButton.sendAction(on: [.leftMouseUp])
                    disclosureButton.target = self
                    disclosureButton.action = #selector(toggleProjectExpanded(_:))
                    c.addSubview(disclosureButton)

                    let separator = NSView()
                    separator.identifier = Self.projectSeparatorIdentifier
                    separator.translatesAutoresizingMaskIntoConstraints = false
                    separator.wantsLayer = true
                    c.addSubview(separator)

                    tf.setContentCompressionResistancePriority(.required, for: .horizontal)

                    NSLayoutConstraint.activate([
                        separator.topAnchor.constraint(equalTo: c.topAnchor, constant: 16),
                        separator.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: -Self.outlineIndentationPerLevel + 12),
                        separator.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                        separator.heightAnchor.constraint(equalToConstant: 1),
                        tf.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -8),
                        tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.sidebarHorizontalInset),
                        tf.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -6),
                        iv.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 6),
                        iv.centerYAnchor.constraint(equalTo: tf.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 10),
                        iv.heightAnchor.constraint(equalToConstant: 10),
                        disclosureButton.trailingAnchor.constraint(
                            equalTo: c.trailingAnchor,
                            constant: -Self.projectDisclosureTrailingInset
                        ),
                        disclosureButton.centerYAnchor.constraint(equalTo: tf.centerYAnchor),
                        disclosureButton.widthAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                        disclosureButton.heightAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                    ])
                    return c
                }()

            cell.textField?.font = NSFont(name: "Noteworthy-Bold", size: 16)
                ?? NSFont.systemFont(ofSize: 16, weight: .medium)
            cell.textField?.stringValue = project.name
            cell.textField?.invalidateIntrinsicContentSize()
            cell.textField?.textColor = NSColor(resource: .textSecondary)
            if let separator = cell.subviews.first(where: { $0.identifier == Self.projectSeparatorIdentifier }) {
                separator.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
                separator.isHidden = !shouldShowTopSeparator(for: project)
            }
            if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.projectDisclosureButtonIdentifier }) as? NSButton {
                let hasChildren = !project.children.isEmpty
                disclosureButton.objectValue = project.projectId.uuidString
                updateProjectDisclosureButton(disclosureButton, isExpanded: !isProjectCollapsed(project))
                disclosureButton.isHidden = !hasChildren
                disclosureButton.isEnabled = hasChildren
            }
            if project.isPinned {
                cell.imageView?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
                cell.imageView?.contentTintColor = NSColor(resource: .textSecondary)
                cell.imageView?.isHidden = false
            } else {
                cell.imageView?.image = nil
                cell.imageView?.isHidden = true
            }
            return cell
        }

        // Level 1: Section header
        if let section = item as? SidebarSection {
            let identifier = NSUserInterfaceItemIdentifier("SectionCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? {
                    let c = NSTableCellView()
                    c.identifier = identifier

                    let iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(iv)
                    c.imageView = iv

                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(tf)
                    c.textField = tf

                    let disclosureButton = NSButton()
                    disclosureButton.identifier = Self.sectionDisclosureButtonIdentifier
                    disclosureButton.translatesAutoresizingMaskIntoConstraints = false
                    disclosureButton.isBordered = false
                    disclosureButton.imagePosition = .imageOnly
                    disclosureButton.focusRingType = .none
                    disclosureButton.setButtonType(.momentaryChange)
                    disclosureButton.sendAction(on: [.leftMouseUp])
                    disclosureButton.target = self
                    disclosureButton.action = #selector(toggleSectionExpanded(_:))
                    c.addSubview(disclosureButton)

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.sidebarHorizontalInset),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 8),
                        iv.heightAnchor.constraint(equalToConstant: 8),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        disclosureButton.trailingAnchor.constraint(
                            equalTo: c.trailingAnchor,
                            constant: -Self.projectDisclosureTrailingInset
                        ),
                        disclosureButton.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        disclosureButton.widthAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                        disclosureButton.heightAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                    ])
                    return c
                }()

            cell.textField?.stringValue = section.name.uppercased()
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = NSColor(resource: .textSecondary)
            cell.imageView?.image = Self.colorDotImage(color: section.color, size: 8)
            if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton {
                disclosureButton.objectValue = sectionCollapseStorageKey(section)
                updateSectionDisclosureButton(disclosureButton, isExpanded: !isSectionCollapsed(section))
                let hasThreads = !section.threads.isEmpty
                disclosureButton.isHidden = !hasThreads
                disclosureButton.isEnabled = hasThreads
            }
            return cell
        }

        // Level 1 or 2: Thread item
        if let thread = item as? MagentThread {
            if thread.isMain {
                let identifier = NSUserInterfaceItemIdentifier("MainThreadCell")
                let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ThreadCell
                    ?? {
                        let c = ThreadCell()
                        c.identifier = identifier

                        let tf = NSTextField(labelWithString: "")
                        tf.translatesAutoresizingMaskIntoConstraints = false
                        c.addSubview(tf)
                        c.textField = tf

                        NSLayoutConstraint.activate([
                            tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.sidebarHorizontalInset),
                            tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -Self.sidebarHorizontalInset),
                            tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        ])

                        return c
                    }()

                cell.configureAsMain(isUnreadCompletion: thread.hasUnreadAgentCompletion, isBusy: thread.hasAgentBusy, isWaitingForInput: thread.hasWaitingForInput, isDirty: thread.isDirty)
                return cell
            }

            // Regular thread: icon on left, name on right
            let identifier = NSUserInterfaceItemIdentifier("ThreadCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? ThreadCell
                ?? {
                    let c = ThreadCell()
                    c.identifier = identifier

                    let iv = NSImageView()
                    iv.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(iv)
                    c.imageView = iv

                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(tf)
                    c.textField = tf

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: Self.sidebarHorizontalInset),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16),
                        iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -Self.sidebarHorizontalInset),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])

                    return c
                }()

            let settings = persistence.loadSettings()
            let sections = settings.threadSections
            let section = sections.first(where: { $0.id == thread.sectionId })
            cell.configure(with: thread, sectionColor: section?.color)
            cell.onArchive = { [weak self] in
                self?.triggerArchive(for: thread)
            }
            return cell
        }

        return nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let project = notification.userInfo?["NSObject"] as? SidebarProject else { return }
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        collapsed.remove(project.projectId.uuidString)
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let project = notification.userInfo?["NSObject"] as? SidebarProject else { return }
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        collapsed.insert(project.projectId.uuidString)
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let thread = outlineView.item(atRow: row) as? MagentThread else {
            diffPanelView?.clear()
            return
        }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(thread.projectId.uuidString, forKey: Self.lastOpenedProjectDefaultsKey)
        delegate?.threadList(self, didSelectThread: thread)
        refreshDiffPanel(for: thread)
    }
}

// MARK: - NSMenuDelegate

extension ThreadListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else { return }

        let clickedItem = outlineView.item(atRow: clickedRow)

        if let project = clickedItem as? SidebarProject {
            let contextMenu = buildProjectContextMenu(for: project)
            for item in contextMenu.items {
                contextMenu.removeItem(item)
                menu.addItem(item)
            }
            return
        }

        if let thread = clickedItem as? MagentThread {
            let contextMenu = buildContextMenu(for: thread)
            for item in contextMenu.items {
                contextMenu.removeItem(item)
                menu.addItem(item)
            }
        }
    }
}

// MARK: - ThreadManagerDelegate

extension ThreadListViewController: ThreadManagerDelegate {
    func threadManager(_ manager: ThreadManager, didCreateThread thread: MagentThread) {
        reloadData()
        let row = outlineView.row(forItem: thread)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func threadManager(_ manager: ThreadManager, didArchiveThread thread: MagentThread) {
        reloadData()
        delegate?.threadList(self, didArchiveThread: thread)
    }

    func threadManager(_ manager: ThreadManager, didDeleteThread thread: MagentThread) {
        reloadData()
        delegate?.threadList(self, didDeleteThread: thread)
    }

    func threadManager(_ manager: ThreadManager, didUpdateThreads threads: [MagentThread]) {
        // reloadData() preserves the current selection by thread ID
        reloadData()

        // If nothing is selected after reload (e.g. first launch), pick the first thread
        if outlineView.selectedRow < 0 {
            autoSelectFirst()
        }
    }
}
