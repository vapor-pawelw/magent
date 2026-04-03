import Cocoa
import MagentCore

final class AppCoordinator {

    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("MagentMainWindow")
    private static let offScreenRecoveryDelay: TimeInterval = 1.0

    private var window: NSWindow?
    private let persistence = PersistenceService.shared
    private var pendingOffScreenRecovery: DispatchWorkItem?
    private(set) var statusBar: StatusBarView?

    func start() {
        let initialThreadsOutcome = persistence.tryLoadThreads()
        let activeThreadProjectIDs: Set<UUID>
        switch initialThreadsOutcome {
        case .loaded(let threads):
            activeThreadProjectIDs = Set(threads.filter { !$0.isArchived }.map(\.projectId))
        case .fileNotFound, .decodeFailed:
            activeThreadProjectIDs = []
        }

        _ = persistence.recoverSettingsFromRollingBackupIfNeeded(activeThreadProjectIDs: activeThreadProjectIDs)

        // Validate critical persistence files before showing the UI.
        // If any file is corrupted or incompatible, block writes and let the
        // user decide: quit (to fix manually) or continue with defaults.
        var failures: [PersistenceLoadFailure] = []

        var settingsOutcome = persistence.tryLoadSettings()
        switch settingsOutcome {
        case .loaded: break
        case .fileNotFound: break
        case .decodeFailed(let failure):
            persistence.blockWrites(for: failure.fileName)
            failures.append(failure)
        }

        var threadsOutcome = persistence.tryLoadThreads()
        switch threadsOutcome {
        case .loaded: break
        case .fileNotFound: break
        case .decodeFailed(let failure):
            persistence.blockWrites(for: failure.fileName)
            failures.append(failure)
        }

        (settingsOutcome, threadsOutcome) = reconcileThreadsToExistingProjectsIfPossible(
            settingsOutcome: settingsOutcome,
            threadsOutcome: threadsOutcome
        )

        if failures.isEmpty, shouldTreatSettingsAsIncomplete(settingsOutcome, threadsOutcome: threadsOutcome) {
            persistence.blockWrites(for: "settings.json")
            let shouldContinue = presentIncompleteSettingsAlert()
            if !shouldContinue {
                NSApp.terminate(nil)
                return
            }
        }

        if !failures.isEmpty {
            let shouldContinue = presentPersistenceFailureAlert(failures)
            if !shouldContinue {
                NSApp.terminate(nil)
                return
            }
            // User chose to continue with reset — backup broken files, then unblock writes
            for failure in failures {
                persistence.backupFile(at: failure.filePath)
                persistence.unblockWrites(for: failure.fileName)
            }
        }

        let settings = persistence.loadSettings()

        BackupService.shared.startPeriodicSnapshots()

        let splitVC = SplitViewController()

        // Default size: 75% of screen. setFrameAutosaveName restores the previous
        // session's size/position on subsequent launches automatically.
        let screenFrame = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let w = screenFrame.width * 0.75
        let h = screenFrame.height * 0.75

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 500)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Wrap the split VC in a container that adds the status bar at the bottom
        let containerVC = MainContainerViewController(splitViewController: splitVC)
        window.contentViewController = containerVC
        self.statusBar = containerVC.statusBar

        // This saves/restores the window frame across launches.
        // On first launch (no saved frame), it uses the contentRect above.
        let restoredFrame = window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        if !restoredFrame {
            window.center()
        }
        ensureWindowIsVisibleOnCurrentScreens(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        installBannerOverlay(for: window)

        if !settings.isConfigured {
            presentConfiguration(over: splitVC)
        } else {
            Task {
                await ThreadManager.shared.restoreThreads()
                ThreadManager.shared.startSessionMonitor()

                // Warn about projects with invalid paths
                let invalidProjects = settings.projects.filter { !$0.isValid }
                if !invalidProjects.isEmpty {
                    await MainActor.run {
                        let names = invalidProjects.map(\.name).joined(separator: ", ")
                        BannerManager.shared.show(
                            message: String(localized: .AppStrings.projectInvalidPathsWarning(names)),
                            style: .warning,
                            isDismissible: true,
                            actions: [BannerAction(title: String(localized: .CommonStrings.commonSettings)) {
                                NotificationCenter.default.post(name: .magentOpenSettings, object: nil)
                            }]
                        )
                    }
                }
            }
        }
    }

    private func installBannerOverlay(for window: NSWindow) {
        guard let contentView = window.contentView else { return }

        // Transparent-titlebar windows can render content visually under the title bar
        // while the theme frame above `contentView` still wins hit-testing there.
        // Mount the banner overlay on that parent when available so top banners remain
        // clickable instead of behaving like titlebar drag targets.
        let overlayHost = contentView.superview ?? contentView

        let bannerOverlay = BannerOverlayView()
        bannerOverlay.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.addSubview(bannerOverlay, positioned: .above, relativeTo: contentView)
        NSLayoutConstraint.activate([
            bannerOverlay.topAnchor.constraint(equalTo: overlayHost.topAnchor),
            bannerOverlay.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
            bannerOverlay.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
            bannerOverlay.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
        ])
        BannerManager.shared.setContainer(bannerOverlay)
    }

    func showMainWindow() {
        guard let window else { return }
        ensureWindowIsVisibleOnCurrentScreens(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func presentConfiguration(over viewController: NSViewController) {
        let configVC = ConfigurationViewController()
        configVC.onComplete = {
            Task {
                await ThreadManager.shared.restoreThreads()
                ThreadManager.shared.startSessionMonitor()
            }
        }
        viewController.presentAsSheet(configVC)
    }

    /// Shows a modal alert for persistence load failures. Returns true if the user chose
    /// to continue with defaults, false if they chose to quit.
    private func presentPersistenceFailureAlert(_ failures: [PersistenceLoadFailure]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to load application data"

        let fileList = failures.map { "  \u{2022} \($0.localizedDescription)" }.joined(separator: "\n")
        let appSupportPath = failures.first?.filePath.deletingLastPathComponent().path
            ?? "~/Library/Application Support/Magent"

        alert.informativeText = """
        The following files could not be read:

        \(fileList)

        You can quit now and restore the files manually (from a backup, by upgrading \
        the app, etc.). The files will not be modified until you choose to reset them.

        Alternatively, continue with default values. The broken files will be backed up \
        with a .corrupted suffix and then overwritten when the app saves.

        File location: \(appSupportPath)
        """

        alert.addButton(withTitle: "Continue with Reset")
        alert.addButton(withTitle: "Quit Magent")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    private func shouldTreatSettingsAsIncomplete(
        _ settingsOutcome: LoadOutcome<AppSettings>,
        threadsOutcome: LoadOutcome<[MagentThread]>
    ) -> Bool {
        guard case .loaded(let threads) = threadsOutcome else {
            return false
        }

        let activeThreadProjectIDs = Set(threads.filter { !$0.isArchived }.map(\.projectId))
        guard !activeThreadProjectIDs.isEmpty else { return false }

        switch settingsOutcome {
        case .fileNotFound:
            return true
        case .loaded(let settings):
            let coveredProjectIDs = Set(settings.projects.map(\.id)).intersection(activeThreadProjectIDs)
            return !settings.isConfigured || settings.projects.isEmpty || coveredProjectIDs.count < activeThreadProjectIDs.count
        case .decodeFailed:
            return false
        }
    }

    private func reconcileThreadsToExistingProjectsIfPossible(
        settingsOutcome: LoadOutcome<AppSettings>,
        threadsOutcome: LoadOutcome<[MagentThread]>
    ) -> (LoadOutcome<AppSettings>, LoadOutcome<[MagentThread]>) {
        guard case .loaded(let settings) = settingsOutcome,
              case .loaded(var threads) = threadsOutcome else {
            return (settingsOutcome, threadsOutcome)
        }

        var didChange = false
        for index in threads.indices {
            guard !threads[index].isArchived else { continue }
            guard settings.projects.contains(where: { $0.id == threads[index].projectId }) == false else { continue }
            guard let replacementProjectID = matchingProjectID(for: threads[index], settings: settings) else { continue }
            threads[index] = threads[index].withProjectId(replacementProjectID)
            didChange = true
        }

        let consolidatedThreads = consolidateDuplicateThreads(threads)
        if consolidatedThreads.count != threads.count {
            threads = consolidatedThreads
            didChange = true
        }

        guard didChange else {
            return (settingsOutcome, threadsOutcome)
        }

        try? persistence.saveThreads(threads)
        return (settingsOutcome, .loaded(threads))
    }

    private func matchingProjectID(for thread: MagentThread, settings: AppSettings) -> UUID? {
        let worktreePath = URL(fileURLWithPath: thread.worktreePath).standardizedFileURL.path

        let exactRepoMatches = settings.projects.filter {
            URL(fileURLWithPath: $0.repoPath).standardizedFileURL.path == worktreePath
        }
        if exactRepoMatches.count == 1 {
            return exactRepoMatches[0].id
        }

        let worktreeBaseMatches = settings.projects.filter {
            let basePath = URL(fileURLWithPath: $0.resolvedWorktreesBasePath()).standardizedFileURL.path
            return worktreePath.hasPrefix(basePath + "/")
        }
        if worktreeBaseMatches.count == 1 {
            return worktreeBaseMatches[0].id
        }

        return nil
    }

    private func consolidateDuplicateThreads(_ threads: [MagentThread]) -> [MagentThread] {
        var consolidated: [MagentThread] = []
        var activeThreadIndexByKey: [String: Int] = [:]

        for thread in threads {
            guard !thread.isArchived else {
                consolidated.append(thread)
                continue
            }

            let key = "\(thread.projectId.uuidString)|\(normalizedThreadWorktreePath(thread))"
            if let existingIndex = activeThreadIndexByKey[key] {
                consolidated[existingIndex] = mergeThreads(consolidated[existingIndex], duplicate: thread)
            } else {
                activeThreadIndexByKey[key] = consolidated.count
                consolidated.append(thread)
            }
        }

        return consolidated
    }

    private func normalizedThreadWorktreePath(_ thread: MagentThread) -> String {
        URL(fileURLWithPath: thread.worktreePath).standardizedFileURL.path
    }

    private func mergeThreads(_ canonical: MagentThread, duplicate: MagentThread) -> MagentThread {
        var merged = canonical

        merged.name = preferredThreadName(primary: canonical.name, secondary: duplicate.name)
        merged.worktreePath = preferredNonEmpty(primary: canonical.worktreePath, secondary: duplicate.worktreePath)
        merged.branchName = preferredNonEmpty(primary: canonical.branchName, secondary: duplicate.branchName)
        merged.tmuxSessionNames = appendUnique(canonical.tmuxSessionNames, duplicate.tmuxSessionNames)
        merged.agentTmuxSessions = appendUnique(canonical.agentTmuxSessions, duplicate.agentTmuxSessions)
        merged.pinnedTmuxSessions = appendUnique(canonical.pinnedTmuxSessions, duplicate.pinnedTmuxSessions)
        merged.protectedTmuxSessions.formUnion(duplicate.protectedTmuxSessions)
        merged.isKeepAlive = canonical.isKeepAlive || duplicate.isKeepAlive
        merged.didOfferKeepAlivePromotion = canonical.didOfferKeepAlivePromotion || duplicate.didOfferKeepAlivePromotion
        merged.isMain = canonical.isMain || duplicate.isMain
        merged.agentHasRun = canonical.agentHasRun || duplicate.agentHasRun
        merged.isPinned = canonical.isPinned || duplicate.isPinned
        merged.isSidebarHidden = canonical.isSidebarHidden && duplicate.isSidebarHidden
        merged.lastAgentCompletionAt = [canonical.lastAgentCompletionAt, duplicate.lastAgentCompletionAt].compactMap { $0 }.max()
        merged.unreadCompletionSessions.formUnion(duplicate.unreadCompletionSessions)
        merged.didAutoRenameFromFirstPrompt = canonical.didAutoRenameFromFirstPrompt || duplicate.didAutoRenameFromFirstPrompt
        merged.baseBranch = preferredOptional(primary: canonical.baseBranch, secondary: duplicate.baseBranch)
        merged.displayOrder = min(canonical.displayOrder, duplicate.displayOrder)
        merged.jiraTicketKey = preferredOptional(primary: canonical.jiraTicketKey, secondary: duplicate.jiraTicketKey)
        merged.taskDescription = preferredOptional(primary: canonical.taskDescription, secondary: duplicate.taskDescription)
        merged.localFileSyncEntriesSnapshot = canonical.localFileSyncEntriesSnapshot ?? duplicate.localFileSyncEntriesSnapshot
        merged.hasEverDoneWork = canonical.hasEverDoneWork || duplicate.hasEverDoneWork
        merged.signEmoji = preferredOptional(primary: canonical.signEmoji, secondary: duplicate.signEmoji)
        merged.archivedAt = nil

        merged.sessionConversationIDs = mergeDictionaries(
            canonical.sessionConversationIDs,
            duplicate.sessionConversationIDs
        )
        merged.sessionAgentTypes = mergeDictionaries(
            canonical.sessionAgentTypes,
            duplicate.sessionAgentTypes
        )
        merged.submittedPromptsBySession = mergePromptHistory(
            canonical: canonical.submittedPromptsBySession,
            duplicate: duplicate.submittedPromptsBySession
        )
        merged.customTabNames = mergeDictionaries(
            canonical.customTabNames,
            duplicate.customTabNames
        )
        merged.persistedWebTabs = mergeWebTabs(
            canonical: canonical.persistedWebTabs,
            duplicate: duplicate.persistedWebTabs
        )
        merged.persistedDraftTabs = mergeDraftTabs(
            canonical: canonical.persistedDraftTabs,
            duplicate: duplicate.persistedDraftTabs
        )

        if canonical.isThreadIconManuallySet {
            merged.threadIcon = canonical.threadIcon
            merged.isThreadIconManuallySet = true
        } else if duplicate.isThreadIconManuallySet {
            merged.threadIcon = duplicate.threadIcon
            merged.isThreadIconManuallySet = true
        } else {
            merged.threadIcon = canonical.threadIcon != .other ? canonical.threadIcon : duplicate.threadIcon
            merged.isThreadIconManuallySet = false
        }

        merged.lastSelectedTabIdentifier = resolvedLastSelectedTabIdentifier(
            canonical: canonical,
            duplicate: duplicate,
            merged: merged
        )

        pruneMergedThreadSessionState(&merged)
        deduplicateMergedTerminalTabTitles(&merged)
        return merged
    }

    private func preferredThreadName(primary: String, secondary: String) -> String {
        let normalizedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPrimary.lowercased() == "main" {
            return normalizedPrimary
        }

        let normalizedSecondary = secondary.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedSecondary.lowercased() == "main" {
            return normalizedSecondary
        }

        return preferredNonEmpty(primary: primary, secondary: secondary)
    }

    private func preferredNonEmpty(primary: String, secondary: String) -> String {
        let normalizedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPrimary.isEmpty {
            return primary
        }
        return secondary
    }

    private func preferredOptional(primary: String?, secondary: String?) -> String? {
        if let primary, !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return primary
        }
        if let secondary, !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return secondary
        }
        return primary ?? secondary
    }

    private func appendUnique(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in lhs + rhs where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func mergeDictionaries<Value>(
        _ canonical: [String: Value],
        _ duplicate: [String: Value]
    ) -> [String: Value] {
        var merged = canonical
        for (key, value) in duplicate where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }

    private func mergePromptHistory(
        canonical: [String: [String]],
        duplicate: [String: [String]]
    ) -> [String: [String]] {
        var merged = canonical
        for (sessionName, prompts) in duplicate {
            var existing = merged[sessionName] ?? []
            for prompt in prompts where !existing.contains(prompt) {
                existing.append(prompt)
            }
            merged[sessionName] = existing
        }
        return merged
    }

    private func mergeWebTabs(
        canonical: [PersistedWebTab],
        duplicate: [PersistedWebTab]
    ) -> [PersistedWebTab] {
        var seen = Set<String>()
        var merged: [PersistedWebTab] = []
        for tab in canonical + duplicate where seen.insert(tab.identifier).inserted {
            merged.append(tab)
        }
        return merged
    }

    private func mergeDraftTabs(
        canonical: [PersistedDraftTab],
        duplicate: [PersistedDraftTab]
    ) -> [PersistedDraftTab] {
        var seen = Set<String>()
        var merged: [PersistedDraftTab] = []
        for tab in canonical + duplicate where seen.insert(tab.identifier).inserted {
            merged.append(tab)
        }
        return merged
    }

    private func resolvedLastSelectedTabIdentifier(
        canonical: MagentThread,
        duplicate: MagentThread,
        merged: MagentThread
    ) -> String? {
        let validIdentifiers = Set(merged.tmuxSessionNames)
            .union(merged.persistedWebTabs.map(\.identifier))
            .union(merged.persistedDraftTabs.map(\.identifier))

        if let selected = canonical.lastSelectedTabIdentifier, validIdentifiers.contains(selected) {
            return selected
        }
        if let selected = duplicate.lastSelectedTabIdentifier, validIdentifiers.contains(selected) {
            return selected
        }
        return merged.tmuxSessionNames.first
            ?? merged.persistedWebTabs.first?.identifier
            ?? merged.persistedDraftTabs.first?.identifier
    }

    private func pruneMergedThreadSessionState(_ thread: inout MagentThread) {
        let validTerminalSessions = Set(thread.tmuxSessionNames)
        let validAgentSessions = Set(thread.agentTmuxSessions).intersection(validTerminalSessions)

        thread.agentTmuxSessions = thread.tmuxSessionNames.filter { validAgentSessions.contains($0) }
        thread.pinnedTmuxSessions = thread.pinnedTmuxSessions.filter { validTerminalSessions.contains($0) }
        thread.protectedTmuxSessions = thread.protectedTmuxSessions.intersection(validTerminalSessions)
        thread.unreadCompletionSessions = thread.unreadCompletionSessions.intersection(validTerminalSessions)
        thread.sessionConversationIDs = thread.sessionConversationIDs.filter { validAgentSessions.contains($0.key) }
        thread.sessionAgentTypes = thread.sessionAgentTypes.filter { validAgentSessions.contains($0.key) }
        thread.submittedPromptsBySession = thread.submittedPromptsBySession.filter { validAgentSessions.contains($0.key) }
        thread.customTabNames = thread.customTabNames.filter { validTerminalSessions.contains($0.key) }
    }

    private func deduplicateMergedTerminalTabTitles(_ thread: inout MagentThread) {
        var usedNames = Set<String>()

        for (index, sessionName) in thread.tmuxSessionNames.enumerated() {
            let preferredName = thread.displayName(for: sessionName, at: index)
            let uniqueName = makeUniqueTerminalTabTitle(
                preferredName,
                usedNames: &usedNames
            )

            if uniqueName == MagentThread.defaultDisplayName(at: index) {
                thread.customTabNames.removeValue(forKey: sessionName)
            } else {
                thread.customTabNames[sessionName] = uniqueName
            }
        }
    }

    private func makeUniqueTerminalTabTitle(
        _ baseName: String,
        usedNames: inout Set<String>
    ) -> String {
        let trimmedBaseName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseName = trimmedBaseName.isEmpty ? "Tab" : trimmedBaseName
        let normalizedBaseName = resolvedBaseName.lowercased()

        if usedNames.insert(normalizedBaseName).inserted {
            return resolvedBaseName
        }

        var suffix = 2
        while !usedNames.insert("\(normalizedBaseName)-\(suffix)").inserted {
            suffix += 1
        }
        return "\(resolvedBaseName)-\(suffix)"
    }

    private func presentIncompleteSettingsAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Found threads, but settings are incomplete"
        alert.informativeText = """
        Magent found existing thread data, but settings.json is missing, empty, or no longer \
        covers every project referenced by active threads. Showing onboarding in this state \
        would strand those threads.

        Magent has blocked writes to settings.json for this launch so the existing recovery \
        files are not overwritten. Quit now and restore from a rolling backup or known-good \
        snapshot, or continue without saving settings changes.

        File location: ~/Library/Application Support/Magent
        """
        alert.addButton(withTitle: "Continue Without Saving")
        alert.addButton(withTitle: "Quit Magent")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func ensureWindowIsVisibleOnCurrentScreens(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let currentFrame = window.frame
        if !isCompletelyOffScreen(currentFrame, visibleFrames: visibleFrames) {
            pendingOffScreenRecovery?.cancel()
            pendingOffScreenRecovery = nil
            return
        }

        // Display topology can still be settling right after launch/activation.
        // Re-check after a short delay before moving the window.
        pendingOffScreenRecovery?.cancel()
        let recoveryWorkItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.recoverOffScreenWindowIfNeeded(window)
        }
        pendingOffScreenRecovery = recoveryWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offScreenRecoveryDelay, execute: recoveryWorkItem)
    }

    private func recoverOffScreenWindowIfNeeded(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let currentFrame = window.frame
        guard isCompletelyOffScreen(currentFrame, visibleFrames: visibleFrames) else { return }

        let targetVisibleFrame = preferredVisibleFrame(for: currentFrame, visibleFrames: visibleFrames)
        var adjustedFrame = currentFrame
        adjustedFrame.size.width = min(max(adjustedFrame.size.width, window.minSize.width), targetVisibleFrame.width)
        adjustedFrame.size.height = min(max(adjustedFrame.size.height, window.minSize.height), targetVisibleFrame.height)
        adjustedFrame.origin.x = clamp(
            adjustedFrame.origin.x,
            min: targetVisibleFrame.minX,
            max: targetVisibleFrame.maxX - adjustedFrame.width
        )
        adjustedFrame.origin.y = clamp(
            adjustedFrame.origin.y,
            min: targetVisibleFrame.minY,
            max: targetVisibleFrame.maxY - adjustedFrame.height
        )

        window.setFrame(adjustedFrame, display: true)
    }

    private func isCompletelyOffScreen(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
        !visibleFrames.contains {
            let intersection = frame.intersection($0)
            return !intersection.isNull && intersection.area > 0
        }
    }

    private func preferredVisibleFrame(for frame: NSRect, visibleFrames: [NSRect]) -> NSRect {
        if let containingFrame = visibleFrames.first(where: { $0.contains(frame.center) }) {
            return containingFrame
        }

        let bestIntersection = visibleFrames.max {
            frame.intersection($0).area < frame.intersection($1).area
        }
        if let bestIntersection, frame.intersection(bestIntersection).area > 0 {
            return bestIntersection
        }

        return NSScreen.main?.visibleFrame ?? visibleFrames[0]
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else { return minValue }
        return Swift.max(minValue, Swift.min(value, maxValue))
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
