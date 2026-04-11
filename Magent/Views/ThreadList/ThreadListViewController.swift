import Cocoa
import MagentCore

@MainActor
protocol ThreadListDelegate: AnyObject {
    func threadList(_ controller: ThreadListViewController, didSelectThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didRenameThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didArchiveThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didDeleteThread thread: MagentThread)
    func threadListDidRequestSettings(_ controller: ThreadListViewController)
}

final class SidebarOutlineView: NSOutlineView {
    var suppressSelectionAutoScroll = false
    private(set) var isDragInteractionActive = false

    func noteLocalDragWillBegin() {
        isDragInteractionActive = true
    }

    func noteLocalDragDidEnd() {
        isDragInteractionActive = false
    }

    override func scrollRowToVisible(_ row: Int) {
        guard !suppressSelectionAutoScroll else { return }
        super.scrollRowToVisible(row)
    }

    /// Suppress AppKit's own selection/focus highlight so right-click context
    /// menus don't draw an extra border around the row.
    override func highlightSelection(inClipRect clipRect: NSRect) {
        // No-op — custom capsule selection is drawn by AlwaysEmphasizedRowView.
    }

    /// Stores the row index for right-click so `clickedRow` stays valid
    /// even though we bypass AppKit's default right-click selection handling.
    private var _contextMenuRow: Int = -1
    override var clickedRow: Int { _contextMenuRow >= 0 ? _contextMenuRow : super.clickedRow }

    /// Prevent right-click from temporarily selecting a row, which causes AppKit
    /// to draw its own selection/focus highlight outside our custom capsule.
    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        _contextMenuRow = row(at: loc)
        defer { _contextMenuRow = -1 }
        if _contextMenuRow >= 0, let menu = self.menu {
            // Highlight the target row while the menu is open so it's obvious
            // which (unselected) thread the actions will apply to.
            let targetRowView = rowView(atRow: _contextMenuRow, makeIfNecessary: false) as? AlwaysEmphasizedRowView
            if !(targetRowView?.isSelected ?? true) {
                targetRowView?.showsContextMenuHighlight = true
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            // popUpContextMenu is synchronous — it returns only after dismissal.
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            targetRowView?.showsContextMenuHighlight = false
        } else {
            super.rightMouseDown(with: event)
        }
    }

    /// Intercept clicks on the archive suggestion button inside thread cells so that
    /// tapping "archive" does not also select the row (which would trigger a heavyweight
    /// detail-view load that is immediately discarded).
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let row = self.row(at: loc)
        if row >= 0,
           let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadCell,
           let archiveBtn = cell.archiveButton,
           !archiveBtn.isHidden {
            let btnLoc = archiveBtn.convert(loc, from: self)
            if archiveBtn.bounds.contains(btnLoc) {
                archiveBtn.sendAction(archiveBtn.action, to: archiveBtn.target)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragInteractionActive = true
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragInteractionActive = true
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragInteractionActive = false
        super.draggingExited(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        super.concludeDragOperation(sender)
        isDragInteractionActive = false
    }

}

final class ThreadListViewController: NSViewController {

    static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    static let lastOpenedProjectDefaultsKey = "MagentLastOpenedProjectID"
    static let collapsedProjectIdsKey = "MagentCollapsedProjectIds"
    static let collapsedSectionIdsKey = "MagentCollapsedSectionIds"
    static let projectDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectDisclosureButton")
    static let projectAddButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectAddButton")
    static let sectionDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("SectionDisclosureButton")
    static let sectionNameStackIdentifier = NSUserInterfaceItemIdentifier("SectionNameStack")
    static let sectionCountBadgeContainerIdentifier = NSUserInterfaceItemIdentifier("SectionCountBadgeContainer")
    static let sectionCountBadgeLabelIdentifier = NSUserInterfaceItemIdentifier("SectionCountBadgeLabel")
    static let sectionInlineRenameFieldIdentifier = NSUserInterfaceItemIdentifier("SectionInlineRenameField")
    static let sectionKeepAliveShieldIdentifier = NSUserInterfaceItemIdentifier("SectionKeepAliveShield")
    /// Leading inset from cell edge to content. For indented threads, setLeadingOffset
    /// subtracts the outline indentation so content aligns to capsule inner edge + padding.
    static let sidebarHorizontalInset: CGFloat =
        AlwaysEmphasizedRowView.capsuleLeadingInset
        + AlwaysEmphasizedRowView.capsuleBorderInset
        + AlwaysEmphasizedRowView.capsuleContentHPadding
    static let addRepoRowHeight: CGFloat = 32
    static let sidebarTrailingInset: CGFloat =
        AlwaysEmphasizedRowView.capsuleTrailingInset
        + AlwaysEmphasizedRowView.capsuleBorderInset
        + AlwaysEmphasizedRowView.capsuleContentHPadding
    /// Leading inset for non-thread rows (project/section headers), aligned to capsule leading edge.
    static let capsuleAlignedLeading: CGFloat = AlwaysEmphasizedRowView.capsuleLeadingInset
    /// Trailing inset for non-thread rows, aligned to capsule trailing edge.
    static let capsuleAlignedTrailing: CGFloat = AlwaysEmphasizedRowView.capsuleTrailingInset
    static let outlineIndentationPerLevel: CGFloat = 16
    static let disclosureButtonSize: CGFloat = 16
    static let projectHeaderActionButtonSize: CGFloat = 24
    static let projectAddButtonTrailingInset: CGFloat =
        capsuleAlignedTrailing - ((projectHeaderActionButtonSize - disclosureButtonSize) / 2)
    static let projectHeaderVerticalPadding: CGFloat = 6
    static let projectHeaderRowHeight: CGFloat = 36
    static let projectHeaderToMainRowGap: CGFloat = 0
    static let projectHeaderInterProjectGap: CGFloat = 24

    weak var delegate: ThreadListDelegate?

    var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var stickyHeaderOverlay: StickyHeaderOverlayView!
    private var stickyHeaderHeightConstraint: NSLayoutConstraint!
    /// The project/section currently shown in the sticky header, for scroll-on-click.
    private weak var stickyProject: SidebarProject?
    private weak var stickySection: SidebarSection?
    let threadManager = ThreadManager.shared
    let persistence = PersistenceService.shared

    private var scrollViewTopConstraint: NSLayoutConstraint?
    var diffPanelView: DiffPanelView!
    var branchMismatchView: BranchMismatchView!
    var isCreatingThread = false
    /// True while reloadData() is executing. Suppresses diffPanelView?.clear() in
    /// outlineViewSelectionDidChange so the panel doesn't blink when the outline view
    /// transiently loses selection mid-reload before restoring it.
    var isReloadingData = false
    var suppressNextSectionRowToggle = false
    var suppressNextProjectRowToggle = false
    var activeSectionRename: (projectId: UUID, sectionId: UUID, originalName: String)?
    var pendingSectionNameToggleWorkItem: DispatchWorkItem?
    var pendingSectionNameToggleKey: String?
    var contextMenuSectionColorTarget: (projectId: UUID, sectionId: UUID)?
    /// Project IDs that have at least one recognized git hosting remote (GitHub/GitLab/Bitbucket).
    var projectsWithValidRemotes: Set<UUID> = []
    private var lastFittedOutlineWidth: CGFloat = 0
    var currentSettings = AppSettings()
    var allowsProgrammaticOutlineDisclosureChanges = false
    /// Set to true inside acceptDrop so reloadData() is not suppressed during a live drag.
    var isInsideAcceptDrop = false
    /// Set to true when reloadData() was skipped due to an active drag; reloadData() will
    /// be called once the drag session ends.
    var pendingReloadAfterDrag = false
    /// Tracks in-flight Jira status transitions (ticketKey → target status).
    var inFlightJiraTransitions: [String: String] = [:]
    /// Debounces progress banner restoration after a Jira transition error.
    var jiraProgressRestorationTask: Task<Void, Never>?
    var diffPanelCommitLimitByThreadId: [UUID: Int] = [:]
    let diffPanelCommitPageSize = 10
    private var pendingSettingsReloadWorkItem: DispatchWorkItem?
    private let selectedThreadJumpCapsule = NSView()
    private let selectedThreadJumpIconView = NSImageView()
    private let selectedThreadJumpTitleLabel = NSTextField(labelWithString: "")
    private let selectedThreadJumpDirectionView = NSImageView()
    private let selectedThreadJumpVisibleBottomInset: CGFloat = 16
    private let selectedThreadJumpHiddenBottomInset: CGFloat = 4
    private let selectedThreadJumpHeight: CGFloat = 32
    private var selectedThreadJumpBottomConstraint: NSLayoutConstraint?
    private var selectedThreadJumpIsVisible = false
    private var selectedThreadJumpClickGesture: NSClickGestureRecognizer?
    private var selectedThreadJumpRequiredListBottomInset: CGFloat {
        (selectedThreadJumpVisibleBottomInset * 2) + selectedThreadJumpHeight
    }
    /// Coalesces multiple `didUpdateThreads` delegate calls into a single sidebar
    /// refresh per run-loop cycle. The session monitor can fire several updates within
    /// one tick (busy sync, rate-limit, completions); without coalescing each would
    /// trigger a separate reloadItem pass.
    var pendingThreadUpdateWorkItem: DispatchWorkItem?
    /// Snapshot of the latest threads array passed to the coalesced update.
    var pendingThreadUpdateSnapshot: [MagentThread]?
    /// Monotonically-increasing generation per thread. Incremented each time refreshDiffPanel is called.
    /// The active Task captures its generation at spawn time and bails if a newer call has since arrived,
    /// preventing stale no-preserve tasks from overwriting later preserve tasks.
    var diffPanelRefreshGeneration: [UUID: Int] = [:]
    /// Guards the manual changes-panel refresh button against overlapping git refresh passes.
    var isDiffPanelManualRefreshInFlight = false
    /// Queues one extra manual refresh when a discard/stage action happens while a refresh is already running.
    var pendingDiffPanelManualRefresh = false
    /// Generation counter for the git remote check Task spawned by reloadData().
    /// Prevents stale Tasks from running when reloadData() is called rapidly.
    private var remoteCheckGeneration: Int = 0
    private(set) var selectedThreadID: UUID?
    private var hasSidebarAppeared = false
    private var didCenterInitialSelectedThreadOnLaunch = false

    private struct SidebarScrollSnapshot {
        let origin: NSPoint
    }

    // MARK: - Data Model (3-level hierarchy)
    // Level 0: SidebarProject (project name header)
    // Level 1: SidebarProjectMainSpacer, MagentThread (main/flat item), or SidebarSection (section header)
    // Level 2: MagentThread (regular threads under a section)

    var sidebarProjects: [SidebarProject] = []
    var sidebarRootItems: [Any] = []

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupOutlineView()

        threadManager.delegate = self
        reloadData()

        // Auto-select first selectable item
        autoSelectFirst()
        updateSelectedThreadJumpCapsuleVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sectionsDidChange),
            name: .magentSectionsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentCompletionDetected(_:)),
            name: .magentAgentCompletionDetected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .magentSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRecoveryReopenRequested(_:)),
            name: .magentRecoveryReopenRequested,
            object: nil
        )
        checkForPendingPromptRecovery()

        // Observe scroll position to update sticky headers
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasSidebarAppeared = true
        // On first appearance the scroll view has its final bounds —
        // force the column width to match so rows don't extend past the trailing edge.
        refitOutlineColumnIfNeeded(force: true)
        scheduleInitialSelectedThreadCenteringIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        refitOutlineColumnIfNeeded()
    }

    func refreshSidebarLayout(forceColumnRefit: Bool = false) {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        scrollView?.layoutSubtreeIfNeeded()
        outlineView?.layoutSubtreeIfNeeded()
        refitOutlineColumnIfNeeded(force: forceColumnRefit)
    }

    private func refitOutlineColumnIfNeeded(force: Bool = false) {
        guard let outlineView, let scrollView else { return }
        let targetWidth = scrollView.contentView.bounds.width
        guard targetWidth > 0 else { return }

        let needsOutlineWidthSync = abs(outlineView.frame.width - targetWidth) > 0.5
        let currentColumnWidth = outlineView.tableColumns.first?.width ?? 0
        let needsColumnWidthSync = abs(currentColumnWidth - targetWidth) > 0.5
        guard force || needsOutlineWidthSync || needsColumnWidthSync || abs(targetWidth - lastFittedOutlineWidth) > 0.5 else { return }

        if needsOutlineWidthSync {
            var frame = outlineView.frame
            frame.size.width = targetWidth
            outlineView.frame = frame
        }
        if let column = outlineView.tableColumns.first {
            column.width = targetWidth
        }

        lastFittedOutlineWidth = targetWidth
        outlineView.noteNumberOfRowsChanged()
        outlineView.layoutSubtreeIfNeeded()
    }

    // MARK: - Sticky Header Scroll Tracking

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        updateStickyHeaders()
        updateSelectedThreadJumpCapsuleVisibility()
    }

    /// Determines which project/section header should be pinned at the top of the
    /// sidebar based on the current scroll position. A header becomes sticky when
    /// its actual row has scrolled above the visible area but its children are still
    /// partially visible.
    func updateStickyHeaders() {
        guard let outlineView, let scrollView else { return }

        let clipBounds = scrollView.contentView.bounds
        let visibleTop = clipBounds.origin.y

        // Walk visible rows from the top to find the first thread row.
        // From that thread, determine its parent project and section.
        let visibleRange = outlineView.rows(in: clipBounds)
        guard visibleRange.length > 0 else {
            stickyHeaderOverlay.update(state: .hidden)
            stickyHeaderHeightConstraint.constant = 0
            return
        }

        var state = StickyHeaderOverlayView.HeaderState.hidden

        // Find the project whose header should be sticky: walk from the topmost
        // visible row upward to find the nearest SidebarProject above the viewport.
        // Also track the nearest section above or at the top of the viewport.
        var foundProject: SidebarProject?
        var foundSection: SidebarSection?

        // Check from the first visible row backwards to find the project/section
        let firstVisibleRow = visibleRange.location
        for row in stride(from: firstVisibleRow, through: 0, by: -1) {
            let item = outlineView.item(atRow: row)
            if foundSection == nil, let section = item as? SidebarSection {
                // Only sticky-pin the section if its row is above (or at) the visible top
                let rowRect = outlineView.rect(ofRow: row)
                if rowRect.origin.y < visibleTop + 1 {
                    foundSection = section
                }
            }
            if let project = item as? SidebarProject {
                let rowRect = outlineView.rect(ofRow: row)
                if rowRect.origin.y < visibleTop + 1 {
                    foundProject = project
                }
                break // project is the top-level parent, stop here
            }
        }

        // Only show sticky project header if the project row is scrolled off
        if let project = foundProject {
            // Verify the project has visible children below — don't pin if we've
            // scrolled past all of its children too.
            let projectRow = outlineView.row(forItem: project)
            if projectRow >= 0 {
                let lastChildRow = lastVisibleChildRow(of: project, projectRow: projectRow)
                let lastChildRect = outlineView.rect(ofRow: lastChildRow)
                // If the bottom of the last child is still visible, show sticky
                if lastChildRect.maxY > visibleTop + StickyHeaderOverlayView.projectRowHeight {
                    state.projectName = project.name
                    state.projectIsPinned = project.isPinned
                }
            }
        }

        // Only show sticky section header if the section is expanded, its header
        // row is scrolled off, and its threads are still partially visible.
        if let section = foundSection,
           state.projectName != nil,
           outlineView.isItemExpanded(section) {
            let sectionRow = outlineView.row(forItem: section)
            let childCount = outlineView.numberOfChildren(ofItem: section)
            if sectionRow >= 0, childCount > 0 {
                let lastThreadRow = sectionRow + childCount
                if lastThreadRow < outlineView.numberOfRows {
                    let lastThreadRect = outlineView.rect(ofRow: lastThreadRow)
                    let stickyBottom = StickyHeaderOverlayView.projectRowHeight + StickyHeaderOverlayView.sectionRowHeight
                    if lastThreadRect.maxY > visibleTop + stickyBottom {
                        state.sectionName = section.name
                        state.sectionColor = section.color
                    }
                }
            }
        }

        stickyProject = foundProject != nil && state.projectName != nil ? foundProject : nil
        stickySection = foundSection != nil && state.sectionName != nil ? foundSection : nil

        stickyHeaderOverlay.update(state: state)
        let height = stickyHeaderOverlay.intrinsicContentSize.height
        stickyHeaderHeightConstraint.constant = height
    }

    private func scrollToStickyProject() {
        guard let project = stickyProject else { return }
        let row = outlineView.row(forItem: project)
        guard row >= 0 else { return }
        scrollOutlineRowToTop(row)
    }

    private func scrollToStickySection() {
        guard let section = stickySection else { return }
        let row = outlineView.row(forItem: section)
        guard row >= 0 else { return }
        // Offset by the project header height so the section row sits just
        // below the sticky project header instead of hidden behind it.
        scrollOutlineRowToTop(row, topOffset: StickyHeaderOverlayView.projectRowHeight)
    }

    /// Scrolls the outline view so the given row's top edge aligns with the
    /// top of the visible clip area (plus an optional offset), with a smooth animation.
    private func scrollOutlineRowToTop(_ row: Int, topOffset: CGFloat = 0) {
        let rowRect = outlineView.rect(ofRow: row)
        let targetY = max(0, rowRect.origin.y - topOffset)
        let targetOrigin = NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollView.contentView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Returns the row index of the last visible child item under the given project.
    private func lastVisibleChildRow(of project: SidebarProject, projectRow: Int) -> Int {
        var lastRow = projectRow
        let totalRows = outlineView.numberOfRows
        for i in (projectRow + 1)..<totalRows {
            let item = outlineView.item(atRow: i)
            // Stop when we hit another project or the add-repo row
            if item is SidebarProject || item is SidebarAddRepoRow {
                break
            }
            // Skip inter-project spacers (they belong between projects)
            if item is SidebarSpacer {
                break
            }
            lastRow = i
        }
        return lastRow
    }

    @objc private func sectionsDidChange() {
        reloadData()
    }

    @objc private func agentCompletionDetected(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        // If the completed thread is currently selected, refresh the diff panel.
        // resetPagination:false keeps the existing commit range intact so the selected
        // commit stays in the list after the agent's new commit lands.
        guard let selected = selectedThreadFromState(),
              selected.id == threadId else { return }
        refreshDiffPanel(for: selected, resetPagination: false, preserveSelection: true)
    }

    @objc private func settingsDidChange() {
        // Debounce: settings can be saved many times in quick succession (e.g. typing in a
        // text field, or multiple observers firing back-to-back). Coalesce into one reload
        // after 100 ms to avoid thrashing the outline view on every keystroke.
        pendingSettingsReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadData()
            self?.refreshSidebarLayout(forceColumnRefit: true)
        }
        pendingSettingsReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Outline View

    private func setupOutlineView() {
        outlineView = SidebarOutlineView()
        outlineView.style = .plain
        outlineView.headerView = nil
        outlineView.floatsGroupRows = true
        // Zero indentation — thread cells use capsule-relative padding directly.
        // Section/project headers add their own leading insets.
        outlineView.indentationPerLevel = 0
        outlineView.rowSizeStyle = .custom
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        // Suppress AppKit's built-in selection drawing so right-click context menus
        // don't add an unwanted border. Our custom capsule is drawn in drawBackground.
        outlineView.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThreadColumn"))
        column.title = "Threads"
        // .autoresizingMask lets the column track the outline view width.
        column.resizingMask = .autoresizingMask
        // Prevent the column from growing wider than the scroll view clip bounds.
        // Actual width is pinned in refitOutlineColumnIfNeeded().
        column.minWidth = 10
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(outlineViewDoubleClicked(_:))

        // Enable drag and drop
        outlineView.registerForDraggedTypes([.string, .magentSectionId])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        view.addSubview(scrollView)

        // Diff panel at the bottom of sidebar
        diffPanelView = DiffPanelView()
        diffPanelView.onLoadMoreCommits = { [weak self] in
            self?.loadMoreCommitsForSelectedThread()
        }
        diffPanelView.onAllChangesRequested = { [weak self] in
            self?.loadAllChangesForSelectedThread()
        }
        diffPanelView.onCommitSelected = { [weak self] commitHash in
            self?.handleCommitSelected(commitHash)
        }
        diffPanelView.onCommitDoubleTapped = { [weak self] commitHash, title in
            self?.handleCommitDoubleTapped(commitHash, title: title)
        }
        diffPanelView.onBaseBranchClicked = { [weak self] anchorView in
            self?.showBaseBranchMenu(anchorView: anchorView)
        }
        diffPanelView.onRefreshRequested = { [weak self] in
            self?.manuallyRefreshSelectedThreadGitState()
        }
        view.addSubview(diffPanelView)

        // Branch mismatch warning below diff panel
        branchMismatchView = BranchMismatchView()
        view.addSubview(branchMismatchView)

        // Sticky project/section header overlay — added last to sit above scroll view
        stickyHeaderOverlay = StickyHeaderOverlayView()
        stickyHeaderOverlay.translatesAutoresizingMaskIntoConstraints = false
        stickyHeaderOverlay.onProjectClicked = { [weak self] in
            self?.scrollToStickyProject()
        }
        stickyHeaderOverlay.onSectionClicked = { [weak self] in
            self?.scrollToStickySection()
        }
        view.addSubview(stickyHeaderOverlay)
        stickyHeaderHeightConstraint = stickyHeaderOverlay.heightAnchor.constraint(equalToConstant: 0)

        setupSelectedThreadJumpCapsule()

        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: view.topAnchor)

        NSLayoutConstraint.activate([
            stickyHeaderOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            stickyHeaderOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stickyHeaderOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stickyHeaderHeightConstraint,

            scrollViewTopConstraint!,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: diffPanelView.topAnchor),

            diffPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diffPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diffPanelView.bottomAnchor.constraint(equalTo: branchMismatchView.topAnchor),

            branchMismatchView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            branchMismatchView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            branchMismatchView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupSelectedThreadJumpCapsule() {
        selectedThreadJumpCapsule.translatesAutoresizingMaskIntoConstraints = false
        selectedThreadJumpCapsule.wantsLayer = true
        selectedThreadJumpCapsule.isHidden = true
        selectedThreadJumpCapsule.alphaValue = 0
        selectedThreadJumpCapsule.toolTip = "Scroll to selected thread"
        let click = NSClickGestureRecognizer(target: self, action: #selector(selectedThreadJumpCapsuleTapped(_:)))
        selectedThreadJumpCapsule.addGestureRecognizer(click)
        selectedThreadJumpClickGesture = click

        selectedThreadJumpIconView.translatesAutoresizingMaskIntoConstraints = false
        selectedThreadJumpIconView.imageScaling = .scaleProportionallyDown
        selectedThreadJumpIconView.setContentHuggingPriority(.required, for: .horizontal)
        selectedThreadJumpIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        selectedThreadJumpTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        selectedThreadJumpTitleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        selectedThreadJumpTitleLabel.textColor = .labelColor
        selectedThreadJumpTitleLabel.lineBreakMode = .byTruncatingTail
        selectedThreadJumpTitleLabel.maximumNumberOfLines = 1
        selectedThreadJumpTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        selectedThreadJumpDirectionView.translatesAutoresizingMaskIntoConstraints = false
        selectedThreadJumpDirectionView.imageScaling = .scaleProportionallyDown
        selectedThreadJumpDirectionView.contentTintColor = .tertiaryLabelColor
        selectedThreadJumpDirectionView.setContentHuggingPriority(.required, for: .horizontal)
        selectedThreadJumpDirectionView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let capsuleContent = NSStackView(views: [selectedThreadJumpIconView, selectedThreadJumpTitleLabel, selectedThreadJumpDirectionView])
        capsuleContent.translatesAutoresizingMaskIntoConstraints = false
        capsuleContent.orientation = .horizontal
        capsuleContent.alignment = .centerY
        capsuleContent.spacing = 8

        selectedThreadJumpCapsule.addSubview(capsuleContent)
        view.addSubview(selectedThreadJumpCapsule)

        selectedThreadJumpBottomConstraint = selectedThreadJumpCapsule.bottomAnchor.constraint(
            equalTo: scrollView.bottomAnchor,
            constant: -selectedThreadJumpHiddenBottomInset
        )

        NSLayoutConstraint.activate([
            capsuleContent.leadingAnchor.constraint(equalTo: selectedThreadJumpCapsule.leadingAnchor, constant: 12),
            capsuleContent.trailingAnchor.constraint(equalTo: selectedThreadJumpCapsule.trailingAnchor, constant: -12),
            capsuleContent.centerYAnchor.constraint(equalTo: selectedThreadJumpCapsule.centerYAnchor),
            selectedThreadJumpIconView.widthAnchor.constraint(equalToConstant: 14),
            selectedThreadJumpIconView.heightAnchor.constraint(equalToConstant: 14),
            selectedThreadJumpDirectionView.widthAnchor.constraint(equalToConstant: 12),
            selectedThreadJumpDirectionView.heightAnchor.constraint(equalToConstant: 12),

            selectedThreadJumpCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            selectedThreadJumpCapsule.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            selectedThreadJumpCapsule.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            selectedThreadJumpCapsule.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            selectedThreadJumpCapsule.heightAnchor.constraint(equalToConstant: selectedThreadJumpHeight),
            selectedThreadJumpBottomConstraint!,
        ])

        applySelectedThreadJumpCapsuleStyle()
    }

    private func applySelectedThreadJumpCapsuleStyle() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            selectedThreadJumpCapsule.layer?.cornerRadius = 16
            selectedThreadJumpCapsule.layer?.borderWidth = 1
            selectedThreadJumpCapsule.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            selectedThreadJumpCapsule.layer?.borderColor = NSColor(resource: .primaryBrand).cgColor
        }
    }

    // MARK: - Data

    func reloadData() {
        // Skip structural reloads while a drag is in progress to prevent section
        // expand/collapse animations from firing on background state updates. Allow
        // reloads that originate from acceptDrop itself (isInsideAcceptDrop).
        if (outlineView as? SidebarOutlineView)?.isDragInteractionActive == true,
           !isInsideAcceptDrop {
            pendingReloadAfterDrag = true
            return
        }
        pendingReloadAfterDrag = false

        isReloadingData = true
        defer { isReloadingData = false }

        let scrollSnapshot = captureSidebarScrollSnapshot()

        // Remember current selection
        let selectedThreadId = selectedThreadID ?? {
            let row = outlineView.selectedRow
            guard row >= 0, let thread = outlineView.item(atRow: row) as? MagentThread else { return nil }
            return thread.id
        }()

        let settings = persistence.loadSettings()
        currentSettings = settings
        let allThreads = threadManager.threads
        let mainThreads = allThreads.filter { $0.isMain }
        let regularThreads = allThreads.filter { !$0.isMain }

        let validVisibleProjects = settings.projects.filter { $0.isValid && !$0.isHidden }
        let sortedValidProjects = validVisibleProjects.filter(\.isPinned) + validVisibleProjects.filter { !$0.isPinned }
        // If project path validation temporarily excludes all projects, still render
        // projects referenced by live threads so users can recover from Settings.
        let sortedProjects: [Project]
        if sortedValidProjects.isEmpty && !allThreads.isEmpty {
            let projectIdsWithThreads = Set(allThreads.map(\.projectId))
            let projectsWithThreads = settings.projects
                .filter { projectIdsWithThreads.contains($0.id) && !$0.isHidden }
            let pinned = projectsWithThreads.filter(\.isPinned)
            let unpinned = projectsWithThreads.filter { !$0.isPinned }
            // Preserve explicit project ordering from settings within each pin group.
            sortedProjects = pinned + unpinned
        } else {
            sortedProjects = sortedValidProjects
        }

        sidebarProjects = sortedProjects.map { project in
            var children: [Any] = []
            let shouldUseSections = settings.shouldUseThreadSections(for: project.id)
            let projectSections = settings.visibleSections(for: project.id)
            let projectKnownSectionIds = Set(settings.sections(for: project.id).map(\.id))
            let projectDefaultSectionId = settings.defaultSection(for: project.id)?.id

            // Main thread(s) for this project first
            let projectMainThreads = mainThreads.filter { $0.projectId == project.id }
            if !projectMainThreads.isEmpty {
                if Self.projectHeaderToMainRowGap > 0 {
                    children.append(SidebarProjectMainSpacer())
                }
                children.append(contentsOf: projectMainThreads)
            }

            if shouldUseSections {
                // Section groups with regular threads (per-project or global fallback)
                for section in projectSections {
                    let matchingThreads = regularThreads.filter { thread in
                        guard thread.projectId == project.id else { return false }
                        return thread.resolvedSectionId(knownSectionIds: projectKnownSectionIds, fallback: projectDefaultSectionId) == section.id
                    }
                    let sortedThreads = sortThreadsForDisplay(
                        matchingThreads,
                        preferRecentCompletions: settings.autoReorderThreadsOnAgentCompletion
                    )
                    children.append(SidebarSection(
                        projectId: project.id,
                        sectionId: section.id,
                        name: section.name,
                        color: section.color,
                        isKeepAlive: section.isKeepAlive,
                        threads: sortedThreads
                    ))
                }
            } else {
                // Flat list: treat the project like one combined section while
                // preserving each thread's stored section assignment.
                let projectRegularThreads = regularThreads.filter { $0.projectId == project.id }
                let sortedThreads = sortThreadsForDisplay(
                    projectRegularThreads,
                    preferRecentCompletions: settings.autoReorderThreadsOnAgentCompletion
                )
                // Insert visual separators at pinned→normal and normal→hidden transitions.
                var lastState: ThreadSidebarListState? = nil
                for thread in sortedThreads {
                    if let last = lastState, thread.sidebarListState != last {
                        children.append(SidebarGroupSeparator())
                    }
                    children.append(thread)
                    lastState = thread.sidebarListState
                }
            }

            return SidebarProject(
                projectId: project.id,
                name: project.name,
                isPinned: project.isPinned,
                children: children
            )
        }

        sidebarRootItems = [SidebarAddRepoRow()]
        for (index, project) in sidebarProjects.enumerated() {
            if index > 0 {
                sidebarRootItems.append(SidebarSpacer())
            }
            sidebarRootItems.append(project)
        }
        sidebarRootItems.append(SidebarBottomPadding(height: selectedThreadJumpRequiredListBottomInset))

        // Read collapse state before reloadData() — AppKit can fire outlineViewItemDidCollapse
        // for previously-expanded items during the reload, which would corrupt UserDefaults
        // and cause the restore loop below to see those projects as collapsed.
        let collapsedIds = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])

        outlineView.reloadData()
        refitOutlineColumnIfNeeded(force: true)

        // Expand projects that are not in the collapsed set; section visibility is
        // controlled by per-project section collapse state.
        // Disable animations: reloadData() creates fresh SidebarProject/SidebarSection
        // objects that NSOutlineView treats as new (collapsed) items. Without animation
        // suppression, expandItem() animates every section back open on each reload —
        // visible as sections repeatedly sliding open during active agent runs.
        allowsProgrammaticOutlineDisclosureChanges = true
        defer { allowsProgrammaticOutlineDisclosureChanges = false }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        defer { NSAnimationContext.endGrouping() }
        for project in sidebarProjects {
            let isCollapsed = collapsedIds.contains(project.projectId.uuidString)
            if isCollapsed {
                outlineView.collapseItem(project)
            } else {
                outlineView.expandItem(project)
                for child in project.children {
                    if let section = child as? SidebarSection {
                        if isSectionCollapsed(section) {
                            outlineView.collapseItem(section)
                        } else {
                            outlineView.expandItem(section)
                        }
                    }
                }
            }
        }
        refreshVisibleSectionDisclosureButtons()

        // Restore selection
        var restoredSelection = false
        if let selectedId = selectedThreadId {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == selectedId {
                    preserveSidebarSelectionViewport {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    restoredSelection = true
                    break
                }
            }
        }
        if let selectedThreadId, !restoredSelection, self.selectedThreadID == selectedThreadId {
            // Only clear the selection if the thread is truly gone (archived/deleted).
            // If it's just hidden inside a collapsed section it's still valid — keep the
            // controller's selection pointer so the next reload can restore it.
            let threadStillExists = threadManager.threads.contains { $0.id == selectedThreadId }
            if !threadStillExists {
                self.selectedThreadID = nil
            }
        }

        restoreSidebarScrollSnapshot(scrollSnapshot)
        updateStickyHeaders()
        updateSelectedThreadJumpCapsuleVisibility()
        DispatchQueue.main.async { [weak self] in
            self?.restoreSidebarScrollSnapshot(scrollSnapshot)
            self?.updateStickyHeaders()
            self?.updateSelectedThreadJumpCapsuleVisibility()
            self?.scheduleInitialSelectedThreadCenteringIfNeeded()
        }

        // Refresh cached remote availability per project (async, non-blocking).
        // Generation-gated: rapid reloadData() calls only run the latest Task.
        remoteCheckGeneration += 1
        let gen = remoteCheckGeneration
        let projectIds = sidebarProjects.map(\.projectId)
        let currentSettings = settings
        Task { [weak self] in
            guard self?.remoteCheckGeneration == gen else { return }
            var validIds: Set<UUID> = []
            for project in currentSettings.projects where projectIds.contains(project.id) {
                guard self?.remoteCheckGeneration == gen else { return }
                let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
                if remotes.contains(where: { $0.provider != .unknown }) {
                    validIds.insert(project.id)
                }
            }
            await MainActor.run {
                guard self?.remoteCheckGeneration == gen else { return }
                self?.projectsWithValidRemotes = validIds
            }
        }
    }

    private func scheduleInitialSelectedThreadCenteringIfNeeded() {
        guard hasSidebarAppeared else { return }
        guard !didCenterInitialSelectedThreadOnLaunch else { return }
        guard selectedThreadID != nil else {
            didCenterInitialSelectedThreadOnLaunch = true
            return
        }
        attemptInitialSelectedThreadCentering(remainingAttempts: 6)
    }

    private func attemptInitialSelectedThreadCentering(remainingAttempts: Int) {
        guard !didCenterInitialSelectedThreadOnLaunch else { return }
        guard hasSidebarAppeared else { return }
        guard let selectedThreadID else {
            didCenterInitialSelectedThreadOnLaunch = true
            return
        }

        refreshSidebarLayout(forceColumnRefit: true)
        expandAncestorsIfNeeded(for: selectedThreadID)

        guard scrollView.contentView.bounds.height > 0, outlineView.numberOfRows > 0 else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.attemptInitialSelectedThreadCentering(remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        for row in 0..<outlineView.numberOfRows {
            guard let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == selectedThreadID else { continue }
            centerOutlineRowInViewport(row) { [weak self] in
                self?.didCenterInitialSelectedThreadOnLaunch = true
                self?.updateSelectedThreadJumpCapsuleVisibility()
            }
            return
        }

        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.attemptInitialSelectedThreadCentering(remainingAttempts: remainingAttempts - 1)
        }
    }

    private func captureSidebarScrollSnapshot() -> SidebarScrollSnapshot {
        SidebarScrollSnapshot(origin: scrollView.contentView.bounds.origin)
    }

    private func restoreSidebarScrollSnapshot(_ snapshot: SidebarScrollSnapshot) {
        let clipView = scrollView.contentView
        let documentRect = clipView.documentRect
        let visibleHeight = clipView.bounds.height
        let minY = documentRect.minY
        let maxY = max(documentRect.minY, documentRect.maxY - visibleHeight)
        let targetY = min(max(snapshot.origin.y, minY), maxY)
        let targetOrigin = NSPoint(x: snapshot.origin.x, y: targetY)

        guard clipView.bounds.origin != targetOrigin else { return }
        clipView.scroll(to: targetOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func preserveSidebarSelectionViewport(_ updates: () -> Void) {
        let sidebarOutlineView = outlineView as? SidebarOutlineView
        sidebarOutlineView?.suppressSelectionAutoScroll = true
        updates()
        DispatchQueue.main.async { [weak sidebarOutlineView] in
            sidebarOutlineView?.suppressSelectionAutoScroll = false
        }
    }

    private func sortThreadsForDisplay(
        _ threads: [MagentThread],
        preferRecentCompletions: Bool
    ) -> [MagentThread] {
        threads
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element

                // Sidebar groups are ordered pinned, normal, then hidden.
                if left.sidebarListState != right.sidebarListState {
                    return left.sidebarListState.rawValue < right.sidebarListState.rawValue
                }

                // Sort by displayOrder (lower first)
                if left.displayOrder != right.displayOrder {
                    return left.displayOrder < right.displayOrder
                }

                if preferRecentCompletions {
                    // Fallback: most recent agent completion first
                    switch (left.lastAgentCompletionAt, right.lastAgentCompletionAt) {
                    case let (l?, r?) where l != r:
                        return l > r
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    default:
                        // Preserve input order when priority keys tie.
                        return lhs.offset < rhs.offset
                    }
                }
                // Preserve input order when priority keys tie.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func autoSelectFirst() {
        let defaults = UserDefaults.standard
        let persistedThreads = persistence.loadThreads()

        let lastOpenedThreadId: UUID? = defaults
            .string(forKey: Self.lastOpenedThreadDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let lastOpenedProjectId: UUID? = defaults
            .string(forKey: Self.lastOpenedProjectDefaultsKey)
            .flatMap(UUID.init(uuidString:))

        if let threadId = lastOpenedThreadId {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
                    let isNewThread = selectedThreadID != thread.id
                    let resolved = recordSelectedThread(thread)
                    if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }

            // If the exact thread is gone (e.g. archived/deleted), restore to the same project.
            let fallbackProjectId = lastOpenedProjectId
                ?? threadManager.threads.first(where: { $0.id == threadId })?.projectId
                ?? persistedThreads.first(where: { $0.id == threadId })?.projectId
            if let fallbackProjectId {
                for row in 0..<outlineView.numberOfRows {
                    if let thread = outlineView.item(atRow: row) as? MagentThread,
                       thread.projectId == fallbackProjectId {
                        let isNewThread = selectedThreadID != thread.id
                        let resolved = recordSelectedThread(thread)
                        if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        return
                    }
                }
            }
        } else if let lastOpenedProjectId {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread,
                   thread.projectId == lastOpenedProjectId {
                    let isNewThread = selectedThreadID != thread.id
                    let resolved = recordSelectedThread(thread)
                    if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }

        // Find the first selectable thread item
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread {
                let isNewThread = selectedThreadID != thread.id
                let resolved = recordSelectedThread(thread)
                if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }

        clearSelectedThreadState()
    }

    func selectThread(byId threadId: UUID, scrollRowToVisible: Bool = true) {
        expandAncestorsIfNeeded(for: threadId)
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
                let isNewThread = selectedThreadID != thread.id
                let resolved = recordSelectedThread(thread)
                if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if scrollRowToVisible {
                    outlineView.scrollRowToVisible(row)
                }
                return
            }
        }
    }

    func centerThreadRow(byId threadId: UUID, completion: (() -> Void)? = nil) {
        expandAncestorsIfNeeded(for: threadId)
        for row in 0..<outlineView.numberOfRows {
            guard let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId else { continue }
            centerOutlineRowInViewport(row, completion: completion)
            return
        }
        completion?()
    }

    func centerAndPulseThreadRow(byId threadId: UUID) {
        centerThreadRow(byId: threadId) { [weak self] in
            self?.pulseThreadRow(threadId: threadId)
        }
    }

    private func expandAncestorsIfNeeded(for threadId: UUID) {
        for project in sidebarProjects {
            if project.children.contains(where: { ($0 as? MagentThread)?.id == threadId }) {
                outlineView.expandItem(project)
                return
            }

            for child in project.children {
                guard let section = child as? SidebarSection,
                      section.threads.contains(where: { $0.id == threadId }) else { continue }
                outlineView.expandItem(project)
                outlineView.expandItem(section)
                return
            }
        }
    }

    private func centerOutlineRowInViewport(_ row: Int, completion: (() -> Void)? = nil) {
        guard row >= 0 else { return }
        let rowRect = outlineView.rect(ofRow: row)
        guard rowRect.height > 0 else { return }

        let clipView = scrollView.contentView
        let visibleHeight = clipView.bounds.height
        guard visibleHeight > 0 else {
            outlineView.scrollRowToVisible(row)
            completion?()
            return
        }

        let rowMidY = rowRect.midY
        let targetY = rowMidY - (visibleHeight / 2)
        let maxOffsetY = max(0, outlineView.bounds.height - visibleHeight)
        let clampedY = min(max(targetY, 0), maxOffsetY)
        let targetOrigin = NSPoint(x: clipView.bounds.origin.x, y: clampedY)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clipView.animator().setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }, completionHandler: {
            completion?()
        })
    }

    func updateSelectedThreadJumpCapsuleVisibility() {
        guard isViewLoaded else { return }
        guard let selectedThread = selectedThreadFromState() else {
            setSelectedThreadJumpCapsuleVisible(false)
            return
        }

        selectedThreadJumpIconView.image = NSImage(systemSymbolName: selectedThread.threadIcon.symbolName, accessibilityDescription: selectedThread.threadIcon.accessibilityDescription)
        selectedThreadJumpIconView.contentTintColor = NSColor(resource: .primaryBrand)
        let description = selectedThread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let worktreeName = (selectedThread.worktreePath as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            selectedThreadJumpTitleLabel.stringValue = description
        } else if !worktreeName.isEmpty {
            selectedThreadJumpTitleLabel.stringValue = worktreeName
        } else {
            selectedThreadJumpTitleLabel.stringValue = "Thread"
        }

        let row = outlineView.row(forItem: selectedThread)
        let shouldShow: Bool
        let directionSymbolName: String
        if row < 0 {
            shouldShow = true
            directionSymbolName = "arrow.up.and.down"
        } else {
            let rowRect = outlineView.rect(ofRow: row)
            let visibleRect = scrollView.contentView.bounds
            shouldShow = !rowRect.intersects(visibleRect)
            if rowRect.maxY < visibleRect.minY {
                directionSymbolName = "arrow.up"
            } else if rowRect.minY > visibleRect.maxY {
                directionSymbolName = "arrow.down"
            } else {
                directionSymbolName = "arrow.up.and.down"
            }
        }
        selectedThreadJumpDirectionView.image = NSImage(
            systemSymbolName: directionSymbolName,
            accessibilityDescription: "Scroll direction"
        )

        setSelectedThreadJumpCapsuleVisible(shouldShow)
    }

    private func setSelectedThreadJumpCapsuleVisible(_ visible: Bool) {
        guard visible != selectedThreadJumpIsVisible else { return }
        selectedThreadJumpIsVisible = visible

        if visible {
            view.addSubview(selectedThreadJumpCapsule, positioned: .above, relativeTo: nil)
            selectedThreadJumpCapsule.isHidden = false
            selectedThreadJumpCapsule.alphaValue = 0
            selectedThreadJumpBottomConstraint?.constant = -selectedThreadJumpHiddenBottomInset
            view.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                selectedThreadJumpCapsule.animator().alphaValue = 1
                selectedThreadJumpBottomConstraint?.animator().constant = -selectedThreadJumpVisibleBottomInset
                view.layoutSubtreeIfNeeded()
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                selectedThreadJumpCapsule.animator().alphaValue = 0
                selectedThreadJumpBottomConstraint?.animator().constant = -selectedThreadJumpHiddenBottomInset
                view.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self] in
                guard let self else { return }
                guard !self.selectedThreadJumpIsVisible else { return }
                self.selectedThreadJumpCapsule.isHidden = true
            })
        }
    }

    @objc private func selectedThreadJumpCapsuleTapped(_ gesture: NSClickGestureRecognizer) {
        guard let selectedThreadID else { return }
        centerAndPulseThreadRow(byId: selectedThreadID)
    }

    private func pulseThreadRow(threadId: UUID) {
        for row in 0..<outlineView.numberOfRows {
            guard let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId else { continue }
            guard let rowView = outlineView.rowView(atRow: row, makeIfNecessary: true) else { return }
            rowView.wantsLayer = true
            guard let layer = rowView.layer else { return }
            layer.removeAnimation(forKey: "selectedThreadRowPulse")

            // Ensure scaling animates around the visual center (not an edge/corner).
            let targetAnchor = CGPoint(x: 0.5, y: 0.5)
            if layer.anchorPoint != targetAnchor {
                let oldAnchor = layer.anchorPoint
                let oldPosition = layer.position
                layer.anchorPoint = targetAnchor
                let dx = (targetAnchor.x - oldAnchor.x) * layer.bounds.width
                let dy = (targetAnchor.y - oldAnchor.y) * layer.bounds.height
                layer.position = CGPoint(x: oldPosition.x + dx, y: oldPosition.y + dy)
            }

            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1.0, 1.05, 1.0]
            pulse.keyTimes = [0.0, 0.5, 1.0]
            pulse.duration = 0.3
            pulse.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            layer.add(pulse, forKey: "selectedThreadRowPulse")
            return
        }
    }

    func selectedThreadFromState() -> MagentThread? {
        guard let selectedThreadID else { return nil }
        return threadManager.threads.first(where: { $0.id == selectedThreadID })
    }

    @discardableResult
    func recordSelectedThread(_ thread: MagentThread) -> MagentThread {
        let resolved = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        selectedThreadID = resolved.id
        UserDefaults.standard.set(resolved.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        UserDefaults.standard.set(resolved.projectId.uuidString, forKey: Self.lastOpenedProjectDefaultsKey)
        return resolved
    }

    func clearSelectedThreadState() {
        selectedThreadID = nil
        diffPanelView?.clear()
        branchMismatchView?.clear()
        updateSelectedThreadJumpCapsuleVisibility()
    }

}
