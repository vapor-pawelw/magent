import Cocoa
import MagentCore

extension ThreadListViewController {

    // MARK: - Context Menu

    private func buildContextMenu(for thread: MagentThread) -> NSMenu {
        let menu = NSMenu()

        // Main threads: limited context menu
        if thread.isMain {
            return buildMainThreadContextMenu(for: thread)
        }

        // Pin/Unpin
        let pinTitle = thread.isPinned ? String(localized: .CommonStrings.commonUnpin) : String(localized: .CommonStrings.commonPin)
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleThreadPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: thread.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = thread.id
        menu.addItem(pinItem)

        let hideTitle = thread.isSidebarHidden
            ? String(localized: .CommonStrings.commonUnhide)
            : String(localized: .CommonStrings.commonHide)
        let hideItem = NSMenuItem(title: hideTitle, action: #selector(toggleThreadHidden(_:)), keyEquivalent: "")
        hideItem.target = self
        hideItem.image = NSImage(
            systemSymbolName: thread.isSidebarHidden ? "eye" : "eye.slash",
            accessibilityDescription: nil
        )
        hideItem.representedObject = thread.id
        menu.addItem(hideItem)

        let promptRenameItem = NSMenuItem(title: String(localized: .ThreadStrings.threadRenameWithAgent), action: #selector(renameThreadFromPrompt(_:)), keyEquivalent: "")
        promptRenameItem.target = self
        promptRenameItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        promptRenameItem.representedObject = thread
        menu.addItem(promptRenameItem)

        menu.addItem(NSMenuItem.separator())

        let descriptionItem = NSMenuItem(title: String(localized: .ThreadStrings.threadSetDescription), action: #selector(setThreadDescription(_:)), keyEquivalent: "")
        descriptionItem.target = self
        descriptionItem.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        descriptionItem.representedObject = thread
        menu.addItem(descriptionItem)

        let settings = persistence.loadSettings()

        // Rename branch
        let renameItem = NSMenuItem(title: String(localized: .ThreadStrings.threadRenameBranch), action: #selector(renameThread(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = thread
        menu.addItem(renameItem)

        let iconItem = NSMenuItem(title: String(localized: .ThreadStrings.threadSetIcon), action: nil, keyEquivalent: "")
        iconItem.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        ) ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Thread icon")
        iconItem.submenu = buildThreadIconSubmenu(for: thread)
        menu.addItem(iconItem)

        menu.addItem(NSMenuItem.separator())

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

        let moveItem = NSMenuItem(title: String(localized: .ThreadStrings.threadMoveTo), action: nil, keyEquivalent: "")
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
        let finderItem = NSMenuItem(title: String(localized: .ThreadStrings.threadOpenInFinder), action: #selector(openThreadInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = OpenActionIcons.finderIcon(size: 16)
        finderItem.representedObject = thread
        menu.addItem(finderItem)

        // Show Pull Request (only for projects with a recognized hosting provider)
        if projectsWithValidRemotes.contains(thread.projectId) {
            let prTitle = thread.pullRequestInfo.map { String(localized: .ThreadStrings.threadOpenPullRequestLabel($0.displayLabel)) } ?? String(localized: .ThreadStrings.threadShowPullRequest)
            let prItem = NSMenuItem(title: prTitle, action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = pullRequestMenuIcon(for: thread)
            prItem.representedObject = thread
            menu.addItem(prItem)
        }

        // Open in Jira
        if let jiraItem = buildJiraMenuItem(for: thread, settings: settings) {
            menu.addItem(jiraItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Archive
        let archiveItem = NSMenuItem(title: String(localized: .ThreadStrings.threadArchiveMenuTitle), action: #selector(archiveThread(_:)), keyEquivalent: "")
        archiveItem.target = self
        archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        archiveItem.representedObject = thread
        menu.addItem(archiveItem)

        // Delete (destructive)
        let deleteItem = NSMenuItem(title: String(localized: .ThreadStrings.threadDeleteMenuTitle), action: #selector(deleteThread(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        deleteItem.representedObject = thread
        let redAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0)
        ]
        deleteItem.attributedTitle = NSAttributedString(string: String(localized: .ThreadStrings.threadDeleteMenuTitle), attributes: redAttributes)
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
        let finderItem = NSMenuItem(title: String(localized: .ThreadStrings.threadOpenInFinder), action: #selector(openThreadInFinder(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = OpenActionIcons.finderIcon(size: 16)
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
            let mainPrTitle = thread.pullRequestInfo.map { String(localized: .ThreadStrings.threadOpenPullRequestLabel($0.displayLabel)) } ?? String(localized: .ThreadStrings.threadShowOpenPullRequests)
            let prItem = NSMenuItem(title: mainPrTitle, action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = pullRequestMenuIcon(for: thread)
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
        let xcodeItem = NSMenuItem(title: String(localized: .ThreadStrings.threadOpenProject), action: #selector(openThreadInXcode(_:)), keyEquivalent: "")
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

        let item = NSMenuItem(title: String(localized: .ThreadStrings.threadCreateFromThisBranch), action: nil, keyEquivalent: "")
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
#if FEATURE_JIRA
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let projectKey = project.jiraProjectKey, !projectKey.isEmpty else {
            return nil
        }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return nil }

        let title: String
        if thread.jiraTicketKey != nil {
            title = String(localized: .ThreadStrings.threadOpenTicketInJira)
        } else if thread.isMain {
            title = String(localized: .ThreadStrings.threadOpenJiraBoard)
        } else {
            title = String(localized: .ThreadStrings.threadOpenInJira)
        }

        let item = NSMenuItem(title: title, action: #selector(openThreadInJira(_:)), keyEquivalent: "")
        item.target = self
        item.image = jiraMenuIcon()
        item.representedObject = thread
        return item
#else
        nil
#endif
    }

    private func jiraMenuIcon() -> NSImage? {
#if FEATURE_JIRA
        if let image = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (image.copy() as? NSImage) ?? image
            sized.size = NSSize(width: 16, height: 16)
            sized.isTemplate = false
            return sized
        }
        return NSImage(systemSymbolName: "ticket", accessibilityDescription: "Jira")
#else
        nil
#endif
    }

    private func pullRequestMenuIcon(for thread: MagentThread) -> NSImage {
        let provider = threadManager._cachedRemoteByProjectId[thread.projectId]?.provider ?? .unknown
        return OpenActionIcons.pullRequestIcon(for: provider, size: 16)
    }

    @objc private func openThreadInJira(_ sender: NSMenuItem) {
#if FEATURE_JIRA
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
#endif
    }

    private func buildProjectContextMenu(for project: SidebarProject) -> NSMenu {
        let menu = NSMenu()
        let pinTitle = project.isPinned ? String(localized: .CommonStrings.commonUnpin) : String(localized: .CommonStrings.commonPin)
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleProjectPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: project.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = project.projectId
        menu.addItem(pinItem)
        return menu
    }

    private func buildSectionContextMenu(for section: SidebarSection) -> NSMenu {
        let menu = NSMenu()

        let renameItem = NSMenuItem(title: "Rename Section", action: #selector(renameSectionFromMenu(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = [
            "projectId": section.projectId.uuidString,
            "sectionId": section.sectionId.uuidString,
            "sectionName": section.name,
        ]
        menu.addItem(renameItem)

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

    @objc private func toggleThreadHidden(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        threadManager.toggleThreadHidden(threadId: threadId)
    }

    @objc private func moveThreadToSection(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let sectionId = info["sectionId"] as? UUID else { return }
        threadManager.moveThread(thread, toSection: sectionId)
        reloadData()
    }

    @objc private func renameSectionFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let sectionIdRaw = info["sectionId"],
              let projectId = UUID(uuidString: projectIdRaw),
              let sectionId = UUID(uuidString: sectionIdRaw) else { return }
        beginRenamingSection(projectId: projectId, sectionId: sectionId, fallbackName: info["sectionName"])
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
            errorAlert.messageText = String(localized: .ThreadStrings.threadCouldNotSaveIcon)
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
            errorAlert.runModal()
        }
    }

    @objc private func renameThreadFromPrompt(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.threadRenameTitle)
        alert.informativeText = String(localized: .ThreadStrings.threadRenameMessage)
        alert.addButton(withTitle: String(localized: .CommonStrings.commonRename))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = String(localized: .ThreadStrings.threadRenamePlaceholder)
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let prompt = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        Task {
            do {
                let didRename = try await threadManager.renameThreadFromPrompt(thread, prompt: prompt)
                guard didRename else { return }
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == thread.id }) {
                        self.delegate?.threadList(self, didRenameThread: updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = String(localized: .CommonStrings.commonRenameFailed)
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    errorAlert.runModal()
                }
            }
        }
    }

    @objc private func renameThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.threadRenameBranchTitle)
        alert.informativeText = String(localized: .ThreadStrings.threadRenameBranchMessage)
        alert.addButton(withTitle: String(localized: .CommonStrings.commonRename))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

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
                    alert.messageText = String(localized: .CommonStrings.commonRenameFailed)
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
                    alert.runModal()
                }
            }
        }
    }

    @objc private func setThreadDescription(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: .ThreadStrings.threadSetDescriptionTitle)
        alert.informativeText = String(localized: .ThreadStrings.threadSetDescriptionMessage)
        alert.addButton(withTitle: String(localized: .CommonStrings.commonSave))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

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
            errorAlert.messageText = String(localized: .ThreadStrings.threadCouldNotSaveDescription)
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
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
            let targetName = thread.isMain ? String(localized: .ThreadStrings.threadProjectRoot) : String(localized: .ThreadStrings.threadWorktree)
            BannerManager.shared.show(
                message: String(localized: .ThreadStrings.threadOpenInFinderMissingDirectory(targetName)),
                style: .warning
            )
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
                    BannerManager.shared.show(message: String(localized: .ThreadStrings.threadNoGitRemotesFound), style: .warning)
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
                    BannerManager.shared.show(message: String(localized: .ThreadStrings.threadCouldNotConstructRemoteURL(remote.name)), style: .warning)
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
                    alert.messageText = String(localized: .ThreadStrings.threadArchiveTitle)
                    alert.informativeText = String(localized: .ThreadStrings.threadArchiveBusyMessage(thread.name, thread.branchName))
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonArchiveAnyway))
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                } else if !clean || !merged {
                    let alert = NSAlert()
                    alert.messageText = String(localized: .ThreadStrings.threadArchiveTitle)
                    var reasons: [String] = []
                    if !clean { reasons.append(String(localized: .ThreadStrings.threadArchiveReasonUncommittedChanges)) }
                    if !merged { reasons.append(String(localized: .ThreadStrings.threadArchiveReasonCommitsNotIn(baseBranch))) }
                    alert.informativeText = String(
                        localized: .ThreadStrings.threadArchiveReasonsMessage(
                            thread.name,
                            reasons.joined(separator: String(localized: .CommonStrings.commonJoinAnd)),
                            thread.branchName
                        )
                    )
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonArchive))
                    alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }
                }

                // Archive directly without a spinner sheet. The delegate-driven
                // reloadData()/showEmptyState() modifies split view items, which
                // crashes if a sheet is being presented on the same window.
                Task {
                    do {
                        _ = try await threadManager.archiveThread(
                            thread,
                            promptForLocalSyncConflicts: true
                        )
                    } catch ThreadManagerError.archiveCancelled {
                        return
                    } catch ThreadManagerError.localFileSyncFailed(let message) {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = String(localized: .ThreadStrings.threadArchiveLocalSyncFailedTitle)
                            alert.informativeText = String(localized: .ThreadStrings.threadArchiveLocalSyncFailedMessage(message))
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: String(localized: .CommonStrings.commonForceArchive))
                            alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))

                            let response = alert.runModal()
                            guard response == .alertFirstButtonReturn else { return }

                            Task {
                                do {
                                    _ = try await threadManager.archiveThread(
                                        thread,
                                        promptForLocalSyncConflicts: false,
                                        force: true
                                    )
                                } catch ThreadManagerError.archiveCancelled {
                                    return
                                } catch {
                                    await MainActor.run {
                                        BannerManager.shared.show(
                                            message: String(localized: .ThreadStrings.threadArchiveFailed(error.localizedDescription)),
                                            style: .error
                                        )
                                    }
                                }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            BannerManager.shared.show(
                                message: String(localized: .ThreadStrings.threadArchiveFailed(error.localizedDescription)),
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
        alert.messageText = String(localized: .ThreadStrings.threadDeleteTitle)
        alert.informativeText = String(localized: .ThreadStrings.threadDeleteMessage(thread.name, thread.branchName))
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: .CommonStrings.commonDelete))
        alert.addButton(withTitle: String(localized: .CommonStrings.commonCancel))
        alert.buttons.first?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            do {
                try await self.threadManager.deleteThread(thread)
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: String(localized: .ThreadStrings.threadDeleteFailed(error.localizedDescription)),
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

        if let section = clickedItem as? SidebarSection {
            let contextMenu = buildSectionContextMenu(for: section)
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

extension ThreadListViewController {

    @objc func outlineViewDoubleClicked(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0,
              let section = sender.item(atRow: row) as? SidebarSection,
              sectionHeaderHitArea(section) == .name else { return }
        cancelPendingSectionNameToggle(for: section)
        beginRenamingSection(projectId: section.projectId, sectionId: section.sectionId, fallbackName: section.name)
    }

    func isRenamingSection(_ section: SidebarSection) -> Bool {
        activeSectionRename?.projectId == section.projectId && activeSectionRename?.sectionId == section.sectionId
    }

    func scheduleSectionNameToggle(for section: SidebarSection) {
        cancelPendingSectionNameToggle()
        let toggleKey = sectionToggleKey(projectId: section.projectId, sectionId: section.sectionId)
        pendingSectionNameToggleKey = toggleKey
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingSectionNameToggleKey == toggleKey,
                  let currentSection = self.sidebarProjects
                    .first(where: { $0.projectId == section.projectId })?
                    .children
                    .compactMap({ $0 as? SidebarSection })
                    .first(where: { $0.sectionId == section.sectionId }) else { return }
            self.pendingSectionNameToggleKey = nil
            self.pendingSectionNameToggleWorkItem = nil
            guard !self.isRenamingSection(currentSection) else { return }
            self.toggleSection(currentSection, animatedDisclosureButton: self.sectionDisclosureButton(for: currentSection))
        }
        pendingSectionNameToggleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    func cancelPendingSectionNameToggle(for section: SidebarSection? = nil) {
        if let section,
           pendingSectionNameToggleKey != sectionToggleKey(projectId: section.projectId, sectionId: section.sectionId) {
            return
        }
        pendingSectionNameToggleWorkItem?.cancel()
        pendingSectionNameToggleWorkItem = nil
        pendingSectionNameToggleKey = nil
    }

    private func sectionToggleKey(projectId: UUID, sectionId: UUID) -> String {
        "\(projectId.uuidString):\(sectionId.uuidString)"
    }

    private func beginRenamingSection(projectId: UUID, sectionId: UUID, fallbackName: String?) {
        cancelPendingSectionNameToggle()

        if let activeSectionRename,
           activeSectionRename.projectId != projectId || activeSectionRename.sectionId != sectionId {
            finishSectionRename(commit: true)
        }

        let currentName = currentSectionName(projectId: projectId, sectionId: sectionId) ?? fallbackName ?? ""
        activeSectionRename = (projectId: projectId, sectionId: sectionId, originalName: currentName)
        reloadData()
        focusActiveSectionRenameField(selectAll: true)
    }

    private func focusActiveSectionRenameField(selectAll: Bool) {
        guard let editor = activeSectionRenameField() else { return }
        view.window?.makeFirstResponder(editor)
        if selectAll {
            editor.selectText(nil)
        }
    }

    private func activeSectionRenameField() -> NSTextField? {
        guard let activeSectionRename,
              let row = rowForSection(projectId: activeSectionRename.projectId, sectionId: activeSectionRename.sectionId),
              row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return nil
        }
        return cell.subviews.first(where: { $0.identifier == Self.sectionInlineRenameFieldIdentifier }) as? NSTextField
    }

    private func rowForSection(projectId: UUID, sectionId: UUID) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard let section = outlineView.item(atRow: row) as? SidebarSection,
                  section.projectId == projectId,
                  section.sectionId == sectionId else { continue }
            return row
        }
        return nil
    }

    private func currentSectionName(projectId: UUID, sectionId: UUID) -> String? {
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == projectId }),
           let projectSections = project.threadSections,
           let section = projectSections.first(where: { $0.id == sectionId }) {
            return section.name
        }
        return settings.threadSections.first(where: { $0.id == sectionId })?.name
    }

    private enum SectionRenameError: LocalizedError {
        case sectionNotFound
        case duplicateName(String)
        case emptyName

        var errorDescription: String? {
            switch self {
            case .sectionNotFound:
                return "The section no longer exists."
            case .duplicateName(let name):
                return "A section named \"\(name)\" already exists."
            case .emptyName:
                return "Section names cannot be empty."
            }
        }
    }

    func finishSectionRename(commit: Bool) {
        guard let activeSectionRename else { return }

        let editorValue = activeSectionRenameField()?.stringValue ?? activeSectionRename.originalName
        let trimmedName = editorValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if !commit {
            self.activeSectionRename = nil
            reloadData()
            return
        }

        if trimmedName.isEmpty {
            BannerManager.shared.show(message: SectionRenameError.emptyName.localizedDescription, style: .warning)
            reloadData()
            focusActiveSectionRenameField(selectAll: true)
            return
        }

        if trimmedName == activeSectionRename.originalName {
            self.activeSectionRename = nil
            reloadData()
            return
        }

        do {
            try persistSectionRename(
                projectId: activeSectionRename.projectId,
                sectionId: activeSectionRename.sectionId,
                newName: trimmedName
            )
            self.activeSectionRename = nil
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        } catch {
            BannerManager.shared.show(message: error.localizedDescription, style: .warning)
            reloadData()
            focusActiveSectionRenameField(selectAll: true)
        }
    }

    private func persistSectionRename(projectId: UUID, sectionId: UUID, newName: String) throws {
        var settings = persistence.loadSettings()

        if let projectIndex = settings.projects.firstIndex(where: { $0.id == projectId }),
           settings.projects[projectIndex].threadSections != nil {
            var sections = settings.projects[projectIndex].threadSections ?? []
            guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else {
                throw SectionRenameError.sectionNotFound
            }
            if sections.contains(where: {
                $0.id != sectionId && $0.name.caseInsensitiveCompare(newName) == .orderedSame
            }) {
                throw SectionRenameError.duplicateName(newName)
            }
            sections[sectionIndex].name = newName
            settings.projects[projectIndex].threadSections = sections
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.id == sectionId }) else {
                throw SectionRenameError.sectionNotFound
            }
            if settings.threadSections.contains(where: {
                $0.id != sectionId && $0.name.caseInsensitiveCompare(newName) == .orderedSame
            }) {
                throw SectionRenameError.duplicateName(newName)
            }
            settings.threadSections[sectionIndex].name = newName
        }

        try persistence.saveSettings(settings)
    }
}

extension ThreadListViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control.identifier == Self.sectionInlineRenameFieldIdentifier else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(nil)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishSectionRename(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.identifier == Self.sectionInlineRenameFieldIdentifier else { return }

        let movementValue = notification.userInfo?["NSTextMovement"] as? Int
        finishSectionRename(commit: movementValue != NSTextMovement.cancel.rawValue)
    }
}
