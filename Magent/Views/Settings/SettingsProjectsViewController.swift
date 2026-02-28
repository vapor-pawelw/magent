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

        // Slug Prompt Override
        let slugPromptHeader = NSTextField(labelWithString: "Slug Prompt")
        slugPromptHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(slugPromptHeader)

        let hasCustomSlug = project.autoRenameSlugPrompt != nil
        slugPromptCheckbox = NSButton(
            checkboxWithTitle: "Use custom slug prompt for this project",
            target: self,
            action: #selector(slugPromptCheckboxToggled)
        )
        slugPromptCheckbox.state = hasCustomSlug ? .on : .off
        stack.addArrangedSubview(slugPromptCheckbox)

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
        stack.addArrangedSubview(slugPromptWrapper)

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
            slugPromptWrapper.widthAnchor.constraint(equalTo: stack.widthAnchor),
            slugScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
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
        } else if textView === slugPromptTextView {
            settings.projects[index].autoRenameSlugPrompt = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}
