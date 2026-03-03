import Cocoa

final class SettingsGeneralViewController: NSViewController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    let persistence = PersistenceService.shared
    var settings: AppSettings!
    private var autoRenameCheckbox: NSButton!
    var slugPromptTextView: NSTextView!
    var terminalInjectionTextView: NSTextView!
    var agentContextTextView: NSTextView!
    var reviewPromptTextView: NSTextView!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

    // Thread sections
    var sectionsTableView: NSTableView!
    private var defaultSectionPopup: NSPopUpButton!
    private var useSectionsCheckbox: NSButton!
    var currentEditingSectionId: UUID?

    var sortedSections: [ThreadSection] {
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

        // Thread Naming
        let worktreeSection = NSStackView()
        worktreeSection.orientation = .vertical
        worktreeSection.alignment = .leading
        worktreeSection.spacing = 6

        let worktreeLabel = NSTextField(labelWithString: "Thread Naming")
        worktreeLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        worktreeSection.addArrangedSubview(worktreeLabel)

        autoRenameCheckbox = NSButton(
            checkboxWithTitle: "Auto-rename branch from the first agent prompt",
            target: self,
            action: #selector(autoRenameToggled)
        )
        autoRenameCheckbox.state = settings.autoRenameWorktrees ? .on : .off
        worktreeSection.addArrangedSubview(autoRenameCheckbox)

        let autoRenameDesc = NSTextField(
            wrappingLabelWithString: "Uses AI to generate a meaningful branch name and thread description from the prompt. Does not rename the worktree directory."
        )
        autoRenameDesc.font = .systemFont(ofSize: 11)
        autoRenameDesc.textColor = NSColor(resource: .textSecondary)
        worktreeSection.addArrangedSubview(autoRenameDesc)

        // Slug prompt customization (always visible)
        let slugPromptWrapper = NSStackView()
        slugPromptWrapper.orientation = .vertical
        slugPromptWrapper.alignment = .leading
        slugPromptWrapper.spacing = 4

        let slugPromptLabel = NSTextField(labelWithString: "Slug Prompt")
        slugPromptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        slugPromptWrapper.addArrangedSubview(slugPromptLabel)

        let slugPromptDesc = NSTextField(
            wrappingLabelWithString: "Instruction used to generate branch slugs — for auto-rename on first prompt, rename via agent, or CLI auto-rename-thread command."
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

        let resetSlugButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetSlugPromptToDefault))
        resetSlugButton.bezelStyle = .rounded
        resetSlugButton.controlSize = .small
        slugPromptWrapper.addArrangedSubview(resetSlugButton)

        slugPromptWrapper.translatesAutoresizingMaskIntoConstraints = false
        worktreeSection.addArrangedSubview(slugPromptWrapper)

        slugPromptTextView.autoresizingMask = [.width]
        slugPromptTextView.textContainer?.widthTracksTextView = true

        worktreeSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(worktreeSection)
        NSLayoutConstraint.activate([
            worktreeSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            slugPromptScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
        ])

        addSectionSeparator(to: stackView)

        // Terminal Injection Command
        terminalInjectionTextView = createSettingsSection(
            in: stackView,
            title: "Terminal Injection Command",
            description: "Shell command auto-sent to every new terminal tab after creation.",
            value: settings.terminalInjectionCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            delegate: self
        )

        addSectionSeparator(to: stackView)

        // Agent Context Injection
        agentContextTextView = createSettingsSection(
            in: stackView,
            title: "Agent Context Injection",
            description: "Text auto-typed into every new agent prompt after startup.",
            value: settings.agentContextInjection,
            font: .systemFont(ofSize: 13),
            delegate: self
        )

        addSectionSeparator(to: stackView)

        // Review Prompt
        reviewPromptTextView = createSettingsSection(
            in: stackView,
            title: "Review Prompt",
            description: "Prompt sent to the agent when clicking the review button. Use {baseBranch} as a placeholder for the target branch.",
            value: settings.reviewPrompt,
            font: .systemFont(ofSize: 13),
            delegate: self
        )

        let resetReviewButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetReviewPromptToDefault))
        resetReviewButton.bezelStyle = .rounded
        resetReviewButton.controlSize = .small
        stackView.addArrangedSubview(resetReviewButton)

        addSectionSeparator(to: stackView)

        // Environment Variables reference
        let envHeader = NSTextField(labelWithString: "Environment Variables")
        envHeader.font = .systemFont(ofSize: 14, weight: .semibold)

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
        sectionsHeader.font = .systemFont(ofSize: 14, weight: .semibold)
        sectionsHeader.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsHeader)

        let sectionsDesc = NSTextField(wrappingLabelWithString: "Organize threads into sections in the sidebar. Click a color dot to change it. Drag to reorder.")
        sectionsDesc.font = .systemFont(ofSize: 11)
        sectionsDesc.textColor = NSColor(resource: .textSecondary)
        sectionsDesc.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsDesc)

        useSectionsCheckbox = NSButton(
            checkboxWithTitle: "Group threads by sections in the sidebar",
            target: self,
            action: #selector(useSectionsToggled)
        )
        useSectionsCheckbox.state = settings.useThreadSections ? .on : .off
        stackView.addArrangedSubview(useSectionsCheckbox)

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

        // Default Section popup
        let defaultSectionStack = NSStackView()
        defaultSectionStack.orientation = .vertical
        defaultSectionStack.alignment = .leading
        defaultSectionStack.spacing = 4

        let defaultSectionLabel = NSTextField(labelWithString: "Default Section")
        defaultSectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        defaultSectionStack.addArrangedSubview(defaultSectionLabel)

        let defaultSectionDesc = NSTextField(wrappingLabelWithString: "New threads without an explicit section go here.")
        defaultSectionDesc.font = .systemFont(ofSize: 11)
        defaultSectionDesc.textColor = NSColor(resource: .textSecondary)
        defaultSectionStack.addArrangedSubview(defaultSectionDesc)

        defaultSectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultSectionPopup.target = self
        defaultSectionPopup.action = #selector(defaultSectionChanged)
        defaultSectionStack.addArrangedSubview(defaultSectionPopup)
        stackView.addArrangedSubview(defaultSectionStack)
        refreshDefaultSectionPopup()

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

    private func addSectionSeparator(to stackView: NSStackView) {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40).isActive = true
    }


    @objc private func autoRenameToggled() {
        settings.autoRenameWorktrees = autoRenameCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func useSectionsToggled() {
        settings.useThreadSections = useSectionsCheckbox.state == .on
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func resetSlugPromptToDefault() {
        slugPromptTextView.string = AppSettings.defaultSlugPrompt
        settings.autoRenameSlugPrompt = AppSettings.defaultSlugPrompt
        try? persistence.saveSettings(settings)
    }

    @objc private func resetReviewPromptToDefault() {
        reviewPromptTextView.string = AppSettings.defaultReviewPrompt
        settings.reviewPrompt = AppSettings.defaultReviewPrompt
        try? persistence.saveSettings(settings)
    }

    // MARK: - Default Section

    func refreshDefaultSectionPopup() {
        defaultSectionPopup.removeAllItems()
        let visible = settings.visibleSections
        for section in visible {
            defaultSectionPopup.addItem(withTitle: section.name)
        }
        if let id = settings.defaultSectionId,
           let idx = visible.firstIndex(where: { $0.id == id }) {
            defaultSectionPopup.selectItem(at: idx)
        } else {
            defaultSectionPopup.selectItem(at: 0)
        }
    }

    @objc private func defaultSectionChanged() {
        let visible = settings.visibleSections
        let selected = defaultSectionPopup.indexOfSelectedItem
        guard selected >= 0, selected < visible.count else { return }
        settings.defaultSectionId = visible[selected].id
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
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
        refreshDefaultSectionPopup()

        showColorPicker(for: section)
    }
}
