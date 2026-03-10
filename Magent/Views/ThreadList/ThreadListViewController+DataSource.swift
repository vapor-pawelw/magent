import Cocoa
import MagentCore

// MARK: - NSOutlineViewDataSource

extension ThreadListViewController: NSOutlineViewDataSource {

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

    private func descriptionLineCount(
        _ description: String,
        for thread: MagentThread,
        in outlineView: NSOutlineView
    ) -> Int {
        let availableWidth = availableDescriptionWidth(for: thread, in: outlineView)
        guard availableWidth > 0 else { return 1 }

        let font = stableDescriptionMeasurementFont()

        let textStorage = NSTextStorage(
            string: description,
            attributes: [.font: font]
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: availableWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 2
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }
        return max(1, lineCount)
    }

    private func compactTextRowHeightIncrement() -> CGFloat {
        let font = stableDescriptionMeasurementFont()
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func stableDescriptionMeasurementFont() -> NSFont {
        // Selection can clear unread completion, which changes the rendered font.
        // Measure with the widest sidebar description font so row heights stay stable.
        .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    }

    private func descriptionTextWidth(for thread: MagentThread, in outlineView: NSOutlineView) -> CGFloat {
        let baseWidth: CGFloat
        let row = outlineView.row(forItem: thread)
        if let outlineColumn = outlineView.outlineTableColumn {
            let columnIndex = outlineView.tableColumns.firstIndex(of: outlineColumn) ?? -1
            if row >= 0, columnIndex >= 0 {
                baseWidth = outlineView.frameOfCell(atColumn: columnIndex, row: row).width
            } else {
                baseWidth = outlineColumn.width
            }
        } else {
            baseWidth = outlineView.bounds.width
        }
        guard baseWidth > 0 else { return 0 }
        let leadingOffsetCompensation = -min(0, threadLeadingOffset(for: thread, in: outlineView))
        let leadingContentWidth: CGFloat = 16 + 6 // thread icon + icon/text spacing
        let trailingInset = ThreadListViewController.projectDisclosureTrailingInset
            + (ThreadListViewController.disclosureButtonSize / 2)
            - 5 // completion indicator radius used by ThreadCell.trailingAlignmentInset
            + 6 // gap between leading and trailing stacks
        let trailingMarkerWidth = threadTrailingMarkerWidth(for: thread)
        return max(0, baseWidth + leadingOffsetCompensation - leadingContentWidth - trailingInset - trailingMarkerWidth)
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

    private func threadTrailingMarkerWidth(for thread: MagentThread) -> CGFloat {
        var markerWidths: [CGFloat] = []

        if thread.jiraTicketKey != nil {
            markerWidths.append(10)
        }
        if thread.showArchiveSuggestion {
            markerWidths.append(12)
        }
        // Reserve width for the status marker regardless of current status so
        // selecting/switching threads does not reflow descriptions and row heights.
        markerWidths.append(14)

        guard !markerWidths.isEmpty else { return 0 }
        let widthsTotal = markerWidths.reduce(0, +)
        let spacingTotal = CGFloat(max(0, markerWidths.count - 1) * 4)
        return widthsTotal + spacingTotal
    }

    private func availableDescriptionWidth(for thread: MagentThread, in outlineView: NSOutlineView) -> CGFloat {
        let measuredWidth = descriptionTextWidth(for: thread, in: outlineView)
        return max(
            0,
            measuredWidth
        )
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
        if let thread = item as? MagentThread {
            if thread.isMain {
                return 46
            }
            let trimmedDescription = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDescription = !(trimmedDescription?.isEmpty ?? true)
            let worktreeName = (thread.worktreePath as NSString).lastPathComponent
            let branchName = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBranchName = branchName.isEmpty ? thread.name : branchName
            let hasBranchWorktreeMismatch = worktreeName != resolvedBranchName
            if hasDescription, let description = trimmedDescription {
                let baseTwoRowHeight: CGFloat = 46
                let descriptionLines = descriptionLineCount(description, for: thread, in: outlineView)
                if descriptionLines > 1 {
                    return baseTwoRowHeight + compactTextRowHeightIncrement()
                }
                return baseTwoRowHeight
            }
            return hasBranchWorktreeMismatch ? 46 : 26
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
            guard !section.threads.isEmpty else { return false }
            toggleSection(section, animatedDisclosureButton: sectionDisclosureButton(for: section))
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

            let settings = persistence.loadSettings()
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
                preferredTextWidth: availableDescriptionWidth(for: thread, in: outlineView)
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
            refreshDiffPanelContext(for: selected)
        }
    }
}
