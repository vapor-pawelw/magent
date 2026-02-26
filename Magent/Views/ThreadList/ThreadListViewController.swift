import Cocoa

protocol ThreadListDelegate: AnyObject {
    func threadList(_ controller: ThreadListViewController, didSelectThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didRenameThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didArchiveThread thread: MagentThread)
    func threadList(_ controller: ThreadListViewController, didDeleteThread thread: MagentThread)
    func threadListDidRequestSettings(_ controller: ThreadListViewController)
}

final class ThreadListViewController: NSViewController {

    private static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"

    weak var delegate: ThreadListDelegate?

    private var outlineView: NSOutlineView!
    private var scrollView: NSScrollView!
    private let threadManager = ThreadManager.shared
    private let persistence = PersistenceService.shared

    private var addButton: NSButton!
    private var isCreatingThread = false

    // MARK: - Data Model (3-level hierarchy)
    // Level 0: SidebarProject (project name header)
    // Level 1: MagentThread (main) or SidebarSection (section header)
    // Level 2: MagentThread (regular threads under a section)

    private var sidebarProjects: [SidebarProject] = []

    class SidebarProject {
        let projectId: UUID
        let name: String
        var children: [Any] // Mix of MagentThread (main) and SidebarSection

        init(projectId: UUID, name: String, children: [Any]) {
            self.projectId = projectId
            self.name = name
            self.children = children
        }
    }

    class SidebarSection {
        let sectionId: UUID
        let name: String
        let color: NSColor
        var threads: [MagentThread]

        init(sectionId: UUID, name: String, color: NSColor, threads: [MagentThread]) {
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
    }

    // MARK: - Toolbar Buttons

    private func setupToolbar() {
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Thread")!, target: self, action: #selector(addThreadTapped))
        addButton.bezelStyle = .texturedRounded

        let buttonBar = NSStackView(views: [NSView(), addButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 4
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        view.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            buttonBar.topAnchor.constraint(equalTo: view.topAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    // MARK: - Outline View

    private func setupOutlineView() {
        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = true
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThreadColumn"))
        column.title = "Threads"
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 4, right: 0)

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Data

    private func reloadData() {
        // Remember current selection
        let selectedThreadId: UUID? = {
            let row = outlineView.selectedRow
            guard row >= 0, let thread = outlineView.item(atRow: row) as? MagentThread else { return nil }
            return thread.id
        }()

        let settings = persistence.loadSettings()
        let visibleSections = settings.visibleSections
        let allThreads = threadManager.threads
        let mainThreads = allThreads.filter { $0.isMain }
        let regularThreads = allThreads.filter { !$0.isMain }

        let knownSectionIds = Set(settings.threadSections.map(\.id))
        let defaultSectionId = settings.defaultSection?.id

        sidebarProjects = settings.projects.map { project in
            var children: [Any] = []

            // Main thread(s) for this project first
            let projectMainThreads = mainThreads.filter { $0.projectId == project.id }
            children.append(contentsOf: projectMainThreads)

            // Section groups with regular threads
            for section in visibleSections {
                let matchingThreads = regularThreads.filter { thread in
                    guard thread.projectId == project.id else { return false }
                    let effectiveSectionId: UUID?
                    if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                        effectiveSectionId = sid
                    } else {
                        effectiveSectionId = defaultSectionId
                    }
                    return effectiveSectionId == section.id
                }
                children.append(SidebarSection(
                    sectionId: section.id,
                    name: section.name,
                    color: section.color,
                    threads: matchingThreads
                ))
            }

            return SidebarProject(
                projectId: project.id,
                name: project.name,
                children: children
            )
        }

        outlineView.reloadData()

        // Expand everything
        for project in sidebarProjects {
            outlineView.expandItem(project)
            for child in project.children {
                if child is SidebarSection {
                    outlineView.expandItem(child)
                }
            }
        }

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

    private func autoSelectFirst() {
        if let threadIdRaw = UserDefaults.standard.string(forKey: Self.lastOpenedThreadDefaultsKey),
           let threadId = UUID(uuidString: threadIdRaw) {
            for row in 0..<outlineView.numberOfRows {
                if let thread = outlineView.item(atRow: row) as? MagentThread, thread.id == threadId {
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
        let activeAgents = settings.availableActiveAgents

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
            if activeAgents.count > 1 {
                presentProjectAgentMenu(project: project)
            } else {
                createThread(for: project)
            }
        } else {
            let menu = NSMenu()
            for project in projects {
                if activeAgents.count > 1 {
                    let item = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
                    item.submenu = buildAgentSubmenu(for: project, activeAgents: activeAgents)
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: project.name, action: #selector(projectMenuItemSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = project
                    menu.addItem(item)
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: addButton.bounds.minX, y: addButton.bounds.minY), in: addButton)
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
            defaultItem.representedObject = ["projectId": project.id.uuidString, "agentRaw": ""] as [String: String]
            submenu.addItem(defaultItem)
            submenu.addItem(.separator())
        }

        for agent in activeAgents {
            let item = NSMenuItem(title: agent.displayName, action: #selector(projectAgentMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["projectId": project.id.uuidString, "agentRaw": agent.rawValue] as [String: String]
            submenu.addItem(item)
        }

        return submenu
    }

    @objc private func projectMenuItemSelected(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? Project else { return }
        createThread(for: project)
    }

    @objc private func projectAgentMenuItemSelected(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? [String: String],
              let projectIdRaw = data["projectId"],
              let projectId = UUID(uuidString: projectIdRaw) else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }

        let agentRaw = data["agentRaw"] ?? ""
        createThread(for: project, requestedAgentType: AgentType(rawValue: agentRaw))
    }

    /// Called from SplitViewController's Cmd+N shortcut to respect the loading guard
    func requestNewThread() {
        addThreadTapped()
    }

    private func createThread(for project: Project, requestedAgentType: AgentType? = nil) {
        isCreatingThread = true
        addButton.isEnabled = false

        performWithSpinner(message: "Creating thread...", errorTitle: "Creation Failed") {
            do {
                let thread = try await self.threadManager.createThread(
                    project: project,
                    requestedAgentType: requestedAgentType
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

    // MARK: - Context Menu

    private func buildContextMenu(for thread: MagentThread) -> NSMenu {
        let menu = NSMenu()

        // Main threads: no context menu
        if thread.isMain { return menu }

        // Move to... submenu
        let settings = persistence.loadSettings()
        let visibleSections = settings.visibleSections.filter { $0.id != thread.sectionId }

        let moveSubmenu = NSMenu()
        for section in visibleSections {
            let item = NSMenuItem(title: section.name, action: #selector(moveThreadToSection(_:)), keyEquivalent: "")
            item.target = self
            item.image = Self.colorDotImage(color: section.color, size: 8)
            item.representedObject = ["thread": thread, "sectionId": section.id] as [String: Any]
            moveSubmenu.addItem(item)
        }

        let moveItem = NSMenuItem(title: "Move to...", action: nil, keyEquivalent: "")
        moveItem.submenu = moveSubmenu
        moveItem.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        menu.addItem(moveItem)

        // Rename
        let renameItem = NSMenuItem(title: "Rename...", action: #selector(renameThread(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = thread
        menu.addItem(renameItem)

        menu.addItem(NSMenuItem.separator())

        // Archive
        let archiveItem = NSMenuItem(title: "Archive...", action: #selector(archiveThread(_:)), keyEquivalent: "")
        archiveItem.target = self
        archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        archiveItem.representedObject = thread
        menu.addItem(archiveItem)

        // Delete (destructive)
        let deleteItem = NSMenuItem(title: "Delete...", action: #selector(deleteThread(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteItem.representedObject = thread
        menu.addItem(deleteItem)

        return menu
    }

    @objc private func moveThreadToSection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let sectionId = info["sectionId"] as? UUID else { return }
        threadManager.moveThread(thread, toSection: sectionId)
        reloadData()
    }

    @objc private func renameThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Thread"
        alert.informativeText = "Enter new name for the thread"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = thread.name
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != thread.name else { return }

        Task {
            do {
                try await threadManager.renameThread(thread, to: newName)
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == thread.id }) {
                        self.delegate?.threadList(self, didRenameThread: updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Rename Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func archiveThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Archive Thread"
        alert.informativeText = "This will archive the thread \"\(thread.name)\", removing its worktree directory but keeping the git branch \"\(thread.branchName)\". You can restore the branch later if needed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
            try await self.threadManager.archiveThread(thread)
        }
    }

    @objc private func deleteThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Thread"
        alert.informativeText = "This will permanently delete the thread \"\(thread.name)\", including its worktree directory and git branch \"\(thread.branchName)\". This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performWithSpinner(message: "Deleting thread...", errorTitle: "Delete Failed") {
            try await self.threadManager.deleteThread(thread)
        }
    }

    private func performWithSpinner(message: String, errorTitle: String, work: @escaping () async throws -> Void) {
        guard let window = view.window else { return }

        // Build a small sheet with a spinner and label
        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: sheetVC.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: sheetVC.view.centerYAnchor),
        ])

        window.contentViewController?.presentAsSheet(sheetVC)

        Task {
            do {
                try await work()
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                }
            } catch {
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                    let alert = NSAlert()
                    alert.messageText = errorTitle
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension ThreadListViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sidebarProjects.count }
        if let project = item as? SidebarProject { return project.children.count }
        if let section = item as? SidebarSection { return section.threads.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return sidebarProjects[index] }
        if let project = item as? SidebarProject { return project.children[index] }
        if let section = item as? SidebarSection { return section.threads[index] }
        fatalError("Unexpected item")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarProject || item is SidebarSection
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
        guard item is SidebarSection else { return [] }
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

        threadManager.moveThread(thread, toSection: section.sectionId)
        reloadData()
        return true
    }
}

// MARK: - NSOutlineViewDelegate

extension ThreadListViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarProject
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is MagentThread
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        // Level 0: Project header
        if let project = item as? SidebarProject {
            let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? {
                    let c = NSTableCellView()
                    c.identifier = identifier
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    c.addSubview(tf)
                    c.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])
                    return c
                }()

            cell.textField?.stringValue = project.name.uppercased()
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .tertiaryLabelColor
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

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 8),
                        iv.heightAnchor.constraint(equalToConstant: 8),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])
                    return c
                }()

            cell.textField?.stringValue = section.name.uppercased()
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .tertiaryLabelColor
            cell.imageView?.image = Self.colorDotImage(color: section.color, size: 8)
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
                            tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                            tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        ])

                        return c
                    }()

                (cell as? ThreadCell)?.configureAsMain()
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

                    NSLayoutConstraint.activate([
                        iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                        iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                        iv.widthAnchor.constraint(equalToConstant: 16),
                        iv.heightAnchor.constraint(equalToConstant: 16),
                        tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    ])

                    return c
                }()

            let settings = persistence.loadSettings()
            let sections = settings.threadSections
            let section = sections.first(where: { $0.id == thread.sectionId })
            (cell as? ThreadCell)?.configure(with: thread, sectionColor: section?.color)
            return cell
        }

        return nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0,
              let thread = outlineView.item(atRow: row) as? MagentThread else { return }
        UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
        delegate?.threadList(self, didSelectThread: thread)
    }
}

// MARK: - NSMenuDelegate

extension ThreadListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0,
              let thread = outlineView.item(atRow: clickedRow) as? MagentThread else { return }

        let contextMenu = buildContextMenu(for: thread)
        for item in contextMenu.items {
            contextMenu.removeItem(item)
            menu.addItem(item)
        }
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
    }
}
