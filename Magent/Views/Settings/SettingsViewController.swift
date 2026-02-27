import Cocoa

// MARK: - Settings Category

enum SettingsCategory: Int, CaseIterable {
    case general, projects

    var title: String {
        switch self {
        case .general: return "General"
        case .projects: return "Projects"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .projects: return "folder"
        }
    }
}

// MARK: - SettingsSplitViewController

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarVC = SettingsSidebarViewController()
    private var currentCategory: SettingsCategory = .general

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 900, height: 640)

        sidebarVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 200
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailVC = detailViewController(for: .general)
        let contentItem = NSSplitViewItem(viewController: detailVC)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
    }

    override func cancelOperation(_ sender: Any?) {
        if let window = view.window, window.sheetParent == nil {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }

    private func detailViewController(for category: SettingsCategory) -> NSViewController {
        switch category {
        case .general: return SettingsGeneralViewController()
        case .projects: return SettingsProjectsViewController()
        }
    }

    fileprivate func showCategory(_ category: SettingsCategory) {
        guard category != currentCategory else { return }
        currentCategory = category

        let detailVC = detailViewController(for: category)
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }
        let contentItem = NSSplitViewItem(viewController: detailVC)
        addSplitViewItem(contentItem)
    }
}

// MARK: - SettingsSidebarDelegate

@MainActor
protocol SettingsSidebarDelegate: AnyObject {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory)
    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController)
}

extension SettingsSplitViewController: SettingsSidebarDelegate {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory) {
        showCategory(category)
    }

    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController) {
        if let window = view.window, window.sheetParent == nil {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }
}

// MARK: - SettingsSidebarViewController

final class SettingsSidebarViewController: NSViewController {

    weak var delegate: SettingsSidebarDelegate?
    private var tableView: NSTableView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.selectionHighlightStyle = .sourceList

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -8),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func doneTapped() {
        delegate?.settingsSidebarDidDismiss(self)
    }
}

extension SettingsSidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        SettingsCategory.allCases.count
    }
}

extension SettingsSidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let category = SettingsCategory.allCases[row]
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
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
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                iv.heightAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        cell.textField?.stringValue = category.title
        cell.imageView?.image = NSImage(systemSymbolName: category.symbolName, accessibilityDescription: category.title)
        cell.imageView?.contentTintColor = NSColor(resource: .textSecondary)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        delegate?.settingsSidebar(self, didSelect: SettingsCategory.allCases[row])
    }
}

// MARK: - SettingsGeneralViewController

final class SettingsGeneralViewController: NSViewController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var claudeCheckbox: NSButton!
    private var codexCheckbox: NSButton!
    private var customCheckbox: NSButton!
    private var defaultAgentSection: NSStackView!
    private var defaultAgentPopup: NSPopUpButton!
    private var customAgentSection: NSStackView!
    private var completionSoundCheckbox: NSButton!
    private var customAgentCommandTextView: NSTextView!
    private var terminalInjectionTextView: NSTextView!
    private var agentContextTextView: NSTextView!

    // Thread sections
    private var sectionsTableView: NSTableView!
    private var currentEditingSectionId: UUID?

    private var sortedSections: [ThreadSection] {
        settings.threadSections.sorted { $0.sortOrder < $1.sortOrder }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Defaults note
        let defaultsNote = NSTextField(
            wrappingLabelWithString: "These are the default settings for all projects. Individual projects can override them in the Projects tab."
        )
        defaultsNote.font = .systemFont(ofSize: 11)
        defaultsNote.textColor = NSColor(resource: .textSecondary)
        defaultsNote.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(defaultsNote)
        NSLayoutConstraint.activate([
            defaultsNote.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Notifications
        let notificationsSection = NSStackView()
        notificationsSection.orientation = .vertical
        notificationsSection.alignment = .leading
        notificationsSection.spacing = 6

        let notificationsLabel = NSTextField(labelWithString: "Notifications")
        notificationsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        notificationsSection.addArrangedSubview(notificationsLabel)

        let notificationsDesc = NSTextField(
            wrappingLabelWithString: "When an agent finishes a command, Magent sends a system notification and moves the thread to the top of its section."
        )
        notificationsDesc.font = .systemFont(ofSize: 11)
        notificationsDesc.textColor = NSColor(resource: .textSecondary)
        notificationsSection.addArrangedSubview(notificationsDesc)

        completionSoundCheckbox = NSButton(
            checkboxWithTitle: "Play sound for completion notifications",
            target: self,
            action: #selector(completionSoundToggled)
        )
        completionSoundCheckbox.state = settings.playSoundForAgentCompletion ? .on : .off
        notificationsSection.addArrangedSubview(completionSoundCheckbox)

        notificationsSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(notificationsSection)
        NSLayoutConstraint.activate([
            notificationsSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Active Agents
        let agentsSection = NSStackView()
        agentsSection.orientation = .vertical
        agentsSection.alignment = .leading
        agentsSection.spacing = 6

        let agentsLabel = NSTextField(labelWithString: "Active Agents")
        agentsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        agentsSection.addArrangedSubview(agentsLabel)

        let agentsDesc = NSTextField(
            wrappingLabelWithString: "Enable agents that can be launched in new chats. If multiple are enabled, a default can be chosen."
        )
        agentsDesc.font = .systemFont(ofSize: 11)
        agentsDesc.textColor = NSColor(resource: .textSecondary)
        agentsSection.addArrangedSubview(agentsDesc)

        claudeCheckbox = NSButton(checkboxWithTitle: AgentType.claude.displayName, target: self, action: #selector(activeAgentsChanged))
        codexCheckbox = NSButton(checkboxWithTitle: AgentType.codex.displayName, target: self, action: #selector(activeAgentsChanged))
        customCheckbox = NSButton(checkboxWithTitle: AgentType.custom.displayName, target: self, action: #selector(activeAgentsChanged))

        let active = Set(settings.availableActiveAgents)
        claudeCheckbox.state = active.contains(.claude) ? .on : .off
        codexCheckbox.state = active.contains(.codex) ? .on : .off
        customCheckbox.state = active.contains(.custom) ? .on : .off

        agentsSection.addArrangedSubview(claudeCheckbox)
        agentsSection.addArrangedSubview(codexCheckbox)
        agentsSection.addArrangedSubview(customCheckbox)

        agentsSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(agentsSection)
        NSLayoutConstraint.activate([
            agentsSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Default Agent
        defaultAgentSection = NSStackView()
        defaultAgentSection.orientation = .vertical
        defaultAgentSection.alignment = .leading
        defaultAgentSection.spacing = 4

        let defaultLabel = NSTextField(labelWithString: "Default Agent")
        defaultLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        defaultAgentSection.addArrangedSubview(defaultLabel)

        let defaultDesc = NSTextField(labelWithString: "Used when no agent is explicitly selected for a new chat.")
        defaultDesc.font = .systemFont(ofSize: 11)
        defaultDesc.textColor = NSColor(resource: .textSecondary)
        defaultAgentSection.addArrangedSubview(defaultDesc)

        defaultAgentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultAgentPopup.target = self
        defaultAgentPopup.action = #selector(defaultAgentChanged)
        defaultAgentSection.addArrangedSubview(defaultAgentPopup)

        defaultAgentSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(defaultAgentSection)
        NSLayoutConstraint.activate([
            defaultAgentSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])
        refreshDefaultAgentSection()

        // Custom Agent Command (only shown when Custom is active)
        customAgentSection = NSStackView()
        customAgentSection.orientation = .vertical
        customAgentSection.alignment = .leading
        customAgentSection.spacing = 4
        customAgentSection.translatesAutoresizingMaskIntoConstraints = false

        customAgentCommandTextView = createSection(
            in: customAgentSection,
            title: "Custom Agent Command",
            description: "Command used when the active agent is set to Custom.",
            value: settings.customAgentCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        stackView.addArrangedSubview(customAgentSection)
        NSLayoutConstraint.activate([
            customAgentSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])
        customAgentSection.isHidden = !active.contains(.custom)

        // Terminal Injection Command
        terminalInjectionTextView = createSection(
            in: stackView,
            title: "Terminal Injection Command",
            description: "Shell command auto-sent to every new terminal tab after creation.",
            value: settings.terminalInjectionCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Agent Context Injection
        agentContextTextView = createSection(
            in: stackView,
            title: "Agent Context Injection",
            description: "Text auto-typed into every new agent prompt after startup.",
            value: settings.agentContextInjection,
            font: .systemFont(ofSize: 13)
        )

        // Environment Variables reference
        let envHeader = NSTextField(labelWithString: "Environment Variables")
        envHeader.font = .systemFont(ofSize: 13, weight: .semibold)

        let envDesc = NSTextField(wrappingLabelWithString: "Available in injection commands:")
        envDesc.font = .systemFont(ofSize: 11)
        envDesc.textColor = NSColor(resource: .textSecondary)

        let envVars: [(String, String)] = [
            ("$MAGENT_WORKTREE_PATH", "Absolute path to the thread's git worktree directory"),
            ("$MAGENT_PROJECT_PATH", "Absolute path to the original git repository"),
            ("$MAGENT_WORKTREE_NAME", "Name of the current thread"),
            ("$MAGENT_PROJECT_NAME", "Name of the project (also usable in Worktrees Path)"),
        ]

        let envStack = NSStackView()
        envStack.orientation = .vertical
        envStack.alignment = .leading
        envStack.spacing = 4

        envStack.addArrangedSubview(envHeader)
        envStack.addArrangedSubview(envDesc)

        for (name, desc) in envVars {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            nameLabel.textColor = .systemGreen

            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = NSColor(resource: .textSecondary)

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(descLabel)
            envStack.addArrangedSubview(row)
        }

        stackView.addArrangedSubview(envStack)

        // Separator before Thread Sections
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Thread Sections
        let sectionsHeader = NSTextField(labelWithString: "Thread Sections")
        sectionsHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionsHeader.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsHeader)

        let sectionsDesc = NSTextField(wrappingLabelWithString: "Organize threads into sections in the sidebar. Click a color dot to change it. Drag to reorder.")
        sectionsDesc.font = .systemFont(ofSize: 11)
        sectionsDesc.textColor = NSColor(resource: .textSecondary)
        sectionsDesc.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsDesc)

        sectionsTableView = NSTableView()
        sectionsTableView.headerView = nil
        sectionsTableView.style = .inset
        sectionsTableView.rowSizeStyle = .default
        sectionsTableView.selectionHighlightStyle = .none
        sectionsTableView.registerForDraggedTypes([.string])
        sectionsTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let sectionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SectionColumn"))
        sectionsTableView.addTableColumn(sectionsColumn)
        sectionsTableView.dataSource = self
        sectionsTableView.delegate = self

        let sectionsScrollView = NSScrollView()
        sectionsScrollView.documentView = sectionsTableView
        sectionsScrollView.hasVerticalScroller = true
        sectionsScrollView.autohidesScrollers = true
        sectionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsScrollView)

        let addSectionButton = NSButton(title: "Add Section...", target: self, action: #selector(addSectionTapped))
        addSectionButton.bezelStyle = .rounded
        addSectionButton.controlSize = .small
        stackView.addArrangedSubview(addSectionButton)

        NSLayoutConstraint.activate([
            sectionsScrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            sectionsScrollView.heightAnchor.constraint(equalToConstant: 140),
        ])

        // Document view wrapper
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func createSection(
        in stackView: NSStackView,
        title: String,
        description: String,
        value: String,
        font: NSFont
    ) -> NSTextView {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 4

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionStack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        sectionStack.addArrangedSubview(descLabel)

        let textView = NSTextView()
        textView.font = font
        textView.string = value
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let textScrollView = NSScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        NSLayoutConstraint.activate([
            textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
        ])

        sectionStack.addArrangedSubview(textScrollView)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        NSLayoutConstraint.activate([
            textScrollView.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    // MARK: - Agent Actions

    @objc private func completionSoundToggled() {
        settings.playSoundForAgentCompletion = completionSoundCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func activeAgentsChanged() {
        var active: [AgentType] = []
        if claudeCheckbox.state == .on { active.append(.claude) }
        if codexCheckbox.state == .on { active.append(.codex) }
        if customCheckbox.state == .on { active.append(.custom) }
        settings.activeAgents = active

        if active.count <= 1 {
            settings.defaultAgentType = nil
        } else if let defaultAgent = settings.defaultAgentType, !active.contains(defaultAgent) {
            settings.defaultAgentType = active.first
        } else if settings.defaultAgentType == nil {
            settings.defaultAgentType = active.first
        }

        refreshDefaultAgentSection()
        customAgentSection.isHidden = !active.contains(.custom)
        try? persistence.saveSettings(settings)
    }

    @objc private func defaultAgentChanged() {
        let active = settings.availableActiveAgents
        let index = defaultAgentPopup.indexOfSelectedItem
        guard index >= 0, index < active.count else { return }
        settings.defaultAgentType = active[index]
        try? persistence.saveSettings(settings)
    }

    private func refreshDefaultAgentSection() {
        let active = settings.availableActiveAgents
        defaultAgentPopup.removeAllItems()
        for agent in active {
            defaultAgentPopup.addItem(withTitle: agent.displayName)
        }

        defaultAgentSection.isHidden = active.count <= 1
        guard active.count > 1 else { return }

        let currentDefault = settings.defaultAgentType.flatMap { active.contains($0) ? $0 : nil } ?? active[0]
        settings.defaultAgentType = currentDefault
        if let idx = active.firstIndex(of: currentDefault) {
            defaultAgentPopup.selectItem(at: idx)
        }
    }

    // MARK: - Thread Section Actions

    @objc private func addSectionTapped() {
        let alert = NSAlert()
        alert.messageText = "New Section"
        alert.informativeText = "Enter section name"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Section name"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = textField.stringValue
        guard !name.isEmpty else { return }

        let maxOrder = settings.threadSections.map(\.sortOrder).max() ?? -1
        let section = ThreadSection(
            name: name,
            colorHex: "#8E8E93",
            sortOrder: maxOrder + 1
        )
        settings.threadSections.append(section)
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()

        showColorPicker(for: section)
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard let index = settings.threadSections.firstIndex(where: { $0.id == section.id }) else { return }

        if section.isVisible {
            let knownSectionIds = Set(settings.threadSections.map(\.id))
            let defaultSectionId = settings.defaultSection?.id
            let threadsInSection = ThreadManager.shared.threads.filter { thread in
                guard !thread.isMain else { return false }
                let effectiveSectionId: UUID?
                if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                    effectiveSectionId = sid
                } else {
                    effectiveSectionId = defaultSectionId
                }
                return effectiveSectionId == section.id
            }
            if !threadsInSection.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Cannot Hide Section"
                alert.informativeText = "Move all threads out of \"\(section.name)\" before hiding it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }

        settings.threadSections[index].isVisible.toggle()
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func deleteSectionTapped(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard !section.isDefault else { return }

        if let defaultSection = settings.defaultSection {
            ThreadManager.shared.reassignThreads(fromSection: section.id, toSection: defaultSection.id)
        }

        settings.threadSections.removeAll { $0.id == section.id }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    @objc private func colorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }
        showColorPicker(for: sortedSections[row])
    }

    private func showColorPicker(for section: ThreadSection) {
        let panel = NSColorPanel.shared
        panel.color = section.color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        currentEditingSectionId = section.id
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let sectionId = currentEditingSectionId,
              let index = settings.threadSections.firstIndex(where: { $0.id == sectionId }) else { return }

        settings.threadSections[index].colorHex = sender.color.hexString
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    static func colorDotImage(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === customAgentCommandTextView {
            settings.customAgentCommand = textView.string
        } else if textView === terminalInjectionTextView {
            settings.terminalInjectionCommand = textView.string
        } else if textView === agentContextTextView {
            settings.agentContextInjection = textView.string
        }

        try? persistence.saveSettings(settings)
    }

    // MARK: - Thread Sections Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedSections.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: .string),
              let sourceRow = Int(rowStr) else { return false }

        var sections = sortedSections
        let moved = sections.remove(at: sourceRow)
        let dest = sourceRow < row ? row - 1 : row
        sections.insert(moved, at: dest)

        for (i, section) in sections.enumerated() {
            if let idx = settings.threadSections.firstIndex(where: { $0.id == section.id }) {
                settings.threadSections[idx].sortOrder = i
            }
        }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sortedSections[row]
        let identifier = NSUserInterfaceItemIdentifier("AppearanceSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.tag = 100
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.tag = 101
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.tag = 102
            delBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(delBtn)

            NSLayoutConstraint.activate([
                colorBtn.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                colorBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                colorBtn.widthAnchor.constraint(equalToConstant: 16),
                colorBtn.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: colorBtn.trailingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                delBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                delBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -4),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        cell.textField?.stringValue = section.name

        if let colorBtn = cell.viewWithTag(100) as? NSButton {
            colorBtn.image = Self.colorDotImage(color: section.color, size: 12)
            colorBtn.target = self
            colorBtn.action = #selector(colorDotClicked(_:))
        }

        if let visBtn = cell.viewWithTag(101) as? NSButton {
            let symbolName = section.isVisible ? "eye" : "eye.slash"
            visBtn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visBtn.contentTintColor = section.isVisible ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
            visBtn.target = self
            visBtn.action = #selector(visibilityToggled(_:))
        }

        if let delBtn = cell.viewWithTag(102) as? NSButton {
            delBtn.isHidden = section.isDefault
            delBtn.target = self
            delBtn.action = #selector(deleteSectionTapped(_:))
        }

        return cell
    }
}

// MARK: - SettingsProjectsViewController

final class SettingsProjectsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!

    private var projectTableView: NSTableView!
    private var detailScrollView: NSScrollView!
    private var emptyLabel: NSTextField!

    // Detail fields
    private var nameField: NSTextField!
    private var repoPathLabel: NSTextField!
    private var worktreesPathLabel: NSTextField!
    private var defaultBranchField: NSTextField!
    private var agentTypePopup: NSPopUpButton!
    private var terminalInjectionTextView: NSTextView!
    private var agentContextTextView: NSTextView!

    private var selectedProjectIndex: Int? {
        let row = projectTableView.selectedRow
        return row >= 0 ? row : nil
    }

    private var selectedProject: Project? {
        guard let index = selectedProjectIndex, index < settings.projects.count else { return nil }
        return settings.projects[index]
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        setupProjectList()
        setupDetailPane()
        setupLayout()
    }

    private func setupProjectList() {
        projectTableView = NSTableView()
        projectTableView.headerView = nil
        projectTableView.style = .inset
        projectTableView.rowSizeStyle = .default
        projectTableView.selectionHighlightStyle = .regular

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectColumn"))
        projectTableView.addTableColumn(column)
        projectTableView.dataSource = self
        projectTableView.delegate = self
    }

    private func setupDetailPane() {
        detailScrollView = NSScrollView()
        detailScrollView.hasVerticalScroller = true
        detailScrollView.autohidesScrollers = true
        detailScrollView.drawsBackground = false
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Select a project")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = NSColor(resource: .textSecondary)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupLayout() {
        // Left: project list with add/remove buttons
        let listScrollView = NSScrollView()
        listScrollView.documentView = projectTableView
        listScrollView.hasVerticalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addProjectTapped))
        addButton.bezelStyle = .smallSquare
        addButton.isBordered = false

        let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeProjectTapped))
        removeButton.bezelStyle = .smallSquare
        removeButton.isBordered = false

        let buttonBar = NSStackView(views: [addButton, removeButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 0
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(listScrollView)
        leftPane.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            listScrollView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor, constant: 4),
            buttonBar.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor, constant: -4),
        ])

        // Right: scrollable detail or empty state
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(detailScrollView)
        rightPane.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            detailScrollView.topAnchor.constraint(equalTo: rightPane.topAnchor),
            detailScrollView.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            detailScrollView.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            detailScrollView.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: rightPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rightPane.centerYAnchor),
        ])

        view.addSubview(leftPane)
        view.addSubview(rightPane)

        NSLayoutConstraint.activate([
            leftPane.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            leftPane.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            leftPane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            leftPane.widthAnchor.constraint(equalToConstant: 180),

            rightPane.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            rightPane.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: 12),
            rightPane.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            rightPane.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        showEmptyState()
    }

    private func showEmptyState() {
        detailScrollView.isHidden = true
        emptyLabel.isHidden = false
    }

    private func showDetailForProject(_ project: Project) {
        detailScrollView.isHidden = false
        emptyLabel.isHidden = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 20, right: 0)

        // Name
        let nameHeader = NSTextField(labelWithString: "Name")
        nameHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(nameHeader)

        nameField = NSTextField(string: project.name)
        nameField.font = .systemFont(ofSize: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(nameFieldChanged)
        stack.addArrangedSubview(nameField)

        // Repo path
        let repoHeader = NSTextField(labelWithString: "Repository Path")
        repoHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(repoHeader)

        let repoRow = NSStackView()
        repoRow.orientation = .horizontal
        repoRow.spacing = 8
        repoPathLabel = NSTextField(labelWithString: project.repoPath)
        repoPathLabel.font = .systemFont(ofSize: 12)
        repoPathLabel.textColor = project.isValid ? NSColor(resource: .textSecondary) : .systemRed
        repoPathLabel.lineBreakMode = .byTruncatingMiddle
        repoRow.addArrangedSubview(repoPathLabel)
        let browseRepoBtn = NSButton(title: "Browse...", target: self, action: #selector(browseRepoPath))
        browseRepoBtn.bezelStyle = .rounded
        browseRepoBtn.controlSize = .small
        repoRow.addArrangedSubview(browseRepoBtn)
        stack.addArrangedSubview(repoRow)

        if !project.isValid {
            let warningLabel = NSTextField(labelWithString: "Path does not exist. Update the repository path.")
            warningLabel.font = .systemFont(ofSize: 11)
            warningLabel.textColor = .systemRed
            stack.addArrangedSubview(warningLabel)
        }

        // Worktrees path
        let wtHeader = NSTextField(labelWithString: "Worktrees Path")
        wtHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(wtHeader)

        let wtRow = NSStackView()
        wtRow.orientation = .horizontal
        wtRow.spacing = 8
        worktreesPathLabel = NSTextField(labelWithString: project.worktreesBasePath)
        worktreesPathLabel.font = .systemFont(ofSize: 12)
        worktreesPathLabel.textColor = NSColor(resource: .textSecondary)
        worktreesPathLabel.lineBreakMode = .byTruncatingMiddle
        wtRow.addArrangedSubview(worktreesPathLabel)
        let browseWtBtn = NSButton(title: "Browse...", target: self, action: #selector(browseWorktreesPath))
        browseWtBtn.bezelStyle = .rounded
        browseWtBtn.controlSize = .small
        wtRow.addArrangedSubview(browseWtBtn)
        stack.addArrangedSubview(wtRow)

        let resolved = project.resolvedWorktreesBasePath()
        if resolved != project.worktreesBasePath {
            let resolvedLabel = NSTextField(labelWithString: "Resolves to: \(resolved)")
            resolvedLabel.font = .systemFont(ofSize: 11)
            resolvedLabel.textColor = NSColor(resource: .textSecondary)
            resolvedLabel.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(resolvedLabel)
        }

        // Default branch
        let branchHeader = NSTextField(labelWithString: "Default Branch")
        branchHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(branchHeader)

        let branchDesc = NSTextField(labelWithString: "Base branch for new worktrees (empty = repo HEAD)")
        branchDesc.font = .systemFont(ofSize: 11)
        branchDesc.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(branchDesc)

        defaultBranchField = NSTextField(string: project.defaultBranch ?? "")
        defaultBranchField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        defaultBranchField.placeholderString = "e.g. develop, main"
        defaultBranchField.translatesAutoresizingMaskIntoConstraints = false
        defaultBranchField.target = self
        defaultBranchField.action = #selector(defaultBranchFieldChanged)
        stack.addArrangedSubview(defaultBranchField)

        // Separator: Project Overrides
        let overrideSep = NSBox()
        overrideSep.boxType = .separator
        overrideSep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(overrideSep)

        let overrideHeader = NSTextField(labelWithString: "Project Overrides")
        overrideHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(overrideHeader)

        let overrideDesc = NSTextField(
            wrappingLabelWithString: "Override global defaults for this project. \"Use Default\" inherits the value from General settings."
        )
        overrideDesc.font = .systemFont(ofSize: 11)
        overrideDesc.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(overrideDesc)

        // Agent type override
        let agentTypeHeader = NSTextField(labelWithString: "Default Agent")
        agentTypeHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(agentTypeHeader)

        agentTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let globalDefault = settings.effectiveGlobalDefaultAgentType
        let globalDefaultName = globalDefault?.displayName ?? "None"
        agentTypePopup.addItem(withTitle: "Use Default (\(globalDefaultName))")
        for agentType in settings.availableActiveAgents {
            agentTypePopup.addItem(withTitle: agentType.displayName)
        }

        if let projectAgentType = project.agentType,
           let idx = settings.availableActiveAgents.firstIndex(of: projectAgentType) {
            agentTypePopup.selectItem(at: idx + 1)
        } else {
            agentTypePopup.selectItem(at: 0)
        }
        agentTypePopup.target = self
        agentTypePopup.action = #selector(agentTypeOverrideChanged)
        stack.addArrangedSubview(agentTypePopup)

        // Terminal Injection Override
        let globalTerminal = settings.terminalInjectionCommand
        let terminalDesc = globalTerminal.isEmpty
            ? "No global default set"
            : "Global default: \(globalTerminal.prefix(60))\(globalTerminal.count > 60 ? "..." : "")"
        terminalInjectionTextView = createOverrideSection(
            in: stack,
            title: "Terminal Injection",
            description: "Empty = use global default. \(terminalDesc)",
            value: project.terminalInjectionCommand ?? "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Agent Context Override
        let globalContext = settings.agentContextInjection
        let contextDesc = globalContext.isEmpty
            ? "No global default set"
            : "Global default: \(globalContext.prefix(60))\(globalContext.count > 60 ? "..." : "")"
        agentContextTextView = createOverrideSection(
            in: stack,
            title: "Agent Context",
            description: "Empty = use global default. \(contextDesc)",
            value: project.agentContextInjection ?? "",
            font: .systemFont(ofSize: 13)
        )

        // Set up the document view for scrolling
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        detailScrollView.documentView = documentView

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: detailScrollView.widthAnchor),

            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repoRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wtRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            defaultBranchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overrideSep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overrideDesc.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func createOverrideSection(
        in stackView: NSStackView,
        title: String,
        description: String,
        value: String,
        font: NSFont
    ) -> NSTextView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stackView.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        stackView.addArrangedSubview(descLabel)

        let textView = NSTextView()
        textView.font = font
        textView.string = value
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let textScrollView = NSScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        NSLayoutConstraint.activate([
            textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            textScrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])

        stackView.addArrangedSubview(textScrollView)

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    // MARK: - Actions

    @objc private func addProjectTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository folder"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path

            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        let project = Project(
                            name: url.lastPathComponent,
                            repoPath: path,
                            worktreesBasePath: Project.suggestedWorktreesPath(for: path),
                            defaultBranch: defaultBranch
                        )
                        self.settings.projects.append(project)
                        try? self.persistence.saveSettings(self.settings)
                        self.projectTableView.reloadData()

                        Task { try? await ThreadManager.shared.createMainThread(project: project) }
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Not a Git Repository"
                        alert.informativeText = "The selected folder is not a git repository."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func removeProjectTapped() {
        guard let index = selectedProjectIndex else { return }
        let project = settings.projects[index]

        let alert = NSAlert()
        alert.messageText = "Remove Project?"
        alert.informativeText = "Remove \"\(project.name)\" from Magent? This won't delete the repository."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        settings.projects.remove(at: index)
        try? persistence.saveSettings(settings)
        projectTableView.reloadData()
        showEmptyState()
    }

    @objc private func nameFieldChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        settings.projects[index].name = value
        try? persistence.saveSettings(settings)
        projectTableView.reloadData()
    }

    @objc private func defaultBranchFieldChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = defaultBranchField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.projects[index].defaultBranch = value.isEmpty ? nil : value
        try? persistence.saveSettings(settings)
    }

    @objc private func agentTypeOverrideChanged() {
        guard let index = selectedProjectIndex, let agentTypePopup else { return }
        let activeAgents = settings.availableActiveAgents
        let selected = agentTypePopup.indexOfSelectedItem
        if selected == 0 {
            settings.projects[index].agentType = nil
        } else {
            let typeIndex = selected - 1
            if typeIndex >= 0, typeIndex < activeAgents.count {
                settings.projects[index].agentType = activeAgents[typeIndex]
            }
        }
        try? persistence.saveSettings(settings)
    }

    @objc private func browseRepoPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.projects[index].repoPath)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path
            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        self.settings.projects[index].repoPath = path
                        self.settings.projects[index].defaultBranch = defaultBranch
                        try? self.persistence.saveSettings(self.settings)
                        self.projectTableView.reloadData()
                        self.showDetailForProject(self.settings.projects[index])
                        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                        Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index]) }
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Not a Git Repository"
                        alert.informativeText = "The selected folder is not a git repository."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func browseWorktreesPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let resolved = settings.projects[index].resolvedWorktreesBasePath()
        panel.directoryURL = URL(fileURLWithPath: resolved)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.projects[index].worktreesBasePath = url.path
            try? self.persistence.saveSettings(self.settings)
            self.showDetailForProject(self.settings.projects[index])
            Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index]) }
        }
    }
}

extension SettingsProjectsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        settings.projects.count
    }
}

extension SettingsProjectsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = settings.projects[row]
        let identifier = NSUserInterfaceItemIdentifier("ProjectListCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        cell.textField?.stringValue = project.name
        cell.textField?.textColor = project.isValid ? .labelColor : .systemRed
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let project = selectedProject else {
            showEmptyState()
            return
        }
        showDetailForProject(project)
    }
}

extension SettingsProjectsViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let index = selectedProjectIndex else { return }

        if textView === terminalInjectionTextView {
            let value = textView.string
            settings.projects[index].terminalInjectionCommand = value.isEmpty ? nil : value
        } else if textView === agentContextTextView {
            let value = textView.string
            settings.projects[index].agentContextInjection = value.isEmpty ? nil : value
        }

        try? persistence.saveSettings(settings)
    }
}
