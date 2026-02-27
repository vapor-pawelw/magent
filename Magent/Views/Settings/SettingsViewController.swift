import Cocoa
import UserNotifications

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class NonCapturingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let nextResponder {
            nextResponder.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Resizable Text Container

private final class ResizableTextContainer: NSView {
    private static let handleHeight: CGFloat = 10

    init(scrollView: NSScrollView, minHeight: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let handle = ResizeHandleView()
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        let heightConst = scrollView.heightAnchor.constraint(equalToConstant: minHeight)
        handle.scrollViewHeightConstraint = heightConst
        handle.minHeight = minHeight

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            handle.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: Self.handleHeight),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightConst,
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ResizeHandleView: NSView {
    var scrollViewHeightConstraint: NSLayoutConstraint?
    var minHeight: CGFloat = 56
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gripWidth: CGFloat = 36
        let gripHeight: CGFloat = 2
        let rect = NSRect(
            x: (bounds.width - gripWidth) / 2,
            y: (bounds.height - gripHeight) / 2,
            width: gripWidth,
            height: gripHeight
        )
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        dragStartHeight = scrollViewHeightConstraint?.constant ?? minHeight
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = dragStartY - event.locationInWindow.y
        scrollViewHeightConstraint?.constant = max(minHeight, dragStartHeight + delta)
    }
}

// MARK: - Settings Category

enum SettingsCategory: Int, CaseIterable {
    case general, agents, notifications, projects

    var title: String {
        switch self {
        case .general: return "General"
        case .agents: return "Agents"
        case .notifications: return "Notifications"
        case .projects: return "Projects"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .agents: return "cpu"
        case .notifications: return "bell"
        case .projects: return "folder"
        }
    }
}

// MARK: - SettingsSplitViewController

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarVC = SettingsSidebarViewController()
    private let detailContainerVC = NSViewController()
    private let generalVC = SettingsGeneralViewController()
    private let agentsVC = SettingsAgentsViewController()
    private let notificationsVC = SettingsNotificationsViewController()
    private let projectsVC = SettingsProjectsViewController()
    private var detailSplitItem: NSSplitViewItem!
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

        setupDetailContainer()
        showCategoryContent(.general)

        detailSplitItem = NSSplitViewItem(viewController: detailContainerVC)
        detailSplitItem.canCollapse = false
        detailSplitItem.minimumThickness = 500
        addSplitViewItem(detailSplitItem)

        splitView.dividerStyle = .thin
    }

    override func cancelOperation(_ sender: Any?) {
        if let window = view.window, window.sheetParent == nil {
            window.performClose(nil)
        } else {
            dismiss(nil)
        }
    }

    private func setupDetailContainer() {
        detailContainerVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
        let container = detailContainerVC.view

        let allVCs: [NSViewController] = [generalVC, agentsVC, notificationsVC, projectsVC]
        for vc in allVCs {
            detailContainerVC.addChild(vc)
            vc.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(vc.view)
            NSLayoutConstraint.activate([
                vc.view.topAnchor.constraint(equalTo: container.topAnchor),
                vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    private func showCategoryContent(_ category: SettingsCategory) {
        generalVC.view.isHidden = category != .general
        agentsVC.view.isHidden = category != .agents
        notificationsVC.view.isHidden = category != .notifications
        projectsVC.view.isHidden = category != .projects
    }

    fileprivate func showCategory(_ category: SettingsCategory) {
        guard category != currentCategory else { return }
        currentCategory = category

        showCategoryContent(category)
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
    private var autoRenameCheckbox: NSButton!
    private var slugPromptTextView: NSTextView!
    private var slugPromptContainer: NSView!
    private var terminalInjectionTextView: NSTextView!
    private var agentContextTextView: NSTextView!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

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

        contentScrollView = NSScrollView()
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Worktree Behavior
        let worktreeSection = NSStackView()
        worktreeSection.orientation = .vertical
        worktreeSection.alignment = .leading
        worktreeSection.spacing = 6

        let worktreeLabel = NSTextField(labelWithString: "Worktree Behavior")
        worktreeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        worktreeSection.addArrangedSubview(worktreeLabel)

        autoRenameCheckbox = NSButton(
            checkboxWithTitle: "Auto-rename worktrees from the first agent prompt",
            target: self,
            action: #selector(autoRenameToggled)
        )
        autoRenameCheckbox.state = settings.autoRenameWorktrees ? .on : .off
        worktreeSection.addArrangedSubview(autoRenameCheckbox)

        let autoRenameDesc = NSTextField(
            wrappingLabelWithString: "Uses AI to generate a meaningful branch name from the prompt. Currently works with Claude Code and Codex."
        )
        autoRenameDesc.font = .systemFont(ofSize: 11)
        autoRenameDesc.textColor = NSColor(resource: .textSecondary)
        worktreeSection.addArrangedSubview(autoRenameDesc)

        // Slug prompt customization (shown when auto-rename is enabled)
        let slugPromptWrapper = NSStackView()
        slugPromptWrapper.orientation = .vertical
        slugPromptWrapper.alignment = .leading
        slugPromptWrapper.spacing = 4

        let slugPromptLabel = NSTextField(labelWithString: "Slug Prompt")
        slugPromptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        slugPromptWrapper.addArrangedSubview(slugPromptLabel)

        let slugPromptDesc = NSTextField(
            wrappingLabelWithString: "Customize the instruction used to generate the branch slug. The SLUG:/EMPTY output format and task text are appended automatically."
        )
        slugPromptDesc.font = .systemFont(ofSize: 11)
        slugPromptDesc.textColor = NSColor(resource: .textSecondary)
        slugPromptWrapper.addArrangedSubview(slugPromptDesc)

        slugPromptTextView = NSTextView()
        slugPromptTextView.font = .systemFont(ofSize: 13)
        slugPromptTextView.string = settings.autoRenameSlugPrompt
        slugPromptTextView.isRichText = false
        slugPromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        slugPromptTextView.isAutomaticDashSubstitutionEnabled = false
        slugPromptTextView.isAutomaticTextReplacementEnabled = false
        slugPromptTextView.delegate = self
        slugPromptTextView.isVerticallyResizable = true
        slugPromptTextView.isHorizontallyResizable = false
        slugPromptTextView.textContainerInset = NSSize(width: 4, height: 4)

        let slugPromptScrollView = NonCapturingScrollView()
        slugPromptScrollView.documentView = slugPromptTextView
        slugPromptScrollView.hasVerticalScroller = true
        slugPromptScrollView.autohidesScrollers = true
        slugPromptScrollView.borderType = .bezelBorder
        slugPromptScrollView.translatesAutoresizingMaskIntoConstraints = false

        let slugLineHeight = NSFont.systemFont(ofSize: 13).ascender + abs(NSFont.systemFont(ofSize: 13).descender) + NSFont.systemFont(ofSize: 13).leading
        let slugHeight = max(slugLineHeight * 3 + 12, 56)

        NSLayoutConstraint.activate([
            slugPromptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: slugHeight),
        ])

        slugPromptWrapper.addArrangedSubview(slugPromptScrollView)
        slugPromptWrapper.translatesAutoresizingMaskIntoConstraints = false
        worktreeSection.addArrangedSubview(slugPromptWrapper)

        slugPromptTextView.autoresizingMask = [.width]
        slugPromptTextView.textContainer?.widthTracksTextView = true

        slugPromptContainer = slugPromptWrapper
        slugPromptContainer.isHidden = !settings.autoRenameWorktrees

        worktreeSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(worktreeSection)
        NSLayoutConstraint.activate([
            worktreeSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            slugPromptScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
        ])

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
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        contentScrollView.documentView = documentView

        view.addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            contentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didInitialScrollToTop {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialScrollToTop, view.window != nil {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    private func scrollToTop() {
        guard let clipView = contentScrollView?.contentView as NSClipView? else { return }
        clipView.scroll(to: NSPoint(x: 0, y: 0))
        contentScrollView.reflectScrolledClipView(clipView)
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

        let textScrollView = NonCapturingScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
        sectionStack.addArrangedSubview(container)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    @objc private func autoRenameToggled() {
        settings.autoRenameWorktrees = autoRenameCheckbox.state == .on
        slugPromptContainer.isHidden = !settings.autoRenameWorktrees
        try? persistence.saveSettings(settings)
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
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "Move all threads out of \"\(section.name)\" before deleting it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        settings.threadSections.removeAll { $0.id == section.id }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
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

        if textView === terminalInjectionTextView {
            settings.terminalInjectionCommand = textView.string
        } else if textView === agentContextTextView {
            settings.agentContextInjection = textView.string
        } else if textView === slugPromptTextView {
            settings.autoRenameSlugPrompt = textView.string
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

// MARK: - SettingsAgentsViewController

final class SettingsAgentsViewController: NSViewController, NSTextViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var claudeCheckbox: NSButton!
    private var codexCheckbox: NSButton!
    private var customCheckbox: NSButton!
    private var defaultAgentSection: NSStackView!
    private var defaultAgentPopup: NSPopUpButton!
    private var customAgentSection: NSStackView!
    private var customAgentCommandTextView: NSTextView!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        contentScrollView = NSScrollView()
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

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

        // Document view wrapper
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        contentScrollView.documentView = documentView

        view.addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            contentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didInitialScrollToTop {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialScrollToTop, view.window != nil {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    private func scrollToTop() {
        guard let clipView = contentScrollView?.contentView as NSClipView? else { return }
        clipView.scroll(to: NSPoint(x: 0, y: 0))
        contentScrollView.reflectScrolledClipView(clipView)
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

        let textScrollView = NonCapturingScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
        sectionStack.addArrangedSubview(container)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    // MARK: - Actions

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

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === customAgentCommandTextView {
            settings.customAgentCommand = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}

// MARK: - SettingsNotificationsViewController

final class SettingsNotificationsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var notificationStatusDot: NSView!
    private var notificationStatusLabel: NSTextField!
    private var showBannersCheckbox: NSButton!
    private var completionSoundCheckbox: NSButton!
    private var soundPickerPopup: NSPopUpButton!
    private var soundPickerRow: NSStackView!
    private var appActiveObserver: NSObjectProtocol?
    private var soundPreviewPlayer: NSSound?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Description
        let notificationsDesc = NSTextField(
            wrappingLabelWithString: "When an agent finishes a command, Magent sends a system notification and moves the thread to the top of its section."
        )
        notificationsDesc.font = .systemFont(ofSize: 11)
        notificationsDesc.textColor = NSColor(resource: .textSecondary)
        notificationsDesc.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(notificationsDesc)
        NSLayoutConstraint.activate([
            notificationsDesc.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Permission status section
        let permissionSection = NSStackView()
        permissionSection.orientation = .vertical
        permissionSection.alignment = .leading
        permissionSection.spacing = 6

        let permissionLabel = NSTextField(labelWithString: "Permission Status")
        permissionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionSection.addArrangedSubview(permissionLabel)

        // Permission status row
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        notificationStatusDot = NSView()
        notificationStatusDot.wantsLayer = true
        notificationStatusDot.layer?.cornerRadius = 5
        notificationStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notificationStatusDot.widthAnchor.constraint(equalToConstant: 10),
            notificationStatusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        statusRow.addArrangedSubview(notificationStatusDot)

        notificationStatusLabel = NSTextField(labelWithString: "Notifications: Checking...")
        notificationStatusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(notificationStatusLabel)

        permissionSection.addArrangedSubview(statusRow)

        // Open Notification Settings button
        let openNotifSettingsButton = NSButton(
            title: "Open Notification Settings",
            target: self,
            action: #selector(openSystemNotificationSettings)
        )
        openNotifSettingsButton.bezelStyle = .accessoryBarAction
        openNotifSettingsButton.controlSize = .small
        openNotifSettingsButton.font = .systemFont(ofSize: 11)
        permissionSection.addArrangedSubview(openNotifSettingsButton)

        permissionSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(permissionSection)
        NSLayoutConstraint.activate([
            permissionSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Behavior section
        let behaviorSection = NSStackView()
        behaviorSection.orientation = .vertical
        behaviorSection.alignment = .leading
        behaviorSection.spacing = 6

        let behaviorLabel = NSTextField(labelWithString: "Behavior")
        behaviorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        behaviorSection.addArrangedSubview(behaviorLabel)

        // Show system banners checkbox
        showBannersCheckbox = NSButton(
            checkboxWithTitle: "Show system banners",
            target: self,
            action: #selector(showBannersToggled)
        )
        showBannersCheckbox.state = settings.showSystemBanners ? .on : .off
        behaviorSection.addArrangedSubview(showBannersCheckbox)

        completionSoundCheckbox = NSButton(
            checkboxWithTitle: "Play sound for completion notifications",
            target: self,
            action: #selector(completionSoundToggled)
        )
        completionSoundCheckbox.state = settings.playSoundForAgentCompletion ? .on : .off
        behaviorSection.addArrangedSubview(completionSoundCheckbox)

        // Sound picker row
        soundPickerRow = NSStackView()
        soundPickerRow.orientation = .horizontal
        soundPickerRow.alignment = .centerY
        soundPickerRow.spacing = 8

        let soundLabel = NSTextField(labelWithString: "Sound:")
        soundLabel.font = .systemFont(ofSize: 12)
        soundPickerRow.addArrangedSubview(soundLabel)

        soundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        soundPickerPopup.controlSize = .small
        soundPickerPopup.font = .systemFont(ofSize: 12)
        soundPickerPopup.target = self
        soundPickerPopup.action = #selector(soundPickerChanged)
        populateSoundPicker()
        soundPickerRow.addArrangedSubview(soundPickerPopup)

        soundPickerRow.isHidden = !settings.playSoundForAgentCompletion
        // Indent to align with checkbox label
        soundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        behaviorSection.addArrangedSubview(soundPickerRow)

        behaviorSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(behaviorSection)
        NSLayoutConstraint.activate([
            behaviorSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshNotificationPermissionStatus()
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotificationPermissionStatus()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        soundPreviewPlayer?.stop()
        soundPreviewPlayer = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
        appActiveObserver = nil
    }

    // MARK: - Actions

    private func populateSoundPicker() {
        soundPickerPopup.removeAllItems()
        let soundNames = Self.systemSoundNames()
        for name in soundNames {
            soundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: settings.agentCompletionSoundName) {
            soundPickerPopup.selectItem(at: index)
        }
    }

    static func systemSoundNames() -> [String] {
        let soundsDir = "/System/Library/Sounds"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            return ["Tink"]
        }
        return contents
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    @objc private func soundPickerChanged() {
        guard let selectedName = soundPickerPopup.selectedItem?.title else { return }
        settings.agentCompletionSoundName = selectedName
        try? persistence.saveSettings(settings)

        // Stop any currently playing preview
        soundPreviewPlayer?.stop()
        // Play the selected sound as preview
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func completionSoundToggled() {
        settings.playSoundForAgentCompletion = completionSoundCheckbox.state == .on
        soundPickerRow.isHidden = !settings.playSoundForAgentCompletion
        if !settings.playSoundForAgentCompletion {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
        try? persistence.saveSettings(settings)
    }

    @objc private func showBannersToggled() {
        settings.showSystemBanners = showBannersCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func openSystemNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshNotificationPermissionStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notifSettings in
            let authorized = notifSettings.authorizationStatus == .authorized
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatusDot.layer?.backgroundColor = authorized
                    ? NSColor.systemGreen.cgColor
                    : NSColor.systemRed.cgColor
                self.notificationStatusLabel.stringValue = authorized
                    ? "Notifications: Enabled"
                    : "Notifications: Disabled \u{2014} enable in System Settings"
                self.notificationStatusLabel.textColor = authorized
                    ? .labelColor
                    : .systemRed

                self.showBannersCheckbox.isEnabled = authorized
                self.completionSoundCheckbox.isEnabled = authorized
                self.soundPickerPopup.isEnabled = authorized
                self.showBannersCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.completionSoundCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.soundPickerRow.alphaValue = authorized ? 1.0 : 0.5
            }
        }
    }
}

// MARK: - SettingsProjectsViewController

final class SettingsProjectsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!

    private var projectTableView: NSTableView!
    private var detailScrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var removeProjectButton: NSButton!

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
        reloadProjectsAndSelect()
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

        let addButton = NSButton(
            image: NSImage(named: NSImage.addTemplateName) ?? NSImage(),
            target: self,
            action: #selector(addProjectTapped)
        )
        addButton.bezelStyle = .texturedRounded
        addButton.controlSize = .small
        addButton.imagePosition = .imageOnly
        addButton.toolTip = "Add Project"

        removeProjectButton = NSButton(
            image: NSImage(named: NSImage.removeTemplateName) ?? NSImage(),
            target: self,
            action: #selector(removeProjectTapped)
        )
        removeProjectButton.bezelStyle = .texturedRounded
        removeProjectButton.controlSize = .small
        removeProjectButton.imagePosition = .imageOnly
        removeProjectButton.toolTip = "Remove Project"

        let buttonBar = NSStackView(views: [addButton, removeProjectButton])
        buttonBar.orientation = .horizontal
        buttonBar.spacing = 6
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
        updateRemoveButtonState()
    }

    private func updateRemoveButtonState() {
        removeProjectButton?.isEnabled = selectedProjectIndex != nil
    }

    private func reloadProjectsAndSelect(row preferredRow: Int? = nil) {
        let currentRow = selectedProjectIndex
        projectTableView.reloadData()

        guard !settings.projects.isEmpty else {
            projectTableView.deselectAll(nil)
            updateRemoveButtonState()
            showEmptyState()
            return
        }

        let target = max(0, min(preferredRow ?? currentRow ?? 0, settings.projects.count - 1))
        projectTableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        showDetailForProject(settings.projects[target])
        updateRemoveButtonState()
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
        let documentView = FlippedDocumentView()
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

        let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
        stackView.addArrangedSubview(container)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])

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
                        self.reloadProjectsAndSelect(row: self.settings.projects.count - 1)

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
        if settings.projects.isEmpty {
            reloadProjectsAndSelect()
        } else {
            reloadProjectsAndSelect(row: min(index, settings.projects.count - 1))
        }
    }

    @objc private func nameFieldChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        settings.projects[index].name = value
        try? persistence.saveSettings(settings)
        reloadProjectsAndSelect(row: index)
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
                        self.reloadProjectsAndSelect(row: index)
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
        updateRemoveButtonState()
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
