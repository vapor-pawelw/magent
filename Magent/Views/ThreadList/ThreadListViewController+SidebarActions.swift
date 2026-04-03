import Cocoa
import MagentCore

extension ThreadListViewController {

    // MARK: - Actions

    @objc func addThreadForProjectTapped(_ sender: NSButton) {
        guard !isCreatingThread else { return }

        suppressNextProjectRowToggle = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextProjectRowToggle = false
            }
        }

        guard let project = projectFromProjectHeaderButton(sender) else { return }
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            let resolvedAgent = threadManager.effectiveAgentType(for: project.id)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true, modelId: modelId, reasoningLevel: reasoning)
        } else {
            presentNewThreadSheet(for: project, anchorView: sender)
        }
    }

    @objc func toggleSectionExpanded(_ sender: NSButton) {
        suppressNextSectionRowToggle = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextSectionRowToggle = false
            }
        }

        let row = outlineView.row(for: sender)
        guard row >= 0,
              let section = outlineView.item(atRow: row) as? SidebarSection,
              !section.threads.isEmpty else { return }
        toggleSection(section, animatedDisclosureButton: sender)
    }

    @objc func toggleProjectExpanded(_ sender: NSButton) {
        suppressNextProjectRowToggle = true
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextProjectRowToggle = false
            }
        }

        let project: SidebarProject? = {
            if let rawProjectId = sender.objectValue as? String,
               let projectId = UUID(uuidString: rawProjectId),
               let matched = sidebarProjects.first(where: { $0.projectId == projectId }) {
                return matched
            }
            let row = outlineView.row(for: sender)
            guard row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? SidebarProject
        }()
        guard let project else { return }

        let willCollapse = !isProjectCollapsed(project)
        setProjectCollapsed(project, isCollapsed: willCollapse)
        reloadData()
    }

    func toggleSection(_ section: SidebarSection, animatedDisclosureButton: NSButton? = nil) {
        let willCollapse = !isSectionCollapsed(section)
        setSectionCollapsed(section, isCollapsed: willCollapse)

        if let button = animatedDisclosureButton {
            updateSectionDisclosureButton(button, isExpanded: !willCollapse)
        }
        reloadData()
    }

    func updateSectionDisclosureButton(_ button: NSButton, isExpanded: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.title = ""
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: isExpanded ? "Collapse section" : "Expand section"
        )?.withSymbolConfiguration(symbolConfig)
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(isExpanded ? "Collapse section" : "Expand section")
    }

    func updateProjectDisclosureButton(_ button: NSButton, isExpanded: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.title = ""
        button.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
            accessibilityDescription: isExpanded ? "Collapse project" : "Expand project"
        )?.withSymbolConfiguration(symbolConfig)
        button.imageScaling = .scaleNone
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(isExpanded ? "Collapse project" : "Expand project")
    }

    func sectionDisclosureButton(for section: SidebarSection) -> NSButton? {
        let row = outlineView.row(forItem: section)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return nil }
        return cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton
    }

    private func setSectionCollapsed(_ section: SidebarSection, isCollapsed: Bool) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionIdsKey) ?? [])
        let key = sectionCollapseStorageKey(section)
        if isCollapsed {
            collapsed.insert(key)
        } else {
            collapsed.remove(key)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedSectionIdsKey)
    }

    func isSectionCollapsed(_ section: SidebarSection) -> Bool {
        let collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionIdsKey) ?? [])
        return collapsed.contains(sectionCollapseStorageKey(section))
    }

    func isProjectCollapsed(_ project: SidebarProject) -> Bool {
        let collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        return collapsed.contains(project.projectId.uuidString)
    }

    func setProjectCollapsed(_ project: SidebarProject, isCollapsed: Bool) {
        var collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedProjectIdsKey) ?? [])
        if isCollapsed {
            collapsed.insert(project.projectId.uuidString)
        } else {
            collapsed.remove(project.projectId.uuidString)
        }
        UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedProjectIdsKey)
    }

    func sectionCollapseStorageKey(_ section: SidebarSection) -> String {
        "\(section.projectId.uuidString):\(section.sectionId.uuidString)"
    }

    private func refreshSectionDisclosureButton(for section: SidebarSection) {
        let row = outlineView.row(forItem: section)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let button = cell.subviews.first(where: { $0.identifier == Self.sectionDisclosureButtonIdentifier }) as? NSButton else { return }
        updateSectionDisclosureButton(button, isExpanded: !isSectionCollapsed(section))
    }

    func refreshVisibleSectionDisclosureButtons() {
        for row in 0..<outlineView.numberOfRows {
            guard let section = outlineView.item(atRow: row) as? SidebarSection else { continue }
            refreshSectionDisclosureButton(for: section)
        }
    }

    private func projectFromProjectHeaderButton(_ sender: NSButton) -> Project? {
        let settings = persistence.loadSettings()

        if let rawProjectId = sender.objectValue as? String,
           let projectId = UUID(uuidString: rawProjectId),
           let matched = settings.projects.first(where: { $0.id == projectId }) {
            return matched
        }

        let row = outlineView.row(for: sender)
        guard row >= 0,
              let sidebarProject = outlineView.item(atRow: row) as? SidebarProject else { return nil }
        return settings.projects.first(where: { $0.id == sidebarProject.projectId })
    }

    private func showNoProjectsAlert() {
        let alert = NSAlert()
        alert.messageText = "No Projects"
        alert.informativeText = "Add a project in Settings first."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func preferredProjectForQuickCreate(from projects: [Project]) -> Project? {
        guard !projects.isEmpty else { return nil }

        if let selectedThread = selectedThreadFromState(),
           let matched = projects.first(where: { $0.id == selectedThread.projectId }) {
            return matched
        }

        let selectedRow = outlineView.selectedRow
        if selectedRow >= 0 {
            if let selectedProject = outlineView.item(atRow: selectedRow) as? SidebarProject,
               let matched = projects.first(where: { $0.id == selectedProject.projectId }) {
                return matched
            }
        }

        if let lastProjectRaw = UserDefaults.standard.string(forKey: Self.lastOpenedProjectDefaultsKey),
           let lastProjectId = UUID(uuidString: lastProjectRaw),
           let matched = projects.first(where: { $0.id == lastProjectId }) {
            return matched
        }

        if let firstSidebarProject = sidebarProjects.first,
           let matched = projects.first(where: { $0.id == firstSidebarProject.projectId }) {
            return matched
        }

        return projects.first
    }

    func presentNewThreadSheet(
        for project: Project,
        anchorView: NSView,
        baseBranch: String? = nil,
        sourceThread: MagentThread? = nil,
        selectedSectionIdOverride: UUID? = nil,
        recoveryPrefill: AgentLaunchSheetPrefill? = nil
    ) {
        guard let window = view.window else { return }
        let settings = persistence.loadSettings()

        var autoHintParts: [String] = []
        if settings.autoRenameBranches { autoHintParts.append("branch") }
        if settings.autoSetThreadDescription { autoHintParts.append("description") }
        let autoGenerateHint: String? = autoHintParts.isEmpty ? nil : {
            let joined = autoHintParts.joined(separator: " and ")
            let cap = joined.prefix(1).uppercased() + joined.dropFirst()
            return "\(cap) will be auto-generated from the first prompt if left blank."
        }()

        let injection = threadManager.effectiveInjection(for: project.id)

        // Build per-project section data for the section picker.
        var sectionsByProjectId: [UUID: [ThreadSection]] = [:]
        var defaultSectionIdByProjectId: [UUID: UUID] = [:]
        for p in settings.projects {
            if settings.shouldUseThreadSections(for: p.id) {
                let visible = settings.visibleSections(for: p.id)
                if !visible.isEmpty {
                    sectionsByProjectId[p.id] = visible
                }
            }
            if let defaultId = settings.defaultSection(for: p.id)?.id {
                defaultSectionIdByProjectId[p.id] = defaultId
            }
        }

        // When creating from an existing thread, pre-select its section.
        if let sourceThread, let sourceSectionId = threadManager.effectiveSectionId(for: sourceThread, settings: settings) {
            defaultSectionIdByProjectId[sourceThread.projectId] = sourceSectionId
        }
        if let selectedSectionIdOverride {
            defaultSectionIdByProjectId[project.id] = selectedSectionIdOverride
        }

        let defaultBranchName = project.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only prefill the base branch field when explicitly creating from another thread's branch.
        // When nil, the field stays empty and uses the default branch placeholder.
        let resolvedBaseBranchPrefill: String? = baseBranch

        let isFork = sourceThread != nil && baseBranch != nil
        let sheetTitle = isFork ? "Fork Thread" : "New Thread"
        let sheetSubtitle: String? = {
            guard isFork, let src = sourceThread else { return nil }
            if src.isMain {
                return "Thread: Main"
            }
            if let desc = src.taskDescription {
                return "Thread: \(desc) (\(src.branchName))"
            }
            return "Thread: \(src.branchName)"
        }()

        let config = AgentLaunchSheetConfig(
            title: sheetTitle,
            acceptButtonTitle: "Create Thread",
            draftScope: .newThread(projectId: project.id),
            availableAgents: settings.availableActiveAgents,
            defaultAgentType: threadManager.effectiveAgentType(for: project.id),
            subtitle: sheetSubtitle,
            availableProjects: isFork ? [project] : settings.projects,
            showDescriptionAndBranchFields: true,
            autoGenerateHint: autoGenerateHint,
            terminalInjectionPrefill: injection.terminalCommand.isEmpty ? nil : injection.terminalCommand,
            agentContextPrefill: injection.agentContext.isEmpty ? nil : injection.agentContext,
            recoveryPrefill: recoveryPrefill,
            sectionsByProjectId: sectionsByProjectId,
            defaultSectionIdByProjectId: defaultSectionIdByProjectId,
            baseBranchPrefill: resolvedBaseBranchPrefill,
            baseBranchRepoPath: project.repoPath,
            defaultBranchName: defaultBranchName,
            showDraftCheckbox: true
        )
        let capturedSourceThread = sourceThread
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            guard let self, let result else { return }
            let targetProject = result.selectedProject ?? project

            // Insert after the source thread when in the same project, section, and
            // sidebar group. When the source is pinned, place at the top of the visible
            // group instead (right below pinned threads).
            let effectiveInsertAfter: UUID?
            let insertAtTop: Bool
            if let source = capturedSourceThread, targetProject.id == source.projectId {
                let settings = self.persistence.loadSettings()
                let sourceSectionId = self.threadManager.effectiveSectionId(for: source, settings: settings)
                let sameSection = sourceSectionId == result.selectedSectionId
                if source.sidebarListState == .visible && sameSection {
                    effectiveInsertAfter = source.id
                    insertAtTop = false
                } else if source.sidebarListState == .pinned && sameSection {
                    effectiveInsertAfter = nil
                    insertAtTop = true
                } else {
                    effectiveInsertAfter = nil
                    insertAtTop = false
                }
            } else {
                effectiveInsertAfter = nil
                insertAtTop = false
            }

            self.createThread(
                for: targetProject,
                requestedAgentType: result.agentType,
                useAgentCommand: result.isDraft ? false : result.useAgentCommand,
                sourceThread: capturedSourceThread,
                baseBranch: result.baseBranch,
                initialPrompt: result.isDraft ? nil : result.prompt,
                shouldSubmitInitialPrompt: !result.isDraft,
                taskDescription: result.description,
                requestedBranchName: result.branchName,
                pendingPromptFileURL: result.pendingPromptFileURL,
                requestedSectionId: result.selectedSectionId,
                insertAfterThreadId: effectiveInsertAfter,
                insertAtTopOfVisibleGroup: insertAtTop,
                initialWebURL: result.initialWebURL,
                draftPrompt: result.isDraft ? result.agentType.map { ($0, result.prompt ?? "", result.modelId, result.reasoningLevel) } : nil,
                modelId: result.modelId,
                reasoningLevel: result.reasoningLevel,
                localFileSyncEntriesOverride: isFork ? capturedSourceThread?.localFileSyncEntriesSnapshot : nil
            )
        }
    }

    func buildAgentSubmenu(for project: Project, extraData: [String: String] = [:]) -> NSMenu {
        let settings = persistence.loadSettings()
        let activeAgents = settings.availableActiveAgents
        var representedData = extraData
        representedData["projectId"] = project.id.uuidString

        let submenu = NSMenu()
        AgentMenuBuilder.populate(
            menu: submenu,
            menuTitle: "New Thread in \(project.name)",
            defaultAgentType: threadManager.effectiveAgentType(for: project.id),
            activeAgents: activeAgents,
            target: self,
            action: #selector(projectAgentMenuItemSelected(_:)),
            extraData: representedData
        )
        return submenu
    }

    @objc private func projectAgentMenuItemSelected(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender),
              let projectIdRaw = selection.data["projectId"],
              let projectId = UUID(uuidString: projectIdRaw) else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }

        let baseBranch = selection.data["baseBranch"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch selection.mode {
        case .terminal:
            createThread(for: project, requestedAgentType: nil, useAgentCommand: false, baseBranch: baseBranch)
        case .agent(let agentType):
            let modelId = AgentLastSelectionStore.lastModel(for: agentType)
            let reasoning = AgentLastSelectionStore.lastReasoning(for: agentType, modelId: modelId)
            createThread(for: project, requestedAgentType: agentType, useAgentCommand: true, baseBranch: baseBranch, modelId: modelId, reasoningLevel: reasoning)
        case .projectDefault:
            let resolvedAgent = threadManager.effectiveAgentType(for: project.id)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true, baseBranch: baseBranch, modelId: modelId, reasoningLevel: reasoning)
        case .web:
            presentNewThreadSheet(for: project, anchorView: outlineView)
        }
    }

    /// Called from SplitViewController's Cmd+Shift+N shortcut. Creates a new thread
    /// branching from the currently selected thread's branch, inheriting its section
    /// and inserting right below it in the sidebar.
    func requestNewThreadFromBranch() {
        guard !isCreatingThread else { return }

        let settings = persistence.loadSettings()
        guard let sourceThread = selectedThreadFromState(),
              let project = settings.projects.first(where: { $0.id == sourceThread.projectId }),
              let baseBranch = baseBranchForNewThread(from: sourceThread, project: project) else {
            // Fall back to regular new-thread flow when no thread is selected or no branch is available.
            requestNewThread()
            return
        }

        presentNewThreadSheet(
            for: project,
            anchorView: outlineView,
            baseBranch: baseBranch,
            sourceThread: sourceThread
        )
    }

    /// Called from SplitViewController's Cmd+N shortcut to respect the loading guard.
    /// Picks the most relevant project context and opens that project's agent menu.
    /// When a thread is selected, inherits its section and positions the new thread below it.
    func requestNewThread() {
        guard !isCreatingThread else { return }

        let settings = persistence.loadSettings()
        let projects = settings.projects
        guard !projects.isEmpty else {
            showNoProjectsAlert()
            return
        }
        guard let project = preferredProjectForQuickCreate(from: projects) else { return }

        // Use the selected thread as the source for section/position inheritance.
        let selectedSource = selectedThreadFromState()
        let sourceInSameProject = selectedSource?.projectId == project.id ? selectedSource : nil

        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            let isPinnedSource = sourceInSameProject?.sidebarListState == .pinned
            let resolvedAgent = threadManager.effectiveAgentType(for: project.id)
            let modelId = resolvedAgent.flatMap { AgentLastSelectionStore.lastModel(for: $0) }
            let reasoning = resolvedAgent.flatMap { AgentLastSelectionStore.lastReasoning(for: $0, modelId: modelId) }
            createThread(
                for: project,
                requestedAgentType: nil,
                useAgentCommand: true,
                requestedSectionId: sourceInSameProject?.sectionId,
                insertAfterThreadId: isPinnedSource ? nil : sourceInSameProject?.id,
                insertAtTopOfVisibleGroup: isPinnedSource,
                modelId: modelId,
                reasoningLevel: reasoning
            )
        } else {
            presentNewThreadSheet(for: project, anchorView: outlineView, sourceThread: sourceInSameProject)
        }
    }

    func createThread(
        for project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        sourceThread: MagentThread? = nil,
        baseBranch: String? = nil,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        taskDescription: String? = nil,
        requestedBranchName: String? = nil,
        pendingPromptFileURL: URL? = nil,
        requestedSectionId: UUID? = nil,
        insertAfterThreadId: UUID? = nil,
        insertAtTopOfVisibleGroup: Bool = false,
        initialWebURL: URL? = nil,
        draftPrompt: (agentType: AgentType, prompt: String, modelId: String?, reasoningLevel: String?)? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        localFileSyncEntriesOverride: [LocalFileSyncEntry]? = nil
    ) {
        isCreatingThread = true
        reloadData()

        Task {
            do {
                let created = try await self.threadManager.createThread(
                    project: project,
                    requestedAgentType: requestedAgentType,
                    useAgentCommand: useAgentCommand,
                    initialPrompt: initialPrompt,
                    shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                    initialDraftTab: draftPrompt.map { draftPrompt in
                        PersistedDraftTab(
                            identifier: "draft:\(UUID().uuidString)",
                            agentType: draftPrompt.agentType,
                            prompt: draftPrompt.prompt,
                            modelId: draftPrompt.modelId,
                            reasoningLevel: draftPrompt.reasoningLevel
                        )
                    },
                    requestedName: requestedBranchName,
                    requestedBaseBranch: baseBranch,
                    pendingPromptFileURL: pendingPromptFileURL,
                    requestedSectionId: requestedSectionId,
                    insertAfterThreadId: insertAfterThreadId,
                    insertAtTopOfVisibleGroup: insertAtTopOfVisibleGroup,
                    initialWebURL: initialWebURL,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel,
                    localFileSyncEntriesOverride: localFileSyncEntriesOverride
                )
                if let desc = taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !desc.isEmpty {
                    try? self.threadManager.setTaskDescription(threadId: created.id, description: desc)
                }
                // Unblock the + button as soon as the thread exists — the rename
                // below is a background nicety that shouldn't gate new-thread creation.
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                }
                // Trigger auto-rename from the draft prompt text after the draft-only
                // thread has been created and persisted.
                if let draftPrompt {
                    let trimmedPrompt = draftPrompt.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedPrompt.isEmpty {
                        _ = await self.threadManager.autoRenameThreadFromDraftPromptIfNeeded(
                            threadId: created.id,
                            prompt: trimmedPrompt
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                    let recoveryPrefill = self.failedThreadCreationRecoveryPrefill(
                        requestedAgentType: requestedAgentType,
                        useAgentCommand: useAgentCommand,
                        initialPrompt: initialPrompt,
                        taskDescription: taskDescription,
                        requestedBranchName: requestedBranchName,
                        initialWebURL: initialWebURL,
                        draftPrompt: draftPrompt,
                        modelId: modelId,
                        reasoningLevel: reasoningLevel
                    )
                    let recoverablePrompt = recoveryPrefill?.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    BannerManager.shared.show(
                        message: "Failed to create thread: \(error.localizedDescription)",
                        style: .error,
                        duration: nil,
                        actions: [
                            BannerAction(title: "Reopen") { [weak self] in
                                guard let self else { return }
                                BannerManager.shared.dismissCurrent()
                                self.presentNewThreadSheet(
                                    for: project,
                                    anchorView: self.outlineView,
                                    baseBranch: baseBranch,
                                    sourceThread: sourceThread,
                                    selectedSectionIdOverride: requestedSectionId,
                                    recoveryPrefill: recoveryPrefill
                                )
                            },
                            BannerAction(title: "Copy Prompt") {
                                guard let recoverablePrompt,
                                      !recoverablePrompt.isEmpty else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(recoverablePrompt, forType: .string)
                            }
                        ]
                    )
                }
            }
        }
    }

    private func failedThreadCreationRecoveryPrefill(
        requestedAgentType: AgentType?,
        useAgentCommand: Bool,
        initialPrompt: String?,
        taskDescription: String?,
        requestedBranchName: String?,
        initialWebURL: URL?,
        draftPrompt: (agentType: AgentType, prompt: String, modelId: String?, reasoningLevel: String?)?,
        modelId: String?,
        reasoningLevel: String?
    ) -> AgentLaunchSheetPrefill? {
        let prompt: String
        let agentType: AgentType?
        let selectionRaw: String?
        let isDraft: Bool

        if let initialWebURL {
            prompt = initialWebURL.absoluteString
            agentType = nil
            selectionRaw = "web"
            isDraft = false
        } else if let draftPrompt {
            prompt = draftPrompt.prompt
            agentType = draftPrompt.agentType
            selectionRaw = draftPrompt.agentType.rawValue
            isDraft = true
        } else if useAgentCommand {
            prompt = initialPrompt ?? ""
            agentType = requestedAgentType
            selectionRaw = requestedAgentType?.rawValue
            isDraft = false
        } else {
            prompt = initialPrompt ?? ""
            agentType = nil
            selectionRaw = "terminal"
            isDraft = false
        }

        let description = (selectionRaw == "web" || selectionRaw == "terminal") ? nil : taskDescription
        let branchName = (selectionRaw == "web" || selectionRaw == "terminal") ? nil : requestedBranchName
        let hasRecoverableContent =
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            !(branchName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            modelId != nil ||
            reasoningLevel != nil ||
            selectionRaw != nil ||
            isDraft
        guard hasRecoverableContent else { return nil }

        return AgentLaunchSheetPrefill(
            prompt: prompt,
            description: description,
            branchName: branchName,
            agentType: agentType,
            modelId: draftPrompt?.modelId ?? modelId,
            reasoningLevel: draftPrompt?.reasoningLevel ?? reasoningLevel,
            selectionRaw: selectionRaw,
            isDraft: isDraft
        )
    }

    // MARK: - Pending Prompt Recovery

    /// Called once on first appearance. Scans `/tmp` for any unsubmitted prompt files
    /// left behind by a previous crash and surfaces a banner for each one so the user
    /// can reopen the creation sheet with all fields pre-populated.
    func checkForPendingPromptRecovery() {
        let pending = PendingInitialPromptStore.loadAll()
        guard !pending.isEmpty else { return }

        // .newTab entries are stored on ThreadManager for per-thread banners;
        // only .newThread entries show as global BannerManager banners.
        let bannerCount = pending.filter { $0.prompt.scopeKind == .newThread }.count

        // Show banners sequentially — when the user acts on or dismisses one, the next appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showNextRecoveryBanner(pending: pending, index: 0, bannerTotal: bannerCount, bannerShown: 0)
        }
    }

    private func showNextRecoveryBanner(
        pending: [(url: URL, prompt: PendingInitialPrompt)],
        index: Int,
        bannerTotal: Int,
        bannerShown: Int
    ) {
        guard index < pending.count else { return }
        let (url, record) = pending[index]
        let settings = persistence.loadSettings()
        let bannerIndex = bannerShown + 1
        let countSuffix = bannerTotal > 1 ? " (\(bannerIndex) of \(bannerTotal))" : ""

        let next = { [weak self] in
            self?.showNextRecoveryBanner(pending: pending, index: index + 1, bannerTotal: bannerTotal, bannerShown: bannerShown)
        }
        let nextAfterBanner = { [weak self] in
            self?.showNextRecoveryBanner(pending: pending, index: index + 1, bannerTotal: bannerTotal, bannerShown: bannerIndex)
        }

        switch record.scopeKind {
        case .newThread:
            guard let projectId = record.projectId,
                  let project = settings.projects.first(where: { $0.id == projectId }) else {
                try? FileManager.default.removeItem(at: url)
                next()
                return
            }
            let prefill = AgentLaunchSheetPrefill(
                prompt: record.prompt,
                description: record.description,
                branchName: record.branchName,
                agentType: record.agentType,
                modelId: record.modelId,
                reasoningLevel: record.reasoningLevel,
                selectionRaw: record.selectionRaw,
                isDraft: false
            )
            let promptPreview = record.prompt.magentPromptPreview(maxLength: 140, singleLine: true)
            let promptDetails = record.prompt.magentPromptPreview(maxLength: 500, singleLine: false)
            BannerManager.shared.show(
                message: "Unsubmitted thread prompt recovered — Project: \(project.name)\(countSuffix)\nPreview: \(promptPreview)",
                style: .warning,
                duration: nil,
                isDismissible: true,
                actions: [
                    BannerAction(title: "Copy Prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.prompt, forType: .string)
                    },
                    BannerAction(title: "Reopen") { [weak self] in
                        BannerManager.shared.dismissCurrent()
                        // File stays alive; a new pending file will be created on next submit.
                        // Delete original once the recovery sheet is closed (submitted or cancelled).
                        self?.presentRecoverySheet(for: project, originalPendingURL: url, prefill: prefill)
                        nextAfterBanner()
                    },
                    BannerAction(title: "Discard") {
                        BannerManager.shared.dismissCurrent()
                        try? FileManager.default.removeItem(at: url)
                        nextAfterBanner()
                    }
                ],
                details: promptDetails,
                detailsCollapsedTitle: "Show More",
                detailsExpandedTitle: "Hide More"
            )

        case .newTab:
            guard let threadId = record.threadId,
                  let thread = threadManager.threads.first(where: { $0.id == threadId }),
                  let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
                try? FileManager.default.removeItem(at: url)
                next()
                return
            }
            // Store on ThreadManager — ThreadDetailViewController shows a per-thread banner
            // when the user selects this thread, instead of a global BannerManager banner.
            threadManager.addPendingPromptRecovery(
                for: threadId,
                info: ThreadManager.PendingPromptRecoveryInfo(
                    tempFileURL: url,
                    prompt: record.prompt,
                    agentType: record.agentType,
                    projectId: project.id,
                    modelId: record.modelId,
                    reasoningLevel: record.reasoningLevel
                )
            )
            next()
        }
    }

    /// Opens a new-thread creation sheet pre-populated with `prefill`.
    /// Deletes `originalPendingURL` when the sheet is closed (whether submitted or cancelled).
    private func presentRecoverySheet(
        for project: Project,
        originalPendingURL: URL,
        prefill: AgentLaunchSheetPrefill
    ) {
        guard let window = view.window else { return }
        let settings = persistence.loadSettings()
        let config = AgentLaunchSheetConfig(
            title: "New Thread",
            acceptButtonTitle: "Create Thread",
            draftScope: .newThread(projectId: project.id),
            availableAgents: settings.availableActiveAgents,
            defaultAgentType: threadManager.effectiveAgentType(for: project.id),
            subtitle: nil,
            showDescriptionAndBranchFields: true,
            autoGenerateHint: nil,
            terminalInjectionPrefill: nil,
            agentContextPrefill: nil,
            recoveryPrefill: prefill
        )
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            // Delete original recovery file — user has seen and acted on it.
            try? FileManager.default.removeItem(at: originalPendingURL)
            guard let self, let result else { return }
            self.createThread(
                for: project,
                requestedAgentType: result.agentType,
                useAgentCommand: result.useAgentCommand,
                initialPrompt: result.prompt,
                shouldSubmitInitialPrompt: true,
                taskDescription: result.description,
                requestedBranchName: result.branchName,
                pendingPromptFileURL: result.pendingPromptFileURL,
                modelId: result.modelId,
                reasoningLevel: result.reasoningLevel
            )
        }
    }

    // MARK: - Recovery Reopen (from ThreadDetailViewController)

    @objc func handleRecoveryReopenRequested(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let projectId = userInfo["projectId"] as? UUID,
              let tempFileURL = userInfo["tempFileURL"] as? URL,
              let prefill = userInfo["prefill"] as? AgentLaunchSheetPrefill else {
            return
        }
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }
        presentRecoverySheet(for: project, originalPendingURL: tempFileURL, prefill: prefill)
    }

    // MARK: - Add Repository

    @objc func addRepoButtonTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let createItem = NSMenuItem(
            title: "Create New Repository\u{2026}",
            action: #selector(addRepoCreateNew(_:)),
            keyEquivalent: ""
        )
        createItem.target = self
        createItem.image = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: nil)

        let importItem = NSMenuItem(
            title: "Import Existing Repository\u{2026}",
            action: #selector(addRepoImportExisting(_:)),
            keyEquivalent: ""
        )
        importItem.target = self
        importItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        menu.addItem(createItem)
        menu.addItem(importItem)

        let buttonBounds = sender.bounds
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: buttonBounds.maxY + 4), in: sender)
    }

    @objc private func addRepoCreateNew(_ sender: NSMenuItem) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select or create an empty folder for the new repository"
        panel.prompt = "Create Repository"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path

            // Reject folders that already contain a .git directory.
            let gitDir = url.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitDir.path) {
                let alert = NSAlert()
                alert.messageText = "Already a Git Repository"
                alert.informativeText = "The selected folder already contains a .git directory. Use \"Import Existing Repository\" instead."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
                return
            }

            Task {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["init", path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        process.terminationHandler = { proc in
                            if proc.terminationStatus == 0 {
                                cont.resume()
                            } else {
                                cont.resume(throwing: NSError(domain: "Magent", code: 1, userInfo: [
                                    NSLocalizedDescriptionKey: "git init exited with status \(proc.terminationStatus)"
                                ]))
                            }
                        }
                        do {
                            try process.run()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }

                    // Create an initial empty commit so the default branch actually
                    // exists — without this, worktree creation and branch validation
                    // fail because `git init` alone leaves the repo with no commits
                    // and no materialized branch.
                    let commitProcess = Process()
                    commitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    commitProcess.arguments = [
                        "-C", path,
                        "commit", "--allow-empty", "-m", "Initial commit"
                    ]
                    commitProcess.standardOutput = FileHandle.nullDevice
                    commitProcess.standardError = FileHandle.nullDevice
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        commitProcess.terminationHandler = { proc in
                            if proc.terminationStatus == 0 {
                                cont.resume()
                            } else {
                                cont.resume(throwing: NSError(domain: "Magent", code: 1, userInfo: [
                                    NSLocalizedDescriptionKey: "git commit exited with status \(proc.terminationStatus)"
                                ]))
                            }
                        }
                        do {
                            try commitProcess.run()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }

                    let defaultBranch = await GitService.shared.detectDefaultBranch(repoPath: path)

                    await MainActor.run {
                        self.addProjectAtPath(url: url, defaultBranch: defaultBranch)
                    }
                } catch {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Failed to Create Repository"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    @objc private func addRepoImportExisting(_ sender: NSMenuItem) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository folder"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path

            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        self.addProjectAtPath(url: url, defaultBranch: defaultBranch)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Not a Git Repository"
                        alert.informativeText = "The selected folder is not a git repository."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    private func addProjectAtPath(url: URL, defaultBranch: String?) {
        var settings = persistence.loadSettings()

        // Don't add a project that's already registered.
        let path = url.standardizedFileURL.path
        if settings.projects.contains(where: {
            ($0.repoPath as NSString).standardizingPath == (path as NSString).standardizingPath
        }) {
            BannerManager.shared.show(
                message: "Repository already added: \(url.lastPathComponent)",
                style: .info,
                duration: 4.0
            )
            return
        }

        let project = Project(
            name: url.lastPathComponent,
            repoPath: path,
            worktreesBasePath: Project.suggestedWorktreesPath(for: path),
            defaultBranch: defaultBranch
        )
        settings.projects.append(project)
        try? persistence.saveSettings(settings)
        reloadData()

        Task { try? await ThreadManager.shared.createMainThread(project: project) }
    }

    // MARK: - Helpers


    // MARK: - Diff Panel

    func refreshDiffPanelForSelectedThread() {
        guard let thread = selectedThreadFromState() else {
            clearSelectedThreadState()
            return
        }
        refreshDiffPanel(for: thread)
    }

    func refreshDiffPanelContextForSelectedThread() {
        guard let thread = selectedThreadFromState() else {
            diffPanelView.updateBranchInfo(branchName: nil, baseBranch: nil, upstreamStatus: nil)
            return
        }
        refreshDiffPanelContext(for: thread)
    }

    func manuallyRefreshSelectedThreadGitState() {
        guard let thread = selectedThreadFromState() else { return }
        if isDiffPanelManualRefreshInFlight {
            pendingDiffPanelManualRefresh = true
            return
        }

        let threadId = thread.id
        isDiffPanelManualRefreshInFlight = true
        pendingDiffPanelManualRefresh = false
        diffPanelView.setRefreshInProgress(true)
        refreshDiffPanel(for: thread, resetPagination: false, preserveSelection: true)

        Task { [weak self] in
            guard let self else { return }

            await self.threadManager.refreshBranchStates()
            await self.threadManager.refreshDirtyStates()
            await self.threadManager.refreshDeliveredStates()

            await MainActor.run {
                let shouldRefreshAgain = self.pendingDiffPanelManualRefresh
                self.pendingDiffPanelManualRefresh = false
                defer {
                    self.isDiffPanelManualRefreshInFlight = false
                    self.diffPanelView.setRefreshInProgress(false)
                }

                guard let selected = self.selectedThreadFromState(),
                      selected.id == threadId else { return }
                self.refreshDiffPanel(for: selected, resetPagination: false, preserveSelection: true)

                if shouldRefreshAgain {
                    DispatchQueue.main.async { [weak self] in
                        self?.manuallyRefreshSelectedThreadGitState()
                    }
                }
            }
        }
    }

    func loadMoreCommitsForSelectedThread() {
        guard let thread = selectedThreadFromState() else { return }
        let nextLimit = diffPanelCommitLimitByThreadId[thread.id, default: diffPanelCommitPageSize] + diffPanelCommitPageSize
        diffPanelCommitLimitByThreadId[thread.id] = nextLimit
        refreshDiffPanel(for: thread, resetPagination: false, preserveSelection: true)
    }

    func handleCommitSelected(_ commitHash: String?) {
        guard let commitHash else {
            // "Uncommitted" selected — CHANGES tab already has working-tree entries; nothing to load
            return
        }
        guard let thread = selectedThreadFromState() else { return }
        let worktreePath = thread.worktreePath
        Task {
            let entries = await GitService.shared.commitDiffStats(worktreePath: worktreePath, commitHash: commitHash)
            await MainActor.run {
                guard self.selectedThreadID == thread.id else { return }
                self.diffPanelView.updateCommitEntries(hash: commitHash, entries: entries, subject: "")
            }
        }
    }

    func refreshDiffPanelContext(for thread: MagentThread) {
        let current = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        let branchName = current.actualBranch ?? current.branchName
        let baseBranch = current.isMain ? nil : threadManager.resolveBaseBranch(for: current)
        Task {
            let upstreamStatus = await GitService.shared.upstreamTrackingStatus(worktreePath: current.worktreePath)
            await MainActor.run {
                guard self.selectedThreadID == current.id else { return }
                guard let latest = self.threadManager.threads.first(where: { $0.id == current.id }) else { return }
                let latestBranchName = latest.actualBranch ?? latest.branchName
                let latestBaseBranch = latest.isMain ? nil : self.threadManager.resolveBaseBranch(for: latest)
                guard latestBranchName == branchName,
                      latestBaseBranch == baseBranch else { return }
                self.diffPanelView.updateBranchInfo(
                    branchName: branchName,
                    baseBranch: baseBranch,
                    upstreamStatus: upstreamStatus
                )
            }
        }
    }

    func showBaseBranchMenu(anchorView: NSView) {
        guard let thread = selectedThreadFromState(), !thread.isMain else { return }
        let currentBase = threadManager.resolveBaseBranch(for: thread)
        let threadId = thread.id

        Task { @MainActor in
            let ancestors = await threadManager.listAncestorBranches(for: threadId)
            let menu = NSMenu()
            menu.autoenablesItems = false

            // Build the list: reversed so closest ancestors are at the bottom
            // (menu pops upward from the bottom-left anchor).
            var addedBranches = Set<String>()
            for branch in ancestors.reversed() {
                let displayName = branch.hasPrefix("origin/") ? String(branch.dropFirst(7)) : branch
                let item = NSMenuItem(title: displayName, action: #selector(self.baseBranchMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = branch
                if branch == currentBase {
                    item.state = .on
                }
                menu.addItem(item)
                addedBranches.insert(branch)
            }

            // If the current base isn't in the ancestor list (manual override or stale), add it at top
            if !addedBranches.contains(currentBase) {
                let displayName = currentBase.hasPrefix("origin/") ? String(currentBase.dropFirst(7)) : currentBase
                let item = NSMenuItem(title: displayName, action: #selector(self.baseBranchMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = currentBase
                item.state = .on
                menu.insertItem(item, at: 0)
            }

            if menu.items.isEmpty {
                let item = NSMenuItem(title: "No ancestor branches found", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(NSMenuItem.separator())
            let otherItem = NSMenuItem(title: "Other…", action: #selector(self.baseBranchOtherSelected(_:)), keyEquivalent: "")
            otherItem.target = self
            otherItem.representedObject = threadId
            menu.addItem(otherItem)

            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
        }
    }

    @objc private func baseBranchMenuItemSelected(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? String,
              let thread = selectedThreadFromState() else { return }
        threadManager.setBaseBranch(branch, for: thread.id)
        refreshDiffPanel(for: thread)
    }

    @objc private func baseBranchOtherSelected(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID,
              let thread = threadManager.threads.first(where: { $0.id == threadId }) else { return }
        let currentBase = threadManager.resolveBaseBranch(for: thread)

        Task { @MainActor in
            // Fetch all branches for combo box suggestions
            let repoPath = thread.worktreePath
            let localBranches = await GitService.shared.listBranchesByDate(repoPath: repoPath)
            let remoteBranches = await GitService.shared.listRemoteBranchesByDate(repoPath: repoPath)

            // Merge local + remote (strip origin/ for display), deduplicate, preserve order
            var seen = Set<String>()
            var allBranches: [String] = []
            for branch in localBranches {
                if seen.insert(branch).inserted {
                    allBranches.append(branch)
                }
            }
            for branch in remoteBranches {
                let name = branch.hasPrefix("origin/") ? String(branch.dropFirst(7)) : branch
                if seen.insert(name).inserted {
                    allBranches.append(name)
                }
            }

            let alert = NSAlert()
            alert.messageText = "Set Target Branch"
            alert.informativeText = "Type a branch name or choose from the list:"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let comboBox = NSComboBox(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            comboBox.isEditable = true
            comboBox.completes = true
            comboBox.stringValue = currentBase.hasPrefix("origin/") ? String(currentBase.dropFirst(7)) : currentBase
            comboBox.addItems(withObjectValues: allBranches)
            comboBox.numberOfVisibleItems = 12
            alert.accessoryView = comboBox

            // Make combo box first responder so user can type immediately
            alert.window.initialFirstResponder = comboBox

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            let entered = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entered.isEmpty else { return }

            threadManager.setBaseBranch(entered, for: thread.id)
            refreshDiffPanel(for: thread)
        }
    }

    func refreshDiffPanel(for thread: MagentThread, resetPagination: Bool = true, preserveSelection: Bool = false) {
        if resetPagination || diffPanelCommitLimitByThreadId[thread.id] == nil {
            diffPanelCommitLimitByThreadId[thread.id] = diffPanelCommitPageSize
        }
        let commitLimit = diffPanelCommitLimitByThreadId[thread.id] ?? diffPanelCommitPageSize

        // Increment the generation for this thread. The task captures this value and
        // abandons its result if a newer call has since arrived — preventing a slow
        // no-preserve task (spawned at thread selection) from overwriting the result
        // of a faster preserve task (spawned by a background structural reload).
        let generation = (diffPanelRefreshGeneration[thread.id] ?? 0) + 1
        diffPanelRefreshGeneration[thread.id] = generation

        Task {
            let current = self.threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
            let entries: [FileDiffEntry]
            let allBranchEntries: [FileDiffEntry]?
            let commits: [BranchCommit]
            let hasMoreCommits: Bool
            let baseBranch: String?
            let upstreamStatus: BranchUpstreamStatus

            if current.isMain {
                baseBranch = nil
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: current.worktreePath)
                async let commitsTask = GitService.shared.recentCommitLog(
                    worktreePath: current.worktreePath,
                    limit: commitLimit + 1
                )
                async let upstreamTask = GitService.shared.upstreamTrackingStatus(worktreePath: current.worktreePath)
                entries = await entriesTask
                allBranchEntries = entries // main thread: all changes = uncommitted
                let commitPage = await commitsTask
                hasMoreCommits = commitPage.count > commitLimit
                commits = Array(commitPage.prefix(commitLimit))
                upstreamStatus = await upstreamTask
            } else {
                let resolvedBaseBranch = self.threadManager.resolveBaseBranch(for: current)
                baseBranch = resolvedBaseBranch
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: current.worktreePath)
                async let commitsTask = GitService.shared.commitLog(
                    worktreePath: current.worktreePath,
                    baseBranch: resolvedBaseBranch,
                    limit: commitLimit + 1
                )
                async let upstreamTask = GitService.shared.upstreamTrackingStatus(worktreePath: current.worktreePath)
                entries = await entriesTask
                allBranchEntries = nil
                let commitPage = await commitsTask
                hasMoreCommits = commitPage.count > commitLimit
                commits = Array(commitPage.prefix(commitLimit))
                upstreamStatus = await upstreamTask
            }

            await MainActor.run {
                guard self.selectedThreadID == current.id else { return }
                // Discard stale results: a newer refresh call was made after this task was spawned.
                guard (self.diffPanelRefreshGeneration[current.id] ?? 0) == generation else { return }
                self.diffPanelView.update(
                    with: entries,
                    allBranchEntries: allBranchEntries,
                    commits: commits,
                    hasMoreCommits: hasMoreCommits,
                    forceVisible: true,
                    worktreePath: current.worktreePath,
                    branchName: current.actualBranch ?? current.branchName,
                    baseBranch: baseBranch,
                    upstreamStatus: upstreamStatus,
                    preserveSelection: preserveSelection
                )
            }
        }
        refreshBranchMismatchView(for: thread)
    }

    func loadAllChangesForSelectedThread() {
        guard let thread = selectedThreadFromState() else { return }
        guard !thread.isMain else { return }

        let generation = diffPanelRefreshGeneration[thread.id] ?? 0
        Task {
            let current = self.threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
            let baseBranch = self.threadManager.resolveBaseBranch(for: current)
            let entries = await GitService.shared.diffStats(
                worktreePath: current.worktreePath,
                baseBranch: baseBranch
            )

            await MainActor.run {
                guard self.selectedThreadID == current.id else { return }
                guard (self.diffPanelRefreshGeneration[current.id] ?? 0) == generation else { return }
                self.diffPanelView.updateAllBranchEntries(entries)
            }
        }
    }

    // MARK: - Commit Detail Mode

    func handleCommitDoubleTapped(_ commitHash: String?, title: String) {
        guard let thread = selectedThreadFromState() else { return }
        let worktreePath = thread.worktreePath
        Task {
            let entries: [FileDiffEntry]
            if let hash = commitHash {
                entries = await GitService.shared.commitDiffStats(worktreePath: worktreePath, commitHash: hash)
            } else {
                entries = await GitService.shared.workingTreeDiffStats(worktreePath: worktreePath)
            }
            await MainActor.run {
                guard self.selectedThreadID == thread.id else { return }
                self.diffPanelView.enterCommitDetailMode(hash: commitHash, title: title, entries: entries)
            }
        }
    }

    // MARK: - Branch Mismatch

    func refreshBranchMismatchView(for thread: MagentThread) {
        // Read the latest transient state from the thread manager
        guard let current = threadManager.threads.first(where: { $0.id == thread.id }) else {
            branchMismatchView.clear()
            return
        }

        // Show branch mismatch (actual != expected) for main and non-main threads
        if current.hasBranchMismatch,
           let actual = current.actualBranch,
           let expected = current.expectedBranch {
            branchMismatchView.update(
                actualBranch: actual,
                expectedBranch: expected,
                hasMismatch: true
            )
            branchMismatchView.onAcceptBranch = { [weak self] in
                self?.handleAcceptBranch(for: current)
            }
            branchMismatchView.onSwitchBranch = { [weak self] in
                self?.handleSwitchBranch(for: current)
            }
            return
        }

        // Non-main threads: show PR target mismatch (app base != PR target)
        if !current.isMain,
           let prInfo = current.pullRequestInfo,
           let prTarget = prInfo.baseBranch,
           !prInfo.isMerged, !prInfo.isClosed {
            let appBase = threadManager.resolveBaseBranch(for: current)
            // Compare without origin/ prefix for matching
            let normalizedAppBase = appBase.hasPrefix("origin/")
                ? String(appBase.dropFirst("origin/".count)) : appBase
            if normalizedAppBase != prTarget {
                branchMismatchView.updatePRTargetMismatch(
                    appBase: appBase,
                    prTarget: prTarget,
                    prLabel: prInfo.displayLabel
                )
                branchMismatchView.onUsePRTarget = { [weak self] in
                    self?.handleUsePRTarget(for: current, prTarget: prTarget)
                }
                return
            }
        }

        // Show one-time banner if the base branch was auto-reset because it no longer exists.
        if let reset = threadManager.baseBranchResets[current.id] {
            let shortOld = reset.oldBase.hasPrefix("origin/")
                ? String(reset.oldBase.dropFirst("origin/".count)) : reset.oldBase
            let shortNew = reset.newBase.hasPrefix("origin/")
                ? String(reset.newBase.dropFirst("origin/".count)) : reset.newBase
            BannerManager.shared.show(
                message: "Base branch \(shortOld) no longer exists — reset to \(shortNew)",
                style: .warning,
                duration: nil,
                isDismissible: true
            )
            threadManager.clearBaseBranchReset(for: current.id)
        }

        branchMismatchView.clear()
    }

    private func handleAcceptBranch(for thread: MagentThread) {
        let actual = thread.actualBranch ?? thread.branchName
        threadManager.acceptActualBranch(threadId: thread.id)
        BannerManager.shared.show(message: "Branch \(actual) accepted as expected", style: .info, duration: 3)
        branchMismatchView.clear()
        refreshDiffPanelForSelectedThread()
    }

    private func handleUsePRTarget(for thread: MagentThread, prTarget: String) {
        // Store as "origin/<branch>" to match the detection format
        let baseBranch = "origin/\(prTarget)"
        threadManager.setBaseBranch(baseBranch, for: thread.id)
        BannerManager.shared.show(
            message: "Target branch changed to \(prTarget)",
            style: .info,
            duration: 3
        )
        branchMismatchView.clear()
        refreshDiffPanelForSelectedThread()
    }

    private func handleSwitchBranch(for thread: MagentThread) {
        Task {
            do {
                try await threadManager.switchToExpectedBranch(threadId: thread.id)
                let expected = threadManager.resolveExpectedBranch(for: thread) ?? thread.branchName
                await MainActor.run {
                    BannerManager.shared.show(message: "Switched back to \(expected)", style: .info, duration: 3)
                    self.branchMismatchView.clear()
                    self.refreshDiffPanelForSelectedThread()
                }
            } catch {
                await MainActor.run {
                    let message: String
                    if let shellError = error as? ShellError,
                       case .commandFailed(_, let stderr) = shellError {
                        let gitMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        message = gitMessage.isEmpty ? error.localizedDescription : gitMessage
                    } else {
                        message = error.localizedDescription
                    }
                    BannerManager.shared.show(message: message, style: .error, duration: 5)
                }
            }
        }
    }

}
