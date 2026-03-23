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
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true)
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

    func presentNewThreadSheet(for project: Project, anchorView: NSView, baseBranch: String? = nil, sourceThread: MagentThread? = nil) {
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

        let defaultBranchName = project.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only prefill the base branch field when explicitly creating from another thread's branch.
        // When nil, the field stays empty and uses the default branch placeholder.
        let resolvedBaseBranchPrefill: String? = baseBranch

        let config = AgentLaunchSheetConfig(
            title: "New Thread",
            acceptButtonTitle: "Create Thread",
            draftScope: .newThread(projectId: project.id),
            availableAgents: settings.availableActiveAgents,
            defaultAgentType: threadManager.effectiveAgentType(for: project.id),
            subtitle: nil,
            availableProjects: settings.projects,
            showDescriptionAndBranchFields: true,
            autoGenerateHint: autoGenerateHint,
            terminalInjectionPrefill: injection.terminalCommand.isEmpty ? nil : injection.terminalCommand,
            agentContextPrefill: injection.agentContext.isEmpty ? nil : injection.agentContext,
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

            // Only insert after the source thread when the new thread will land in the
            // same project, section, and sidebar group. Otherwise fall back to normal
            // bottom-of-group placement.
            let effectiveInsertAfter: UUID? = {
                guard let source = capturedSourceThread else { return nil }
                // Project must match.
                guard targetProject.id == source.projectId else { return nil }
                // Source must be in the normal visible group (not pinned/hidden).
                guard source.sidebarListState == .visible else { return nil }
                // Section must match (compare effective section of source vs what the user picked).
                let settings = self.persistence.loadSettings()
                let sourceSectionId = self.threadManager.effectiveSectionId(for: source, settings: settings)
                if sourceSectionId != result.selectedSectionId { return nil }
                return source.id
            }()

            self.createThread(
                for: targetProject,
                requestedAgentType: result.agentType,
                useAgentCommand: result.useAgentCommand,
                baseBranch: result.baseBranch,
                initialPrompt: result.isDraft ? nil : result.prompt,
                shouldSubmitInitialPrompt: !result.isDraft,
                taskDescription: result.description,
                requestedBranchName: result.branchName,
                pendingPromptFileURL: result.pendingPromptFileURL,
                requestedSectionId: result.selectedSectionId,
                insertAfterThreadId: effectiveInsertAfter,
                initialWebURL: result.initialWebURL,
                draftPrompt: result.isDraft ? result.agentType.map { ($0, result.prompt ?? "") } : nil
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
            defaultAgentName: threadManager.effectiveAgentType(for: project.id)?.displayName,
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
            createThread(for: project, requestedAgentType: agentType, useAgentCommand: true, baseBranch: baseBranch)
        case .projectDefault:
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true, baseBranch: baseBranch)
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
    func requestNewThread() {
        guard !isCreatingThread else { return }

        let settings = persistence.loadSettings()
        let projects = settings.projects
        guard !projects.isEmpty else {
            showNoProjectsAlert()
            return
        }
        guard let project = preferredProjectForQuickCreate(from: projects) else { return }
        let isOptionPressed = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        if isOptionPressed {
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true)
        } else {
            presentNewThreadSheet(for: project, anchorView: outlineView)
        }
    }

    func createThread(
        for project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        baseBranch: String? = nil,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        taskDescription: String? = nil,
        requestedBranchName: String? = nil,
        pendingPromptFileURL: URL? = nil,
        requestedSectionId: UUID? = nil,
        insertAfterThreadId: UUID? = nil,
        initialWebURL: URL? = nil,
        draftPrompt: (AgentType, String)? = nil
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
                    requestedName: requestedBranchName,
                    requestedBaseBranch: baseBranch,
                    pendingPromptFileURL: pendingPromptFileURL,
                    requestedSectionId: requestedSectionId,
                    insertAfterThreadId: insertAfterThreadId,
                    initialWebURL: initialWebURL
                )
                if let desc = taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !desc.isEmpty {
                    try? self.threadManager.setTaskDescription(threadId: created.id, description: desc)
                }
                // If this is a draft, add a persisted draft tab to the newly created thread.
                if let (agentType, prompt) = draftPrompt {
                    let identifier = "draft:\(UUID().uuidString)"
                    let draftTab = PersistedDraftTab(identifier: identifier, agentType: agentType, prompt: prompt)
                    self.threadManager.updatePersistedDraftTabs(for: created.id, draftTabs: [draftTab])
                }
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                    BannerManager.shared.show(
                        message: "Failed to create thread: \(error.localizedDescription)",
                        style: .error,
                        duration: 8.0
                    )
                }
            }
        }
    }

    // MARK: - Pending Prompt Recovery

    /// Called once on first appearance. Scans `/tmp` for any unsubmitted prompt files
    /// left behind by a previous crash and surfaces a banner for each one so the user
    /// can reopen the creation sheet with all fields pre-populated.
    func checkForPendingPromptRecovery() {
        let pending = PendingInitialPromptStore.loadAll()
        guard !pending.isEmpty else { return }

        // Show banners sequentially — when the user acts on or dismisses one, the next appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.showNextRecoveryBanner(pending: pending, index: 0)
        }
    }

    private func showNextRecoveryBanner(pending: [(url: URL, prompt: PendingInitialPrompt)], index: Int) {
        guard index < pending.count else { return }
        let (url, record) = pending[index]
        let settings = persistence.loadSettings()
        let remaining = pending.count - index
        let countSuffix = remaining > 1 ? " (\(index + 1) of \(pending.count))" : ""

        let next = { [weak self] in
            self?.showNextRecoveryBanner(pending: pending, index: index + 1)
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
                agentType: record.agentType
            )
            BannerManager.shared.show(
                message: "Unsubmitted thread prompt recovered — Project: \(project.name)\(countSuffix)",
                style: .warning,
                duration: nil,
                isDismissible: true,
                actions: [
                    BannerAction(title: "Reopen") { [weak self] in
                        // File stays alive; a new pending file will be created on next submit.
                        // Delete original once the recovery sheet is closed (submitted or cancelled).
                        self?.presentRecoverySheet(for: project, originalPendingURL: url, prefill: prefill)
                        next()
                    },
                    BannerAction(title: "Discard") {
                        try? FileManager.default.removeItem(at: url)
                        next()
                    }
                ]
            )

        case .newTab:
            guard let threadId = record.threadId,
                  let thread = threadManager.threads.first(where: { $0.id == threadId }),
                  let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
                try? FileManager.default.removeItem(at: url)
                next()
                return
            }
            let prefill = AgentLaunchSheetPrefill(
                prompt: record.prompt,
                description: nil,
                branchName: nil,
                agentType: record.agentType
            )
            BannerManager.shared.show(
                message: "Unsubmitted tab prompt recovered — Thread: \(thread.name)\(countSuffix)",
                style: .warning,
                duration: nil,
                isDismissible: true,
                actions: [
                    BannerAction(title: "Reopen as Thread") { [weak self] in
                        self?.presentRecoverySheet(for: project, originalPendingURL: url, prefill: prefill)
                        next()
                    },
                    BannerAction(title: "Discard") {
                        try? FileManager.default.removeItem(at: url)
                        next()
                    }
                ]
            )
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
                pendingPromptFileURL: result.pendingPromptFileURL
            )
        }
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
            diffPanelView.updateBranchInfo(branchName: nil, baseBranch: nil)
            return
        }
        refreshDiffPanelContext(for: thread)
    }

    func manuallyRefreshSelectedThreadGitState() {
        guard let thread = selectedThreadFromState(),
              !isDiffPanelManualRefreshInFlight else { return }

        let threadId = thread.id
        isDiffPanelManualRefreshInFlight = true
        diffPanelView.setRefreshInProgress(true)

        Task { [weak self] in
            guard let self else { return }

            await self.threadManager.refreshBranchStates()
            await self.threadManager.refreshDirtyStates()
            await self.threadManager.refreshDeliveredStates()

            await MainActor.run {
                defer {
                    self.isDiffPanelManualRefreshInFlight = false
                    self.diffPanelView.setRefreshInProgress(false)
                }

                guard let selected = self.selectedThreadFromState(),
                      selected.id == threadId else { return }
                self.refreshDiffPanel(for: selected, resetPagination: false, preserveSelection: true)
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
        let branchName = current.isMain ? nil : (current.actualBranch ?? current.branchName)
        let baseBranch = current.isMain ? nil : threadManager.resolveBaseBranch(for: current)
        diffPanelView.updateBranchInfo(branchName: branchName, baseBranch: baseBranch)
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
            let allBranchEntries: [FileDiffEntry]
            let commits: [BranchCommit]
            let hasMoreCommits: Bool
            let baseBranch: String?

            if current.isMain {
                baseBranch = nil
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: current.worktreePath)
                async let commitsTask = GitService.shared.recentCommitLog(
                    worktreePath: current.worktreePath,
                    limit: commitLimit + 1
                )
                entries = await entriesTask
                allBranchEntries = entries // main thread: all changes = uncommitted
                let commitPage = await commitsTask
                hasMoreCommits = commitPage.count > commitLimit
                commits = Array(commitPage.prefix(commitLimit))
            } else {
                let resolvedBaseBranch = self.threadManager.resolveBaseBranch(for: current)
                baseBranch = resolvedBaseBranch
                async let entriesTask = GitService.shared.workingTreeDiffStats(worktreePath: current.worktreePath)
                async let allBranchTask = GitService.shared.diffStats(worktreePath: current.worktreePath, baseBranch: resolvedBaseBranch)
                async let commitsTask = GitService.shared.commitLog(
                    worktreePath: current.worktreePath,
                    baseBranch: resolvedBaseBranch,
                    limit: commitLimit + 1
                )
                entries = await entriesTask
                allBranchEntries = await allBranchTask
                let commitPage = await commitsTask
                hasMoreCommits = commitPage.count > commitLimit
                commits = Array(commitPage.prefix(commitLimit))
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
                    forceVisible: current.isMain,
                    worktreePath: current.worktreePath,
                    branchName: current.isMain ? nil : (current.actualBranch ?? current.branchName),
                    baseBranch: baseBranch,
                    preserveSelection: preserveSelection
                )
            }
        }
        refreshBranchMismatchView(for: thread)
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

        // Main threads: show branch mismatch (actual != expected)
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
