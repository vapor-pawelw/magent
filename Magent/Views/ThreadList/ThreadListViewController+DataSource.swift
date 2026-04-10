import Cocoa
import MagentCore

extension NSPasteboard.PasteboardType {
    static let magentSectionId = NSPasteboard.PasteboardType("app.magent.section-id")
}

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

    /// Converts a raw NSOutlineView child index within a section (which accounts
    /// for inserted `SidebarGroupSeparator` items) to the logical thread-only index.
    private func adjustedDropIndex(_ rawIndex: Int, in section: SidebarSection) -> Int {
        let separatorsBefore = section.items.prefix(rawIndex).filter { $0 is SidebarGroupSeparator }.count
        return rawIndex - separatorsBefore
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
            return isSectionCollapsed(section) ? 0 : section.items.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sidebarRootItems[index] }
        if let project = item as? SidebarProject { return project.children[index] }
        if let section = item as? SidebarSection { return section.items[index] }
        fatalError("Unexpected item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is SidebarProject { return true }
        if let section = item as? SidebarSection { return !section.threads.isEmpty }
        return false
    }

    // MARK: Drag & Drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if let thread = item as? MagentThread, !thread.isMain {
            return thread.id.uuidString as NSString
        }
        if let section = item as? SidebarSection {
            let pbItem = NSPasteboardItem()
            pbItem.setString(section.sectionId.uuidString, forType: .magentSectionId)
            return pbItem
        }
        return nil
    }

    private func draggedSectionId(from info: NSDraggingInfo) -> UUID? {
        guard let pbItem = info.draggingPasteboard.pasteboardItems?.first,
              let str = pbItem.string(forType: .magentSectionId) else { return nil }
        return UUID(uuidString: str)
    }

    private func parentProject(of section: SidebarSection) -> SidebarProject? {
        sidebarRootItems.compactMap { $0 as? SidebarProject }.first { project in
            project.children.contains { ($0 as? SidebarSection)?.sectionId == section.sectionId }
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Section reordering
        if let sectionId = draggedSectionId(from: info) {
            // Redirect drop-on-section → drop-before-that-section in its project
            if let targetSection = item as? SidebarSection {
                if let project = parentProject(of: targetSection),
                   let sectionChildIdx = project.children.firstIndex(where: { ($0 as? SidebarSection)?.sectionId == targetSection.sectionId }) {
                    outlineView.setDropItem(project, dropChildIndex: sectionChildIdx)
                }
                return .move
            }
            guard let project = item as? SidebarProject,
                  index != NSOutlineViewDropOnItemIndex,
                  project.children.contains(where: { ($0 as? SidebarSection)?.sectionId == sectionId }) else {
                return []
            }
            let firstSectionIdx = project.children.firstIndex(where: { $0 is SidebarSection }) ?? project.children.count
            let sectionCount = project.children.filter { $0 is SidebarSection }.count
            guard index >= firstSectionIdx && index <= firstSectionIdx + sectionCount else { return [] }
            return .move
        }

        guard let thread = draggedThread(from: info) else {
            return []
        }

        if let project = item as? SidebarProject {
            let settings = persistence.loadSettings()
            guard !settings.shouldUseThreadSections(for: project.projectId) else { return [] }
            return validateFlatProjectDrop(for: thread, in: project, childIndex: index)
        }

        guard let section = item as? SidebarSection,
              section.projectId == thread.projectId else { return [] }

        // Drop "on" section header → cross-section move (always allowed)
        if index == NSOutlineViewDropOnItemIndex {
            return .move
        }

        // Drop at specific index → reorder within section while preserving the
        // pinned / visible / hidden group boundaries. Adjust for inserted separators.
        let counts = threadGroupCounts(in: section)
        let threadIndex = adjustedDropIndex(index, in: section)
        guard validDropIndex(threadIndex, for: thread.sidebarListState, in: counts) else { return [] }

        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        // Section reordering
        if let sectionId = draggedSectionId(from: info),
           let project = item as? SidebarProject {
            let sectionChildren = project.children.compactMap { $0 as? SidebarSection }
            guard let sourceSection = sectionChildren.first(where: { $0.sectionId == sectionId }) else { return false }

            let firstSectionIdx = project.children.firstIndex(where: { $0 is SidebarSection }) ?? 0
            let sourceChildIdx = project.children.firstIndex(where: { ($0 as? SidebarSection)?.sectionId == sectionId }) ?? firstSectionIdx
            let sourceSectionIdx = sourceChildIdx - firstSectionIdx
            let rawDest = index - firstSectionIdx
            let destSectionIdx = sourceChildIdx < index ? rawDest - 1 : rawDest

            var sections = sectionChildren
            sections.remove(at: sourceSectionIdx)
            sections.insert(sourceSection, at: max(0, min(destSectionIdx, sections.count)))

            var settings = persistence.loadSettings()
            guard let projectIndex = settings.projects.firstIndex(where: { $0.id == project.projectId }) else { return false }
            let isProjectOverride = settings.projects[projectIndex].threadSections != nil
            for (i, section) in sections.enumerated() {
                if isProjectOverride {
                    if let idx = settings.projects[projectIndex].threadSections?.firstIndex(where: { $0.id == section.sectionId }) {
                        settings.projects[projectIndex].threadSections![idx].sortOrder = i
                    }
                } else {
                    if let idx = settings.threadSections.firstIndex(where: { $0.id == section.sectionId }) {
                        settings.threadSections[idx].sortOrder = i
                    }
                }
            }
            try? persistence.saveSettings(settings)
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
            reloadData()
            return true
        }

        guard let thread = draggedThread(from: info) else {
            return false
        }

        isInsideAcceptDrop = true
        defer { isInsideAcceptDrop = false }

        if let project = item as? SidebarProject {
            let settings = persistence.loadSettings()
            guard !settings.shouldUseThreadSections(for: project.projectId) else { return false }
            return acceptFlatProjectDrop(for: thread, in: project, childIndex: index)
        }

        guard let section = item as? SidebarSection,
              section.projectId == thread.projectId else { return false }

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

        // Calculate group-relative index for the reorder. Adjust for inserted separators.
        let counts = threadGroupCounts(in: section)
        let threadIndex = adjustedDropIndex(index, in: section)
        let groupIndex = groupRelativeDropIndex(threadIndex, for: thread.sidebarListState, in: counts)
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
        if pendingReloadAfterDrag {
            reloadData()
        }
    }
}

// MARK: - NSOutlineViewDelegate

extension ThreadListViewController: NSOutlineViewDelegate {
    /// NSOutlineView can hand us stale value-type `MagentThread` snapshots after
    /// metadata-only in-place updates. Always resolve by id before configuring UI.
    private func resolvedThreadSnapshot(for thread: MagentThread) -> MagentThread {
        threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is SidebarAddRepoRow {
            return SidebarSpacerRowView()
        }
        if item is SidebarSpacer {
            return SidebarSpacerRowView()
        }
        if item is SidebarProjectMainSpacer {
            return SidebarSpacerRowView()
        }
        if item is SidebarGroupSeparator {
            return SidebarSpacerRowView()
        }
        if item is SidebarProject {
            let rowView = ProjectHeaderRowView()
            return rowView
        }
        if item is SidebarSection {
            return ProjectHeaderRowView()
        }

        let rowView = AlwaysEmphasizedRowView()
        if let itemThread = item as? MagentThread {
            let thread = resolvedThreadSnapshot(for: itemThread)
            let isSelected = outlineView.isRowSelected(outlineView.row(forItem: item))
            rowView.busyBorderPhaseKey = thread.id
            rowView.showsRateLimitHighlight = thread.hasUnreadRateLimit
            rowView.showsCompletionHighlight = thread.hasUnreadAgentCompletion && !thread.hasUnreadRateLimit
            rowView.showsWaitingHighlight = thread.hasWaitingForInput && !thread.hasUnreadAgentCompletion && !thread.hasUnreadRateLimit
            rowView.showsSubtleBottomSeparator = false
            rowView.showsBusyShimmer = thread.isAnyBusy
            rowView.showsArchivingOverlay = thread.isArchiving
            rowView.configureSignEmoji(
                thread.signEmoji,
                tintColor: thread.signEmoji.flatMap { Self.signEmojiTintColor(for: $0) },
                isSelected: isSelected
            )
        } else {
            rowView.showsRateLimitHighlight = false
            rowView.showsCompletionHighlight = false
            rowView.showsWaitingHighlight = false
            rowView.showsSubtleBottomSeparator = false
            rowView.showsBusyShimmer = false
            rowView.showsArchivingOverlay = false
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
        // Cell spans full row width (frameOfCell override), so no indentation
        // compensation needed — capsule padding is applied directly.
        return 0
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
        if item is SidebarAddRepoRow {
            return Self.addRepoRowHeight
        }
        if item is SidebarSpacer {
            return Self.projectHeaderInterProjectGap
        }
        if item is SidebarProjectMainSpacer {
            return Self.projectHeaderToMainRowGap
        }
        if item is SidebarGroupSeparator {
            return 12
        }
        if let bottomPadding = item as? SidebarBottomPadding {
            return bottomPadding.height
        }
        if item is SidebarProject {
            return Self.projectHeaderRowHeight
        }
        if item is SidebarSection {
            return 28
        }
        if let itemThread = item as? MagentThread {
            let thread = resolvedThreadSnapshot(for: itemThread)
            let settings = currentSettings
            let maxDescLines = settings.sidebarDescriptionLineLimit
            let trimmedDesc = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDescription = !(trimmedDesc?.isEmpty ?? true)

            let worktreeName = (thread.worktreePath as NSString).lastPathComponent
            let branchName = (thread.actualBranch ?? thread.branchName).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBranch = branchName.isEmpty ? thread.name : branchName
            let hasBranchWorktreeMismatch = worktreeName != resolvedBranch

            // Subtitle visible when description exists or branch != worktree.
            let hasSubtitle = hasDescription || hasBranchWorktreeMismatch

            let jiraEnabled = settings.jiraIntegrationEnabled && settings.jiraTicketDetectionEnabled
            let hasTicket = jiraEnabled && thread.effectiveJiraTicketKey(settings: settings) != nil
            let hasPR = thread.pullRequestInfo != nil
            let hasPRRow = hasTicket || hasPR

            let descLines: Int
            if hasDescription, let desc = trimmedDesc, maxDescLines > 1 {
                // Estimate available text width: sidebar width minus icon, spacing, trailing, capsule insets.
                let sidebarWidth = outlineView.bounds.width
                let textAvailableWidth = sidebarWidth
                    - Self.sidebarHorizontalInset  // leading inset
                    - Self.sidebarTrailingInset     // trailing inset
                    - 16 - 6                        // icon + spacing
                    - 30                            // trailing stack allowance
                descLines = ThreadCell.estimatedDescriptionLineCount(
                    text: desc, maxLines: maxDescLines, availableWidth: textAvailableWidth
                )
            } else {
                descLines = 1
            }
            return ThreadCell.sidebarRowHeight(
                descriptionLines: descLines,
                hasSubtitle: hasSubtitle,
                hasPRRow: hasPRRow,
                narrowThreads: settings.narrowThreads
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
        // All expand/collapse must go through the programmatic restore loop (which sets
        // allowsProgrammaticOutlineDisclosureChanges = true). This prevents AppKit from
        // expanding items on its own — during reloadItem, background run-loop cycles,
        // nil-currentEvent callbacks, or any other non-user-driven trigger.
        guard allowsProgrammaticOutlineDisclosureChanges else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        // Mirror shouldExpandItem: only the programmatic restore loop may collapse items.
        guard allowsProgrammaticOutlineDisclosureChanges else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if (outlineView as? SidebarOutlineView)?.isDragInteractionActive == true {
            return false
        }
        if item is SidebarAddRepoRow {
            addRepoButtonTapped(NSButton())
            return false
        }
        if item is SidebarSpacer {
            return false
        }
        if item is SidebarProjectMainSpacer {
            return false
        }
        if item is SidebarGroupSeparator {
            return false
        }
        if item is SidebarBottomPadding {
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
            // sectionHeaderHitArea returns .other for any non-mouse event (keyboard navigation,
            // type-select, etc.). The .other branch calls toggleSection, which would inadvertently
            // collapse/expand sections whenever arrow-key navigation crosses a section row.
            // Bail out early for non-mouse events — section toggling is mouse-only.
            let currentEventType = NSApp.currentEvent?.type
            guard currentEventType == .leftMouseDown || currentEventType == .leftMouseUp else {
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
        if let itemThread = item as? MagentThread,
           resolvedThreadSnapshot(for: itemThread).isArchiving {
            return false
        }
        return item is MagentThread
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if item is SidebarAddRepoRow {
            let identifier = NSUserInterfaceItemIdentifier("AddRepoCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? {
                    let c = NSTableCellView()
                    c.identifier = identifier

                    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    let button = NSButton()
                    button.bezelStyle = .inline
                    button.isBordered = false
                    button.image = NSImage(
                        systemSymbolName: "folder.badge.plus",
                        accessibilityDescription: "Add Repository"
                    )?.withSymbolConfiguration(symbolConfig)
                    button.contentTintColor = .secondaryLabelColor
                    button.target = self
                    button.action = #selector(addRepoButtonTapped(_:))
                    button.toolTip = "Add repository"
                    button.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(button)

                    NSLayoutConstraint.activate([
                        button.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        button.trailingAnchor.constraint(
                            equalTo: c.trailingAnchor,
                            constant: -Self.capsuleAlignedTrailing
                        ),
                        button.widthAnchor.constraint(equalToConstant: 22),
                        button.heightAnchor.constraint(equalToConstant: 22),
                    ])
                    return c
                }()
            return cell
        }
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
        if item is SidebarGroupSeparator {
            let identifier = NSUserInterfaceItemIdentifier("GroupSeparatorCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarGroupSeparatorCellView
                ?? {
                    let c = SidebarGroupSeparatorCellView()
                    c.identifier = identifier
                    return c
                }()
            return cell
        }
        if item is SidebarBottomPadding {
            let identifier = NSUserInterfaceItemIdentifier("BottomPaddingCell")
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
                            constant: Self.capsuleAlignedLeading
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

            cell.textField?.font = .systemFont(ofSize: 20, weight: .bold)
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
                addButton.toolTip = "Add thread to \(project.name). Right-click for agent options. Option-click to use project default."
                addButton.isEnabled = !isCreatingThread
                if let fullProject = currentSettings.projects.first(where: { $0.id == project.projectId }) {
                    addButton.menu = buildAgentSubmenu(for: fullProject)
                }
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

                    let shieldView = NSImageView()
                    shieldView.identifier = Self.sectionKeepAliveShieldIdentifier
                    shieldView.translatesAutoresizingMaskIntoConstraints = false
                    shieldView.image = NSImage(systemSymbolName: "shield.righthalf.filled", accessibilityDescription: "Keep Alive")
                    shieldView.contentTintColor = .systemCyan
                    shieldView.setContentHuggingPriority(.required, for: .horizontal)
                    shieldView.setContentCompressionResistancePriority(.required, for: .horizontal)
                    NSLayoutConstraint.activate([
                        shieldView.widthAnchor.constraint(equalToConstant: 12),
                        shieldView.heightAnchor.constraint(equalToConstant: 12),
                    ])

                    let nameStack = NSStackView(views: [tf, shieldView, badgeContainer])
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
                            constant: Self.capsuleAlignedLeading
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
                            constant: -Self.capsuleAlignedTrailing
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
            if let shieldView = cell.subviews
                .first(where: { $0.identifier == Self.sectionNameStackIdentifier })?
                .subviews
                .first(where: { $0.identifier == Self.sectionKeepAliveShieldIdentifier }) {
                shieldView.isHidden = !section.isKeepAlive
                shieldView.toolTip = section.isKeepAlive ? "Keep Alive — all threads in this section are protected" : nil
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
        if let itemThread = item as? MagentThread {
            let thread = resolvedThreadSnapshot(for: itemThread)
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
                    isBusy: thread.isAnyBusy,
                    isWaitingForInput: thread.hasWaitingForInput,
                    isDirty: thread.isDirty,
                    isBlockedByRateLimit: thread.isBlockedByRateLimit,
                    isRateLimitExpiredAndResumable: thread.isRateLimitExpiredAndResumable,
                    isRateLimitPropagatedOnly: thread.isRateLimitPropagatedOnly,
                    rateLimitTooltip: thread.rateLimitLiftDescription.map { "Rate limit reached. \($0)" },
                    rateLimitedAgentTypes: thread.rateLimitedAgentTypes,
                    currentBranch: currentBranch,
                    busyStateSince: thread.busyStateSince,
                    leadingOffset: 3 + 6 // accent bar width + spacing (matches icon flow)
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
                maxDescriptionLines: settings.sidebarDescriptionLineLimit,
                isAutoRenaming: threadManager.autoRenameInProgress.contains(thread.id)
            )
            cell.onArchive = { [weak self] in
                self?.triggerArchive(for: thread)
            }
            return cell
        }

        return nil
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Skip during reloadData() — AppKit may fire this for items being restored
        // programmatically in the restore loop. We don't want mid-reload state changes
        // to overwrite UserDefaults, since collapse state was already read before the reload.
        guard !isReloadingData else { return }
        guard let project = notification.userInfo?["NSObject"] as? SidebarProject else { return }
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        collapsed.remove(project.projectId.uuidString)
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        // Skip during reloadData() — AppKit can fire this for previously-expanded projects
        // when the outline view resets its expansion state. Without this guard, those projects
        // would be written into collapsedProjectIdsKey, causing the restore loop to collapse
        // them and hide all their sections.
        guard !isReloadingData else { return }
        guard let project = notification.userInfo?["NSObject"] as? SidebarProject else { return }
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        collapsed.insert(project.projectId.uuidString)
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Suppress intermediate selection events fired by NSOutlineView during reloadData().
        // The structural reload path in threadManager(didUpdateThreads:) calls refreshDiffPanel
        // directly with preserveSelection:true after reloadData() completes.
        guard !isReloadingData else { return }

        // Cancel any pending single-click section-name toggle. If the user clicked a section
        // name and then immediately selected a thread, the scheduled toggle would fire ~0.5 s
        // later and unexpectedly collapse/expand the section.
        cancelPendingSectionNameToggle()

        let row = outlineView.selectedRow
        guard row >= 0,
              let thread = outlineView.item(atRow: row) as? MagentThread else {
            // NSOutlineView can transiently report no selected row while reloading.
            // Keep the controller-owned selection until the selected thread is truly gone.
            guard selectedThreadFromState() == nil else { return }
            clearSelectedThreadState()
            return
        }
        let selectionChanged = selectedThreadID != thread.id
        let resolved = recordSelectedThread(thread)
        updateSelectedThreadJumpCapsuleVisibility()
        if selectionChanged {
            // New thread selected: delegate calls refreshDiffPanelForSelectedThread() which resets
            // the panel. Do NOT also call refreshDiffPanel here — that would create a second
            // no-preserve Task that races with the delegate's Task and can arrive late.
            delegate?.threadList(self, didSelectThread: resolved)
        } else {
            // Same thread re-selected (e.g. reloadData() programmatically restores the outline
            // selection after a structural reload). Preserve the active tab and commit selection.
            // resetPagination:false keeps the previously-loaded commit range intact so the
            // selected commit doesn't fall off the list.
            refreshDiffPanel(for: resolved, resetPagination: false, preserveSelection: true)
        }
    }
}



// MARK: - ThreadManagerDelegate

extension ThreadListViewController: ThreadManagerDelegate {
    func threadManager(_ manager: ThreadManager, didCreateThread thread: MagentThread) {
        reloadData()
        let skipDueToIPC = manager.skipNextAutoSelect
        manager.skipNextAutoSelect = false
        guard !skipDueToIPC,
              PersistenceService.shared.loadSettings().switchToNewlyCreatedThread else { return }
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
        // Coalesce: the session monitor can fire several didUpdateThreads calls within
        // a single tick (busy sync, rate-limit, completions). Rather than refreshing the
        // sidebar for each, store the latest snapshot and schedule a single refresh on the
        // next run-loop cycle. If another call arrives before the scheduled work fires,
        // the snapshot is updated and the previous work item is cancelled — so only one
        // sidebar refresh happens per burst.
        pendingThreadUpdateSnapshot = threads
        pendingThreadUpdateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let threads = self.pendingThreadUpdateSnapshot else { return }
            self.pendingThreadUpdateSnapshot = nil
            self.applyThreadUpdate(threads)
        }
        pendingThreadUpdateWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func applyThreadUpdate(_ threads: [MagentThread]) {
        // Only do a full reloadData() when the sidebar structure actually changed (threads
        // added/removed/reordered/re-sectioned). For metadata-only updates (busy state,
        // rate limits, dirty flag, PR info, etc.), update cells in-place — this avoids
        // the scroll-position flash that reloadData() + expand/collapse causes.
        let didStructuralReload = sidebarNeedsStructuralReload(for: threads)
        if didStructuralReload {
            reloadData()
        } else {
            updateSidebarInPlace(with: threads)
        }

        // If nothing is selected after reload (e.g. first launch), pick the first thread.
        // Guard against calling autoSelectFirst() when the selected thread is merely hidden
        // inside a collapsed section — outlineView.selectedRow is -1 in that case too, but
        // selectedThreadFromState() still returns the thread (it exists in threadManager.threads).
        if outlineView.selectedRow < 0, selectedThreadFromState() == nil {
            autoSelectFirst()
        }

        // Refresh branch mismatch view and diff panel for currently selected thread.
        // After a structural reload, outlineViewSelectionDidChange is suppressed (isReloadingData),
        // so we must explicitly refresh the diff panel here — with preserveSelection:true so the
        // active tab and selected commit are not reset by the background refresh.
        if let selected = selectedThreadFromState() {
            refreshBranchMismatchView(for: selected)
            if didStructuralReload {
                // resetPagination:false preserves the currently-loaded commit count so a
                // structural reload doesn't shrink the list and lose the selected commit hash.
                refreshDiffPanel(for: selected, resetPagination: false, preserveSelection: true)
            } else {
                refreshDiffPanelContext(for: selected)
            }
        } else if outlineView.selectedRow < 0 {
            clearSelectedThreadState()
        }
        updateSelectedThreadJumpCapsuleVisibility()
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

        /// - Parameter considerCompletionDate: Pass true only when
        ///   `autoReorderThreadsOnAgentCompletion` is enabled. When false, `lastAgentCompletionAt`
        ///   does not affect display order, so a change to it is not a structural change.
        init(_ thread: MagentThread, considerCompletionDate: Bool) {
            id = thread.id
            sectionId = thread.sectionId
            displayOrder = thread.displayOrder
            isPinned = thread.isPinned
            isSidebarHidden = thread.isSidebarHidden
            isArchived = thread.isArchived
            lastAgentCompletionAt = considerCompletionDate ? thread.lastAgentCompletionAt : nil
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

        // Only consider completion date as a structural signal when the sidebar actually
        // reorders threads on completion — otherwise every agent completion needlessly
        // triggers a full reload (and the animate-open jitter that comes with it).
        let considerCompletionDate = currentSettings.autoReorderThreadsOnAgentCompletion
        let sortById: (SidebarThreadStructuralKey, SidebarThreadStructuralKey) -> Bool = {
            $0.id.uuidString < $1.id.uuidString
        }
        let currentKeys = currentThreads
            .map { SidebarThreadStructuralKey($0, considerCompletionDate: considerCompletionDate) }
            .sorted(by: sortById)
        let newKeys = newThreads
            .map { SidebarThreadStructuralKey($0, considerCompletionDate: considerCompletionDate) }
            .sorted(by: sortById)
        return currentKeys != newKeys
    }

    /// Updates thread cell content in-place without a full reloadData().
    /// Mutates sidebar model objects, then directly reconfigures existing visible
    /// row/cell views — avoids reloadItem() which recreates row views and kills
    /// running CA animations (busy border rotation, shimmer).
    private func updateSidebarInPlace(with updatedThreads: [MagentThread]) {
        let threadById = Dictionary(uniqueKeysWithValues: updatedThreads.map { ($0.id, $0) })

        // Phase 1: Update model objects in-place.
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
        }

        // Phase 2: Reconfigure visible row and cell views directly — no
        // reloadItem() call, so NSOutlineView keeps existing view instances
        // and running CA animations survive.
        let settings = currentSettings
        for row in 0..<outlineView.numberOfRows {
            guard let thread = outlineView.item(atRow: row) as? MagentThread,
                  let updated = threadById[thread.id] else { continue }

            // Reconfigure the row view (shimmer, highlight borders, sign emoji).
            if let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) as? AlwaysEmphasizedRowView {
                let isSelected = outlineView.isRowSelected(row)
                rowView.busyBorderPhaseKey = updated.id
                rowView.showsRateLimitHighlight = updated.hasUnreadRateLimit
                rowView.showsCompletionHighlight = updated.hasUnreadAgentCompletion && !updated.hasUnreadRateLimit
                rowView.showsWaitingHighlight = updated.hasWaitingForInput && !updated.hasUnreadAgentCompletion && !updated.hasUnreadRateLimit
                rowView.showsBusyShimmer = updated.isAnyBusy
                rowView.showsArchivingOverlay = updated.isArchiving
                rowView.configureSignEmoji(
                    updated.signEmoji,
                    tintColor: updated.signEmoji.flatMap { Self.signEmojiTintColor(for: $0) },
                    isSelected: isSelected
                )
            }

            // Reconfigure the cell view (text, icon, metadata).
            if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadCell {
                if updated.isMain {
                    let currentBranch = {
                        let actualBranch = updated.actualBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !actualBranch.isEmpty, actualBranch != "HEAD" {
                            return actualBranch
                        }
                        return updated.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }()
                    cell.configureAsMain(
                        isUnreadCompletion: updated.hasUnreadAgentCompletion,
                        isBusy: updated.isAnyBusy,
                        isWaitingForInput: updated.hasWaitingForInput,
                        isDirty: updated.isDirty,
                        isBlockedByRateLimit: updated.isBlockedByRateLimit,
                        isRateLimitExpiredAndResumable: updated.isRateLimitExpiredAndResumable,
                        isRateLimitPropagatedOnly: updated.isRateLimitPropagatedOnly,
                        rateLimitTooltip: updated.rateLimitLiftDescription.map { "Rate limit reached. \($0)" },
                        currentBranch: currentBranch,
                        busyStateSince: updated.busyStateSince,
                        leadingOffset: 3 + 6
                    )
                } else {
                    let shouldUseSections = settings.shouldUseThreadSections(for: updated.projectId)
                    let sectionColor: NSColor?
                    if shouldUseSections {
                        let projectSections = settings.sections(for: updated.projectId)
                        let knownSectionIds = Set(projectSections.map(\.id))
                        let defaultSectionId = settings.defaultSection(for: updated.projectId)?.id
                        let resolvedSectionId = updated.resolvedSectionId(
                            knownSectionIds: knownSectionIds,
                            fallback: defaultSectionId
                        )
                        sectionColor = projectSections.first(where: { $0.id == resolvedSectionId })?.color
                    } else {
                        sectionColor = nil
                    }
                    cell.configure(
                        with: updated,
                        sectionColor: sectionColor,
                        leadingOffset: threadLeadingOffset(for: updated, in: outlineView),
                        maxDescriptionLines: settings.sidebarDescriptionLineLimit,
                        isAutoRenaming: threadManager.autoRenameInProgress.contains(updated.id)
                    )
                }
            }
        }
    }
}
