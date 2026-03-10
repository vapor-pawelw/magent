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

final class ThreadListViewController: NSViewController {

    static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    static let lastOpenedProjectDefaultsKey = "MagentLastOpenedProjectID"
    static let collapsedProjectIdsKey = "MagentCollapsedProjectIds"
    static let collapsedSectionIdsKey = "MagentCollapsedSectionIds"
    static let projectDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectDisclosureButton")
    static let projectAddButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectAddButton")
    static let sectionDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("SectionDisclosureButton")
    static let sectionCountBadgeContainerIdentifier = NSUserInterfaceItemIdentifier("SectionCountBadgeContainer")
    static let sectionCountBadgeLabelIdentifier = NSUserInterfaceItemIdentifier("SectionCountBadgeLabel")
    static let sidebarHorizontalInset: CGFloat = 0
    static let sidebarTopInset: CGFloat = 8
    static let rateLimitStatusTopInset: CGFloat = 8
    static let rateLimitStatusListSpacing: CGFloat = 6
    static let projectDisclosureTrailingInset: CGFloat = 8
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
    static let projectSpacerDividerTrailingInset: CGFloat = projectSpacerDividerHorizontalInset
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
    private var scrollViewTopConstraint: NSLayoutConstraint?
    var diffPanelView: DiffPanelView!
    var branchMismatchView: BranchMismatchView!
    var isCreatingThread = false
    var suppressNextSectionRowToggle = false
    var suppressNextProjectRowToggle = false
    /// Project IDs that have at least one recognized git hosting remote (GitHub/GitLab/Bitbucket).
    var projectsWithValidRemotes: Set<UUID> = []
    private var lastFittedOutlineWidth: CGFloat = 0
    private var currentScrollTopOffset: CGFloat = 0

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
        updateGlobalRateLimitSummary()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let currentWidth = outlineView.bounds.width
        guard currentWidth > 0 else { return }
        guard abs(currentWidth - lastFittedOutlineWidth) > 0.5 else { return }
        lastFittedOutlineWidth = currentWidth
        outlineView.sizeLastColumnToFit()
    }

    @objc private func sectionsDidChange() {
        reloadData()
    }

    @objc private func agentCompletionDetected(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        // If the completed thread is currently selected, refresh the diff panel
        let row = outlineView.selectedRow
        guard row >= 0,
              let selected = outlineView.item(atRow: row) as? MagentThread,
              selected.id == threadId else { return }
        refreshDiffPanel(for: selected)
    }

    @objc private func globalRateLimitSummaryDidChange() {
        updateGlobalRateLimitSummary()
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
        view.addSubview(rateLimitStatusContainer)

        rebuildRateLimitStatusMenu()

        NSLayoutConstraint.activate([
            rateLimitStatusContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.rateLimitStatusTopInset),
            rateLimitStatusContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rateLimitStatusContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func updateGlobalRateLimitSummary() {
        let summary = threadManager.globalRateLimitSummaryText()
        rateLimitStatusLabel.stringValue = summary ?? ""
        rateLimitStatusContainer.isHidden = (summary == nil)
        rateLimitStatusLabel.toolTip = summary
        let topInset: CGFloat
        if summary == nil {
            topInset = Self.sidebarTopInset
        } else {
            view.layoutSubtreeIfNeeded()
            let summaryHeight = ceil(rateLimitStatusContainer.fittingSize.height)
            topInset = Self.sidebarTopInset
                + Self.rateLimitStatusTopInset
                + summaryHeight
                + Self.rateLimitStatusListSpacing
        }
        if abs(topInset - currentScrollTopOffset) > 0.5 {
            currentScrollTopOffset = topInset
            scrollViewTopConstraint?.constant = topInset
        }
        rebuildRateLimitStatusMenu()
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
        outlineView = NSOutlineView()
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

        // Enable drag and drop
        outlineView.registerForDraggedTypes([.string])
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
        if rateLimitStatusContainer.superview === view {
            view.addSubview(rateLimitStatusContainer, positioned: .above, relativeTo: scrollView)
        }

        // Diff panel at the bottom of sidebar
        diffPanelView = DiffPanelView()
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
        // Remember current selection
        let selectedThreadId: UUID? = {
            let row = outlineView.selectedRow
            guard row >= 0, let thread = outlineView.item(atRow: row) as? MagentThread else { return nil }
            return thread.id
        }()

        let settings = persistence.loadSettings()
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

        outlineView.reloadData()

        // Expand projects that are not in the collapsed set; section visibility is
        // controlled by per-project section collapse state.
        let collapsedIds = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
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
        if let selectedId = selectedThreadId {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == selectedId {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    break
                }
            }
        }

        // Refresh cached remote availability per project (async, non-blocking)
        let projectIds = sidebarProjects.map(\.projectId)
        let currentSettings = settings
        Task { [weak self] in
            var validIds: Set<UUID> = []
            for project in currentSettings.projects where projectIds.contains(project.id) {
                let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
                if remotes.contains(where: { $0.provider != .unknown }) {
                    validIds.insert(project.id)
                }
            }
            await MainActor.run {
                self?.projectsWithValidRemotes = validIds
            }
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
                    delegate?.threadList(self, didSelectThread: thread)
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
                        delegate?.threadList(self, didSelectThread: thread)
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        return
                    }
                }
            }
        } else if let lastOpenedProjectId {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread,
                   thread.projectId == lastOpenedProjectId {
                    delegate?.threadList(self, didSelectThread: thread)
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    return
                }
            }
        }

        // Find the first selectable thread item
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread {
                delegate?.threadList(self, didSelectThread: thread)
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }

    func selectThread(byId threadId: UUID) {
        for row in 0..<outlineView.numberOfRows {
            if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
                delegate?.threadList(self, didSelectThread: thread)
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }

}
