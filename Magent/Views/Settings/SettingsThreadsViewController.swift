import Cocoa
import MagentCore

final class SettingsThreadsViewController: NSViewController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let sectionColorPanelIdentifier = NSUserInterfaceItemIdentifier("SettingsThreadsSectionColorPanel")
    private static let recentArchivedThreadLimit = 10
    static let sectionNameLabelTag = 103
    static let sectionInlineRenameFieldTag = 104

    let persistence = PersistenceService.shared
    var settings: AppSettings!
    private var autoRenameBranchCheckbox: NSButton!
    private var autoSetDescriptionCheckbox: NSButton!
    private var autoSetIconFromWorkTypeCheckbox: NSButton!
    private var narrowThreadsCheckbox: NSButton!
    private var showPRStatusBadgesCheckbox: NSButton!
    private var showJiraStatusBadgesCheckbox: NSButton!
    private var showBusyStateDurationCheckbox: NSButton!
    private var autoReorderOnCompletionCheckbox: NSButton!
    var slugPromptTextView: NSTextView!
    var terminalInjectionTextView: NSTextView!
    var agentContextTextView: NSTextView!
    var reviewPromptTextView: NSTextView!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false
    private var recentArchivedThreadsStackView: NSStackView!
    private var recentArchivedThreadsById: [UUID: MagentThread] = [:]

    // Thread sections
    var sectionsTableView: NSTableView!
    private var defaultSectionPopup: NSPopUpButton!
    private var useSectionsCheckbox: NSButton!
    var currentEditingSectionId: UUID?
    var isUpdatingSectionColorPanel = false
    var activeInlineRenameSectionId: UUID?

    var sortedSections: [ThreadSection] {
        settings.threadSections.sorted { $0.sortOrder < $1.sortOrder }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        sectionsTableView.target = self
        sectionsTableView.doubleAction = #selector(sectionTableDoubleClicked(_:))

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

        let (sidebarCard, sidebarSection) = createSectionCard(
            title: "Sidebar",
            description: "Control how much space each thread row uses in the sidebar."
        )
        stackView.addArrangedSubview(sidebarCard)

        narrowThreadsCheckbox = NSButton(
            checkboxWithTitle: "Narrow threads",
            target: self,
            action: #selector(narrowThreadsToggled)
        )
        narrowThreadsCheckbox.state = settings.narrowThreads ? .on : .off
        sidebarSection.addArrangedSubview(narrowThreadsCheckbox)

        let narrowThreadsDesc = NSTextField(
            wrappingLabelWithString: "Limit thread descriptions to one line and size every thread row for that tighter layout."
        )
        narrowThreadsDesc.font = .systemFont(ofSize: 11)
        narrowThreadsDesc.textColor = NSColor(resource: .textSecondary)
        sidebarSection.addArrangedSubview(narrowThreadsDesc)

        autoReorderOnCompletionCheckbox = NSButton(
            checkboxWithTitle: "Move completed threads to top",
            target: self,
            action: #selector(autoReorderOnCompletionToggled)
        )
        autoReorderOnCompletionCheckbox.state = settings.autoReorderThreadsOnAgentCompletion ? .on : .off
        sidebarSection.addArrangedSubview(autoReorderOnCompletionCheckbox)

        let autoReorderDesc = NSTextField(
            wrappingLabelWithString: "When an agent finishes, bump the thread to the top of its section."
        )
        autoReorderDesc.font = .systemFont(ofSize: 11)
        autoReorderDesc.textColor = NSColor(resource: .textSecondary)
        sidebarSection.addArrangedSubview(autoReorderDesc)

        showPRStatusBadgesCheckbox = NSButton(
            checkboxWithTitle: "Show PR status badges",
            target: self,
            action: #selector(showPRStatusBadgesToggled)
        )
        showPRStatusBadgesCheckbox.state = settings.showPRStatusBadges ? .on : .off
        sidebarSection.addArrangedSubview(showPRStatusBadgesCheckbox)

        showJiraStatusBadgesCheckbox = NSButton(
            checkboxWithTitle: "Show Jira status badges",
            target: self,
            action: #selector(showJiraStatusBadgesToggled)
        )
        showJiraStatusBadgesCheckbox.state = settings.showJiraStatusBadges ? .on : .off
        sidebarSection.addArrangedSubview(showJiraStatusBadgesCheckbox)

        let statusBadgesDesc = NSTextField(
            wrappingLabelWithString: "Display colored status pills next to PR numbers and Jira ticket keys in the sidebar and top bar."
        )
        statusBadgesDesc.font = .systemFont(ofSize: 11)
        statusBadgesDesc.textColor = NSColor(resource: .textSecondary)
        sidebarSection.addArrangedSubview(statusBadgesDesc)

        showBusyStateDurationCheckbox = NSButton(
            checkboxWithTitle: "Show busy/idle duration on thread rows",
            target: self,
            action: #selector(showBusyStateDurationToggled)
        )
        showBusyStateDurationCheckbox.state = settings.showBusyStateDuration ? .on : .off
        sidebarSection.addArrangedSubview(showBusyStateDurationCheckbox)

        let (injectionCard, injectionSection) = createSectionCard(
            title: "Startup Injection",
            description: "Values in this section are applied to every new terminal/agent tab at startup."
        )
        stackView.addArrangedSubview(injectionCard)

        terminalInjectionTextView = createTextEditorSection(
            in: injectionSection,
            title: "Terminal Injection Command",
            description: "Pre-filled into the prompt field when creating a terminal session. Sent as a shell command on start if submitted as-is, or replaced by whatever you type.",
            value: settings.terminalInjectionCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        agentContextTextView = createTextEditorSection(
            in: injectionSection,
            title: "Agent Context Injection",
            description: "Pre-filled into the prompt field when creating an agent session. Sent as the initial message if submitted as-is, or replaced by whatever you type. Skipped when you provide your own initial prompt.",
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

        let (recentArchivedCard, recentArchivedSection) = createSectionCard(
            title: "Recently Archived",
            description: "Shows up to 10 archived threads. Restore uses the same flow as the archive banner."
        )
        stackView.addArrangedSubview(recentArchivedCard)

        recentArchivedThreadsStackView = NSStackView()
        recentArchivedThreadsStackView.orientation = .vertical
        recentArchivedThreadsStackView.alignment = .leading
        recentArchivedThreadsStackView.spacing = 10
        recentArchivedThreadsStackView.translatesAutoresizingMaskIntoConstraints = false
        recentArchivedSection.addArrangedSubview(recentArchivedThreadsStackView)

        NSLayoutConstraint.activate([
            recentArchivedThreadsStackView.widthAnchor.constraint(equalTo: recentArchivedSection.widthAnchor),
        ])

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
            sidebarCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            injectionCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            reviewCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            recentArchivedCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshArchivedThreadsNotificationReceived),
            name: .magentArchivedThreadsDidChange,
            object: nil
        )

        refreshRecentlyArchivedThreads()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didInitialScrollToTop {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        dismissSectionColorPickerIfNeeded()
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

    func refreshRecentlyArchivedThreads() {
        guard isViewLoaded, recentArchivedThreadsStackView != nil else { return }

        let currentSettings = persistence.loadSettings()
        let projectsById = Dictionary(uniqueKeysWithValues: currentSettings.projects.map { ($0.id, $0.name) })
        let archivedThreads = persistence.loadThreads()
            .filter { $0.isArchived && !$0.isMain }
            .sorted { lhs, rhs in
                let lhsDate = lhs.archivedAt ?? .distantPast
                let rhsDate = rhs.archivedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.createdAt > rhs.createdAt
            }

        recentArchivedThreadsById = Dictionary(
            uniqueKeysWithValues: archivedThreads.map { ($0.id, $0) }
        )

        recentArchivedThreadsStackView.arrangedSubviews.forEach { subview in
            recentArchivedThreadsStackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let recentThreads = Array(archivedThreads.prefix(Self.recentArchivedThreadLimit))
        guard !recentThreads.isEmpty else {
            let emptyLabel = NSTextField(wrappingLabelWithString: "No recently archived threads.")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = NSColor(resource: .textSecondary)
            recentArchivedThreadsStackView.addArrangedSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.widthAnchor.constraint(equalTo: recentArchivedThreadsStackView.widthAnchor),
            ])
            return
        }

        for (index, thread) in recentThreads.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                recentArchivedThreadsStackView.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalTo: recentArchivedThreadsStackView.widthAnchor),
                ])
            }
            let row = makeRecentArchivedThreadRow(
                thread: thread,
                projectName: projectsById[thread.projectId] ?? "Unknown Project"
            )
            recentArchivedThreadsStackView.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: recentArchivedThreadsStackView.widthAnchor),
            ])
        }
    }

    @objc private func refreshArchivedThreadsNotificationReceived(_ notification: Notification) {
        refreshRecentlyArchivedThreads()
    }

    private func makeRecentArchivedThreadRow(thread: MagentThread, projectName: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        )
        iconView.contentTintColor = NSColor(resource: .textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        row.addArrangedSubview(iconView)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // "Thread archived" caption
        let captionLabel = NSTextField(labelWithString: "Thread archived")
        captionLabel.font = .systemFont(ofSize: 10)
        captionLabel.textColor = NSColor(resource: .textSecondary)
        textStack.addArrangedSubview(captionLabel)

        // Description (prominent) or thread name as fallback
        let titleText: String
        if let description = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            titleText = description
        } else {
            titleText = thread.name
        }
        let titleLabel = NSTextField(wrappingLabelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(resource: .textPrimary)
        textStack.addArrangedSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])

        // Branch + worktree folder (prominent, skip worktree if same as branch)
        let worktreeFolder = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        let resolvedBranch = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchWorktreeText: String
        if resolvedBranch == worktreeFolder {
            branchWorktreeText = resolvedBranch
        } else {
            branchWorktreeText = "\(resolvedBranch)  ·  \(worktreeFolder)"
        }
        let branchWorktreeLabel = NSTextField(labelWithString: branchWorktreeText)
        branchWorktreeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        branchWorktreeLabel.textColor = NSColor(resource: .textPrimary)
        textStack.addArrangedSubview(branchWorktreeLabel)

        // Metadata: project · archived date
        let metadataLabel = NSTextField(
            wrappingLabelWithString: recentArchivedThreadMetadata(
                thread: thread,
                projectName: projectName
            )
        )
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = NSColor(resource: .textSecondary)
        textStack.addArrangedSubview(metadataLabel)

        row.addArrangedSubview(textStack)

        NSLayoutConstraint.activate([
            metadataLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
        ])

        let restoreButton = NSButton(title: "Restore", target: self, action: #selector(restoreArchivedThreadTapped(_:)))
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.identifier = NSUserInterfaceItemIdentifier(thread.id.uuidString)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        container.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: restoreButton.leadingAnchor, constant: -8),
            restoreButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            restoreButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func recentArchivedThreadMetadata(thread: MagentThread, projectName: String) -> String {
        var segments = [projectName]
        if let archivedAt = thread.archivedAt {
            segments.append("Archived \(archivedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return segments.joined(separator: " · ")
    }

    @objc private func restoreArchivedThreadTapped(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let threadId = UUID(uuidString: rawValue),
              let thread = recentArchivedThreadsById[threadId] else { return }

        sender.isEnabled = false
        Task { [weak self] in
            let restored = await ThreadManager.shared.restoreArchivedThreadFromUserAction(
                id: thread.id,
                threadName: thread.name
            )
            await MainActor.run {
                if restored {
                    self?.refreshRecentlyArchivedThreads()
                } else {
                    sender.isEnabled = true
                }
            }
        }
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

    private func persistSettings(notify: Bool = false) {
        try? persistence.saveSettings(settings)
        guard notify else { return }
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)
    }

    @objc private func autoRenameBranchToggled() {
        settings.autoRenameBranches = autoRenameBranchCheckbox.state == .on
        persistSettings()
    }

    @objc private func autoSetDescriptionToggled() {
        settings.autoSetThreadDescription = autoSetDescriptionCheckbox.state == .on
        persistSettings()
    }

    @objc private func autoSetIconFromWorkTypeToggled() {
        settings.autoSetThreadIconFromWorkType = autoSetIconFromWorkTypeCheckbox.state == .on
        persistSettings()
    }

    @objc private func narrowThreadsToggled() {
        settings.narrowThreads = narrowThreadsCheckbox.state == .on
        persistSettings(notify: true)
    }

    @objc private func autoReorderOnCompletionToggled() {
        settings.autoReorderThreadsOnAgentCompletion = autoReorderOnCompletionCheckbox.state == .on
        persistSettings()
    }

    @objc private func showPRStatusBadgesToggled() {
        settings.showPRStatusBadges = showPRStatusBadgesCheckbox.state == .on
        persistSettings(notify: true)
    }

    @objc private func showJiraStatusBadgesToggled() {
        settings.showJiraStatusBadges = showJiraStatusBadgesCheckbox.state == .on
        persistSettings(notify: true)
    }

    @objc private func showBusyStateDurationToggled() {
        settings.showBusyStateDuration = showBusyStateDurationCheckbox.state == .on
        persistSettings(notify: true)
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

        persistSettings()
    }

    @objc private func useSectionsToggled() {
        settings.useThreadSections = useSectionsCheckbox.state == .on
        persistSettings()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func resetSlugPromptToDefault() {
        slugPromptTextView.string = AppSettings.defaultSlugPrompt
        settings.autoRenameSlugPrompt = AppSettings.defaultSlugPrompt
        persistSettings()
    }

    @objc private func resetReviewPromptToDefault() {
        reviewPromptTextView.string = AppSettings.defaultReviewPrompt
        settings.reviewPrompt = AppSettings.defaultReviewPrompt
        persistSettings()
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
        persistSettings()
        sectionsTableView.reloadData()
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

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if settings.threadSections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let alert = NSAlert()
            alert.messageText = "Duplicate Section"
            alert.informativeText = "A section named \"\(name)\" already exists."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let maxOrder = settings.threadSections.map(\.sortOrder).max() ?? -1
        let section = ThreadSection(
            name: name,
            colorHex: "#8E8E93",
            sortOrder: maxOrder + 1
        )
        settings.threadSections.append(section)
        persistSettings()
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup()

        showColorPicker(for: section)
    }
}
