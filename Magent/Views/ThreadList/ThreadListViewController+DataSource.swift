import Cocoa
import MagentCore

// MARK: - NSOutlineViewDataSource

extension ThreadListViewController: NSOutlineViewDataSource {

    private func draggedThread(from info: NSDraggingInfo) -> MagentThread? {
        guard let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
              let uuidString = pasteboardItem.string(forType: .string),
              let threadId = UUID(uuidString: uuidString) else {
            return nil
        }
        return threadManager.threads.first(where: { $0.id == threadId })
    }

    private func flatRegularThreads(in project: SidebarProject) -> [MagentThread] {
        project.children.compactMap { child in
            guard let thread = child as? MagentThread, !thread.isMain else { return nil }
            return thread
        }
    }

    private func flatInsertionIndex(
        in project: SidebarProject,
        childIndex: Int,
        group: ThreadSidebarListState,
        excluding threadId: UUID
    ) -> Int {
        let priorChildren = project.children.prefix(max(0, childIndex))
        return priorChildren.reduce(into: 0) { count, child in
            guard let thread = child as? MagentThread,
                  !thread.isMain,
                  thread.id != threadId,
                  thread.sidebarListState == group else { return }
            count += 1
        }
    }

    private func flatRegularInsertionIndex(
        in project: SidebarProject,
        childIndex: Int,
        excluding threadId: UUID
    ) -> Int {
        let priorChildren = project.children.prefix(max(0, childIndex))
        return priorChildren.reduce(into: 0) { count, child in
            guard let thread = child as? MagentThread,
                  !thread.isMain,
                  thread.id != threadId else { return }
            count += 1
        }
    }

    private func threadGroupCounts(in section: SidebarSection) -> [ThreadSidebarListState: Int] {
        Dictionary(
            uniqueKeysWithValues: ThreadSidebarListState.allCases.map { group in
                (group, section.threads.filter { $0.sidebarListState == group }.count)
            }
        )
    }

    private func validDropIndex(
        _ index: Int,
        for group: ThreadSidebarListState,
        in counts: [ThreadSidebarListState: Int]
    ) -> Bool {
        let pinnedCount = counts[.pinned] ?? 0
        let visibleCount = counts[.visible] ?? 0

        switch group {
        case .pinned:
            return index <= pinnedCount
        case .visible:
            return index >= pinnedCount && index <= pinnedCount + visibleCount
        case .hidden:
            return index >= pinnedCount + visibleCount
        }
    }

    private func groupRelativeDropIndex(
        _ index: Int,
        for group: ThreadSidebarListState,
        in counts: [ThreadSidebarListState: Int]
    ) -> Int {
        let pinnedCount = counts[.pinned] ?? 0
        let visibleCount = counts[.visible] ?? 0

        switch group {
        case .pinned:
            return index
        case .visible:
            return index - pinnedCount
        case .hidden:
            return index - pinnedCount - visibleCount
        }
    }

    private func validateFlatProjectDrop(
        for thread: MagentThread,
        in project: SidebarProject,
        childIndex index: Int
    ) -> NSDragOperation {
        guard thread.projectId == project.projectId,
              index != NSOutlineViewDropOnItemIndex else {
            return []
        }

        let regularThreads = flatRegularThreads(in: project)
        let counts = Dictionary(
            uniqueKeysWithValues: ThreadSidebarListState.allCases.map { group in
                (
                    group,
                    regularThreads.filter {
                        $0.sidebarListState == group && $0.id != thread.id
                    }.count
                )
            }
        )
        let flatIndex = flatRegularInsertionIndex(
            in: project,
            childIndex: index,
            excluding: thread.id
        )

        guard validDropIndex(flatIndex, for: thread.sidebarListState, in: counts) else { return [] }
        return .move
    }

    private func acceptFlatProjectDrop(
        for thread: MagentThread,
        in project: SidebarProject,
        childIndex index: Int
    ) -> Bool {
        guard thread.projectId == project.projectId,
              index != NSOutlineViewDropOnItemIndex else {
            return false
        }

        let group = thread.sidebarListState
        let visibleGroup = flatRegularThreads(in: project)
            .filter { $0.sidebarListState == group && $0.id != thread.id }
        let insertionIndex = flatInsertionIndex(
            in: project,
            childIndex: index,
            group: group,
            excluding: thread.id
        )
        let clampedInsertionIndex = max(0, min(insertionIndex, visibleGroup.count))
        threadManager.reorderThreadInVisibleProjectList(thread.id, toIndex: clampedInsertionIndex)
        reloadData()
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sidebarRootItems.count }
        if let project = item as? SidebarProject { return project.children.count }
        if let section = item as? SidebarSection {
            return isSectionCollapsed(section) ? 0 : section.threads.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sidebarRootItems[index] }
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
        guard let thread = draggedThread(from: info) else {
            return []
        }

        if let project = item as? SidebarProject {
            let settings = persistence.loadSettings()
            guard !settings.shouldUseThreadSections(for: project.projectId) else { return [] }
            return validateFlatProjectDrop(for: thread, in: project, childIndex: index)
        }

        guard let section = item as? SidebarSection else { return [] }

        // Drop "on" section header → cross-section move (always allowed)
        if index == NSOutlineViewDropOnItemIndex {
            return .move
        }

        // Drop at specific index → reorder within section while preserving the
        // pinned / visible / hidden group boundaries.
        let counts = threadGroupCounts(in: section)
        guard validDropIndex(index, for: thread.sidebarListState, in: counts) else { return [] }

        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let thread = draggedThread(from: info) else {
            return false
        }

        if let project = item as? SidebarProject {
            let settings = persistence.loadSettings()
            guard !settings.shouldUseThreadSections(for: project.projectId) else { return false }
            return acceptFlatProjectDrop(for: thread, in: project, childIndex: index)
        }

        guard let section = item as? SidebarSection else { return false }

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

        // Calculate group-relative index for the reorder.
        let counts = threadGroupCounts(in: section)
        let groupIndex = groupRelativeDropIndex(index, for: thread.sidebarListState, in: counts)
        threadManager.reorderThread(thread.id, toIndex: groupIndex, inSection: section.sectionId)
        reloadData()
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems items: [Any]
    ) {
        (outlineView as? SidebarOutlineView)?.noteLocalDragWillBegin()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        (outlineView as? SidebarOutlineView)?.noteLocalDragDidEnd()
    }
}

// MARK: - NSOutlineViewDelegate

extension ThreadListViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is SidebarSpacer {
            return SidebarSpacerRowView()
        }
        if item is SidebarProjectMainSpacer {
            return SidebarSpacerRowView()
        }
        if item is SidebarProject {
            let rowView = ProjectHeaderRowView()
            return rowView
        }

        let rowView = AlwaysEmphasizedRowView()
        if let thread = item as? MagentThread {
            rowView.showsCompletionHighlight = thread.hasUnreadAgentCompletion
            rowView.showsSubtleBottomSeparator = false
            rowView.showsBusyShimmer = thread.hasAgentBusy
        } else {
            rowView.showsCompletionHighlight = false
            rowView.showsSubtleBottomSeparator = false
            rowView.showsBusyShimmer = false
        }
        return rowView
    }

    private enum ProjectHeaderHitArea {
        case name
        case disclosure
        case add
        case other
    }

    enum SectionHeaderHitArea {
        case name
        case disclosure
        case other
    }

    private func threadLeadingOffset(for thread: MagentThread, in outlineView: NSOutlineView) -> CGFloat {
        if outlineView.parent(forItem: thread) is SidebarSection {
            return Self.sidebarRowLeadingInset - Self.outlineIndentationPerLevel
        }
        if outlineView.parent(forItem: thread) is SidebarProject {
            return Self.sidebarRowLeadingInset - Self.outlineIndentationPerLevel
        }
        return Self.sidebarRowLeadingInset
    }

    private func projectHeaderHitArea(_ project: SidebarProject) -> ProjectHeaderHitArea {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp else { return .other }

        let pointInOutline = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: pointInOutline)
        guard row >= 0,
              let rowProject = outlineView.item(atRow: row) as? SidebarProject,
              rowProject.projectId == project.projectId,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return .other
        }

        let pointInCell = cell.convert(pointInOutline, from: outlineView)
        if let textField = cell.textField,
           textField.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .name
        }
        if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.projectDisclosureButtonIdentifier }),
           disclosureButton.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .disclosure
        }
        if let addButton = cell.subviews.first(where: { $0.identifier == Self.projectAddButtonIdentifier }),
           addButton.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .add
        }
        return .other
    }

    func sectionHeaderHitArea(_ section: SidebarSection) -> SectionHeaderHitArea {
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .leftMouseUp else { return .other }

        let pointInOutline = outlineView.convert(event.locationInWindow, from: nil)
        let row = outlineView.row(at: pointInOutline)
        guard row >= 0,
              let rowSection = outlineView.item(atRow: row) as? SidebarSection,
              rowSection.projectId == section.projectId,
              rowSection.sectionId == section.sectionId,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return .other
        }

        let pointInCell = cell.convert(pointInOutline, from: outlineView)
        if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }),
           disclosureButton.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .disclosure
        }
        if let nameStack = cell.subviews.first(where: { $0.identifier == Self.sectionNameStackIdentifier }),
           nameStack.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .name
        }
        if let textField = cell.textField,
           textField.frame.insetBy(dx: -2, dy: -2).contains(pointInCell) {
            return .name
        }
        return .other
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is SidebarSpacer {
            return Self.projectHeaderInterProjectGap
        }
        if item is SidebarProjectMainSpacer {
            return Self.projectHeaderToMainRowGap
        }
        if item is SidebarProject {
            return Self.projectHeaderRowHeight
        }
        if item is SidebarSection {
            return 28
        }
        if item is MagentThread {
            return ThreadCell.uniformSidebarRowHeight(
                maxDescriptionLines: currentSettings.sidebarDescriptionLineLimit
            )
        }
        return 26
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if allowsProgrammaticOutlineDisclosureChanges {
            return true
        }
        return (outlineView as? SidebarOutlineView)?.isDragInteractionActive != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if allowsProgrammaticOutlineDisclosureChanges {
            return true
        }
        return (outlineView as? SidebarOutlineView)?.isDragInteractionActive != true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if (outlineView as? SidebarOutlineView)?.isDragInteractionActive == true {
            return false
        }
        if item is SidebarSpacer {
            return false
        }
        if item is SidebarProjectMainSpacer {
            return false
        }
        if let project = item as? SidebarProject {
            if suppressNextProjectRowToggle {
                return false
            }

            switch projectHeaderHitArea(project) {
            case .name:
                setProjectCollapsed(project, isCollapsed: !isProjectCollapsed(project))
                reloadData()
            case .add, .disclosure, .other:
                break
            }
            return false
        }

        if let section = item as? SidebarSection {
            if suppressNextSectionRowToggle {
                return false
            }

            switch sectionHeaderHitArea(section) {
            case .disclosure:
                break
            case .name:
                guard !isRenamingSection(section) else { return false }
                if NSApp.currentEvent?.clickCount == 2 {
                    cancelPendingSectionNameToggle(for: section)
                } else if !section.threads.isEmpty {
                    scheduleSectionNameToggle(for: section)
                }
            case .other:
                guard !section.threads.isEmpty else { return false }
                toggleSection(section, animatedDisclosureButton: sectionDisclosureButton(for: section))
            }
            return false
        }
        return item is MagentThread
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is SidebarSpacer {
            let identifier = NSUserInterfaceItemIdentifier("ProjectSpacerCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarSpacerCellView
                ?? {
                    let c = SidebarSpacerCellView()
                    c.identifier = identifier
                    return c
                }()
            return cell
        }
        if item is SidebarProjectMainSpacer {
            let identifier = NSUserInterfaceItemIdentifier("ProjectMainSpacerCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? {
                    let c = NSTableCellView()
                    c.identifier = identifier
                    return c
                }()
            return cell
        }

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

                    let addButton = NSButton()
                    addButton.identifier = Self.projectAddButtonIdentifier
                    addButton.translatesAutoresizingMaskIntoConstraints = false
                    addButton.isBordered = false
                    addButton.imagePosition = .imageOnly
                    addButton.focusRingType = .none
                    addButton.setButtonType(.momentaryChange)
                    addButton.sendAction(on: [.leftMouseUp])
                    addButton.target = self
                    addButton.action = #selector(addThreadForProjectTapped(_:))
                    c.addSubview(addButton)

                    tf.setContentCompressionResistancePriority(.required, for: .horizontal)

                    NSLayoutConstraint.activate([
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor, constant: -1),
                        tf.leadingAnchor.constraint(
                            equalTo: c.leadingAnchor,
                            constant: Self.projectHeaderTitleLeadingInset
                        ),
                        disclosureButton.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 0),
                        disclosureButton.centerYAnchor.constraint(equalTo: tf.centerYAnchor, constant: 1),
                        disclosureButton.widthAnchor.constraint(equalToConstant: Self.projectHeaderActionButtonSize),
                        disclosureButton.heightAnchor.constraint(equalToConstant: Self.projectHeaderActionButtonSize),
                        iv.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 6),
                        iv.centerYAnchor.constraint(equalTo: tf.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 10),
                        iv.heightAnchor.constraint(equalToConstant: 10),
                        iv.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -6),
                        addButton.centerYAnchor.constraint(equalTo: tf.centerYAnchor),
                        addButton.widthAnchor.constraint(equalToConstant: Self.projectHeaderActionButtonSize),
                        addButton.heightAnchor.constraint(equalToConstant: Self.projectHeaderActionButtonSize),
                        addButton.trailingAnchor.constraint(
                            equalTo: c.trailingAnchor,
                            constant: -Self.projectAddButtonTrailingInset
                        ),
                    ])
                    return c
                }()

            cell.textField?.font = NSFont(name: "Noteworthy-Bold", size: 16)
                ?? NSFont.systemFont(ofSize: 16, weight: .semibold)
            cell.textField?.stringValue = project.name
            cell.textField?.invalidateIntrinsicContentSize()
            cell.textField?.textColor = .labelColor
            if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.projectDisclosureButtonIdentifier }) as? NSButton {
                let hasChildren = !project.children.isEmpty
                disclosureButton.objectValue = project.projectId.uuidString
                updateProjectDisclosureButton(disclosureButton, isExpanded: !isProjectCollapsed(project))
                disclosureButton.isHidden = !hasChildren
                disclosureButton.isEnabled = hasChildren
            }
            if let addButton = cell.subviews.first(where: { $0.identifier == Self.projectAddButtonIdentifier }) as? NSButton {
                let plusImage = NSImage(
                    systemSymbolName: "plus",
                    accessibilityDescription: "Add Thread to \(project.name)"
                )?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
                addButton.image = plusImage ?? NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Thread")
                addButton.contentTintColor = .controlAccentColor
                addButton.objectValue = project.projectId.uuidString
                addButton.toolTip = "Add thread to \(project.name). Option-click to use project default (or Terminal if no agent is active)."
                addButton.isEnabled = !isCreatingThread
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
                    c.textField = tf
                    tf.lineBreakMode = .byTruncatingTail
                    tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                    let badgeContainer = NSView()
                    badgeContainer.identifier = Self.sectionCountBadgeContainerIdentifier
                    badgeContainer.translatesAutoresizingMaskIntoConstraints = false
                    badgeContainer.wantsLayer = true
                    badgeContainer.layer?.cornerRadius = 8
                    badgeContainer.layer?.masksToBounds = true
                    c.addSubview(badgeContainer)

                    let badgeLabel = NSTextField(labelWithString: "")
                    badgeLabel.identifier = Self.sectionCountBadgeLabelIdentifier
                    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
                    badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
                    badgeLabel.alignment = .center
                    badgeLabel.lineBreakMode = .byClipping
                    badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                    badgeContainer.addSubview(badgeLabel)

                    let nameStack = NSStackView(views: [tf, badgeContainer])
                    nameStack.identifier = Self.sectionNameStackIdentifier
                    nameStack.translatesAutoresizingMaskIntoConstraints = false
                    nameStack.orientation = .horizontal
                    nameStack.alignment = .centerY
                    nameStack.spacing = 6
                    nameStack.detachesHiddenViews = true
                    c.addSubview(nameStack)

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

                    let editor = NSTextField(string: "")
                    editor.identifier = Self.sectionInlineRenameFieldIdentifier
                    editor.translatesAutoresizingMaskIntoConstraints = false
                    editor.isHidden = true
                    editor.focusRingType = .none
                    editor.font = .systemFont(ofSize: 12, weight: .medium)
                    editor.delegate = self
                    c.addSubview(editor)

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(
                            equalTo: c.leadingAnchor,
                            constant: Self.sidebarRowLeadingInset - Self.outlineIndentationPerLevel
                        ),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 8),
                        iv.heightAnchor.constraint(equalToConstant: 8),
                        nameStack.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                        nameStack.trailingAnchor.constraint(lessThanOrEqualTo: disclosureButton.leadingAnchor, constant: -6),
                        nameStack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        badgeContainer.heightAnchor.constraint(equalToConstant: 16),
                        badgeContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
                        badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 5),
                        badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -5),
                        badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
                        disclosureButton.trailingAnchor.constraint(
                            equalTo: c.trailingAnchor,
                            constant: -Self.projectDisclosureTrailingInset
                        ),
                        disclosureButton.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        disclosureButton.widthAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                        disclosureButton.heightAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
                        editor.leadingAnchor.constraint(equalTo: nameStack.leadingAnchor, constant: -2),
                        editor.trailingAnchor.constraint(equalTo: disclosureButton.leadingAnchor, constant: -6),
                        editor.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])
                    return c
                }()

            cell.textField?.stringValue = section.name.uppercased()
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = NSColor(resource: .textSecondary)
            cell.imageView?.image = colorDotImage(color: section.color, size: 8)
            let threadCount = section.threads.count
            if let badgeContainer = cell.subviews.first(where: { $0.identifier == Self.sectionCountBadgeContainerIdentifier }) {
                badgeContainer.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                badgeContainer.isHidden = threadCount == 0
                badgeContainer.toolTip = threadCount > 0 ? "\(threadCount) threads in \(section.name)" : nil
            }
            if let badgeLabel = cell
                .subviews
                .first(where: { $0.identifier == Self.sectionCountBadgeContainerIdentifier })?
                .subviews
                .first(where: { $0.identifier == Self.sectionCountBadgeLabelIdentifier }) as? NSTextField {
                badgeLabel.stringValue = "\(threadCount)"
                badgeLabel.textColor = NSColor.controlAccentColor
            }
            if let disclosureButton = cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton {
                disclosureButton.objectValue = sectionCollapseStorageKey(section)
                updateSectionDisclosureButton(disclosureButton, isExpanded: !isSectionCollapsed(section))
                let hasThreads = !section.threads.isEmpty
                disclosureButton.isHidden = !hasThreads
                disclosureButton.isEnabled = hasThreads
            }
            if let nameStack = cell.subviews.first(where: { $0.identifier == Self.sectionNameStackIdentifier }) {
                let isRenaming = isRenamingSection(section)
                nameStack.isHidden = isRenaming
                cell.imageView?.isHidden = isRenaming
            }
            if let editor = cell.subviews.first(where: { $0.identifier == Self.sectionInlineRenameFieldIdentifier }) as? NSTextField {
                let isRenaming = isRenamingSection(section)
                editor.isHidden = !isRenaming
                editor.stringValue = isRenaming ? activeSectionRename?.originalName ?? section.name : section.name
                editor.placeholderString = "Section name"
                editor.toolTip = "Press Return or click anywhere to save."
            }
            return cell
        }

        // Level 1 or 2: Thread item
        if let thread = item as? MagentThread {
            if thread.isMain {
                let currentBranch = {
                    let actualBranch = thread.actualBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !actualBranch.isEmpty, actualBranch != "HEAD" {
                        return actualBranch
                    }
                    return thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
                }()
                let identifier = NSUserInterfaceItemIdentifier("MainThreadCell")
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

                cell.configureAsMain(
                    isUnreadCompletion: thread.hasUnreadAgentCompletion,
                    isBusy: thread.hasAgentBusy,
                    isWaitingForInput: thread.hasWaitingForInput,
                    isDirty: thread.isDirty,
                    isBlockedByRateLimit: thread.isBlockedByRateLimit,
                    isRateLimitExpiredAndResumable: thread.isRateLimitExpiredAndResumable,
                    rateLimitTooltip: thread.rateLimitLiftDescription.map { "Rate limit reached. \($0)" },
                    currentBranch: currentBranch,
                    leadingOffset: Self.sidebarRowLeadingInset - Self.outlineIndentationPerLevel + 14
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

            let settings = currentSettings
            let shouldUseSections = settings.shouldUseThreadSections(for: thread.projectId)
            let sectionColor: NSColor?
            if shouldUseSections {
                let projectSections = settings.sections(for: thread.projectId)
                let knownSectionIds = Set(projectSections.map(\.id))
                let defaultSectionId = settings.defaultSection(for: thread.projectId)?.id
                let resolvedSectionId = thread.resolvedSectionId(
                    knownSectionIds: knownSectionIds,
                    fallback: defaultSectionId
                )
                sectionColor = projectSections.first(where: { $0.id == resolvedSectionId })?.color
            } else {
                sectionColor = nil
            }
            cell.configure(
                with: thread,
                sectionColor: sectionColor,
                leadingOffset: threadLeadingOffset(for: thread, in: outlineView),
                maxDescriptionLines: settings.sidebarDescriptionLineLimit
            )
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
        // Only do a full reloadData() when the sidebar structure actually changed (threads
        // added/removed/reordered/re-sectioned). For metadata-only updates (busy state,
        // rate limits, dirty flag, PR info, etc.), update cells in-place — this avoids
        // the scroll-position flash that reloadData() + expand/collapse causes.
        if sidebarNeedsStructuralReload(for: threads) {
            reloadData()
        } else {
            updateSidebarInPlace(with: threads)
        }

        // If nothing is selected after reload (e.g. first launch), pick the first thread
        if outlineView.selectedRow < 0 {
            autoSelectFirst()
        }

        // Refresh branch mismatch view for currently selected thread
        let row = outlineView.selectedRow
        if row >= 0, let selected = outlineView.item(atRow: row) as? MagentThread {
            refreshBranchMismatchView(for: selected)
            refreshDiffPanelContext(for: selected)
        }
    }

    // MARK: - Structural change detection

    /// Thread properties that determine position/visibility in the sidebar.
    /// A change in any of these requires a full reloadData(); anything else can be
    /// updated in-place via updateSidebarInPlace(with:).
    private struct SidebarThreadStructuralKey: Equatable {
        let id: UUID
        let sectionId: UUID?
        let displayOrder: Int
        let isPinned: Bool
        let isSidebarHidden: Bool
        let isArchived: Bool
        let lastAgentCompletionAt: Date?

        init(_ thread: MagentThread) {
            id = thread.id
            sectionId = thread.sectionId
            displayOrder = thread.displayOrder
            isPinned = thread.isPinned
            isSidebarHidden = thread.isSidebarHidden
            isArchived = thread.isArchived
            lastAgentCompletionAt = thread.lastAgentCompletionAt
        }
    }

    private func sidebarNeedsStructuralReload(for newThreads: [MagentThread]) -> Bool {
        guard !sidebarProjects.isEmpty else { return true }

        var currentThreads: [MagentThread] = []
        for project in sidebarProjects {
            for child in project.children {
                if let t = child as? MagentThread {
                    currentThreads.append(t)
                } else if let s = child as? SidebarSection {
                    currentThreads.append(contentsOf: s.threads)
                }
            }
        }

        let sortById: (SidebarThreadStructuralKey, SidebarThreadStructuralKey) -> Bool = {
            $0.id.uuidString < $1.id.uuidString
        }
        let currentKeys = currentThreads.map { SidebarThreadStructuralKey($0) }.sorted(by: sortById)
        let newKeys = newThreads.map { SidebarThreadStructuralKey($0) }.sorted(by: sortById)
        return currentKeys != newKeys
    }

    /// Updates thread cell content in-place without a full reloadData().
    /// Since SidebarProject and SidebarSection are class objects, we can mutate their
    /// thread arrays in-place, then call reloadItem(_:reloadChildren:) to refresh cell
    /// views — which never alters scroll position or expansion state.
    private func updateSidebarInPlace(with updatedThreads: [MagentThread]) {
        let threadById = Dictionary(uniqueKeysWithValues: updatedThreads.map { ($0.id, $0) })

        for project in sidebarProjects {
            for i in project.children.indices {
                if let thread = project.children[i] as? MagentThread,
                   let updated = threadById[thread.id] {
                    project.children[i] = updated
                } else if let section = project.children[i] as? SidebarSection {
                    for j in section.threads.indices {
                        if let updated = threadById[section.threads[j].id] {
                            section.threads[j] = updated
                        }
                    }
                }
            }
            outlineView.reloadItem(project, reloadChildren: true)
        }
    }
}
