import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Open PR/MR

    @objc func openPRTapped(_ sender: NSButton) {
        // If we have a detected PR, open it directly
        if let pr = thread.pullRequestInfo {
            NSWorkspace.shared.open(pr.url)
            return
        }

        Task {
            let settings = PersistenceService.shared.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            guard !remotes.isEmpty else {
                await MainActor.run {
                    BannerManager.shared.show(message: "No git remotes found", style: .warning)
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
            if remotes.count == 1 {
                await MainActor.run {
                    openRemoteURL(remotes[0], branch: branch, defaultBranch: defaultBranch)
                }
            } else {
                // Find the "primary" remote — prefer origin
                let origin = remotes.first(where: { $0.name == "origin" })
                if let origin, remotes.allSatisfy({ $0.host == origin.host && $0.repoPath == origin.repoPath }) {
                    // All remotes point to the same place
                    await MainActor.run {
                        openRemoteURL(origin, branch: branch, defaultBranch: defaultBranch)
                    }
                } else {
                    let menuTargets = await resolveRemoteMenuTargets(remotes: remotes, branch: branch, defaultBranch: defaultBranch)
                    await MainActor.run {
                        showRemoteMenu(targets: menuTargets, relativeTo: sender)
                    }
                }
            }
        }
    }

    func refreshOpenPRButtonIcon() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let settings = PersistenceService.shared.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == self.thread.projectId }) else {
                self.openPRButton.isHidden = true
                return
            }

            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            let provider = self.preferredHostingProvider(from: remotes)
            if remotes.isEmpty || provider == .unknown {
                self.openPRButton.isHidden = true
            } else {
                self.openPRButton.isHidden = false
                self.openPRButton.image = self.openPRButtonImage(for: provider)
                self.applyPRButtonTitle()
            }
        }
    }

    private func applyPRButtonTitle() {
        if let pr = thread.pullRequestInfo {
            openPRButton.title = pr.shortLabel
            openPRButton.imagePosition = .imageLeading
            openPRButton.toolTip = "\(pr.displayLabel) — Click to open"
        } else {
            openPRButton.title = ""
            openPRButton.imagePosition = .imageOnly
            let provider = threadManager._cachedRemoteByProjectId[thread.projectId]?.provider ?? .unknown
            openPRButton.toolTip = openPRTooltip(for: provider)
        }
    }

    private func preferredHostingProvider(from remotes: [GitRemote]) -> GitHostingProvider {
        guard !remotes.isEmpty else { return .unknown }

        if let first = remotes.first,
           remotes.allSatisfy({ $0.host == first.host && $0.repoPath == first.repoPath }) {
            return first.provider
        }

        if let origin = remotes.first(where: { $0.name == "origin" }) {
            return origin.provider
        }

        return remotes.first(where: { $0.provider != .unknown })?.provider ?? .unknown
    }

    func openPRButtonImage(for provider: GitHostingProvider) -> NSImage {
        OpenActionIcons.pullRequestIcon(for: provider, size: 16)
    }

    private func openPRTooltip(for provider: GitHostingProvider) -> String {
        switch provider {
        case .github:
            return "Open GitHub Pull Request in Browser"
        case .gitlab:
            return "Open GitLab Merge Request in Browser"
        case .bitbucket:
            return "Open Bitbucket Pull Request in Browser"
        case .unknown:
            return "Open Pull Request in Browser"
        }
    }

    private func hostIcon(for provider: GitHostingProvider) -> NSImage? {
        OpenActionIcons.hostingProviderIcon(for: provider, size: 16)
    }

    private func resolveRemoteMenuTargets(
        remotes: [GitRemote],
        branch: String,
        defaultBranch: String?
    ) async -> [(remote: GitRemote, url: URL)] {
        var targets: [(remote: GitRemote, url: URL)] = []
        for remote in remotes {
            let directURL: URL?
            if branch != defaultBranch {
                directURL = await GitService.shared.fetchPullRequest(remote: remote, branch: branch)?.url
            } else {
                directURL = nil
            }

            if let url = directURL
                ?? remote.pullRequestURL(for: branch, defaultBranch: defaultBranch)
                ?? remote.openPullRequestsURL
                ?? remote.repoWebURL {
                targets.append((remote: remote, url: url))
            }
        }
        return targets
    }

    private func showRemoteMenu(targets: [(remote: GitRemote, url: URL)], relativeTo button: NSButton) {
        let menu = NSMenu(title: "Select Remote")
        for target in targets {
            let remote = target.remote
            let title = "\(remote.name) (\(remote.host)/\(remote.repoPath))"
            let item = NSMenuItem(title: title, action: #selector(remoteMenuItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.url
            item.image = hostIcon(for: remote.provider)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func remoteMenuItemTapped(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRemoteURL(_ remote: GitRemote, branch: String, defaultBranch: String?) {
        Task {
            let url = await GitService.shared.fetchPullRequest(remote: remote, branch: branch)?.url
                ?? remote.pullRequestURL(for: branch, defaultBranch: defaultBranch)
                ?? remote.openPullRequestsURL
                ?? remote.repoWebURL

            await MainActor.run {
                guard let url else {
                    BannerManager.shared.show(message: "Could not construct URL for remote \(remote.name)", style: .warning)
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    func xcodeButtonImage(forAppURL url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path())
        image.size = NSSize(width: 14, height: 14)
        return image
    }

    private func xcodeProjectPath() -> String? {
        let dirPath = NSString(string: finderTargetPath()).expandingTildeInPath
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return nil }

        // Look for .xcworkspace first (prefer over .xcodeproj)
        let workspaces = contents.filter { name in
            guard name.hasSuffix(".xcworkspace") else { return false }
            // Filter out Xcode-internal project.xcworkspace
            if name == "project.xcworkspace" { return false }
            return true
        }
        if let first = workspaces.first {
            return (dirPath as NSString).appendingPathComponent(first)
        }

        // Fall back to .xcodeproj
        let projects = contents.filter { $0.hasSuffix(".xcodeproj") }
        if let first = projects.first {
            return (dirPath as NSString).appendingPathComponent(first)
        }

        return nil
    }
    
    private func urlForXcodeProjectOpeningApp() -> URL? {
        guard let projPath = xcodeProjectPath() else { return nil }
        let projURL = URL(fileURLWithPath: projPath)
        return NSWorkspace.shared.urlForApplication(toOpen: projURL)
    }
    
    func refreshXcodeButton() {
        let openingAppURL = urlForXcodeProjectOpeningApp()
        
        if let openingAppURL {
            openInXcodeButton.image = xcodeButtonImage(forAppURL: openingAppURL)
        }
        
        openInXcodeButton.isHidden = openingAppURL == nil
    }

    @objc func openInXcodeTapped() {
        guard let path = xcodeProjectPath() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func finderButtonImage() -> NSImage {
        OpenActionIcons.finderIcon(size: 14)
    }

    private func finderTargetPath() -> String {
        if thread.isMain {
            let settings = PersistenceService.shared.loadSettings()
            if let projectPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath {
                return projectPath
            }
        }
        return thread.worktreePath
    }

    @objc func openInFinderTapped() {
        let path = NSString(string: finderTargetPath()).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue else {
            let targetName = thread.isMain ? "project root" : "worktree"
            BannerManager.shared.show(message: "Could not open \(targetName) in Finder because the directory is missing.", style: .warning)
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Review Button

    func refreshReviewButtonVisibility() {
        reviewButton.isHidden = thread.isMain
    }

    func syncTransientState() {
        guard let latest = threadManager.threads.first(where: { $0.id == thread.id }) else { return }
        thread.isFullyDelivered = latest.isFullyDelivered
        thread.isDirty = latest.isDirty
        let prChanged = thread.pullRequestInfo != latest.pullRequestInfo
        thread.pullRequestInfo = latest.pullRequestInfo
        refreshReviewButtonVisibility()
        if prChanged {
            applyPRButtonTitle()
        }
    }
}
