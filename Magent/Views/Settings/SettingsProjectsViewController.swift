import Cocoa

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
    private var slugPromptCheckbox: NSButton!
    private var slugPromptTextView: NSTextView!
    private var slugPromptContainer: NSView!

    // Default section
    private var defaultSectionPopup: NSPopUpButton!

    // Sections management
    private var sectionsModePopup: NSPopUpButton!
    private var sectionsContentStack: NSStackView!
    private var sectionsTableView: NSTableView!
    private var currentEditingSectionId: UUID?

    private var projectSortedSections: [ThreadSection] {
        guard let index = selectedProjectIndex,
              let sections = settings.projects[index].threadSections else { return [] }
        return sections.sorted { $0.sortOrder < $1.sortOrder }
    }

    // Jira fields
    private var jiraProjectKeyField: NSTextField!
    private var jiraBoardPopup: NSPopUpButton!
    private var jiraAssigneeField: NSTextField!
    private var jiraSyncButton: NSButton!
    private var jiraAutoSyncCheckbox: NSButton!
    private var jiraBoards: [JiraBoard] = []

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
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)

        let (detailsCard, detailsStack) = createSectionCard(title: "Project Details")
        stack.addArrangedSubview(detailsCard)

        // Name
        let nameHeader = NSTextField(labelWithString: "Name")
        nameHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsStack.addArrangedSubview(nameHeader)

        nameField = NSTextField(string: project.name)
        nameField.font = .systemFont(ofSize: 13)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.target = self
        nameField.action = #selector(nameFieldChanged)
        detailsStack.addArrangedSubview(nameField)

        // Repo path
        let repoHeader = NSTextField(labelWithString: "Repository Path")
        repoHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsStack.addArrangedSubview(repoHeader)

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
        detailsStack.addArrangedSubview(repoRow)

        if !project.isValid {
            let warningLabel = NSTextField(labelWithString: "Path does not exist. Update the repository path.")
            warningLabel.font = .systemFont(ofSize: 11)
            warningLabel.textColor = .systemRed
            detailsStack.addArrangedSubview(warningLabel)
        }

        // Worktrees path
        let wtHeader = NSTextField(labelWithString: "Worktrees Path")
        wtHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsStack.addArrangedSubview(wtHeader)

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
        detailsStack.addArrangedSubview(wtRow)

        let resolved = project.resolvedWorktreesBasePath()
        if resolved != project.worktreesBasePath {
            let resolvedLabel = NSTextField(labelWithString: "Resolves to: \(resolved)")
            resolvedLabel.font = .systemFont(ofSize: 11)
            resolvedLabel.textColor = NSColor(resource: .textSecondary)
            resolvedLabel.lineBreakMode = .byTruncatingMiddle
            detailsStack.addArrangedSubview(resolvedLabel)
        }

        // Default branch
        let branchHeader = NSTextField(labelWithString: "Default Branch")
        branchHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsStack.addArrangedSubview(branchHeader)

        let branchDesc = NSTextField(labelWithString: "Base branch for new worktrees (empty = repo HEAD)")
        branchDesc.font = .systemFont(ofSize: 11)
        branchDesc.textColor = NSColor(resource: .textSecondary)
        detailsStack.addArrangedSubview(branchDesc)

        defaultBranchField = NSTextField(string: project.defaultBranch ?? "")
        defaultBranchField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        defaultBranchField.placeholderString = "e.g. develop, main"
        defaultBranchField.translatesAutoresizingMaskIntoConstraints = false
        defaultBranchField.target = self
        defaultBranchField.action = #selector(defaultBranchFieldChanged)
        detailsStack.addArrangedSubview(defaultBranchField)

        // Default Section popup
        let defaultSectionHeader = NSTextField(labelWithString: "Default Section")
        defaultSectionHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsStack.addArrangedSubview(defaultSectionHeader)

        let defaultSectionDesc = NSTextField(wrappingLabelWithString: "Section for new threads without an explicit section. \"Inherit global\" uses the global default.")
        defaultSectionDesc.font = .systemFont(ofSize: 11)
        defaultSectionDesc.textColor = NSColor(resource: .textSecondary)
        detailsStack.addArrangedSubview(defaultSectionDesc)

        defaultSectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultSectionPopup.target = self
        defaultSectionPopup.action = #selector(defaultSectionChanged)
        refreshDefaultSectionPopup(for: project)
        detailsStack.addArrangedSubview(defaultSectionPopup)

        // Sections card
        let (sectionsCard, sectionsStack) = createSectionCard(title: "Sections")

        let sectionsModeLabel = NSTextField(labelWithString: "Mode")
        sectionsModeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionsStack.addArrangedSubview(sectionsModeLabel)

        sectionsModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sectionsModePopup.addItem(withTitle: "Use Global Sections")
        sectionsModePopup.addItem(withTitle: "Custom Sections")
        sectionsModePopup.selectItem(at: project.threadSections != nil ? 1 : 0)
        sectionsModePopup.target = self
        sectionsModePopup.action = #selector(sectionsModeChanged)
        sectionsStack.addArrangedSubview(sectionsModePopup)

        sectionsContentStack = NSStackView()
        sectionsContentStack.orientation = .vertical
        sectionsContentStack.alignment = .leading
        sectionsContentStack.spacing = 8
        sectionsContentStack.isHidden = project.threadSections == nil

        sectionsTableView = NSTableView()
        sectionsTableView.headerView = nil
        sectionsTableView.style = .inset
        sectionsTableView.rowSizeStyle = .default
        sectionsTableView.selectionHighlightStyle = .none
        sectionsTableView.registerForDraggedTypes([.string])
        sectionsTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let sectionsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectSectionColumn"))
        sectionsTableView.addTableColumn(sectionsCol)
        sectionsTableView.dataSource = self
        sectionsTableView.delegate = self

        let sectionsScrollView = NSScrollView()
        sectionsScrollView.documentView = sectionsTableView
        sectionsScrollView.hasVerticalScroller = true
        sectionsScrollView.autohidesScrollers = true
        sectionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        sectionsContentStack.addArrangedSubview(sectionsScrollView)

        let addSectionBtn = NSButton(title: "Add Section...", target: self, action: #selector(addProjectSectionTapped))
        addSectionBtn.bezelStyle = .rounded
        addSectionBtn.controlSize = .small
        sectionsContentStack.addArrangedSubview(addSectionBtn)

        sectionsContentStack.translatesAutoresizingMaskIntoConstraints = false
        sectionsStack.addArrangedSubview(sectionsContentStack)

        stack.addArrangedSubview(sectionsCard)

        let (jiraCard, jiraStack) = createSectionCard(
            title: "Jira Integration",
            description: "Project-specific Jira settings for ticket sync and section mapping."
        )
        stack.addArrangedSubview(jiraCard)

        // Project Key
        let projectKeyLabel = NSTextField(labelWithString: "Project Key")
        projectKeyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        jiraStack.addArrangedSubview(projectKeyLabel)

        jiraProjectKeyField = NSTextField(string: project.jiraProjectKey ?? "")
        jiraProjectKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        jiraProjectKeyField.placeholderString = "e.g. IP, PROJ"
        jiraProjectKeyField.translatesAutoresizingMaskIntoConstraints = false
        jiraProjectKeyField.target = self
        jiraProjectKeyField.action = #selector(jiraProjectKeyChanged)
        jiraStack.addArrangedSubview(jiraProjectKeyField)

        // Board
        let boardLabel = NSTextField(labelWithString: "Board")
        boardLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        jiraStack.addArrangedSubview(boardLabel)

        let boardRow = NSStackView()
        boardRow.orientation = .horizontal
        boardRow.spacing = 8

        jiraBoardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        jiraBoardPopup.target = self
        jiraBoardPopup.action = #selector(jiraBoardChanged)
        if let boardName = project.jiraBoardName {
            jiraBoardPopup.addItem(withTitle: boardName)
        } else {
            jiraBoardPopup.addItem(withTitle: "Select board")
        }
        boardRow.addArrangedSubview(jiraBoardPopup)

        let refreshBoardsBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshBoardsTapped))
        refreshBoardsBtn.bezelStyle = .rounded
        refreshBoardsBtn.controlSize = .small
        boardRow.addArrangedSubview(refreshBoardsBtn)
        jiraStack.addArrangedSubview(boardRow)

        // Assignee Account ID
        let assigneeLabel = NSTextField(labelWithString: "Assignee Account ID")
        assigneeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        jiraStack.addArrangedSubview(assigneeLabel)

        let assigneeDesc = NSTextField(wrappingLabelWithString: "Your Jira account ID for filtering tickets.")
        assigneeDesc.font = .systemFont(ofSize: 11)
        assigneeDesc.textColor = NSColor(resource: .textSecondary)
        jiraStack.addArrangedSubview(assigneeDesc)

        jiraAssigneeField = NSTextField(string: project.jiraAssigneeAccountId ?? "")
        jiraAssigneeField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        jiraAssigneeField.placeholderString = "e.g. 5e0dd2629a4b780d990e8760"
        jiraAssigneeField.translatesAutoresizingMaskIntoConstraints = false
        jiraAssigneeField.target = self
        jiraAssigneeField.action = #selector(jiraAssigneeChanged)
        jiraStack.addArrangedSubview(jiraAssigneeField)

        // Sync Sections button
        jiraSyncButton = NSButton(title: "Sync Sections from Jira", target: self, action: #selector(syncSectionsFromJiraTapped))
        jiraSyncButton.bezelStyle = .rounded
        jiraStack.addArrangedSubview(jiraSyncButton)

        let syncDesc = NSTextField(wrappingLabelWithString: "Fetches statuses from project tickets and replaces this project's sections to match.")
        syncDesc.font = .systemFont(ofSize: 11)
        syncDesc.textColor = NSColor(resource: .textSecondary)
        jiraStack.addArrangedSubview(syncDesc)

        // Auto-sync checkbox
        jiraAutoSyncCheckbox = NSButton(
            checkboxWithTitle: "Enable auto-sync",
            target: self,
            action: #selector(jiraAutoSyncToggled)
        )
        jiraAutoSyncCheckbox.state = project.jiraSyncEnabled ? .on : .off
        jiraStack.addArrangedSubview(jiraAutoSyncCheckbox)

        let autoSyncDesc = NSTextField(wrappingLabelWithString: "Polls Jira and moves threads to matching sections. Creates threads for new tickets.")
        autoSyncDesc.font = .systemFont(ofSize: 11)
        autoSyncDesc.textColor = NSColor(resource: .textSecondary)
        jiraStack.addArrangedSubview(autoSyncDesc)

        let (overridesCard, overridesStack) = createSectionCard(title: "Project Overrides")
        stack.addArrangedSubview(overridesCard)

        let overrideDesc = NSTextField(
            wrappingLabelWithString: "Override global defaults for this project. \"Use Default\" inherits the value from General settings."
        )
        overrideDesc.font = .systemFont(ofSize: 11)
        overrideDesc.textColor = NSColor(resource: .textSecondary)
        overridesStack.addArrangedSubview(overrideDesc)

        // Agent type override
        let agentTypeHeader = NSTextField(labelWithString: "Default Agent")
        agentTypeHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        overridesStack.addArrangedSubview(agentTypeHeader)

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
        overridesStack.addArrangedSubview(agentTypePopup)

        // Slug Prompt Override
        let slugPromptHeader = NSTextField(labelWithString: "Slug Prompt")
        slugPromptHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        overridesStack.addArrangedSubview(slugPromptHeader)

        let hasCustomSlug = project.autoRenameSlugPrompt != nil
        slugPromptCheckbox = NSButton(
            checkboxWithTitle: "Use custom slug prompt for this project",
            target: self,
            action: #selector(slugPromptCheckboxToggled)
        )
        slugPromptCheckbox.state = hasCustomSlug ? .on : .off
        overridesStack.addArrangedSubview(slugPromptCheckbox)

        let slugPromptWrapper = NSStackView()
        slugPromptWrapper.orientation = .vertical
        slugPromptWrapper.alignment = .leading
        slugPromptWrapper.spacing = 4

        slugPromptTextView = NSTextView()
        slugPromptTextView.font = .systemFont(ofSize: 13)
        slugPromptTextView.string = project.autoRenameSlugPrompt ?? settings.autoRenameSlugPrompt
        slugPromptTextView.isRichText = false
        slugPromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        slugPromptTextView.isAutomaticDashSubstitutionEnabled = false
        slugPromptTextView.isAutomaticTextReplacementEnabled = false
        slugPromptTextView.delegate = self
        slugPromptTextView.isVerticallyResizable = true
        slugPromptTextView.isHorizontallyResizable = false
        slugPromptTextView.textContainerInset = NSSize(width: 4, height: 4)
        slugPromptTextView.isEditable = hasCustomSlug

        let slugScrollView = NSScrollView()
        slugScrollView.documentView = slugPromptTextView
        slugScrollView.hasVerticalScroller = true
        slugScrollView.autohidesScrollers = true
        slugScrollView.borderType = .bezelBorder
        slugScrollView.translatesAutoresizingMaskIntoConstraints = false

        let slugLineHeight = NSFont.systemFont(ofSize: 13).ascender + abs(NSFont.systemFont(ofSize: 13).descender) + NSFont.systemFont(ofSize: 13).leading
        let slugHeight = max(slugLineHeight * 3 + 12, 56)
        NSLayoutConstraint.activate([
            slugScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: slugHeight),
        ])

        slugPromptWrapper.addArrangedSubview(slugScrollView)

        let resetSlugButton = NSButton(title: "Reset to Global", target: self, action: #selector(resetSlugPromptToGlobal))
        resetSlugButton.bezelStyle = .rounded
        resetSlugButton.controlSize = .small
        slugPromptWrapper.addArrangedSubview(resetSlugButton)

        slugPromptWrapper.translatesAutoresizingMaskIntoConstraints = false
        overridesStack.addArrangedSubview(slugPromptWrapper)

        slugPromptTextView.autoresizingMask = [.width]
        slugPromptTextView.textContainer?.widthTracksTextView = true

        slugPromptContainer = slugPromptWrapper
        slugPromptContainer.isHidden = !hasCustomSlug

        // Terminal Injection Override
        let globalTerminal = settings.terminalInjectionCommand
        let terminalDesc = globalTerminal.isEmpty
            ? "No global default set"
            : "Global default: \(globalTerminal.prefix(60))\(globalTerminal.count > 60 ? "..." : "")"
        terminalInjectionTextView = createOverrideSection(
            in: overridesStack,
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
            in: overridesStack,
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

            detailsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sectionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sectionsScrollView.widthAnchor.constraint(equalTo: sectionsContentStack.widthAnchor),
            sectionsScrollView.heightAnchor.constraint(equalToConstant: 140),
            sectionsContentStack.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor),
            jiraCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overridesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            repoRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            wtRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultBranchField.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultSectionDesc.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultSectionPopup.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            jiraProjectKeyField.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
            boardRow.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
            jiraAssigneeField.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
            syncDesc.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
            autoSyncDesc.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
            overrideDesc.widthAnchor.constraint(equalTo: overridesStack.widthAnchor),
            slugPromptWrapper.widthAnchor.constraint(equalTo: overridesStack.widthAnchor),
            slugScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
        ])
    }

    private func createSectionCard(title: String, description: String? = nil) -> (container: NSView, content: NSStackView) {
        let container = SettingsSectionCardView()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
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

    @objc private func slugPromptCheckboxToggled() {
        guard let index = selectedProjectIndex else { return }
        let enabled = slugPromptCheckbox.state == .on
        if enabled {
            // Initialize with global slug prompt
            let globalPrompt = settings.autoRenameSlugPrompt
            settings.projects[index].autoRenameSlugPrompt = globalPrompt
            slugPromptTextView.string = globalPrompt
            slugPromptTextView.isEditable = true
        } else {
            settings.projects[index].autoRenameSlugPrompt = nil
            slugPromptTextView.string = settings.autoRenameSlugPrompt
            slugPromptTextView.isEditable = false
        }
        slugPromptContainer.isHidden = !enabled
        try? persistence.saveSettings(settings)
    }

    @objc private func resetSlugPromptToGlobal() {
        guard let index = selectedProjectIndex else { return }
        let globalPrompt = settings.autoRenameSlugPrompt
        slugPromptTextView.string = globalPrompt
        settings.projects[index].autoRenameSlugPrompt = globalPrompt
        try? persistence.saveSettings(settings)
    }

    // MARK: - Default Section

    private func refreshDefaultSectionPopup(for project: Project) {
        defaultSectionPopup.removeAllItems()
        defaultSectionPopup.addItem(withTitle: "Inherit global")
        let visible = settings.visibleSections(for: project.id)
        for section in visible {
            defaultSectionPopup.addItem(withTitle: section.name)
        }
        if let id = project.defaultSectionId,
           let idx = visible.firstIndex(where: { $0.id == id }) {
            defaultSectionPopup.selectItem(at: idx + 1) // +1 for "Inherit global"
        } else {
            defaultSectionPopup.selectItem(at: 0)
        }
    }

    @objc private func defaultSectionChanged() {
        guard let index = selectedProjectIndex else { return }
        let selected = defaultSectionPopup.indexOfSelectedItem
        if selected == 0 {
            settings.projects[index].defaultSectionId = nil
        } else {
            let visible = settings.visibleSections(for: settings.projects[index].id)
            let sectionIndex = selected - 1
            if sectionIndex >= 0, sectionIndex < visible.count {
                settings.projects[index].defaultSectionId = visible[sectionIndex].id
            }
        }
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
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
        let oldResolved = settings.projects[index].resolvedWorktreesBasePath()
        panel.directoryURL = URL(fileURLWithPath: oldResolved)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let newPath = url.path

            // No-op if paths are the same
            guard newPath != oldResolved else { return }

            let project = self.settings.projects[index]
            let fm = FileManager.default
            var oldHasWorktrees = false
            if fm.fileExists(atPath: oldResolved) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldResolved)) ?? []
                oldHasWorktrees = contents.contains { entry in
                    entry != ".magent-cache.json" && !entry.hasPrefix(".")
                }
            }

            if oldHasWorktrees {
                Task {
                    do {
                        try await ThreadManager.shared.moveWorktreesBasePath(
                            for: project, from: oldResolved, to: newPath
                        )
                    } catch let error as ThreadManagerError {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Cannot Change Worktrees Path"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = self.view.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                        return
                    } catch {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Failed to Move Worktrees"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = self.view.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                        return
                    }

                    await MainActor.run {
                        self.settings.projects[index].worktreesBasePath = newPath
                        try? self.persistence.saveSettings(self.settings)
                        self.showDetailForProject(self.settings.projects[index])
                    }

                    await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index])
                }
            } else {
                // No worktrees to move — just update the setting
                self.settings.projects[index].worktreesBasePath = newPath
                try? self.persistence.saveSettings(self.settings)
                self.showDetailForProject(self.settings.projects[index])
                Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index]) }
            }
        }
    }

    // MARK: - Sections Actions

    @objc private func sectionsModeChanged() {
        guard let index = selectedProjectIndex else { return }
        let isCustom = sectionsModePopup.indexOfSelectedItem == 1

        if isCustom {
            if settings.projects[index].threadSections == nil {
                // Copy global sections
                settings.projects[index].threadSections = settings.threadSections
            }
        } else {
            settings.projects[index].threadSections = nil
            settings.projects[index].defaultSectionId = nil
        }

        try? persistence.saveSettings(settings)
        sectionsContentStack.isHidden = !isCustom
        sectionsTableView?.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func addProjectSectionTapped() {
        guard let index = selectedProjectIndex else { return }

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

        var sections = settings.projects[index].threadSections ?? []
        let maxOrder = sections.map(\.sortOrder).max() ?? -1
        let section = ThreadSection(
            name: name,
            colorHex: "#8E8E93",
            sortOrder: maxOrder + 1
        )
        sections.append(section)
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

        showProjectColorPicker(for: section)
    }

    private func threadsInProjectSection(_ section: ThreadSection, projectIndex: Int) -> [MagentThread] {
        let project = settings.projects[projectIndex]
        let sections = project.threadSections ?? []
        let knownIds = Set(sections.map(\.id))
        let defaultId = project.defaultSectionId ?? sections.first?.id
        return ThreadManager.shared.threads.filter { thread in
            guard !thread.isMain, thread.projectId == project.id else { return false }
            let effectiveId: UUID?
            if let sid = thread.sectionId, knownIds.contains(sid) {
                effectiveId = sid
            } else {
                effectiveId = defaultId
            }
            return effectiveId == section.id
        }
    }

    @objc private func projectSectionVisibilityToggled(_ sender: NSButton) {
        guard let index = selectedProjectIndex else { return }
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = projectSortedSections[row]
        guard var sections = settings.projects[index].threadSections,
              let sectionIndex = sections.firstIndex(where: { $0.id == section.id }) else { return }

        if section.isVisible {
            let threadsHere = threadsInProjectSection(section, projectIndex: index)
            if !threadsHere.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Cannot Hide Section"
                alert.informativeText = "Move all threads out of \"\(section.name)\" before hiding it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }

        sections[sectionIndex].isVisible.toggle()
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func deleteProjectSectionTapped(_ sender: NSButton) {
        guard let index = selectedProjectIndex else { return }
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = projectSortedSections[row]
        guard var sections = settings.projects[index].threadSections else { return }

        guard sections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let threadsInSection = threadsInProjectSection(section, projectIndex: index)
        if !threadsInSection.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "Move all threads out of \"\(section.name)\" before deleting it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if settings.projects[index].defaultSectionId == section.id {
            settings.projects[index].defaultSectionId = nil
        }
        sections.removeAll { $0.id == section.id }
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func projectSectionColorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }
        showProjectColorPicker(for: projectSortedSections[row])
    }

    private func showProjectColorPicker(for section: ThreadSection) {
        let panel = NSColorPanel.shared
        panel.color = section.color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(projectSectionColorChanged(_:)))
        currentEditingSectionId = section.id
        panel.orderFront(nil)
    }

    @objc private func projectSectionColorChanged(_ sender: NSColorPanel) {
        guard let sectionId = currentEditingSectionId,
              let index = selectedProjectIndex,
              var sections = settings.projects[index].threadSections,
              let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }

        sections[sectionIndex].colorHex = sender.color.hexString
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    // MARK: - Jira Actions

    @objc private func jiraProjectKeyChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = jiraProjectKeyField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        settings.projects[index].jiraProjectKey = value.isEmpty ? nil : value
        jiraProjectKeyField.stringValue = value
        try? persistence.saveSettings(settings)
    }

    @objc private func jiraBoardChanged() {
        guard let index = selectedProjectIndex else { return }
        let selected = jiraBoardPopup.indexOfSelectedItem
        if selected >= 0, selected < jiraBoards.count {
            let board = jiraBoards[selected]
            settings.projects[index].jiraBoardId = board.id
            settings.projects[index].jiraBoardName = board.name
        } else {
            settings.projects[index].jiraBoardId = nil
            settings.projects[index].jiraBoardName = nil
        }
        try? persistence.saveSettings(settings)
    }

    @objc private func refreshBoardsTapped() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            jiraBoardPopup.removeAllItems()
            jiraBoardPopup.addItem(withTitle: "Loading...")

            do {
                let boards = try await JiraService.shared.listBoards()
                self.jiraBoards = boards

                jiraBoardPopup.removeAllItems()
                if boards.isEmpty {
                    jiraBoardPopup.addItem(withTitle: "No boards found")
                } else {
                    for board in boards {
                        jiraBoardPopup.addItem(withTitle: "\(board.name) (#\(board.id))")
                    }
                    // Select current board if set
                    if let index = selectedProjectIndex,
                       let currentId = settings.projects[index].jiraBoardId,
                       let boardIndex = boards.firstIndex(where: { $0.id == currentId }) {
                        jiraBoardPopup.selectItem(at: boardIndex)
                    }
                }
            } catch {
                jiraBoardPopup.removeAllItems()
                jiraBoardPopup.addItem(withTitle: "Error: \(error.localizedDescription)")
            }
        }
    }

    @objc private func jiraAssigneeChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = jiraAssigneeField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.projects[index].jiraAssigneeAccountId = value.isEmpty ? nil : value
        try? persistence.saveSettings(settings)
    }

    @objc private func syncSectionsFromJiraTapped() {
        guard let index = selectedProjectIndex else { return }
        let project = settings.projects[index]

        guard project.jiraProjectKey?.isEmpty == false else {
            BannerManager.shared.show(message: "Set a Jira project key first", style: .warning, duration: 3.0)
            return
        }

        jiraSyncButton.isEnabled = false
        jiraSyncButton.title = "Syncing..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                jiraSyncButton.isEnabled = true
                jiraSyncButton.title = "Sync Sections from Jira"
            }

            do {
                let sections = try await ThreadManager.shared.syncSectionsFromJira(project: project)
                guard !sections.isEmpty else {
                    BannerManager.shared.show(message: "No statuses found for \(project.jiraProjectKey ?? "")", style: .warning, duration: 3.0)
                    return
                }

                settings.projects[index].threadSections = sections
                settings.projects[index].jiraAcknowledgedStatuses = nil
                try? persistence.saveSettings(settings)
                NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

                // Update sections card UI
                sectionsModePopup?.selectItem(at: 1)
                sectionsContentStack?.isHidden = false
                sectionsTableView?.reloadData()
                refreshDefaultSectionPopup(for: settings.projects[index])

                BannerManager.shared.show(
                    message: "Created \(sections.count) sections from Jira statuses",
                    style: .info,
                    duration: 3.0
                )
            } catch {
                BannerManager.shared.show(
                    message: "Failed to sync: \(error.localizedDescription)",
                    style: .error,
                    duration: 5.0
                )
            }
        }
    }

    @objc private func jiraAutoSyncToggled() {
        guard let index = selectedProjectIndex else { return }
        let enabling = jiraAutoSyncCheckbox.state == .on

        if enabling {
            let project = settings.projects[index]
            var missing: [String] = []
            if project.jiraProjectKey?.isEmpty != false { missing.append("Project Key") }
            if project.jiraAssigneeAccountId?.isEmpty != false { missing.append("Assignee Account ID") }
            let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
            if siteURL.isEmpty { missing.append("Jira Site URL (set in Settings > Jira)") }

            if !missing.isEmpty {
                jiraAutoSyncCheckbox.state = .off
                BannerManager.shared.show(
                    message: "Cannot enable sync — missing: \(missing.joined(separator: ", "))",
                    style: .warning,
                    duration: 5.0
                )
                return
            }
        }

        settings.projects[index].jiraSyncEnabled = enabling
        try? persistence.saveSettings(settings)

        // Auto-create project sections from Jira when enabling sync and no custom sections exist
        if enabling, settings.projects[index].threadSections == nil {
            let project = settings.projects[index]
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let sections = try await ThreadManager.shared.syncSectionsFromJira(project: project)
                    guard !sections.isEmpty else { return }
                    settings.projects[index].threadSections = sections
                    try? persistence.saveSettings(settings)
                    NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

                    // Update sections card UI
                    sectionsModePopup?.selectItem(at: 1)
                    sectionsContentStack?.isHidden = false
                    sectionsTableView?.reloadData()
                    refreshDefaultSectionPopup(for: settings.projects[index])

                    BannerManager.shared.show(
                        message: "Created \(sections.count) sections from Jira statuses",
                        style: .info,
                        duration: 3.0
                    )
                } catch {
                    // Non-critical — sync will retry on next tick
                }
            }
        }
    }
}

extension SettingsProjectsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sectionsTableView {
            return projectSortedSections.count
        }
        return settings.projects.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === sectionsTableView else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === sectionsTableView else { return [] }
        return dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === sectionsTableView,
              let index = selectedProjectIndex,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: .string),
              let sourceRow = Int(rowStr) else { return false }

        var sections = projectSortedSections
        let moved = sections.remove(at: sourceRow)
        let dest = sourceRow < row ? row - 1 : row
        sections.insert(moved, at: dest)

        for (i, section) in sections.enumerated() {
            if var projectSections = settings.projects[index].threadSections,
               let idx = projectSections.firstIndex(where: { $0.id == section.id }) {
                projectSections[idx].sortOrder = i
                settings.projects[index].threadSections = projectSections
            }
        }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        return true
    }
}

extension SettingsProjectsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sectionsTableView {
            return sectionsCellView(for: row, in: tableView)
        }

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

    private func sectionsCellView(for row: Int, in tableView: NSTableView) -> NSView? {
        let section = projectSortedSections[row]
        let identifier = NSUserInterfaceItemIdentifier("ProjectSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.tag = 200
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.tag = 201
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.tag = 202
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

        if let colorBtn = cell.viewWithTag(200) as? NSButton {
            colorBtn.image = colorDotImage(color: section.color, size: 12)
            colorBtn.target = self
            colorBtn.action = #selector(projectSectionColorDotClicked(_:))
        }

        if let visBtn = cell.viewWithTag(201) as? NSButton {
            let symbolName = section.isVisible ? "eye" : "eye.slash"
            visBtn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visBtn.contentTintColor = section.isVisible ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
            visBtn.target = self
            visBtn.action = #selector(projectSectionVisibilityToggled(_:))
        }

        if let delBtn = cell.viewWithTag(202) as? NSButton {
            delBtn.target = self
            delBtn.action = #selector(deleteProjectSectionTapped(_:))
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView === projectTableView else { return }
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
        } else if textView === slugPromptTextView {
            settings.projects[index].autoRenameSlugPrompt = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}
