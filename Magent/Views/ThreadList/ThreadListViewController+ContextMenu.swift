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

        let settings = persistence.loadSettings()

        // Mark as read (when thread has unread agent completion)
        if thread.hasUnreadAgentCompletion {
            let markReadItem = NSMenuItem(title: String(localized: .ThreadStrings.threadMarkAsRead), action: #selector(markThreadAsRead(_:)), keyEquivalent: "")
            markReadItem.target = self
            markReadItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            markReadItem.representedObject = thread.id
            menu.addItem(markReadItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Pin/Unpin
        let pinTitle = thread.isPinned ? String(localized: .CommonStrings.commonUnpin) : String(localized: .CommonStrings.commonPin)
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(toggleThreadPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.image = NSImage(systemSymbolName: thread.isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        pinItem.representedObject = thread.id
        menu.addItem(pinItem)

        // Fork Thread
        if let createFromBranchItem = createThreadFromBaseMenuItem(for: thread, settings: settings) {
            menu.addItem(createFromBranchItem)
        }

        // Jira (below pin)
        if let jiraItem = buildJiraMenuItem(for: thread, settings: settings) {
            menu.addItem(jiraItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Rename with prompt (submenu: recent prompts + custom)
        let renamePromptItem = NSMenuItem(title: String(localized: .ThreadStrings.threadRenameWithPrompt), action: nil, keyEquivalent: "")
        renamePromptItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        renamePromptItem.submenu = buildRenameWithPromptSubmenu(for: thread)
        menu.addItem(renamePromptItem)

        // Rename branch
        let renameItem = NSMenuItem(title: String(localized: .ThreadStrings.threadRenameBranch), action: #selector(renameThread(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = thread
        menu.addItem(renameItem)

        let appearanceItem = NSMenuItem(title: String(localized: .ThreadStrings.threadAppearanceMenuTitle), action: nil, keyEquivalent: "")
        appearanceItem.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: nil)
        appearanceItem.submenu = buildAppearanceSubmenu(for: thread)
        menu.addItem(appearanceItem)

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

        menu.addItem(NSMenuItem.separator())

        // Hide/Unhide
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

        // Keep Alive
        let keepAliveTitle = thread.isKeepAlive ? "Remove Keep Alive" : "Keep Alive"
        let keepAliveItem = NSMenuItem(title: keepAliveTitle, action: #selector(toggleThreadKeepAlive(_:)), keyEquivalent: "")
        keepAliveItem.target = self
        keepAliveItem.image = NSImage(systemSymbolName: thread.isKeepAlive ? "shield.slash" : "shield.righthalf.filled", accessibilityDescription: nil)
        keepAliveItem.representedObject = thread.id
        menu.addItem(keepAliveItem)

        // Kill All Sessions
        let hasLiveSessions = thread.tmuxSessionNames.contains {
            !thread.deadSessions.contains($0)
        }
        if hasLiveSessions {
            let killItem = NSMenuItem(title: "Kill All Sessions", action: #selector(killAllThreadSessions(_:)), keyEquivalent: "")
            killItem.target = self
            killItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            killItem.representedObject = thread.id
            menu.addItem(killItem)
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

        if let prTitle = pullRequestMenuTitle(for: thread) {
            let prItem = NSMenuItem(title: prTitle, action: #selector(openThreadPullRequest(_:)), keyEquivalent: "")
            prItem.target = self
            prItem.image = pullRequestMenuIcon(for: thread)
            prItem.representedObject = thread
            menu.addItem(prItem)
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

    private func buildRenameWithPromptSubmenu(for thread: MagentThread) -> NSMenu {
        let submenu = NSMenu()

        // Draft tab prompts (shown first, prefixed with "DRAFT:")
        let draftPrompts: [(String, String)] = thread.persistedDraftTabs.compactMap { draft in
            let trimmed = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (draft.identifier, trimmed)
        }
        for (identifier, prompt) in draftPrompts {
            let display = prompt.count > 54 ? String(prompt.prefix(51)) + "…" : prompt
            let item = NSMenuItem(title: "\(ThreadManager.draftDescriptionPrefix)\(display)", action: #selector(renameWithDraftPrompt(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Draft")
            item.representedObject = ["thread": thread, "prompt": prompt, "draftId": identifier] as [String: Any]
            submenu.addItem(item)
        }

        // Collect recent prompts across all sessions (newest last), deduplicate, take last 3
        let recentPrompts: [String] = {
            var seen = Set<String>()
            var result: [String] = []
            for prompt in thread.submittedPromptsBySession.values.flatMap({ $0 }).reversed() {
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                result.append(trimmed)
                if result.count >= 3 { break }
            }
            return result.reversed() // oldest-first for menu order
        }()

        if !draftPrompts.isEmpty, !recentPrompts.isEmpty {
            submenu.addItem(.separator())
        }

        for prompt in recentPrompts {
            let truncated = prompt.count > 60 ? String(prompt.prefix(57)) + "…" : prompt
            let item = NSMenuItem(title: truncated, action: #selector(renameWithRecentPrompt(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["thread": thread, "prompt": prompt] as [String: Any]
            submenu.addItem(item)
        }

        if !recentPrompts.isEmpty || !draftPrompts.isEmpty {
            submenu.addItem(.separator())
        }

        let customItem = NSMenuItem(title: String(localized: .ThreadStrings.threadRenameCustom), action: #selector(renameThreadFromPrompt(_:)), keyEquivalent: "")
        customItem.target = self
        customItem.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
        customItem.representedObject = thread
        submenu.addItem(customItem)

        return submenu
    }

    private func buildAppearanceSubmenu(for thread: MagentThread) -> NSMenu {
        let submenu = NSMenu()

        let descriptionItem = NSMenuItem(title: String(localized: .ThreadStrings.threadSetDescription), action: #selector(setThreadDescription(_:)), keyEquivalent: "")
        descriptionItem.target = self
        descriptionItem.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        descriptionItem.representedObject = thread
        submenu.addItem(descriptionItem)

        let iconItem = NSMenuItem(title: String(localized: .ThreadStrings.threadIconMenuTitle), action: nil, keyEquivalent: "")
        iconItem.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        ) ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: "Thread icon")
        iconItem.submenu = buildThreadIconSubmenu(for: thread)
        submenu.addItem(iconItem)

        let signItem = NSMenuItem(title: "Sign", action: nil, keyEquivalent: "")
        signItem.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Sign emoji")
        signItem.submenu = buildSignEmojiSubmenu(for: thread)
        submenu.addItem(signItem)

        return submenu
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

    struct SignOption {
        var emoji: String
        var label: String
        var tintColor: NSColor?
    }

    static let signEmojiOptions: [SignOption] = [
        SignOption(emoji: "↑", label: "High Priority", tintColor: .systemRed),
        SignOption(emoji: "↓", label: "Low Priority", tintColor: .systemGreen),
        SignOption(emoji: "🛑", label: "Stop"),
        SignOption(emoji: "✅", label: "Done"),
        SignOption(emoji: "⏸️", label: "Paused"),
        SignOption(emoji: "⚠️", label: "Attention"),
        SignOption(emoji: "🔥", label: "Urgent"),
    ]

    /// Returns the tint color for a sign emoji string, if any.
    static func signEmojiTintColor(for emoji: String) -> NSColor? {
        signEmojiOptions.first(where: { $0.emoji == emoji })?.tintColor
    }

    private func buildSignEmojiSubmenu(for thread: MagentThread) -> NSMenu {
        let submenu = NSMenu()
        var addedSeparator = false
        for option in Self.signEmojiOptions {
            if !addedSeparator && option.tintColor == nil {
                submenu.addItem(.separator())
                addedSeparator = true
            }
            let isSelected = thread.signEmoji == option.emoji
            let item = NSMenuItem(title: "\(option.emoji)  \(option.label)", action: #selector(setThreadSignEmoji(_:)), keyEquivalent: "")
            item.target = self
            item.state = isSelected ? .on : .off
            if let tint = option.tintColor {
                let attributed = NSMutableAttributedString(string: option.emoji, attributes: [.foregroundColor: tint, .font: NSFont.menuFont(ofSize: 0)])
                attributed.append(NSAttributedString(string: "  \(option.label)", attributes: [.font: NSFont.menuFont(ofSize: 0)]))
                item.attributedTitle = attributed
            }
            item.representedObject = [
                "threadId": thread.id,
                "emoji": isSelected ? "" : option.emoji
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

        let item = NSMenuItem(title: String(localized: .ThreadStrings.threadCreateFromThisBranch), action: #selector(createThreadFromBranch(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        item.representedObject = ["project": project, "baseBranch": baseBranch, "sourceThread": thread] as [String: Any]
        return item
    }

    @objc private func createThreadFromBranch(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let project = info["project"] as? Project,
              let baseBranch = info["baseBranch"] as? String else { return }
        let sourceThread = info["sourceThread"] as? MagentThread
        presentNewThreadSheet(for: project, anchorView: outlineView, baseBranch: baseBranch, sourceThread: sourceThread)
    }

    func baseBranchForNewThread(from thread: MagentThread, project: Project) -> String? {
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
        guard settings.jiraIntegrationEnabled else { return nil }

        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let siteURL = project?.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return nil }

        let menuTitle: String

#if FEATURE_JIRA_SYNC
        if let projectKey = project?.jiraProjectKey, !projectKey.isEmpty {
            if let ticketKey = thread.jiraTicketKey {
                menuTitle = jiraMenuTitle(ticketKey: ticketKey, thread: thread)
            } else if thread.isMain {
                menuTitle = String(localized: .ThreadStrings.threadOpenJiraBoard)
            } else {
                menuTitle = String(localized: .ThreadStrings.threadOpenInJira)
            }
        } else if settings.jiraTicketDetectionEnabled, let ticketKey = thread.effectiveJiraTicketKey(settings: settings) {
            menuTitle = jiraMenuTitle(ticketKey: ticketKey, thread: thread)
        } else {
            return nil
        }
#else
        guard settings.jiraTicketDetectionEnabled,
              let ticketKey = thread.effectiveJiraTicketKey(settings: settings) else { return nil }
        menuTitle = jiraMenuTitle(ticketKey: ticketKey, thread: thread)
#endif

        let item = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        item.image = jiraMenuIcon()

        let submenu = NSMenu()

        let openItem = NSMenuItem(
            title: String(localized: .ThreadStrings.threadOpenInJira),
            action: #selector(openThreadInJira(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        openItem.representedObject = thread
        submenu.addItem(openItem)

        let copyLinkItem = NSMenuItem(
            title: String(localized: .ThreadStrings.threadCopyJiraLink),
            action: #selector(copyJiraLink(_:)),
            keyEquivalent: ""
        )
        copyLinkItem.target = self
        copyLinkItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copyLinkItem.representedObject = thread
        submenu.addItem(copyLinkItem)

        if let jiraSummary = thread.verifiedJiraTicket?.summary, !jiraSummary.isEmpty {
            let descItem = NSMenuItem(
                title: String(localized: .ThreadStrings.threadSetDescriptionFromJira),
                action: #selector(setThreadDescriptionFromJira(_:)),
                keyEquivalent: ""
            )
            descItem.target = self
            descItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
            descItem.representedObject = thread
            submenu.addItem(descItem)
        }

        // Change Status submenu
        if let ticketKey = thread.effectiveJiraTicketKey(settings: settings),
           let changeStatusItem = buildChangeStatusSubmenu(for: thread, ticketKey: ticketKey, settings: settings) {
            submenu.addItem(NSMenuItem.separator())
            submenu.addItem(changeStatusItem)
        }

        // Refresh
        submenu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(
            title: "Refresh",
            action: #selector(refreshJiraTicket(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshItem.representedObject = thread
        submenu.addItem(refreshItem)

        item.submenu = submenu
        return item
    }

    private func buildChangeStatusSubmenu(for thread: MagentThread, ticketKey: String, settings: AppSettings) -> NSMenuItem? {
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        guard let projectKey = projectKeyFromTicket(ticketKey) ?? project?.jiraProjectKey else { return nil }

        let statuses = threadManager.cachedProjectStatuses(for: projectKey)
        let currentStatus = thread.verifiedJiraTicket?.status

        let changeStatusItem = NSMenuItem(title: "Change Status", action: nil, keyEquivalent: "")
        changeStatusItem.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)

        if let statuses, !statuses.isEmpty {
            let sortedStatuses = statuses.sorted { a, b in
                let categoryOrder = ["new": 0, "indeterminate": 1, "done": 2]
                let orderA = categoryOrder[a.categoryKey ?? "indeterminate"] ?? 1
                let orderB = categoryOrder[b.categoryKey ?? "indeterminate"] ?? 1
                if orderA != orderB { return orderA < orderB }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            let statusSubmenu = NSMenu()
            for status in sortedStatuses {
                let statusItem = NSMenuItem(
                    title: status.name,
                    action: #selector(changeJiraStatus(_:)),
                    keyEquivalent: ""
                )
                statusItem.target = self
                statusItem.image = jiraStatusDotImage(categoryKey: status.categoryKey)
                statusItem.representedObject = [
                    "thread": thread,
                    "ticketKey": ticketKey,
                    "status": status.name
                ] as [String: Any]
                if status.name == currentStatus {
                    statusItem.state = .on
                }
                statusSubmenu.addItem(statusItem)
            }
            changeStatusItem.submenu = statusSubmenu
        } else {
            // Statuses not cached yet — fetch in background for next time
            changeStatusItem.action = nil
            changeStatusItem.isEnabled = false
            changeStatusItem.title = "Change Status (loading…)"
            Task {
                _ = await threadManager.fetchAndCacheProjectStatuses(projectKey: projectKey)
            }
        }

        return changeStatusItem
    }

    /// Extracts the project key from a ticket key (e.g. "IP-1234" → "IP").
    private func projectKeyFromTicket(_ ticketKey: String) -> String? {
        let parts = ticketKey.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return String(parts[0])
    }

    /// Returns a colored dot image based on Jira status category.
    private func jiraStatusDotImage(categoryKey: String?) -> NSImage {
        let color = StatusBadgeView.jiraCategoryColor(forKey: categoryKey) ?? .tertiaryLabelColor
        return colorDotImage(color: color, size: 8)
    }

    private func jiraMenuTitle(ticketKey: String, thread: MagentThread) -> String {
        if let summary = thread.verifiedJiraTicket?.summary, !summary.isEmpty {
            let title = "\(ticketKey): \(summary)"
            if title.count > 100 {
                return String(title.prefix(100)) + "…"
            }
            return title
        }
        return ticketKey
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

    private func pullRequestMenuIcon(for thread: MagentThread) -> NSImage {
        let provider = threadManager._cachedRemoteByProjectId[thread.projectId]?.provider ?? .unknown
        return OpenActionIcons.pullRequestIcon(for: provider, size: 16)
    }

    private func pullRequestMenuTitle(for thread: MagentThread) -> String? {
        if thread.isMain {
            guard projectsWithValidRemotes.contains(thread.projectId) else { return nil }
            return thread.pullRequestInfo.map { String(localized: .ThreadStrings.threadOpenPullRequestLabel($0.displayLabel)) }
                ?? String(localized: .ThreadStrings.threadShowOpenPullRequests)
        }

        if let pr = thread.pullRequestInfo {
            return String(localized: .ThreadStrings.threadOpenPullRequestLabel(pr.displayLabel))
        }

        guard thread.pullRequestLookupStatus == .notFound else { return nil }
        let provider = threadManager._cachedRemoteByProjectId[thread.projectId]?.provider ?? .unknown
        switch provider {
        case .gitlab:
            return String(localized: .ThreadStrings.threadCreateMergeRequest)
        case .github, .bitbucket, .unknown:
            return String(localized: .ThreadStrings.threadCreatePullRequest)
        }
    }

    private func resolveJiraURL(for thread: MagentThread) -> URL? {
        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let siteURL = project?.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return nil }
        let jira = JiraService.shared

        var url: URL?

#if FEATURE_JIRA_SYNC
        if let ticketKey = thread.jiraTicketKey {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        } else if thread.isMain,
                  let projectKey = project?.jiraProjectKey,
                  let boardId = project?.jiraBoardId {
            url = jira.boardURL(siteURL: siteURL, projectKey: projectKey, boardId: boardId)
        } else if let projectKey = project?.jiraProjectKey {
            url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
        }
#endif

        if url == nil, let ticketKey = thread.effectiveJiraTicketKey(settings: settings) {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        }

        return url
    }

    private func prefersInAppExternalLinks() -> Bool {
        persistence.loadSettings().externalLinkOpenPreference == .inApp
    }

    private func openExternalLinkForThread(
        _ thread: MagentThread,
        url: URL,
        identifier: String,
        title: String,
        iconType: WebTabIconType
    ) {
        guard prefersInAppExternalLinks() else {
            NSWorkspace.shared.open(url)
            return
        }
        NotificationCenter.default.post(
            name: .magentOpenExternalLinkInApp,
            object: nil,
            userInfo: [
                "threadId": thread.id,
                "url": url,
                "identifier": identifier,
                "title": title,
                "iconType": iconType.rawValue,
            ]
        )
    }

    @objc private func openThreadInJira(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread,
              let url = resolveJiraURL(for: thread) else { return }
        let ticketKey = thread.effectiveJiraTicketKey(settings: persistence.loadSettings())
        openExternalLinkForThread(
            thread,
            url: url,
            identifier: ticketKey.map { "jira:\($0)" } ?? "jira:\(url.absoluteString)",
            title: ticketKey ?? "Jira",
            iconType: .jira
        )
    }

    @objc private func copyJiraLink(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread,
              let url = resolveJiraURL(for: thread) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func changeJiraStatus(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let ticketKey = info["ticketKey"] as? String,
              let status = info["status"] as? String else { return }

        // Don't transition if already in this status
        if thread.verifiedJiraTicket?.status == status { return }

        inFlightJiraTransitions[ticketKey] = status
        showJiraTransitionProgressBanner()

        Task {
            do {
                try await threadManager.transitionJiraTicket(
                    ticketKey: ticketKey,
                    toStatus: status
                )
                await MainActor.run {
                    inFlightJiraTransitions.removeValue(forKey: ticketKey)
                    if inFlightJiraTransitions.isEmpty {
                        BannerManager.shared.show(
                            message: "\(ticketKey) → \(status)",
                            style: .info
                        )
                    } else {
                        showJiraTransitionProgressBanner()
                    }
                }
            } catch {
                await MainActor.run {
                    inFlightJiraTransitions.removeValue(forKey: ticketKey)
                    BannerManager.shared.show(
                        message: "Failed to transition \(ticketKey): \(error.localizedDescription)",
                        style: .error
                    )
                    if !inFlightJiraTransitions.isEmpty {
                        jiraProgressRestorationTask?.cancel()
                        jiraProgressRestorationTask = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, let self, !inFlightJiraTransitions.isEmpty else { return }
                            showJiraTransitionProgressBanner()
                        }
                    }
                }
            }
        }
    }

    private func showJiraTransitionProgressBanner() {
        let items = inFlightJiraTransitions
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: ", ")
        BannerManager.shared.show(
            message: "Transitioning \(items)…",
            style: .info,
            duration: nil,
            isDismissible: false,
            showsSpinner: true
        )
    }

    @objc private func refreshJiraTicket(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }
        threadManager.forceRefreshJiraTicket(for: thread)
        BannerManager.shared.show(message: "Refreshing Jira ticket…", style: .info)
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

        let sectionInfo: [String: String] = [
            "projectId": section.projectId.uuidString,
            "sectionId": section.sectionId.uuidString,
            "sectionName": section.name,
        ]

        let renameItem = NSMenuItem(title: "Rename Section", action: #selector(renameSectionFromMenu(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        renameItem.representedObject = sectionInfo
        menu.addItem(renameItem)

        let colorItem = NSMenuItem(title: "Change Color…", action: #selector(changeSectionColorFromMenu(_:)), keyEquivalent: "")
        colorItem.target = self
        colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        colorItem.representedObject = sectionInfo
        menu.addItem(colorItem)

        let keepAliveTitle = section.isKeepAlive ? "Remove Keep Alive" : "Keep Alive"
        let keepAliveItem = NSMenuItem(title: keepAliveTitle, action: #selector(toggleSectionKeepAlive(_:)), keyEquivalent: "")
        keepAliveItem.target = self
        keepAliveItem.image = NSImage(systemSymbolName: section.isKeepAlive ? "shield.slash" : "shield.righthalf.filled", accessibilityDescription: nil)
        keepAliveItem.representedObject = sectionInfo
        menu.addItem(keepAliveItem)

        menu.addItem(NSMenuItem.separator())

        let addItem = NSMenuItem(title: "Add Section…", action: #selector(addSectionFromMenu(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        addItem.representedObject = sectionInfo
        menu.addItem(addItem)

        let deleteItem = NSMenuItem(title: "Delete Section…", action: #selector(deleteSectionFromMenu(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteItem.representedObject = sectionInfo
        menu.addItem(deleteItem)

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

    @objc private func toggleThreadKeepAlive(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        threadManager.toggleThreadKeepAlive(threadId: threadId)
    }

    @objc private func killAllThreadSessions(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        Task {
            await threadManager.killAllSessions(threadId: threadId)
        }
    }

    @objc private func markThreadAsRead(_ sender: NSMenuItem) {
        guard let threadId = sender.representedObject as? UUID else { return }
        threadManager.markThreadCompletionSeen(threadId: threadId)
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

    @objc private func toggleSectionKeepAlive(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let sectionIdRaw = info["sectionId"],
              let projectId = UUID(uuidString: projectIdRaw),
              let sectionId = UUID(uuidString: sectionIdRaw) else { return }
        threadManager.toggleSectionKeepAlive(projectId: projectId, sectionId: sectionId)
    }

    @objc private func renameSectionFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let sectionIdRaw = info["sectionId"],
              let projectId = UUID(uuidString: projectIdRaw),
              let sectionId = UUID(uuidString: sectionIdRaw) else { return }
        beginRenamingSection(projectId: projectId, sectionId: sectionId, fallbackName: info["sectionName"])
    }

    @objc private func addSectionFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let projectId = UUID(uuidString: projectIdRaw) else { return }

        let afterSectionId = info["sectionId"].flatMap { UUID(uuidString: $0) }

        let alert = NSAlert()
        alert.messageText = "New Section"
        alert.informativeText = "Enter section name"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Section name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var settings = persistence.loadSettings()
        guard let projectIndex = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }

        let isProjectOverride = settings.projects[projectIndex].threadSections != nil
        var sections = isProjectOverride ? settings.projects[projectIndex].threadSections! : settings.threadSections
        guard !sections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            BannerManager.shared.show(
                message: "A section named \"\(name)\" already exists.",
                style: .warning
            )
            return
        }

        // Determine insertion sort order: right after the source section, or at the end
        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }
        let insertAfterOrder: Int
        if let afterId = afterSectionId,
           let afterSection = sortedSections.first(where: { $0.id == afterId }) {
            insertAfterOrder = afterSection.sortOrder
        } else {
            insertAfterOrder = sortedSections.last.map(\.sortOrder) ?? -1
        }

        // Shift all sections that come after the insertion point
        for i in 0..<sections.count where sections[i].sortOrder > insertAfterOrder {
            sections[i].sortOrder += 1
        }

        let newSection = ThreadSection(
            name: name,
            colorHex: ThreadSection.randomColorHex(),
            sortOrder: insertAfterOrder + 1
        )
        sections.append(newSection)
        if isProjectOverride {
            settings.projects[projectIndex].threadSections = sections
        } else {
            settings.threadSections = sections
        }
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func changeSectionColorFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let sectionIdRaw = info["sectionId"],
              let projectId = UUID(uuidString: projectIdRaw),
              let sectionId = UUID(uuidString: sectionIdRaw) else { return }

        let settings = persistence.loadSettings()
        guard let section = settings.sections(for: projectId).first(where: { $0.id == sectionId }) else { return }

        contextMenuSectionColorTarget = (projectId: projectId, sectionId: sectionId)
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = section.color
        panel.setTarget(self)
        panel.setAction(#selector(sectionContextMenuColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func sectionContextMenuColorChanged(_ sender: NSColorPanel) {
        guard let target = contextMenuSectionColorTarget else { return }
        var settings = persistence.loadSettings()
        if let projectIndex = settings.projects.firstIndex(where: { $0.id == target.projectId }),
           settings.projects[projectIndex].threadSections != nil {
            guard let sectionIndex = settings.projects[projectIndex].threadSections!.firstIndex(where: { $0.id == target.sectionId }) else { return }
            settings.projects[projectIndex].threadSections![sectionIndex].colorHex = sender.color.hexString
        } else {
            guard let sectionIndex = settings.threadSections.firstIndex(where: { $0.id == target.sectionId }) else { return }
            settings.threadSections[sectionIndex].colorHex = sender.color.hexString
        }
        try? persistence.saveSettings(settings)
        reloadData()
    }

    @objc private func deleteSectionFromMenu(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let projectIdRaw = info["projectId"],
              let sectionIdRaw = info["sectionId"],
              let projectId = UUID(uuidString: projectIdRaw),
              let sectionId = UUID(uuidString: sectionIdRaw) else { return }

        var settings = persistence.loadSettings()
        guard let projectIndex = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }

        let sections = settings.sections(for: projectId)
        guard let section = sections.first(where: { $0.id == sectionId }) else { return }
        guard let defaultSection = settings.defaultSection(for: projectId) else { return }

        guard sections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard defaultSection.id != section.id else {
            BannerManager.shared.show(
                message: "Cannot delete the default section. Change the default section first.",
                style: .warning
            )
            return
        }

        let threadCount = ThreadManager.shared.threadsAssigned(
            toSection: sectionId,
            projectId: projectId,
            settings: settings
        ).count
        if threadCount > 0 {
            let infoText = threadCount == 1
                ? "Delete \"\(section.name)\"? 1 thread will be moved to \"\(defaultSection.name)\"."
                : "Delete \"\(section.name)\"? \(threadCount) threads will be moved to \"\(defaultSection.name)\"."
            let alert = NSAlert()
            alert.messageText = "Delete Section?"
            alert.informativeText = infoText
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        ThreadManager.shared.reassignThreadsAssigned(
            toSection: sectionId,
            toSection: defaultSection.id,
            projectId: projectId,
            settings: settings
        )

        let isProjectOverride = settings.projects[projectIndex].threadSections != nil
        if isProjectOverride {
            settings.projects[projectIndex].threadSections = sections.filter { $0.id != sectionId }
        } else {
            settings.threadSections = settings.threadSections.filter { $0.id != sectionId }
        }
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
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

    @objc private func setThreadSignEmoji(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let threadId = info["threadId"] as? UUID,
              let emojiRaw = info["emoji"] as? String else { return }
        let emoji: String? = emojiRaw.isEmpty ? nil : emojiRaw
        do {
            try threadManager.setThreadSignEmoji(threadId: threadId, signEmoji: emoji)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could not save sign emoji"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
            errorAlert.runModal()
        }
    }

    @objc private func renameWithRecentPrompt(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let prompt = info["prompt"] as? String else { return }

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

    @objc private func renameWithDraftPrompt(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let thread = info["thread"] as? MagentThread,
              let prompt = info["prompt"] as? String else { return }

        Task {
            do {
                let didRename = try await threadManager.renameThreadFromPrompt(thread, prompt: prompt, prefixDraft: true)
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
        textField.stringValue = thread.branchName
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != thread.branchName else { return }

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

        try? threadManager.setTaskDescription(threadId: thread.id, description: textField.stringValue)
    }

    @objc private func setThreadDescriptionFromJira(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread,
              let jiraSummary = thread.verifiedJiraTicket?.summary, !jiraSummary.isEmpty else { return }

        try? threadManager.setTaskDescription(threadId: thread.id, description: jiraSummary)
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

        if !thread.isMain {
            Task {
                guard let action = await threadManager.resolvePullRequestActionTarget(for: thread) else { return }
                await MainActor.run {
                    let title: String
                    if action.isCreation {
                        title = action.provider == .gitlab ? "Create MR" : "Create PR"
                    } else if let pr = thread.pullRequestInfo {
                        title = pr.shortLabel
                    } else {
                        title = action.provider == .gitlab ? "MR" : "PR"
                    }
                    let identifierPrefix = action.isCreation ? "pr-create:" : "pr:"
                    self.openExternalLinkForThread(
                        thread,
                        url: action.url,
                        identifier: "\(identifierPrefix)\(action.url.absoluteString)",
                        title: title,
                        iconType: .pullRequest
                    )
                }
            }
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

            let branch = thread.actualBranch ?? thread.branchName
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
                let title = thread.pullRequestInfo?.shortLabel ?? (remote.provider == .gitlab ? "MR" : "PR")
                self.openExternalLinkForThread(
                    thread,
                    url: url,
                    identifier: "pr:\(url.absoluteString)",
                    title: title,
                    iconType: .pullRequest
                )
            }
        }
    }

    @objc private func archiveThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? MagentThread else { return }
        triggerArchive(for: thread)
    }

    func triggerArchive(for thread: MagentThread) {
        let threadManager = self.threadManager
        let liveThread = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        guard !liveThread.isArchiving else { return }

        threadManager.markThreadArchiving(id: liveThread.id)
        Task {
            do {
                _ = try await threadManager.archiveThread(liveThread, force: true)
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
