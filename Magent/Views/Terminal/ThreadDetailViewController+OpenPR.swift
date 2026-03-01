import Cocoa

extension ThreadDetailViewController {

    // MARK: - Open PR/MR

    @objc func openPRTapped(_ sender: NSButton) {
        Task {
            let settings = PersistenceService.shared.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            guard !remotes.isEmpty else {
                BannerManager.shared.show(message: "No git remotes found", style: .warning)
                return
            }

            let branch = thread.branchName
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
                    await MainActor.run {
                        showRemoteMenu(remotes: remotes, branch: branch, defaultBranch: defaultBranch, relativeTo: sender)
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
                self.openPRButton.toolTip = self.openPRTooltip(for: provider)
            }
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
        if let image = hostIcon(for: provider) {
            return image
        }
        return NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open Pull Request") ?? NSImage()
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
        let imageName: String?
        switch provider {
        case .github:
            imageName = "RepoHostGitHub"
        case .gitlab:
            imageName = "RepoHostGitLab"
        case .bitbucket:
            imageName = "RepoHostBitbucket"
        case .unknown:
            imageName = nil
        }

        guard let imageName, let baseImage = NSImage(named: NSImage.Name(imageName)) else { return nil }
        let sourceImage = (baseImage.copy() as? NSImage) ?? baseImage
        sourceImage.size = NSSize(width: 16, height: 16)

        if provider == .github {
            // GitHub favicon is dark; keep it readable in dark mode with a subtle light badge.
            let size = NSSize(width: 16, height: 16)
            let composed = NSImage(size: size, flipped: false) { _ in
                let rect = NSRect(origin: .zero, size: size)
                let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                NSColor.white.setFill()
                bgPath.fill()
                NSColor.black.withAlphaComponent(0.16).setStroke()
                bgPath.lineWidth = 1
                bgPath.stroke()

                let iconRect = rect.insetBy(dx: 2, dy: 2)
                sourceImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            composed.isTemplate = false
            return composed
        }

        sourceImage.isTemplate = false
        return sourceImage
    }

    private func showRemoteMenu(remotes: [GitRemote], branch: String, defaultBranch: String?, relativeTo button: NSButton) {
        let menu = NSMenu(title: "Select Remote")
        for remote in remotes {
            let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL
            guard let url else { continue }
            let title = "\(remote.name) (\(remote.host)/\(remote.repoPath))"
            let item = NSMenuItem(title: title, action: #selector(remoteMenuItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
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
        guard let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL else {
            BannerManager.shared.show(message: "Could not construct URL for remote \(remote.name)", style: .warning)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func xcodeButtonImage() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/Applications/Xcode.app")
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

    func refreshXcodeButton() {
        let xcodeExists = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
        openInXcodeButton.isHidden = !xcodeExists || xcodeProjectPath() == nil
    }

    @objc func openInXcodeTapped() {
        guard let path = xcodeProjectPath() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func finderButtonImage() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        image.size = NSSize(width: 14, height: 14)
        return image
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
}
