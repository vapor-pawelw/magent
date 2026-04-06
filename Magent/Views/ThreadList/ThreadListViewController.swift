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
            menu.delegate?.menuNeedsUpdate?(menu)
            NSMenu.popUpContextMenu(menu, with: event, for: self)
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
    static let sidebarToolbarRowHeight: CGFloat = 32
    static let sidebarTrailingInset: CGFloat =
        AlwaysEmphasizedRowView.capsuleTrailingInset
        + AlwaysEmphasizedRowView.capsuleBorderInset
        + AlwaysEmphasizedRowView.capsuleContentHPadding
    static let projectDisclosureTrailingInset: CGFloat = sidebarTrailingInset
    static let outlineIndentationPerLevel: CGFloat = 16
    static let disclosureButtonSize: CGFloat = 16
    static let projectHeaderActionButtonSize: CGFloat = 24
    static let projectAddButtonTrailingInset: CGFloat =
        projectDisclosureTrailingInset - ((projectHeaderActionButtonSize - disclosureButtonSize) / 2)
    static let projectHeaderVerticalPadding: CGFloat = 4
    static let projectHeaderRowHeight: CGFloat = disclosureButtonSize + (projectHeaderVerticalPadding * 2) + 2
    static let projectHeaderToMainRowGap: CGFloat = 8
    static let projectSpacerDividerVerticalSpacing: CGFloat = 4
    static let projectSpacerDividerHeight: CGFloat = 1
    static let projectSpacerDividerHorizontalInset: CGFloat = 8
    static let projectSpacerDividerLeadingInset: CGFloat = projectSpacerDividerHorizontalInset
    static let projectSpacerDividerTrailingInset: CGFloat = sidebarTrailingInset
    static let sidebarRowLeadingInset: CGFloat = projectSpacerDividerLeadingInset
    static let projectHeaderTitleLeadingInset: CGFloat = sidebarRowLeadingInset + 3
    static let projectHeaderInterProjectGap: CGFloat =
        (projectSpacerDividerVerticalSpacing * 2) + projectSpacerDividerHeight

    weak var delegate: ThreadListDelegate?

    var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private var toolbarRowView: NSView!
    let threadManager = ThreadManager.shared
    let persistence = PersistenceService.shared

    private var addRepoButton: NSButton!
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

        setupToolbar()
        setupOutlineView()

        threadManager.delegate = self
        reloadData()

        // Auto-select first selectable item
        autoSelectFirst()

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // On first appearance the scroll view has its final bounds —
        // force the column width to match so rows don't extend past the trailing edge.
        refitOutlineColumnIfNeeded(force: true)
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

    // MARK: - Toolbar Buttons

    private func setupToolbar() {
        toolbarRowView = NSView()
        toolbarRowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbarRowView)

        // Add repo button (top-right)
        let addRepoSymbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        addRepoButton = NSButton()
        addRepoButton.bezelStyle = .inline
        addRepoButton.isBordered = false
        addRepoButton.image = NSImage(
            systemSymbolName: "folder.badge.plus",
            accessibilityDescription: "Add Repository"
        )?.withSymbolConfiguration(addRepoSymbolConfig)
        addRepoButton.contentTintColor = .secondaryLabelColor
        addRepoButton.target = self
        addRepoButton.action = #selector(addRepoButtonTapped(_:))
        addRepoButton.toolTip = "Add repository"
        addRepoButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarRowView.addSubview(addRepoButton)

        NSLayoutConstraint.activate([
            toolbarRowView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarRowView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarRowView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarRowView.heightAnchor.constraint(equalToConstant: Self.sidebarToolbarRowHeight),

            addRepoButton.centerYAnchor.constraint(equalTo: toolbarRowView.centerYAnchor),
            addRepoButton.trailingAnchor.constraint(equalTo: toolbarRowView.trailingAnchor, constant: -8),
            addRepoButton.widthAnchor.constraint(equalToConstant: 22),
            addRepoButton.heightAnchor.constraint(equalToConstant: 22),
        ])
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

        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: toolbarRowView.bottomAnchor)

        NSLayoutConstraint.activate([
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
                children.append(SidebarProjectMainSpacer())
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
                children.append(contentsOf: sortedThreads)
            }

            return SidebarProject(
                projectId: project.id,
                name: project.name,
                isPinned: project.isPinned,
                children: children
            )
        }

        sidebarRootItems = []
        for (index, project) in sidebarProjects.enumerated() {
            if index > 0 {
                sidebarRootItems.append(SidebarSpacer())
            }
            sidebarRootItems.append(project)
        }

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
        DispatchQueue.main.async { [weak self] in
            self?.restoreSidebarScrollSnapshot(scrollSnapshot)
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

    func selectThread(byId threadId: UUID) {
        expandAncestorsIfNeeded(for: threadId)
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
                let isNewThread = selectedThreadID != thread.id
                let resolved = recordSelectedThread(thread)
                if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                return
            }
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
    }

}
