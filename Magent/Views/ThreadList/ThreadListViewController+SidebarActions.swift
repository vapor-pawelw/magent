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

    private func presentNewThreadSheet(for project: Project, anchorView: NSView, baseBranch: String? = nil) {
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
            agentContextPrefill: injection.agentContext.isEmpty ? nil : injection.agentContext
        )
        let controller = AgentLaunchPromptSheetController(config: config)
        controller.present(for: window) { [weak self] result in
            guard let self, let result else { return }
            let targetProject = result.selectedProject ?? project
            self.createThread(
                for: targetProject,
                requestedAgentType: result.agentType,
                useAgentCommand: result.useAgentCommand,
                baseBranch: baseBranch,
                initialPrompt: result.prompt,
                shouldSubmitInitialPrompt: true,
                taskDescription: result.description,
                requestedBranchName: result.branchName,
                pendingPromptFileURL: result.pendingPromptFileURL
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
        }
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
        pendingPromptFileURL: URL? = nil
    ) {
        isCreatingThread = true
        reloadData()

        Task {
            do {
                let thread = try await self.threadManager.createThread(
                    project: project,
                    requestedAgentType: requestedAgentType,
                    useAgentCommand: useAgentCommand,
                    initialPrompt: initialPrompt,
                    requestedName: requestedBranchName,
                    requestedBaseBranch: baseBranch
                )
                await MainActor.run {
                    if let pendingPromptFileURL,
                       let sessionName = thread.tmuxSessionNames.first {
                        PendingInitialPromptStore.clearAfterInjection(
                            fileURL: pendingPromptFileURL,
                            sessionName: sessionName
                        )
                    }
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
                let commitPage = await commitsTask
                hasMoreCommits = commitPage.count > commitLimit
                commits = Array(commitPage.prefix(commitLimit))
            } else {
                let resolvedBaseBranch = self.threadManager.resolveBaseBranch(for: current)
                baseBranch = resolvedBaseBranch
                async let entriesTask = threadManager.refreshDiffStats(for: thread.id)
                async let commitsTask = GitService.shared.commitLog(
                    worktreePath: current.worktreePath,
                    baseBranch: resolvedBaseBranch,
                    limit: commitLimit + 1
                )
                entries = await entriesTask
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

    // MARK: - Commit Files Popover

    func showCommitFilesPopover(commitHash: String?, relativeTo sourceView: NSView) {
        guard let thread = selectedThreadFromState() else { return }
        let worktreePath = thread.worktreePath

        let popover = NSPopover()
        popover.behavior = .transient

        let vc = CommitFilesPopoverViewController(
            title: commitHash == nil ? "Uncommitted changes" : "Commit \(commitHash!)",
            worktreePath: worktreePath,
            commitHash: commitHash
        )
        popover.contentViewController = vc
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxX)
    }

    // MARK: - Branch Mismatch

    func refreshBranchMismatchView(for thread: MagentThread) {
        // Read the latest transient state from the thread manager
        guard let current = threadManager.threads.first(where: { $0.id == thread.id }),
              current.hasBranchMismatch,
              let actual = current.actualBranch,
              let expected = current.expectedBranch else {
            branchMismatchView.clear()
            return
        }
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
    }

    private func handleAcceptBranch(for thread: MagentThread) {
        let actual = thread.actualBranch ?? thread.branchName
        threadManager.acceptActualBranch(threadId: thread.id)
        BannerManager.shared.show(message: "Branch \(actual) accepted as expected", style: .info, duration: 3)
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
