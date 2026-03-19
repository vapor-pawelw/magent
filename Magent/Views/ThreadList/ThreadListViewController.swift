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
    static let sidebarHorizontalInset: CGFloat = 0
    static let sidebarTopInset: CGFloat = 8
    static let rateLimitStatusTopInset: CGFloat = 8
    static let rateLimitStatusListSpacing: CGFloat = 6
    static let sidebarTrailingInset: CGFloat = 20
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
    static let projectSpacerDividerLeadingInset: CGFloat =
        projectSpacerDividerHorizontalInset - (outlineIndentationPerLevel / 2)
    static let projectSpacerDividerTrailingInset: CGFloat = sidebarTrailingInset
    static let sidebarRowLeadingInset: CGFloat = projectSpacerDividerLeadingInset
    static let projectHeaderTitleLeadingInset: CGFloat = sidebarRowLeadingInset + 3
    static let projectHeaderInterProjectGap: CGFloat =
        (projectSpacerDividerVerticalSpacing * 2) + projectSpacerDividerHeight

    weak var delegate: ThreadListDelegate?

    var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    let threadManager = ThreadManager.shared
    let persistence = PersistenceService.shared

    private var rateLimitStatusContainer: NSStackView!
    private var rateLimitStatusIconView: NSImageView!
    private var rateLimitStatusLabel: NSTextField!
    private var sidebarHeaderStack: NSStackView!
    private var syncStatusContainer: NSStackView!
    private var syncStatusLabel: NSTextField!
    private var syncRefreshButton: NSButton!
    /// Repeating timer for updating the "Synced X ago" label. Uses `[weak self]` closure.
    /// Not invalidated on deinit — this VC lives for the app's lifetime.
    private var syncStatusTimer: Timer?
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
    private var currentScrollTopOffset: CGFloat = 0
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
            selector: #selector(globalRateLimitSummaryDidChange),
            name: .magentGlobalRateLimitSummaryChanged,
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
            selector: #selector(statusSyncCompleted),
            name: .magentStatusSyncCompleted,
            object: nil
        )
        updateGlobalRateLimitSummary()
        updateSyncStatusLabel()
        startSyncStatusTimer()
        checkForPendingPromptRecovery()
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

    @objc private func globalRateLimitSummaryDidChange() {
        updateGlobalRateLimitSummary()
    }

    @objc private func statusSyncCompleted() {
        updateSyncStatusLabel()
    }

    @objc private func syncRefreshTapped() {
        threadManager.forceRefreshStatuses()
        syncStatusLabel.stringValue = "Syncing…"
    }

    private func updateSyncStatusLabel() {
        guard let lastSync = threadManager.lastStatusSyncAt else {
            // Startup sync is in flight — show "Syncing…" if we have threads loaded.
            if !threadManager.threads.isEmpty {
                syncStatusLabel.stringValue = "Syncing…"
                syncRefreshButton.isHidden = true
                syncStatusContainer.isHidden = false
            } else {
                syncStatusContainer.isHidden = true
            }
            recalculateSidebarHeaderInset()
            return
        }
        syncStatusLabel.stringValue = "Synced \(Self.relativeTimeString(from: lastSync))"
        syncRefreshButton.isHidden = false
        syncStatusContainer.isHidden = false
        recalculateSidebarHeaderInset()
    }

    private func startSyncStatusTimer() {
        syncStatusTimer?.invalidate()
        syncStatusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateSyncStatusLabel()
        }
    }

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
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
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        rateLimitStatusIconView = NSImageView()
        rateLimitStatusIconView.image = NSImage(
            systemSymbolName: "hourglass",
            accessibilityDescription: "Rate limits"
        )?.withSymbolConfiguration(symbolConfig)
        rateLimitStatusIconView.contentTintColor = NSColor(resource: .textSecondary)
        rateLimitStatusIconView.translatesAutoresizingMaskIntoConstraints = false

        rateLimitStatusLabel = NSTextField(labelWithString: "")
        rateLimitStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        rateLimitStatusLabel.textColor = NSColor(resource: .textSecondary)
        rateLimitStatusLabel.lineBreakMode = .byTruncatingTail
        rateLimitStatusLabel.maximumNumberOfLines = 1
        rateLimitStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        rateLimitStatusContainer = NSStackView(views: [rateLimitStatusIconView, rateLimitStatusLabel])
        rateLimitStatusContainer.orientation = .horizontal
        rateLimitStatusContainer.alignment = .centerY
        rateLimitStatusContainer.spacing = 4
        rateLimitStatusContainer.isHidden = true
        rateLimitStatusContainer.translatesAutoresizingMaskIntoConstraints = false

        // Sync status row
        let syncSymbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        syncStatusLabel = NSTextField(labelWithString: "")
        syncStatusLabel.font = .systemFont(ofSize: 9, weight: .medium)
        syncStatusLabel.textColor = .tertiaryLabelColor
        syncStatusLabel.lineBreakMode = .byTruncatingTail
        syncStatusLabel.maximumNumberOfLines = 1
        syncStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        syncRefreshButton = NSButton()
        syncRefreshButton.bezelStyle = .inline
        syncRefreshButton.isBordered = false
        syncRefreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(syncSymbolConfig)
        syncRefreshButton.contentTintColor = .tertiaryLabelColor
        syncRefreshButton.target = self
        syncRefreshButton.action = #selector(syncRefreshTapped)
        syncRefreshButton.toolTip = "Refresh PR and Jira statuses now"
        syncRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            syncRefreshButton.widthAnchor.constraint(equalToConstant: 14),
            syncRefreshButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        syncStatusContainer = NSStackView(views: [syncStatusLabel, syncRefreshButton])
        syncStatusContainer.orientation = .horizontal
        syncStatusContainer.alignment = .centerY
        syncStatusContainer.spacing = 3
        syncStatusContainer.isHidden = true
        syncStatusContainer.translatesAutoresizingMaskIntoConstraints = false

        // Vertical header stack holding rate limit + sync status
        sidebarHeaderStack = NSStackView(views: [rateLimitStatusContainer, syncStatusContainer])
        sidebarHeaderStack.orientation = .vertical
        sidebarHeaderStack.alignment = .leading
        sidebarHeaderStack.spacing = 2
        sidebarHeaderStack.detachesHiddenViews = true
        sidebarHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarHeaderStack)

        rebuildRateLimitStatusMenu()

        NSLayoutConstraint.activate([
            sidebarHeaderStack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.rateLimitStatusTopInset),
            sidebarHeaderStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            sidebarHeaderStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func updateGlobalRateLimitSummary() {
        let summary = threadManager.globalRateLimitSummaryText()
        rateLimitStatusLabel.stringValue = summary ?? ""
        rateLimitStatusContainer.isHidden = (summary == nil)
        rateLimitStatusLabel.toolTip = summary
        recalculateSidebarHeaderInset()
        rebuildRateLimitStatusMenu()
    }

    private func recalculateSidebarHeaderInset() {
        let hasRateLimit = !rateLimitStatusContainer.isHidden
        let hasSyncStatus = !syncStatusContainer.isHidden
        let hasAnyHeader = hasRateLimit || hasSyncStatus

        let topInset: CGFloat
        if !hasAnyHeader {
            topInset = Self.sidebarTopInset
        } else {
            view.layoutSubtreeIfNeeded()
            let headerHeight = ceil(sidebarHeaderStack.fittingSize.height)
            topInset = Self.sidebarTopInset
                + Self.rateLimitStatusTopInset
                + headerHeight
                + Self.rateLimitStatusListSpacing
        }
        if abs(topInset - currentScrollTopOffset) > 0.5 {
            currentScrollTopOffset = topInset
            scrollViewTopConstraint?.constant = topInset
        }
    }

    private func rebuildRateLimitStatusMenu() {
        let menu = NSMenu(title: "Rate Limits")
        menu.autoenablesItems = false
        addRateLimitMenuItems(for: .claude, to: menu)
        menu.addItem(NSMenuItem.separator())
        addRateLimitMenuItems(for: .codex, to: menu)

        rateLimitStatusContainer.menu = menu
        rateLimitStatusLabel.menu = menu
        rateLimitStatusIconView.menu = menu
    }

    private func addRateLimitMenuItems(for agent: AgentType, to menu: NSMenu) {
        let hasActiveLimit = threadManager.hasActiveRateLimit(for: agent)
        let shortName = agent == .claude ? "Claude" : "Codex"

        let liftItem = NSMenuItem(
            title: "Lift \(shortName) Limit Now",
            action: #selector(liftRateLimitFromMenu(_:)),
            keyEquivalent: ""
        )
        liftItem.target = self
        liftItem.representedObject = agent.rawValue
        liftItem.isEnabled = hasActiveLimit
        menu.addItem(liftItem)

        let ignoreLiftItem = NSMenuItem(
            title: "Lift + Ignore Current \(shortName) Messages",
            action: #selector(liftAndIgnoreRateLimitFromMenu(_:)),
            keyEquivalent: ""
        )
        ignoreLiftItem.target = self
        ignoreLiftItem.representedObject = agent.rawValue
        ignoreLiftItem.isEnabled = hasActiveLimit
        menu.addItem(ignoreLiftItem)
    }

    @objc private func liftRateLimitFromMenu(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }

        Task {
            _ = await threadManager.liftRateLimitManually(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                BannerManager.shared.show(message: "\(shortName) rate limit lifted manually.", style: .info)
                updateGlobalRateLimitSummary()
            }
        }
    }

    @objc private func liftAndIgnoreRateLimitFromMenu(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }

        Task {
            let ignoredCount = await threadManager.liftAndIgnoreCurrentRateLimitFingerprints(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                let message: String
                if ignoredCount > 0 {
                    message = "\(shortName) limit lifted. Ignoring \(ignoredCount) current fingerprint\(ignoredCount == 1 ? "" : "s")."
                } else {
                    message = "\(shortName) limit lifted. No active fingerprints found to ignore."
                }
                BannerManager.shared.show(message: message, style: .info)
                updateGlobalRateLimitSummary()
            }
        }
    }

    // MARK: - Outline View

    private func setupOutlineView() {
        outlineView = SidebarOutlineView()
        outlineView.style = .fullWidth
        outlineView.headerView = nil
        outlineView.floatsGroupRows = true
        outlineView.indentationPerLevel = Self.outlineIndentationPerLevel
        outlineView.rowSizeStyle = .custom
        outlineView.backgroundColor = .clear
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.intercellSpacing = NSSize(width: 0, height: 4)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThreadColumn"))
        column.title = "Threads"
        column.resizingMask = .autoresizingMask
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
        if sidebarHeaderStack.superview === view {
            view.addSubview(sidebarHeaderStack, positioned: .above, relativeTo: scrollView)
        }

        // Diff panel at the bottom of sidebar
        diffPanelView = DiffPanelView()
        diffPanelView.onLoadMoreCommits = { [weak self] in
            self?.loadMoreCommitsForSelectedThread()
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
        view.addSubview(diffPanelView)

        // Branch mismatch warning below diff panel
        branchMismatchView = BranchMismatchView()
        view.addSubview(branchMismatchView)

        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: view.topAnchor)

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
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
                let isNewThread = selectedThreadID != thread.id
                let resolved = recordSelectedThread(thread)
                if isNewThread { delegate?.threadList(self, didSelectThread: resolved) }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
