import Cocoa

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
        guard let section = item as? SidebarSection else { return [] }

        // Read the dragged thread's pin status
        guard let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
              let uuidString = pasteboardItem.string(forType: .string),
              let threadId = UUID(uuidString: uuidString),
              let thread = threadManager.threads.first(where: { $0.id == threadId }) else {
            return []
        }

        // Drop "on" section header → cross-section move (always allowed)
        if index == NSOutlineViewDropOnItemIndex {
            return .move
        }

        // Drop at specific index → reorder within section
        // Enforce pinned/unpinned boundary
        let pinnedCount = section.threads.filter(\.isPinned).count
        if thread.isPinned {
            // Pinned threads can only be placed within 0..<pinnedCount (or at pinnedCount to be last pinned)
            guard index <= pinnedCount else { return [] }
        } else {
            // Unpinned threads can only be placed at pinnedCount...count
            guard index >= pinnedCount else { return [] }
        }

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

        if index == NSOutlineViewDropOnItemIndex {
            // Cross-section move (drop on section header)
            threadManager.moveThread(thread, toSection: section.sectionId)
            reloadData()
            return true
        }

        // Reorder within section at specific index
        let isCrossSection = thread.sectionId != section.sectionId
        if isCrossSection {
            // Move to the new section first (this sets displayOrder to bottom)
            threadManager.moveThread(thread, toSection: section.sectionId)
        }

        // Calculate group-relative index for the reorder
        let pinnedCount = section.threads.filter(\.isPinned).count
        let groupIndex = thread.isPinned ? index : index - pinnedCount
        threadManager.reorderThread(threadId, toIndex: groupIndex, inSection: section.sectionId)
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
        if let thread = item as? MagentThread {
            if thread.isMain {
                return 26
            }
            let hasDescription = !(thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasDescription ? 46 : 26
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
            cell.imageView?.image = colorDotImage(color: section.color, size: 8)
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

                cell.configureAsMain(
                    isUnreadCompletion: thread.hasUnreadAgentCompletion,
                    isBusy: thread.hasAgentBusy,
                    isWaitingForInput: thread.hasWaitingForInput,
                    isDirty: thread.isDirty,
                    isBlockedByRateLimit: thread.isBlockedByRateLimit,
                    rateLimitTooltip: thread.rateLimitLiftDescription.map { "Rate limit reached. \($0)" }
                )
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

        // Refresh branch mismatch view for currently selected thread
        let row = outlineView.selectedRow
        if row >= 0, let selected = outlineView.item(atRow: row) as? MagentThread {
            refreshBranchMismatchView(for: selected)
        }
    }
}
