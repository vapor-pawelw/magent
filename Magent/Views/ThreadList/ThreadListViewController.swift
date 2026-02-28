import Cocoa

// MARK: - AlwaysEmphasizedRowView

/// Row view that always draws its selection in the emphasized (active) style,
/// even when the outline view is not the first responder.
final class AlwaysEmphasizedRowView: NSTableRowView {
    var showsCompletionHighlight = false {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsCompletionHighlight, !isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

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
    static let sectionDisclosureButtonIdentifier = NSUserInterfaceItemIdentifier("SectionDisclosureButton")
    static let sidebarHorizontalInset: CGFloat = 0
    static let projectDisclosureTrailingInset: CGFloat = 8
    static let outlineIndentationPerLevel: CGFloat = 16
    static let toolbarPlusTrailingInset: CGFloat = projectDisclosureTrailingInset
    static let disclosureButtonSize: CGFloat = 16

    weak var delegate: ThreadListDelegate?

    var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    let threadManager = ThreadManager.shared
    let persistence = PersistenceService.shared

    private var addButton: NSButton!
    var diffPanelView: DiffPanelView!
    private var isCreatingThread = false
    var suppressNextSectionRowToggle = false
    var suppressNextProjectRowToggle = false

    // MARK: - Data Model (3-level hierarchy)
    // Level 0: SidebarProject (project name header)
    // Level 1: MagentThread (main) or SidebarSection (section header)
    // Level 2: MagentThread (regular threads under a section)

    var sidebarProjects: [SidebarProject] = []

    class SidebarProject {
        let projectId: UUID
        let name: String
        let isPinned: Bool
        var children: [Any] // Mix of MagentThread (main) and SidebarSection

        init(projectId: UUID, name: String, isPinned: Bool, children: [Any]) {
            self.projectId = projectId
            self.name = name
            self.isPinned = isPinned
            self.children = children
        }
    }

    class SidebarSection {
        let projectId: UUID
        let sectionId: UUID
        let name: String
        let color: NSColor
        var threads: [MagentThread]

        init(projectId: UUID, sectionId: UUID, name: String, color: NSColor, threads: [MagentThread]) {
            self.projectId = projectId
            self.sectionId = sectionId
            self.name = name
            self.color = color
            self.threads = threads
        }
    }

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

    // MARK: - Toolbar Buttons

    private func setupToolbar() {
        let plusImage = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add Thread"
        )?.withSymbolConfiguration(.init(pointSize: 15, weight: .heavy))
        addButton = NSButton(
            image: plusImage ?? NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Thread")!,
            target: self,
            action: #selector(addThreadTapped)
        )
        addButton.isBordered = false
        addButton.contentTintColor = .controlAccentColor
        addButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(addButton)

        NSLayoutConstraint.activate([
            addButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.toolbarPlusTrailingInset),
            addButton.widthAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
            addButton.heightAnchor.constraint(equalToConstant: Self.disclosureButtonSize),
        ])
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

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: diffPanelView.topAnchor),

            diffPanelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diffPanelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diffPanelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
            let projectDefaultSectionId = projectSections.first?.id

            for section in projectSections {
                let matchingThreads = regularThreads.filter { thread in
                    guard thread.projectId == project.id else { return false }
                    let effectiveSectionId: UUID?
                    if let sid = thread.sectionId, projectKnownSectionIds.contains(sid) {
                        effectiveSectionId = sid
                    } else {
                        effectiveSectionId = projectDefaultSectionId
                    }
                    return effectiveSectionId == section.id
                }
                let sortedThreads = sortThreadsForDisplay(matchingThreads)
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
                    return
                }
            }
        }
    }

    private func sortThreadsForDisplay(_ threads: [MagentThread]) -> [MagentThread] {
        threads
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element

                if left.isPinned != right.isPinned {
                    return left.isPinned
                }

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

    // MARK: - Actions

    @objc private func addThreadTapped() {
        guard !isCreatingThread else { return }

        let settings = persistence.loadSettings()
        let projects = settings.projects

        guard !projects.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Projects"
            alert.informativeText = "Add a project in Settings first."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if projects.count == 1 {
            let project = projects[0]
            presentProjectAgentMenu(project: project)
        } else {
            let menu = NSMenu()
            let activeAgents = settings.availableActiveAgents
            for project in projects {
                let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
                item.submenu = buildAgentSubmenu(for: project, activeAgents: activeAgents)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: addButton.bounds.minX, y: addButton.bounds.minY), in: addButton)
        }
    }

    @objc func toggleSectionExpanded(_ sender: NSButton) {
        suppressNextSectionRowToggle = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextSectionRowToggle = false
            }
        }

        let row = outlineView.row(for: sender)
        guard row >= 0,
              let section = outlineView.item(atRow: row) as? SidebarSection,
              !section.threads.isEmpty else { return }
        toggleSection(section, animatedDisclosureButton: sender)
    }

    @objc func toggleProjectExpanded(_ sender: NSButton) {
        suppressNextProjectRowToggle = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextProjectRowToggle = false
            }
        }

        let project: SidebarProject? = {
            if let rawProjectId = sender.objectValue as? String,
               let projectId = UUID(uuidString: rawProjectId),
               let matched = sidebarProjects.first(where: { $0.projectId == projectId }) {
                return matched
            }
            let row = outlineView.row(for: sender)
            guard row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? SidebarProject
        }()
        guard let project else { return }

        let willCollapse = !isProjectCollapsed(project)
        setProjectCollapsed(project, isCollapsed: willCollapse)
        reloadData()
    }

    func toggleSection(_ section: SidebarSection, animatedDisclosureButton: NSButton? = nil) {
        let willCollapse = !isSectionCollapsed(section)
        setSectionCollapsed(section, isCollapsed: willCollapse)

        if let button = animatedDisclosureButton {
            updateSectionDisclosureButton(button, isExpanded: !willCollapse)
        }
        reloadData()
    }

    func updateSectionDisclosureButton(_ button: NSButton, isExpanded: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.title = ""
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: isExpanded ? "Collapse section" : "Expand section"
        )?.withSymbolConfiguration(symbolConfig)
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
    }

    func updateProjectDisclosureButton(_ button: NSButton, isExpanded: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.title = ""
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: isExpanded ? "Collapse project" : "Expand project"
        )?.withSymbolConfiguration(symbolConfig)
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(isExpanded ? "Collapse project" : "Expand project")
    }

    func sectionDisclosureButton(for section: SidebarSection) -> NSButton? {
        let row = outlineView.row(forItem: section)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return nil }
        return cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton
    }

    private func setSectionCollapsed(_ section: SidebarSection, isCollapsed: Bool) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionIdsKey) ?? [])
        let key = sectionCollapseStorageKey(section)
        if isCollapsed {
            collapsed.insert(key)
        } else {
            collapsed.remove(key)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedSectionIdsKey)
    }

    func isSectionCollapsed(_ section: SidebarSection) -> Bool {
        let collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionIdsKey) ?? [])
        return collapsed.contains(sectionCollapseStorageKey(section))
    }

    func isProjectCollapsed(_ project: SidebarProject) -> Bool {
        let collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        return collapsed.contains(project.projectId.uuidString)
    }

    func setProjectCollapsed(_ project: SidebarProject, isCollapsed: Bool) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        if isCollapsed {
            collapsed.insert(project.projectId.uuidString)
        } else {
            collapsed.remove(project.projectId.uuidString)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func sectionCollapseStorageKey(_ section: SidebarSection) -> String {
        "\(section.projectId.uuidString):\(section.sectionId.uuidString)"
    }

    private func refreshSectionDisclosureButton(for section: SidebarSection) {
        let row = outlineView.row(forItem: section)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let button = cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton else { return }
        updateSectionDisclosureButton(button, isExpanded: !isSectionCollapsed(section))
    }

    private func refreshVisibleSectionDisclosureButtons() {
        for row in 0..<outlineView.numberOfRows {
            guard let section = outlineView.item(atRow: row) as? SidebarSection else { continue }
            refreshSectionDisclosureButton(for: section)
        }
    }

    private func presentProjectAgentMenu(project: Project) {
        let settings = persistence.loadSettings()
        let activeAgents = settings.availableActiveAgents
        let menu = buildAgentSubmenu(for: project, activeAgents: activeAgents)
        menu.popUp(positioning: nil, at: NSPoint(x: addButton.bounds.minX, y: addButton.bounds.minY), in: addButton)
    }

    private func buildAgentSubmenu(for project: Project, activeAgents: [AgentType]) -> NSMenu {
        let submenu = NSMenu()

        if let defaultAgent = threadManager.effectiveAgentType(for: project.id) {
            let defaultItem = NSMenuItem(
                title: "Use Project Default (\(defaultAgent.displayName))",
                action: #selector(projectAgentMenuItemSelected(_:)),
                keyEquivalent: ""
            )
            defaultItem.target = self
            defaultItem.representedObject = ["projectId": project.id.uuidString, "mode": "default"] as [String: String]
            submenu.addItem(defaultItem)
        }

        for agent in activeAgents {
            let item = NSMenuItem(title: agent.displayName, action: #selector(projectAgentMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["projectId": project.id.uuidString, "mode": "agent", "agentRaw": agent.rawValue] as [String: String]
            submenu.addItem(item)
        }

        if submenu.items.count > 0 {
            submenu.addItem(.separator())
        }

        let terminalItem = NSMenuItem(title: "Terminal", action: #selector(projectAgentMenuItemSelected(_:)), keyEquivalent: "")
        terminalItem.target = self
        terminalItem.representedObject = ["projectId": project.id.uuidString, "mode": "terminal"] as [String: String]
        submenu.addItem(terminalItem)

        return submenu
    }

    @objc private func projectAgentMenuItemSelected(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String],
              let projectIdRaw = data["projectId"],
              let projectId = UUID(uuidString: projectIdRaw) else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }

        let mode = data["mode"] ?? "default"
        switch mode {
        case "terminal":
            createThread(for: project, requestedAgentType: nil, useAgentCommand: false)
        case "agent":
            let agentRaw = data["agentRaw"] ?? ""
            createThread(for: project, requestedAgentType: AgentType(rawValue: agentRaw), useAgentCommand: true)
        default:
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true)
        }
    }

    /// Called from SplitViewController's Cmd+N shortcut to respect the loading guard
    func requestNewThread() {
        addThreadTapped()
    }

    private func createThread(
        for project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true
    ) {
        isCreatingThread = true
        addButton.isEnabled = false

        performWithSpinner(message: "Creating thread...", errorTitle: "Creation Failed") {
            do {
                let thread = try await self.threadManager.createThread(
                    project: project,
                    requestedAgentType: requestedAgentType,
                    useAgentCommand: useAgentCommand
                )
                await MainActor.run {
                    self.isCreatingThread = false
                    self.addButton.isEnabled = true
                    self.delegate?.threadList(self, didSelectThread: thread)
                }
            } catch {
                await MainActor.run {
                    self.isCreatingThread = false
                    self.addButton.isEnabled = true
                }
                throw error
            }
        }
    }

    // MARK: - Helpers

    static func colorDotImage(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    // MARK: - Diff Panel

    func refreshDiffPanelForSelectedThread() {
        let row = outlineView.selectedRow
        guard row >= 0,
              let thread = outlineView.item(atRow: row) as? MagentThread else {
            diffPanelView.clear()
            return
        }
        refreshDiffPanel(for: thread)
    }

    func refreshDiffPanel(for thread: MagentThread) {
        Task {
            let entries = await threadManager.refreshDiffStats(for: thread.id)
            let baseBranch = threadManager.resolveBaseBranch(for: thread)
            await MainActor.run {
                self.diffPanelView.update(
                    with: entries,
                    branchName: thread.isMain ? nil : thread.branchName,
                    baseBranch: thread.isMain ? nil : baseBranch
                )
            }
        }
    }

}
