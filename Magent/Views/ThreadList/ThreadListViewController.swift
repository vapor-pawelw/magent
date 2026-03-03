import Cocoa

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
    static let projectSeparatorIdentifier = NSUserInterfaceItemIdentifier("ProjectTopSeparator")
    static let projectDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectDisclosureButton")
    static let projectAddButtonIdentifier = NSUserInterfaceItemIdentifier("ProjectAddButton")
    static let sectionDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("SectionDisclosureButton")
    static let sidebarHorizontalInset: CGFloat = 0
    static let projectDisclosureTrailingInset: CGFloat = 8
    static let outlineIndentationPerLevel: CGFloat = 16
    static let disclosureButtonSize: CGFloat = 16

    weak var delegate: ThreadListDelegate?

    var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    let threadManager = ThreadManager.shared
    let persistence = PersistenceService.shared

    private var rateLimitStatusLabel: NSTextField!
    var diffPanelView: DiffPanelView!
    var branchMismatchView: BranchMismatchView!
    var isCreatingThread = false
    var suppressNextSectionRowToggle = false
    var suppressNextProjectRowToggle = false
    /// Project IDs that have at least one recognized git hosting remote (GitHub/GitLab/Bitbucket).
    var projectsWithValidRemotes: Set<UUID> = []

    // MARK: - Data Model (3-level hierarchy)
    // Level 0: SidebarProject (project name header)
    // Level 1: MagentThread (main) or SidebarSection (section header)
    // Level 2: MagentThread (regular threads under a section)

    var sidebarProjects: [SidebarProject] = []

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
        rateLimitStatusLabel = NSTextField(labelWithString: "")
        rateLimitStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        rateLimitStatusLabel.textColor = NSColor(resource: .textSecondary)
        rateLimitStatusLabel.lineBreakMode = .byTruncatingTail
        rateLimitStatusLabel.isHidden = true
        rateLimitStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(rateLimitStatusLabel)

        NSLayoutConstraint.activate([
            rateLimitStatusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 11),
            rateLimitStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            rateLimitStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
    }

    private func updateGlobalRateLimitSummary() {
        let summary = threadManager.globalRateLimitSummaryText()
        rateLimitStatusLabel.stringValue = summary ?? ""
        rateLimitStatusLabel.isHidden = (summary == nil)
        rateLimitStatusLabel.toolTip = summary
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
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 4, right: 0)

        view.addSubview(scrollView)

        // Diff panel at the bottom of sidebar
        diffPanelView = DiffPanelView()
        view.addSubview(diffPanelView)

        // Branch mismatch warning below diff panel
        branchMismatchView = BranchMismatchView()
        view.addSubview(branchMismatchView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
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

        let sortedValidProjects = settings.projects.filter(\.isValid).sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return false // stable: preserve original order within each group
        }
        // If project path validation temporarily excludes all projects, still render
        // projects referenced by live threads so users can recover from Settings.
        let sortedProjects: [Project]
        if sortedValidProjects.isEmpty && !allThreads.isEmpty {
            let projectIdsWithThreads = Set(allThreads.map(\.projectId))
            sortedProjects = settings.projects
                .filter { projectIdsWithThreads.contains($0.id) }
                .sorted { a, b in
                    if a.isPinned != b.isPinned { return a.isPinned }
                    return false
                }
        } else {
            sortedProjects = sortedValidProjects
        }

        sidebarProjects = sortedProjects.map { project in
            var children: [Any] = []

            // Main thread(s) for this project first
            let projectMainThreads = mainThreads.filter { $0.projectId == project.id }
            children.append(contentsOf: projectMainThreads)

            // Section groups with regular threads (per-project or global fallback)
            let projectSections = settings.visibleSections(for: project.id)
            let projectKnownSectionIds = Set(settings.sections(for: project.id).map(\.id))
            let projectDefaultSectionId = settings.defaultSection(for: project.id)?.id

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

            return SidebarProject(
                projectId: project.id,
                name: project.name,
                isPinned: project.isPinned,
                children: children
            )
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

                // Pinned threads always come first
                if left.isPinned != right.isPinned {
                    return left.isPinned
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
