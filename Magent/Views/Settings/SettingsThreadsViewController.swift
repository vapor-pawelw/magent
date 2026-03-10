import Cocoa
import MagentCore

final class SettingsThreadsViewController: NSViewController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    let persistence = PersistenceService.shared
    var settings: AppSettings!
    private var autoRenameBranchCheckbox: NSButton!
    private var autoSetDescriptionCheckbox: NSButton!
    private var autoSetIconFromWorkTypeCheckbox: NSButton!
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
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let (threadNamingCard, threadNamingSection) = createSectionCard(title: "Thread Naming")
        stackView.addArrangedSubview(threadNamingCard)

        autoRenameBranchCheckbox = NSButton(
            checkboxWithTitle: "Auto-rename branch from the first agent prompt",
            target: self,
            action: #selector(autoRenameBranchToggled)
        )
        autoRenameBranchCheckbox.state = settings.autoRenameBranches ? .on : .off
        threadNamingSection.addArrangedSubview(autoRenameBranchCheckbox)

        let autoRenameDesc = NSTextField(
            wrappingLabelWithString: "Uses AI to generate a meaningful branch name from the first agent prompt. Does not rename the worktree directory."
        )
        autoRenameDesc.font = .systemFont(ofSize: 11)
        autoRenameDesc.textColor = NSColor(resource: .textSecondary)
        threadNamingSection.addArrangedSubview(autoRenameDesc)

        autoSetDescriptionCheckbox = NSButton(
            checkboxWithTitle: "Auto-set thread description from agent prompts",
            target: self,
            action: #selector(autoSetDescriptionToggled)
        )
        autoSetDescriptionCheckbox.state = settings.autoSetThreadDescription ? .on : .off
        threadNamingSection.addArrangedSubview(autoSetDescriptionCheckbox)

        let autoSetDescriptionDesc = NSTextField(
            wrappingLabelWithString: "Uses AI to generate a short thread description when one is missing."
        )
        autoSetDescriptionDesc.font = .systemFont(ofSize: 11)
        autoSetDescriptionDesc.textColor = NSColor(resource: .textSecondary)
        threadNamingSection.addArrangedSubview(autoSetDescriptionDesc)

        autoSetIconFromWorkTypeCheckbox = NSButton(
            checkboxWithTitle: "Auto-set thread icon from work type",
            target: self,
            action: #selector(autoSetIconFromWorkTypeToggled)
        )
        autoSetIconFromWorkTypeCheckbox.state = settings.autoSetThreadIconFromWorkType ? .on : .off
        threadNamingSection.addArrangedSubview(autoSetIconFromWorkTypeCheckbox)

        let autoSetIconDesc = NSTextField(
            wrappingLabelWithString: "When generating a description, AI picks the highest-confidence icon category and uses other only when confidence is low."
        )
        autoSetIconDesc.font = .systemFont(ofSize: 11)
        autoSetIconDesc.textColor = NSColor(resource: .textSecondary)
        threadNamingSection.addArrangedSubview(autoSetIconDesc)
        threadNamingSection.setCustomSpacing(10, after: autoSetIconDesc)

        slugPromptTextView = createTextEditorSection(
            in: threadNamingSection,
            title: "Slug Prompt",
            description: "Instruction used to generate branch slugs for auto-rename on first prompt, rename via agent, or CLI auto-rename-thread command.",
            value: settings.autoRenameSlugPrompt,
            font: .systemFont(ofSize: 13)
        )

        let resetSlugButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetSlugPromptToDefault))
        resetSlugButton.bezelStyle = .rounded
        resetSlugButton.controlSize = .small
        threadNamingSection.addArrangedSubview(resetSlugButton)

        let (sectionsCard, sectionsSection) = createSectionCard(
            title: "Thread Sections",
            description: "Organize threads in the sidebar. Click a color dot to edit it and drag rows to reorder."
        )
        stackView.addArrangedSubview(sectionsCard)

        useSectionsCheckbox = NSButton(
            checkboxWithTitle: "Group threads by sections in the sidebar",
            target: self,
            action: #selector(useSectionsToggled)
        )
        useSectionsCheckbox.state = settings.useThreadSections ? .on : .off
        sectionsSection.addArrangedSubview(useSectionsCheckbox)

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
        sectionsSection.addArrangedSubview(sectionsScrollView)

        let addSectionButton = NSButton(title: "Add Section...", target: self, action: #selector(addSectionTapped))
        addSectionButton.bezelStyle = .rounded
        addSectionButton.controlSize = .small
        sectionsSection.addArrangedSubview(addSectionButton)

        let defaultSectionStack = NSStackView()
        defaultSectionStack.orientation = .vertical
        defaultSectionStack.alignment = .leading
        defaultSectionStack.spacing = 4
        defaultSectionStack.translatesAutoresizingMaskIntoConstraints = false

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
        sectionsSection.addArrangedSubview(defaultSectionStack)
        refreshDefaultSectionPopup()

        NSLayoutConstraint.activate([
            sectionsScrollView.widthAnchor.constraint(equalTo: sectionsSection.widthAnchor),
            sectionsScrollView.heightAnchor.constraint(equalToConstant: 140),
            defaultSectionStack.widthAnchor.constraint(equalTo: sectionsSection.widthAnchor),
            defaultSectionPopup.widthAnchor.constraint(equalTo: defaultSectionStack.widthAnchor),
        ])

        let (injectionCard, injectionSection) = createSectionCard(
            title: "Startup Injection",
            description: "Values in this section are applied to every new terminal/agent tab at startup."
        )
        stackView.addArrangedSubview(injectionCard)

        terminalInjectionTextView = createTextEditorSection(
            in: injectionSection,
            title: "Terminal Injection Command",
            description: "Shell command auto-sent to every new terminal tab after creation.",
            value: settings.terminalInjectionCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        agentContextTextView = createTextEditorSection(
            in: injectionSection,
            title: "Agent Context Injection",
            description: "Text auto-typed into every new agent prompt after startup.",
            value: settings.agentContextInjection,
            font: .systemFont(ofSize: 13)
        )

        let (reviewCard, reviewSection) = createSectionCard(title: "Review")
        stackView.addArrangedSubview(reviewCard)

        reviewPromptTextView = createTextEditorSection(
            in: reviewSection,
            title: "Review Prompt",
            description: "Prompt sent to the agent when clicking the review button. Use {baseBranch} as a placeholder for the target branch.",
            value: settings.reviewPrompt,
            font: .systemFont(ofSize: 13)
        )

        let resetReviewButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetReviewPromptToDefault))
        resetReviewButton.bezelStyle = .rounded
        resetReviewButton.controlSize = .small
        reviewSection.addArrangedSubview(resetReviewButton)

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
            threadNamingCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            sectionsCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            injectionCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            reviewCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
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

    private func createSectionCard(title: String, description: String? = nil) -> (container: NSView, content: NSStackView) {
        let container = SettingsSectionCardView()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(titleLabel)

        if let description, !description.isEmpty {
            let descriptionLabel = NSTextField(wrappingLabelWithString: description)
            descriptionLabel.font = .systemFont(ofSize: 11)
            descriptionLabel.textColor = NSColor(resource: .textSecondary)
            content.addArrangedSubview(descriptionLabel)
            content.setCustomSpacing(12, after: descriptionLabel)
            NSLayoutConstraint.activate([
                descriptionLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return (container, content)
    }

    private func createTextEditorSection(
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
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionStack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        sectionStack.addArrangedSubview(descLabel)
        sectionStack.setCustomSpacing(8, after: descLabel)

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

        NSLayoutConstraint.activate([
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            descLabel.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    @objc private func autoRenameBranchToggled() {
        settings.autoRenameBranches = autoRenameBranchCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func autoSetDescriptionToggled() {
        settings.autoSetThreadDescription = autoSetDescriptionCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func autoSetIconFromWorkTypeToggled() {
        settings.autoSetThreadIconFromWorkType = autoSetIconFromWorkTypeCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === terminalInjectionTextView {
            settings.terminalInjectionCommand = textView.string
        } else if textView === agentContextTextView {
            settings.agentContextInjection = textView.string
        } else if textView === slugPromptTextView {
            settings.autoRenameSlugPrompt = textView.string
        } else if textView === reviewPromptTextView {
            settings.reviewPrompt = textView.string
        }

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
