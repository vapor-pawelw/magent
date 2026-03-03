import Cocoa

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
        presentProjectAgentMenu(project: project, anchorView: sender)
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

        let selectedRow = outlineView.selectedRow
        if selectedRow >= 0 {
            if let selectedThread = outlineView.item(atRow: selectedRow) as? MagentThread,
               let matched = projects.first(where: { $0.id == selectedThread.projectId }) {
                return matched
            }
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

    private func presentProjectAgentMenu(project: Project, anchorView: NSView) {
        let settings = persistence.loadSettings()
        let activeAgents = settings.availableActiveAgents
        let menu = buildAgentSubmenu(for: project, activeAgents: activeAgents)
        menu.popUp(positioning: nil, at: NSPoint(x: anchorView.bounds.minX, y: anchorView.bounds.minY), in: anchorView)
    }

    private func buildAgentSubmenu(for project: Project, activeAgents: [AgentType]) -> NSMenu {
        let submenu = NSMenu()
        AgentMenuBuilder.populate(
            menu: submenu,
            defaultAgentName: threadManager.effectiveAgentType(for: project.id)?.displayName,
            activeAgents: activeAgents,
            target: self,
            action: #selector(projectAgentMenuItemSelected(_:)),
            extraData: ["projectId": project.id.uuidString]
        )
        return submenu
    }

    @objc private func projectAgentMenuItemSelected(_ sender: NSMenuItem) {
        guard let selection = AgentMenuBuilder.parseSelection(from: sender),
              let projectIdRaw = selection.data["projectId"],
              let projectId = UUID(uuidString: projectIdRaw) else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }

        switch selection.mode {
        case .terminal:
            createThread(for: project, requestedAgentType: nil, useAgentCommand: false)
        case .agent(let agentType):
            createThread(for: project, requestedAgentType: agentType, useAgentCommand: true)
        case .projectDefault:
            createThread(for: project, requestedAgentType: nil, useAgentCommand: true)
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
        presentProjectAgentMenu(project: project, anchorView: outlineView)
    }

    private func createThread(
        for project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true
    ) {
        isCreatingThread = true
        reloadData()

        performWithSpinner(message: "Creating thread...", errorTitle: "Creation Failed") {
            do {
                let thread = try await self.threadManager.createThread(
                    project: project,
                    requestedAgentType: requestedAgentType,
                    useAgentCommand: useAgentCommand
                )
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                    self.delegate?.threadList(self, didSelectThread: thread)
                }
            } catch {
                await MainActor.run {
                    self.isCreatingThread = false
                    self.reloadData()
                }
                throw error
            }
        }
    }

    // MARK: - Helpers


    // MARK: - Diff Panel

    func refreshDiffPanelForSelectedThread() {
        let row = outlineView.selectedRow
        guard row >= 0,
              let thread = outlineView.item(atRow: row) as? MagentThread else {
            diffPanelView.clear()
            branchMismatchView.clear()
            return
        }
        refreshDiffPanel(for: thread)
    }

    func refreshDiffPanel(for thread: MagentThread) {
        Task {
            let entries = await threadManager.refreshDiffStats(for: thread.id)
            let baseBranch = threadManager.resolveBaseBranch(for: thread)
            await MainActor.run {
                self.diffPanelView.update(
                    with: entries,
                    branchName: thread.isMain ? nil : thread.branchName,
                    baseBranch: thread.isMain ? nil : baseBranch
                )
            }
        }
        refreshBranchMismatchView(for: thread)
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
        branchMismatchView.onSwitchBranch = { [weak self] in
            self?.handleSwitchBranch(for: current)
        }
    }

    private func handleSwitchBranch(for thread: MagentThread) {
        Task {
            do {
                try await threadManager.switchToExpectedBranch(threadId: thread.id)
                let expected = threadManager.resolveExpectedBranch(for: thread) ?? thread.branchName
                await MainActor.run {
                    BannerManager.shared.show(message: "Switched back to \(expected)", style: .info, duration: 3)
                    self.branchMismatchView.clear()
                    self.refreshDiffPanel(for: thread)
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
