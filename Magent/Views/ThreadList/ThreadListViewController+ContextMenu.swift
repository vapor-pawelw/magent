import Cocoa

extension ThreadListViewController {

    // MARK: - Context Menu

    private func buildContextMenu(for thread: MagentThread) -> NSMenu {
        let menu = NSMenu()

        // Main threads: limited context menu
        if thread.isMain {
            return buildMainThreadContextMenu(for: thread)
        }

        // Pin/Unpin
        let pinTitle = thread.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleThreadPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: thread.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = thread.id
        menu.addItem(pinItem)
        menu.addItem(NSMenuItem.separator())

        let descriptionItem = NSMenuItem(title: "Set description...", action: #selector(setThreadDescription(_:)), keyEquivalent: "")
        descriptionItem.target = self
        descriptionItem.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        descriptionItem.representedObject = thread
        menu.addItem(descriptionItem)

        let settings = persistence.loadSettings()

        // Rename branch
        let renameItem = NSMenuItem(title: "Rename branch...", action: #selector(renameThread(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = thread
        menu.addItem(renameItem)

        let iconItem = NSMenuItem(title: "Set icon", action: nil, keyEquivalent: "")
        iconItem.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        ) ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Thread icon")
        iconItem.submenu = buildThreadIconSubmenu(for: thread)
        menu.addItem(iconItem)

        // Move to... submenu
        let visibleSections = settings.visibleSections.filter { $0.id != thread.sectionId }
        let moveSubmenu = NSMenu()
        for section in visibleSections {
            let item = NSMenuItem(title: section.name, action: #selector(moveThreadToSection(_:)), keyEquivalent: "")
            item.target = self
            item.image = colorDotImage(color: section.color, size: 8)
            item.representedObject = ["thread": thread, "sectionId": section.id] as [String: Any]
            moveSubmenu.addItem(item)
        }

        let moveItem = NSMenuItem(title: "Move to...", action: nil, keyEquivalent: "")
        moveItem.submenu = moveSubmenu
        moveItem.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        menu.addItem(moveItem)

        if let createFromBranchItem = createThreadFromBaseMenuItem(for: thread, settings: settings) {
            menu.addItem(createFromBranchItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Open project (if Xcode is installed and project has xcworkspace/xcodeproj)
        if let projectPath = xcodeProjectPath(for: thread), let xcodePath = urlForXcodeProjectOpeningApp(for: projectPath) {
            let xcodeItem = createMenuItemForOpenProject(for: thread, xcodePath: xcodePath.path())
            menu.addItem(xcodeItem)
        }
        
        // Open in Finder
        let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openThreadInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        finderItem.representedObject = thread
        menu.addItem(finderItem)

        // Show Pull Request (only for projects with a recognized hosting provider)
        if projectsWithValidRemotes.contains(thread.projectId) {
            let prTitle = thread.pullRequestInfo.map { "Open \($0.displayLabel)" } ?? "Show Pull Request"
            let prItem = NSMenuItem(title: prTitle, action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            prItem.representedObject = thread
            menu.addItem(prItem)
        }

        // Open in Jira
        if let jiraItem = buildJiraMenuItem(for: thread, settings: settings) {
            menu.addItem(jiraItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Archive
        let archiveItem = NSMenuItem(title: "Archive...", action: #selector(archiveThread(_:)), keyEquivalent: "")
        archiveItem.target = self
        archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        archiveItem.representedObject = thread
        menu.addItem(archiveItem)

        // Delete (destructive)
        let deleteItem = NSMenuItem(title: "Delete...", action: #selector(deleteThread(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        deleteItem.representedObject = thread
        let redAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        deleteItem.attributedTitle = NSAttributedString(string: "Delete...", attributes: redAttributes)
        menu.addItem(deleteItem)

        return menu
    }

    private func buildThreadIconSubmenu(for thread: MagentThread) -> NSMenu {
        let submenu = NSMenu()
        for icon in ThreadIcon.allCases {
            let item = NSMenuItem(title: icon.menuTitle, action: #selector(setThreadIcon(_:)), keyEquivalent: "")
            item.target = self
            item.state = thread.threadIcon == icon ? .on : .off
            item.image = NSImage(
                systemSymbolName: icon.symbolName,
                accessibilityDescription: icon.accessibilityDescription
            ) ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Thread icon")
            item.representedObject = [
                "threadId": thread.id,
                "icon": icon.rawValue
            ] as [String: Any]
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildMainThreadContextMenu(for thread: MagentThread) -> NSMenu {
        let menu = NSMenu()

        // Open in Finder
        let finderItem = NSMenuItem(title: "Open in Finder", action: #selector(openThreadInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        finderItem.representedObject = thread
        menu.addItem(finderItem)

        let settings = persistence.loadSettings()
        if let createFromBranchItem = createThreadFromBaseMenuItem(for: thread, settings: settings) {
            menu.addItem(createFromBranchItem)
        }

        // Open project (if Xcode is installed and project has xcworkspace/xcodeproj)
        if let projectPath = xcodeProjectPath(for: thread), let xcodePath = urlForXcodeProjectOpeningApp(for: projectPath) {
            let xcodeItem = createMenuItemForOpenProject(for: thread, xcodePath: xcodePath.path())
            menu.addItem(xcodeItem)
        }

        // Show open pull requests (only for projects with a recognized hosting provider)
        if projectsWithValidRemotes.contains(thread.projectId) {
            let mainPrTitle = thread.pullRequestInfo.map { "Open \($0.displayLabel)" } ?? "Show Open Pull Requests"
            let prItem = NSMenuItem(title: mainPrTitle, action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            prItem.representedObject = thread
            menu.addItem(prItem)
        }

        // Open Jira Board
        if let jiraItem = buildJiraMenuItem(for: thread, settings: settings) {
            menu.addItem(jiraItem)
        }

        return menu
    }
    
    private func createMenuItemForOpenProject(for thread: MagentThread, xcodePath: String) -> NSMenuItem {
        let xcodeItem = NSMenuItem(title: "Open project", action: #selector(openThreadInXcode(_:)), keyEquivalent: "")
        xcodeItem.target = self
        let xcodeIcon = NSWorkspace.shared.icon(forFile: xcodePath)
        xcodeIcon.size = NSSize(width: 16, height: 16)
        xcodeItem.image = xcodeIcon
        xcodeItem.representedObject = thread
        return xcodeItem
    }

    private func createThreadFromBaseMenuItem(for thread: MagentThread, settings: AppSettings) -> NSMenuItem? {
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let baseBranch = baseBranchForNewThread(from: thread, project: project) else {
            return nil
        }

        let item = NSMenuItem(title: "Create Thread from This Branch", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        item.submenu = buildAgentSubmenu(for: project, extraData: ["baseBranch": baseBranch])
        return item
    }

    private func baseBranchForNewThread(from thread: MagentThread, project: Project) -> String? {
        let actualBranch = thread.actualBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !actualBranch.isEmpty, actualBranch != "HEAD" {
            return actualBranch
        }

        let storedBranch = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedBranch.isEmpty {
            return storedBranch
        }

        let expectedBranch = thread.expectedBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedBranch.isEmpty {
            return expectedBranch
        }

        let projectDefault = project.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !projectDefault.isEmpty {
            return projectDefault
        }

        return nil
    }

    private func projectRootPath(for thread: MagentThread) -> String {
        if thread.isMain {
            let settings = persistence.loadSettings()
            return settings.projects.first(where: { $0.id == thread.projectId })?.repoPath ?? thread.worktreePath
        }
        return thread.worktreePath
    }
    
    private func urlForXcodeProjectOpeningApp(for thread: MagentThread) -> URL? {
        guard let projectPath = xcodeProjectPath(for: thread) else { return nil }
        return urlForXcodeProjectOpeningApp(for: projectPath)
    }
    
    private func urlForXcodeProjectOpeningApp(for projPath: String) -> URL? {
        let projURL = URL(fileURLWithPath: projPath)
        return NSWorkspace.shared.urlForApplication(toOpen: projURL)
    }

    private func xcodeProjectPath(for thread: MagentThread) -> String? {
        let dirPath = NSString(string: projectRootPath(for: thread)).expandingTildeInPath
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return nil }

        let workspaces = contents.filter { $0.hasSuffix(".xcworkspace") && $0 != "project.xcworkspace" }
        if let first = workspaces.first {
            return (dirPath as NSString).appendingPathComponent(first)
        }
        let projects = contents.filter { $0.hasSuffix(".xcodeproj") }
        if let first = projects.first {
            return (dirPath as NSString).appendingPathComponent(first)
        }
        return nil
    }

    @objc private func openThreadInXcode(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread,
              let path = xcodeProjectPath(for: thread),
              urlForXcodeProjectOpeningApp(for: path) != nil else {
            return
        }
        
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Jira Context Menu

    private func buildJiraMenuItem(for thread: MagentThread, settings: AppSettings) -> NSMenuItem? {
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let projectKey = project.jiraProjectKey, !projectKey.isEmpty else {
            return nil
        }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return nil }

        let title: String
        if thread.jiraTicketKey != nil {
            title = "Open Ticket in Jira"
        } else if thread.isMain {
            title = "Open Jira Board"
        } else {
            title = "Open in Jira"
        }

        let item = NSMenuItem(title: title, action: #selector(openThreadInJira(_:)), keyEquivalent: "")
        item.target = self
        item.image = jiraMenuIcon()
        item.representedObject = thread
        return item
    }

    private func jiraMenuIcon() -> NSImage? {
        if let image = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (image.copy() as? NSImage) ?? image
            sized.size = NSSize(width: 16, height: 16)
            sized.isTemplate = false
            return sized
        }
        return NSImage(systemSymbolName: "ticket", accessibilityDescription: "Jira")
    }

    @objc private func openThreadInJira(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let projectKey = project.jiraProjectKey else { return }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return }
        let jira = JiraService.shared

        let url: URL?
        if let ticketKey = thread.jiraTicketKey {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        } else if thread.isMain, let boardId = project.jiraBoardId {
            url = jira.boardURL(siteURL: siteURL, projectKey: projectKey, boardId: boardId)
        } else {
            url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
        }

        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    private func buildProjectContextMenu(for project: SidebarProject) -> NSMenu {
        let menu = NSMenu()
        let pinTitle = project.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleProjectPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: project.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = project.projectId
        menu.addItem(pinItem)
        return menu
    }

    @objc private func toggleProjectPin(_ sender: NSMenuItem) {
        guard let projectId = sender.representedObject as? UUID else { return }
        var settings = persistence.loadSettings()
        guard let index = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }
        settings.projects[index].isPinned.toggle()
        try? persistence.saveSettings(settings)
        reloadData()
    }

    @objc private func toggleThreadPin(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        threadManager.toggleThreadPin(threadId: threadId)
    }

    @objc private func moveThreadToSection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let sectionId = info["sectionId"] as? UUID else { return }
        threadManager.moveThread(thread, toSection: sectionId)
        reloadData()
    }

    @objc private func setThreadIcon(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let threadId = info["threadId"] as? UUID,
              let iconRaw = info["icon"] as? String,
              let icon = ThreadIcon(rawValue: iconRaw) else { return }
        do {
            try threadManager.setThreadIcon(threadId: threadId, icon: icon)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could Not Save Icon"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    @objc private func renameThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Branch"
        alert.informativeText = "Enter a new branch name"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = thread.name
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != thread.name else { return }

        Task {
            do {
                try await threadManager.renameThread(thread, to: newName)
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == thread.id }) {
                        self.delegate?.threadList(self, didRenameThread: updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Rename Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    @objc private func setThreadDescription(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Set Description"
        alert.informativeText = "Enter a short description (max 8 words). Leave empty to clear."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = thread.taskDescription ?? ""
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let requestedDescription = textField.stringValue
        do {
            try threadManager.setTaskDescription(threadId: thread.id, description: requestedDescription)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could Not Save Description"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    @objc private func openThreadInFinder(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let targetPath: String
        if thread.isMain {
            let settings = persistence.loadSettings()
            targetPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath ?? thread.worktreePath
        } else {
            targetPath = thread.worktreePath
        }

        let path = NSString(string: targetPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue else {
            let targetName = thread.isMain ? "project root" : "worktree"
            BannerManager.shared.show(message: "Could not open \(targetName) in Finder because the directory is missing.", style: .warning)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openThreadPullRequest(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        // If we have a detected PR, open it directly
        if let pr = thread.pullRequestInfo {
            NSWorkspace.shared.open(pr.url)
            return
        }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

        Task {
            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            guard !remotes.isEmpty else {
                await MainActor.run {
                    BannerManager.shared.show(message: "No git remotes found", style: .warning)
                }
                return
            }

            let branch = thread.branchName
            let defaultBranch: String?
            if let projectDefaultBranch = project.defaultBranch {
                defaultBranch = projectDefaultBranch
            } else {
                defaultBranch = await GitService.shared.detectDefaultBranch(repoPath: project.repoPath)
            }

            await MainActor.run {
                // Find the best remote — prefer origin
                let remote: GitRemote
                if remotes.count == 1 {
                    remote = remotes[0]
                } else if let origin = remotes.first(where: { $0.name == "origin" }) {
                    remote = origin
                } else {
                    remote = remotes[0]
                }

                guard let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL else {
                    BannerManager.shared.show(message: "Could not construct URL for remote \(remote.name)", style: .warning)
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func archiveThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }
        triggerArchive(for: thread)
    }

    func triggerArchive(for thread: MagentThread) {
        let threadManager = self.threadManager
        let baseBranch = threadManager.resolveBaseBranch(for: thread)

        Task {
            let git = GitService.shared
            let clean = await git.isClean(worktreePath: thread.worktreePath)
            let merged = await git.isMergedInto(worktreePath: thread.worktreePath, baseBranch: baseBranch)

            await MainActor.run {
                let liveThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
                let agentBusy = liveThread.hasAgentBusy

                if agentBusy {
                    let alert = NSAlert()
                    alert.messageText = "Archive Thread"
                    alert.informativeText = "An agent in \"\(thread.name)\" is currently busy. Archiving will terminate the running agent and remove the worktree directory. The git branch \"\(thread.branchName)\" will be kept."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Archive Anyway")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                } else if !clean || !merged {
                    let alert = NSAlert()
                    alert.messageText = "Archive Thread"
                    var reasons: [String] = []
                    if !clean { reasons.append("uncommitted changes") }
                    if !merged { reasons.append("commits not in \(baseBranch)") }
                    alert.informativeText = "The thread \"\(thread.name)\" has \(reasons.joined(separator: " and ")). Archiving will remove its worktree directory but keep the git branch \"\(thread.branchName)\"."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Archive")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                }

                // Archive directly without a spinner sheet. The delegate-driven
                // reloadData()/showEmptyState() modifies split view items, which
                // crashes if a sheet is being presented on the same window.
                Task {
                    do {
                        try await threadManager.archiveThread(thread)
                    } catch {
                        await MainActor.run {
                            BannerManager.shared.show(
                                message: "Archive failed: \(error.localizedDescription)",
                                style: .error
                            )
                        }
                    }
                }
            }
        }
    }

    @objc private func deleteThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = "Delete Thread"
        alert.informativeText = "This will permanently delete the thread \"\(thread.name)\", including its worktree directory and git branch \"\(thread.branchName)\". This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await self.threadManager.deleteThread(thread)
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Delete failed: \(error.localizedDescription)",
                        style: .error
                    )
                }
            }
        }
    }

}

// MARK: - NSMenuDelegate

extension ThreadListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0 else { return }

        let clickedItem = outlineView.item(atRow: clickedRow)

        if let project = clickedItem as? SidebarProject {
            let contextMenu = buildProjectContextMenu(for: project)
            for item in contextMenu.items {
                contextMenu.removeItem(item)
                menu.addItem(item)
            }
            return
        }

        if let thread = clickedItem as? MagentThread {
            let contextMenu = buildContextMenu(for: thread)
            for item in contextMenu.items {
                contextMenu.removeItem(item)
                menu.addItem(item)
            }
        }
    }
}
