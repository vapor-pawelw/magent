import Cocoa
import MagentCore

extension SettingsProjectsViewController {

    func showDetailForProject(_ project: Project) {
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

        createLocalSyncEntriesSection(in: detailsStack, project: project)

        // Default Section popup
        defaultSectionContainer = NSStackView()
        defaultSectionContainer.orientation = .vertical
        defaultSectionContainer.alignment = .leading
        defaultSectionContainer.spacing = 4
        detailsStack.addArrangedSubview(defaultSectionContainer)

        let defaultSectionHeader = NSTextField(labelWithString: "Default Section")
        defaultSectionHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        defaultSectionContainer.addArrangedSubview(defaultSectionHeader)

        let defaultSectionDesc = NSTextField(wrappingLabelWithString: "Section for new threads without an explicit section. \"Inherit global\" uses the global default.")
        defaultSectionDesc.font = .systemFont(ofSize: 11)
        defaultSectionDesc.textColor = NSColor(resource: .textSecondary)
        defaultSectionContainer.addArrangedSubview(defaultSectionDesc)

        defaultSectionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultSectionPopup.target = self
        defaultSectionPopup.action = #selector(defaultSectionChanged)
        refreshDefaultSectionPopup(for: project)
        defaultSectionContainer.addArrangedSubview(defaultSectionPopup)

        // Sections card
        let (sectionsCard, sectionsStack) = createSectionCard(title: "Sections")

        let sectionsVisibilityLabel = NSTextField(labelWithString: "Visibility")
        sectionsVisibilityLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionsStack.addArrangedSubview(sectionsVisibilityLabel)

        threadListLayoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let globalLayoutName = settings.useThreadSections ? "Enabled" : "Disabled"
        threadListLayoutPopup.addItem(withTitle: "Use App Default (\(globalLayoutName))")
        threadListLayoutPopup.addItem(withTitle: "Always Enabled")
        threadListLayoutPopup.addItem(withTitle: "Always Disabled")
        switch project.useThreadSectionsOverride {
        case .some(true):
            threadListLayoutPopup.selectItem(at: 1)
        case .some(false):
            threadListLayoutPopup.selectItem(at: 2)
        case .none:
            threadListLayoutPopup.selectItem(at: 0)
        }
        threadListLayoutPopup.target = self
        threadListLayoutPopup.action = #selector(threadListLayoutOverrideChanged)
        sectionsStack.addArrangedSubview(threadListLayoutPopup)

        sectionsOverridesStack = NSStackView()
        sectionsOverridesStack.orientation = .vertical
        sectionsOverridesStack.alignment = .leading
        sectionsOverridesStack.spacing = 8
        sectionsOverridesStack.translatesAutoresizingMaskIntoConstraints = false
        sectionsStack.addArrangedSubview(sectionsOverridesStack)

        let sectionsModeLabel = NSTextField(labelWithString: "Section Source")
        sectionsModeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionsOverridesStack.addArrangedSubview(sectionsModeLabel)

        sectionsModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sectionsModePopup.addItem(withTitle: "Use Global Sections")
        sectionsModePopup.addItem(withTitle: "Custom Sections")
        sectionsModePopup.selectItem(at: project.threadSections != nil ? 1 : 0)
        sectionsModePopup.target = self
        sectionsModePopup.action = #selector(sectionsModeChanged)
        sectionsOverridesStack.addArrangedSubview(sectionsModePopup)

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
        sectionsTableView.registerForDraggedTypes([Self.sectionRowPasteboardType])
        sectionsTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let sectionsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectSectionColumn"))
        sectionsTableView.addTableColumn(sectionsCol)
        sectionsTableView.dataSource = self
        sectionsTableView.delegate = self
        sectionsTableView.target = self
        sectionsTableView.doubleAction = #selector(projectSectionTableDoubleClicked(_:))

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
        sectionsOverridesStack.addArrangedSubview(sectionsContentStack)

        stack.addArrangedSubview(sectionsCard)

        var jiraCard: NSView?
        var jiraStack: NSStackView?
        var boardRow: NSStackView?
        var syncDesc: NSTextField?
        var autoSyncDesc: NSTextField?

        if AppFeatures.jiraSyncEnabled {
            let jiraSection = createSectionCard(
                title: AppFeatures.annotatedTitle("Jira Sync", for: .jiraSync),
                description: "Project-specific Jira sync settings: ticket-to-thread sync and section mapping."
            )
            jiraCard = jiraSection.container
            jiraStack = jiraSection.content
            stack.addArrangedSubview(jiraSection.container)

            let projectKeyLabel = NSTextField(labelWithString: "Project Key")
            projectKeyLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            jiraSection.content.addArrangedSubview(projectKeyLabel)

            jiraProjectKeyField = NSTextField(string: project.jiraProjectKey ?? "")
            jiraProjectKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            jiraProjectKeyField.placeholderString = "e.g. IP, PROJ"
            jiraProjectKeyField.translatesAutoresizingMaskIntoConstraints = false
            jiraProjectKeyField.target = self
            jiraProjectKeyField.action = #selector(jiraProjectKeyChanged)
            jiraSection.content.addArrangedSubview(jiraProjectKeyField)

            let boardLabel = NSTextField(labelWithString: "Board")
            boardLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            jiraSection.content.addArrangedSubview(boardLabel)

            let currentBoardRow = NSStackView()
            currentBoardRow.orientation = .horizontal
            currentBoardRow.spacing = 8
            boardRow = currentBoardRow

            jiraBoardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            jiraBoardPopup.target = self
            jiraBoardPopup.action = #selector(jiraBoardChanged)
            if let boardName = project.jiraBoardName {
                jiraBoardPopup.addItem(withTitle: boardName)
            } else {
                jiraBoardPopup.addItem(withTitle: "Select board")
            }
            currentBoardRow.addArrangedSubview(jiraBoardPopup)

            let refreshBoardsBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshBoardsTapped))
            refreshBoardsBtn.bezelStyle = .rounded
            refreshBoardsBtn.controlSize = .small
            currentBoardRow.addArrangedSubview(refreshBoardsBtn)
            jiraSection.content.addArrangedSubview(currentBoardRow)

            let assigneeLabel = NSTextField(labelWithString: "Assignee Account ID")
            assigneeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            jiraSection.content.addArrangedSubview(assigneeLabel)

            let assigneeDesc = NSTextField(wrappingLabelWithString: "Your Jira account ID for filtering tickets.")
            assigneeDesc.font = .systemFont(ofSize: 11)
            assigneeDesc.textColor = NSColor(resource: .textSecondary)
            jiraSection.content.addArrangedSubview(assigneeDesc)

            jiraAssigneeField = NSTextField(string: project.jiraAssigneeAccountId ?? "")
            jiraAssigneeField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            jiraAssigneeField.placeholderString = "e.g. 5e0dd2629a4b780d990e8760"
            jiraAssigneeField.translatesAutoresizingMaskIntoConstraints = false
            jiraAssigneeField.target = self
            jiraAssigneeField.action = #selector(jiraAssigneeChanged)
            jiraSection.content.addArrangedSubview(jiraAssigneeField)

            jiraSectionsSyncControlsStack = NSStackView()
            jiraSectionsSyncControlsStack.orientation = .vertical
            jiraSectionsSyncControlsStack.alignment = .leading
            jiraSectionsSyncControlsStack.spacing = 4
            jiraSectionsSyncControlsStack.translatesAutoresizingMaskIntoConstraints = false
            jiraSection.content.addArrangedSubview(jiraSectionsSyncControlsStack)

            jiraSyncButton = NSButton(title: "Sync Sections from Jira", target: self, action: #selector(syncSectionsFromJiraTapped))
            jiraSyncButton.bezelStyle = .rounded
            jiraSectionsSyncControlsStack.addArrangedSubview(jiraSyncButton)

            let currentSyncDesc = NSTextField(wrappingLabelWithString: "Fetches statuses from project tickets and replaces this project's sections to match.")
            currentSyncDesc.font = .systemFont(ofSize: 11)
            currentSyncDesc.textColor = NSColor(resource: .textSecondary)
            jiraSectionsSyncControlsStack.addArrangedSubview(currentSyncDesc)
            syncDesc = currentSyncDesc

            jiraAutoSyncCheckbox = NSButton(
                checkboxWithTitle: "Enable auto-sync",
                target: self,
                action: #selector(jiraAutoSyncToggled)
            )
            jiraAutoSyncCheckbox.state = project.jiraSyncEnabled ? .on : .off
            jiraSectionsSyncControlsStack.addArrangedSubview(jiraAutoSyncCheckbox)

            let currentAutoSyncDesc = NSTextField(wrappingLabelWithString: "Polls Jira and moves threads to matching sections. Creates threads for new tickets.")
            currentAutoSyncDesc.font = .systemFont(ofSize: 11)
            currentAutoSyncDesc.textColor = NSColor(resource: .textSecondary)
            jiraSectionsSyncControlsStack.addArrangedSubview(currentAutoSyncDesc)
            autoSyncDesc = currentAutoSyncDesc

            updateSectionsVisibilityControls(for: project)
        }

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
            description: "Pre-filled into the prompt when creating a terminal session. Empty = use global default. \(terminalDesc)",
            value: project.terminalInjectionCommand ?? "",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        preAgentInjectionTextView = createOverrideSection(
            in: overridesStack,
            title: "Pre-Agent Command",
            description: "Runs after shell startup and before the agent command. Empty = disabled.",
            value: project.preAgentInjectionCommand ?? "",
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
            description: "Pre-filled into the prompt field when creating an agent session; skipped when you provide your own prompt. Empty = use global default. \(contextDesc)",
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
            sectionsContentStack.widthAnchor.constraint(equalTo: sectionsOverridesStack.widthAnchor),
            overridesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            repoRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            wtRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultBranchField.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultSectionContainer.widthAnchor.constraint(equalTo: detailsStack.widthAnchor),
            defaultSectionDesc.widthAnchor.constraint(equalTo: defaultSectionContainer.widthAnchor),
            defaultSectionPopup.widthAnchor.constraint(equalTo: defaultSectionContainer.widthAnchor),
            threadListLayoutPopup.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor),
            overrideDesc.widthAnchor.constraint(equalTo: overridesStack.widthAnchor),
            sectionsOverridesStack.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor),
            slugPromptWrapper.widthAnchor.constraint(equalTo: overridesStack.widthAnchor),
            slugScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
        ])

        if let jiraCard, let jiraStack, let boardRow, let syncDesc, let autoSyncDesc {
            NSLayoutConstraint.activate([
                jiraCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
                jiraProjectKeyField.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
                boardRow.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
                jiraAssigneeField.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
                jiraSectionsSyncControlsStack.widthAnchor.constraint(equalTo: jiraStack.widthAnchor),
                syncDesc.widthAnchor.constraint(equalTo: jiraSectionsSyncControlsStack.widthAnchor),
                autoSyncDesc.widthAnchor.constraint(equalTo: jiraSectionsSyncControlsStack.widthAnchor),
            ])
        }
    }

    func createSectionCard(title: String, description: String? = nil) -> (container: NSView, content: NSStackView) {
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

    func createOverrideSection(
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

    func createLocalSyncEntriesSection(in stackView: NSStackView, project: Project) {
        let titleLabel = NSTextField(labelWithString: "Local Sync Paths")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stackView.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(
            wrappingLabelWithString: "Repo-relative files/directories for local-only assets. Copy gives each thread its own version seeded from the base branch source. Shared Link creates a live symlink to the main repo copy."
        )
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        stackView.addArrangedSubview(descLabel)

        localFileSyncEntriesStack = NSStackView()
        localFileSyncEntriesStack.orientation = .vertical
        localFileSyncEntriesStack.alignment = .leading
        localFileSyncEntriesStack.spacing = 8
        localFileSyncEntriesStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(localFileSyncEntriesStack)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let addRowButton = NSButton(title: "Add Row", target: self, action: #selector(addLocalSyncEntryRow))
        addRowButton.bezelStyle = .rounded
        addRowButton.controlSize = .small
        buttonRow.addArrangedSubview(addRowButton)

        let addPathButton = NSButton(title: "Add Paths…", target: self, action: #selector(addLocalSyncPathsFromRepo))
        addPathButton.bezelStyle = .rounded
        addPathButton.controlSize = .small
        buttonRow.addArrangedSubview(addPathButton)

        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            localFileSyncEntriesStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])

        rebuildLocalSyncEntryRows(for: project.normalizedLocalFileSyncEntries)
    }

    func rebuildLocalSyncEntryRows(for entries: [LocalFileSyncEntry]) {
        guard let localFileSyncEntriesStack else { return }

        for arrangedSubview in localFileSyncEntriesStack.arrangedSubviews {
            localFileSyncEntriesStack.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        if entries.isEmpty {
            let emptyLabel = NSTextField(
                wrappingLabelWithString: "No local sync entries configured. Add copy entries for base-branch seeded files, or shared links for repo-root-backed symlinks."
            )
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = NSColor(resource: .textSecondary)
            localFileSyncEntriesStack.addArrangedSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.widthAnchor.constraint(equalTo: localFileSyncEntriesStack.widthAnchor),
            ])
            return
        }

        for entry in entries {
            let row = LocalSyncEntryRowView(entry: entry)
            row.onChange = { [weak self] _ in
                self?.persistLocalSyncEntriesFromVisibleRows()
            }
            row.onRemove = { [weak self, weak row] in
                guard let self, let row else { return }
                self.localFileSyncEntriesStack.removeArrangedSubview(row)
                row.removeFromSuperview()
                self.persistLocalSyncEntriesFromVisibleRows()
                self.rebuildLocalSyncEntryRows(for: self.visibleLocalSyncEntries())
            }
            localFileSyncEntriesStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: localFileSyncEntriesStack.widthAnchor),
            ])
        }
    }

    func visibleLocalSyncEntries() -> [LocalFileSyncEntry] {
        guard let localFileSyncEntriesStack else { return [] }
        let rows = localFileSyncEntriesStack.arrangedSubviews.compactMap { $0 as? LocalSyncEntryRowView }
        return rows.map(\.entry)
    }

    func persistLocalSyncEntriesFromVisibleRows() {
        guard let index = selectedProjectIndex else { return }
        settings.projects[index].localFileSyncEntries = Project.normalizeLocalFileSyncEntries(visibleLocalSyncEntries())
        try? persistence.saveSettings(settings)
    }
}

private final class LocalSyncEntryRowView: NSView, NSTextFieldDelegate {
    var entry: LocalFileSyncEntry {
        didSet {
            onChange?(entry)
        }
    }

    var onChange: ((LocalFileSyncEntry) -> Void)?
    var onRemove: (() -> Void)?

    private let pathField: NSTextField
    private let modePopup: NSPopUpButton

    init(entry: LocalFileSyncEntry) {
        self.entry = entry
        self.pathField = NSTextField(string: entry.path)
        self.modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        pathField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        pathField.placeholderString = "repo-relative/path"
        pathField.delegate = self
        row.addArrangedSubview(pathField)

        modePopup.addItems(withTitles: LocalFileSyncMode.allCases.map(\.displayName))
        if let selectedIndex = LocalFileSyncMode.allCases.firstIndex(of: entry.mode) {
            modePopup.selectItem(at: selectedIndex)
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        row.addArrangedSubview(modePopup)

        let removeButton = NSButton(
            image: NSImage(named: NSImage.removeTemplateName) ?? NSImage(),
            target: self,
            action: #selector(removeTapped)
        )
        removeButton.bezelStyle = .texturedRounded
        removeButton.controlSize = .small
        removeButton.imagePosition = .imageOnly
        removeButton.toolTip = "Remove Local Sync Path"
        row.addArrangedSubview(removeButton)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modePopup.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ obj: Notification) {
        entry.path = pathField.stringValue
    }

    @objc private func modeChanged() {
        let modes = LocalFileSyncMode.allCases
        let index = modePopup.indexOfSelectedItem
        guard modes.indices.contains(index) else { return }
        entry.mode = modes[index]
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}
