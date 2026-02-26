import Cocoa

// MARK: - Settings Category

enum SettingsCategory: Int, CaseIterable {
    case general, projects, appearance

    var title: String {
        switch self {
        case .general: return "General"
        case .projects: return "Projects"
        case .appearance: return "Appearance"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .projects: return "folder"
        case .appearance: return "paintpalette"
        }
    }
}

// MARK: - SettingsSplitViewController

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarVC = SettingsSidebarViewController()
    private var currentCategory: SettingsCategory = .general

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: 760, height: 520)

        sidebarVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 200
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detailVC = detailViewController(for: .general)
        let contentItem = NSSplitViewItem(viewController: detailVC)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
    }

    private func detailViewController(for category: SettingsCategory) -> NSViewController {
        switch category {
        case .general: return SettingsGeneralViewController()
        case .projects: return SettingsProjectsViewController()
        case .appearance: return SettingsAppearanceViewController()
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

protocol SettingsSidebarDelegate: AnyObject {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory)
    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController)
}

extension SettingsSplitViewController: SettingsSidebarDelegate {
    func settingsSidebar(_ sidebar: SettingsSidebarViewController, didSelect category: SettingsCategory) {
        showCategory(category)
    }

    func settingsSidebarDidDismiss(_ sidebar: SettingsSidebarViewController) {
        dismiss(nil)
    }
}

// MARK: - SettingsSidebarViewController

final class SettingsSidebarViewController: NSViewController {

    weak var delegate: SettingsSidebarDelegate?
    private var tableView: NSTableView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 520))
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
        // Select first row by default
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
        cell.imageView?.contentTintColor = .secondaryLabelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        delegate?.settingsSidebar(self, didSelect: SettingsCategory.allCases[row])
    }
}

// MARK: - SettingsGeneralViewController

final class SettingsGeneralViewController: NSViewController, NSTextViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var agentCommandTextView: NSTextView!
    private var terminalInjectionTextView: NSTextView!
    private var agentContextTextView: NSTextView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
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

        // Agent Command
        agentCommandTextView = createSection(
            in: stackView,
            title: "Agent Command",
            description: "Command to start the coding agent in new threads.",
            value: settings.agentCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

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
        envDesc.textColor = .secondaryLabelColor

        let envVars: [(String, String)] = [
            ("$WORKTREE_PATH", "Absolute path to the thread's git worktree directory"),
            ("$PROJECT_PATH", "Absolute path to the original git repository"),
            ("$WORKTREE_NAME", "Name of the current thread"),
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
            descLabel.textColor = .secondaryLabelColor

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(descLabel)
            envStack.addArrangedSubview(row)
        }

        stackView.addArrangedSubview(envStack)

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
        descLabel.textColor = .secondaryLabelColor
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

        // 3-line height
        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        NSLayoutConstraint.activate([
            textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: height),
        ])

        sectionStack.addArrangedSubview(textScrollView)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        // Make text scroll view fill width
        NSLayoutConstraint.activate([
            textScrollView.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === agentCommandTextView {
            let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                settings.agentCommand = value
            }
        } else if textView === terminalInjectionTextView {
            settings.terminalInjectionCommand = textView.string
        } else if textView === agentContextTextView {
            settings.agentContextInjection = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}

// MARK: - SettingsProjectsViewController

final class SettingsProjectsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!

    private var projectTableView: NSTableView!
    private var detailContainer: NSView!
    private var emptyLabel: NSTextField!

    // Detail fields
    private var nameField: NSTextField!
    private var repoPathLabel: NSTextField!
    private var worktreesPathLabel: NSTextField!
    private var defaultBranchField: NSTextField!
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
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
        detailContainer = NSView()
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: "Select a project")
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .secondaryLabelColor
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

        // Right: detail or empty state
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.addSubview(detailContainer)
        rightPane.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            detailContainer.topAnchor.constraint(equalTo: rightPane.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
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
        detailContainer.isHidden = true
        emptyLabel.isHidden = false
    }

    private func showDetailForProject(_ project: Project) {
        // Remove old detail subviews
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        detailContainer.isHidden = false
        emptyLabel.isHidden = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

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
        repoPathLabel.textColor = .secondaryLabelColor
        repoPathLabel.lineBreakMode = .byTruncatingMiddle
        repoRow.addArrangedSubview(repoPathLabel)
        let browseRepoBtn = NSButton(title: "Browse...", target: self, action: #selector(browseRepoPath))
        browseRepoBtn.bezelStyle = .rounded
        browseRepoBtn.controlSize = .small
        repoRow.addArrangedSubview(browseRepoBtn)
        stack.addArrangedSubview(repoRow)

        // Worktrees path
        let wtHeader = NSTextField(labelWithString: "Worktrees Path")
        wtHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(wtHeader)

        let wtRow = NSStackView()
        wtRow.orientation = .horizontal
        wtRow.spacing = 8
        worktreesPathLabel = NSTextField(labelWithString: project.worktreesBasePath)
        worktreesPathLabel.font = .systemFont(ofSize: 12)
        worktreesPathLabel.textColor = .secondaryLabelColor
        worktreesPathLabel.lineBreakMode = .byTruncatingMiddle
        wtRow.addArrangedSubview(worktreesPathLabel)
        let browseWtBtn = NSButton(title: "Browse...", target: self, action: #selector(browseWorktreesPath))
        browseWtBtn.bezelStyle = .rounded
        browseWtBtn.controlSize = .small
        wtRow.addArrangedSubview(browseWtBtn)
        stack.addArrangedSubview(wtRow)

        // Default branch
        let branchHeader = NSTextField(labelWithString: "Default Branch")
        branchHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(branchHeader)

        let branchDesc = NSTextField(labelWithString: "Base branch for new worktrees (empty = repo HEAD)")
        branchDesc.font = .systemFont(ofSize: 11)
        branchDesc.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(branchDesc)

        defaultBranchField = NSTextField(string: project.defaultBranch ?? "")
        defaultBranchField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        defaultBranchField.placeholderString = "e.g. develop, main"
        defaultBranchField.translatesAutoresizingMaskIntoConstraints = false
        defaultBranchField.target = self
        defaultBranchField.action = #selector(defaultBranchFieldChanged)
        stack.addArrangedSubview(defaultBranchField)

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)

        // Terminal Injection Override
        terminalInjectionTextView = createOverrideSection(
            in: stack,
            title: "Terminal Injection Override",
            description: "Empty = use global setting",
            value: project.terminalInjectionCommand ?? "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            tag: 200
        )

        // Agent Context Override
        agentContextTextView = createOverrideSection(
            in: stack,
            title: "Agent Context Override",
            description: "Empty = use global setting",
            value: project.agentContextInjection ?? "",
            font: .systemFont(ofSize: 13),
            tag: 201
        )

        detailContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            repoRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wtRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            defaultBranchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func createOverrideSection(
        in stackView: NSStackView,
        title: String,
        description: String,
        value: String,
        font: NSFont,
        tag: Int
    ) -> NSTextView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stackView.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .tertiaryLabelColor
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

    @objc private func browseRepoPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.projects[index].repoPath)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.projects[index].repoPath = url.path
            try? self.persistence.saveSettings(self.settings)
            self.repoPathLabel.stringValue = url.path
        }
    }

    @objc private func browseWorktreesPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.projects[index].worktreesBasePath)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.projects[index].worktreesBasePath = url.path
            try? self.persistence.saveSettings(self.settings)
            self.worktreesPathLabel.stringValue = url.path
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

// MARK: - SettingsAppearanceViewController

final class SettingsAppearanceViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var tableView: NSTableView!
    private var currentEditingSectionId: UUID?

    private var sortedSections: [ThreadSection] {
        settings.threadSections.sorted { $0.sortOrder < $1.sortOrder }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        let titleLabel = NSTextField(labelWithString: "Thread Sections")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: "Organize threads into sections in the sidebar. Click a color dot to change it.")
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descLabel)

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowSizeStyle = .default
        tableView.selectionHighlightStyle = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SectionColumn"))
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self

        // Drag and drop
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Section")!, target: self, action: #selector(addSectionTapped))
        addButton.bezelStyle = .smallSquare
        addButton.isBordered = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(addButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            descLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Actions

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
        tableView.reloadData()

        showColorPicker(for: section)
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard let index = settings.threadSections.firstIndex(where: { $0.id == section.id }) else { return }
        settings.threadSections[index].isVisible.toggle()
        try? persistence.saveSettings(settings)
        tableView.reloadData()
    }

    @objc private func deleteSectionTapped(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: tableView)
        let row = tableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard !section.isDefault else { return }

        if let defaultSection = settings.defaultSection {
            ThreadManager.shared.reassignThreads(fromSection: section.id, toSection: defaultSection.id)
        }

        settings.threadSections.removeAll { $0.id == section.id }
        try? persistence.saveSettings(settings)
        tableView.reloadData()
    }

    @objc private func colorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: tableView)
        let row = tableView.row(at: point)
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
        tableView.reloadData()
    }

    static func colorDotImage(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }
}

// MARK: - Appearance Table Data Source & Delegate

extension SettingsAppearanceViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedSections.count
    }

    // Drag & drop
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

        // Update sort orders
        for (i, section) in sections.enumerated() {
            if let idx = settings.threadSections.firstIndex(where: { $0.id == section.id }) {
                settings.threadSections[idx].sortOrder = i
            }
        }
        try? persistence.saveSettings(settings)
        tableView.reloadData()
        return true
    }
}

extension SettingsAppearanceViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sortedSections[row]
        let identifier = NSUserInterfaceItemIdentifier("AppearanceSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            // Color dot button
            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.tag = 100
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            // Name label
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            // Visibility button
            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.tag = 101
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            // Delete button
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
            visBtn.contentTintColor = section.isVisible ? .labelColor : .tertiaryLabelColor
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
