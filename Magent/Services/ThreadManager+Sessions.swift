import AppKit
import Foundation
import UserNotifications

extension ThreadManager {

    // MARK: - Worktree Sync

    func syncThreadsWithWorktrees(for project: Project) async {
        let basePath = project.resolvedWorktreesBasePath()
        let fm = FileManager.default

        // Discover directories in the worktrees base path
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else { return }

        // Build a map of symlink target → latest symlink name.
        // Rename creates symlinks from the new name pointing to the original worktree directory,
        // so the latest symlink name represents the most recent thread name.
        var latestSymlinkName: [String: (name: String, date: Date)] = [:]
        for entry in contents {
            let entryPath = (basePath as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: entryPath),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: entryPath) else { continue }
            let resolved = dest.hasPrefix("/") ? dest : (basePath as NSString).appendingPathComponent(dest)
            let created = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date ?? .distantPast
            if let existing = latestSymlinkName[resolved], existing.date > created { continue }
            latestSymlinkName[resolved] = (name: entry, date: created)
        }

        var changed = false
        let existingPaths = Set(threads.filter { $0.projectId == project.id }.map(\.worktreePath))

        for dirName in contents {
            let fullPath = (basePath as NSString).appendingPathComponent(dirName)

            // Skip symlinks — these are rename aliases, not real worktrees
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                continue
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check if this is a git worktree (has a .git file, not directory)
            let gitPath = (fullPath as NSString).appendingPathComponent(".git")
            var gitIsDir: ObjCBool = false
            let gitExists = fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir)
            guard gitExists && !gitIsDir.boolValue else { continue }

            // Skip if we already have a thread for this path
            guard !existingPaths.contains(fullPath) else { continue }

            // If a symlink points here, the worktree was renamed — use the symlink name
            let threadName = latestSymlinkName[fullPath]?.name ?? dirName
            let branchName = threadName

            let settings = persistence.loadSettings()
            let thread = MagentThread(
                projectId: project.id,
                name: threadName,
                worktreePath: fullPath,
                branchName: branchName,
                sectionId: settings.defaultSection?.id
            )
            threads.append(thread)
            changed = true
        }

        // Archive threads whose worktree directories no longer exist on disk
        // (skip main threads — those point at the repo itself)
        for i in threads.indices {
            guard threads[i].projectId == project.id,
                  !threads[i].isMain,
                  !threads[i].isArchived else { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: threads[i].worktreePath, isDirectory: &isDir) && isDir.boolValue
            if !exists {
                threads[i].isArchived = true
                changed = true
            }
        }

        if changed {
            // Remove archived from active list
            threads = threads.filter { !$0.isArchived }

            // Save all (including newly archived) to persistence
            var allThreads = persistence.loadThreads()
            // Merge: update archived flags, add new threads
            for thread in threads where !allThreads.contains(where: { $0.id == thread.id }) {
                allThreads.append(thread)
            }
            // Update archived flags
            for i in allThreads.indices {
                if !threads.contains(where: { $0.id == allThreads[i].id }) && allThreads[i].projectId == project.id && !allThreads[i].isMain {
                    allThreads[i].isArchived = true
                }
            }
            try? persistence.saveThreads(allThreads)

            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }


    // MARK: - Session Recreation

    /// Kills live tmux sessions prefixed with "magent" that are not referenced by any non-archived thread/tab.
    @discardableResult
    func cleanupStaleMagentSessions() async -> [String] {
        let referencedSessions = referencedMagentSessionNames()

        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return []
        }

        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("magent") && !referencedSessions.contains(sessionName)
        }

        guard !staleSessions.isEmpty else { return [] }

        for sessionName in staleSessions {
            try? await tmux.killSession(name: sessionName)
        }

        return staleSessions
    }

    private func referencedMagentSessionNames() -> Set<String> {
        var names = Set<String>()

        // Include both in-memory and persisted threads so cleanup is safe during transitional states.
        let allNonArchivedThreads = threads.filter { !$0.isArchived } + persistence.loadThreads().filter { !$0.isArchived }
        for thread in allNonArchivedThreads {
            for sessionName in thread.tmuxSessionNames where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            for sessionName in thread.agentTmuxSessions where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            for sessionName in thread.pinnedTmuxSessions where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            if let selectedSession = thread.lastSelectedTmuxSessionName, selectedSession.hasPrefix("magent") {
                names.insert(selectedSession)
            }
        }

        return names
    }

    /// Ensures a tmux session exists and belongs to the expected thread context.
    /// Recreates dead or mismatched sessions.
    /// Returns true if the session was recreated.
    func recreateSessionIfNeeded(
        sessionName: String,
        thread: MagentThread
    ) async -> Bool {
        // Skip if already being recreated
        guard !sessionsBeingRecreated.contains(sessionName) else { return false }

        sessionsBeingRecreated.insert(sessionName)
        defer { sessionsBeingRecreated.remove(sessionName) }

        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectPath = project?.repoPath ?? thread.worktreePath
        let projectName = project?.name ?? "project"
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)

        if await tmux.hasSession(name: sessionName) {
            let sessionMatches = await sessionMatchesThreadContext(
                sessionName: sessionName,
                thread: thread,
                projectPath: projectPath,
                isAgentSession: isAgentSession
            )
            if sessionMatches {
                await setSessionEnvironment(
                    sessionName: sessionName,
                    thread: thread,
                    projectPath: projectPath,
                    projectName: projectName
                )
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: thread.worktreePath)
                enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: thread.worktreePath)
                if isAgentSession {
                    await tmux.setupBellPipe(for: sessionName)
                }
                return false
            }

            // Session name exists but points at another thread/project context.
            try? await tmux.killSession(name: sessionName)
        }

        let startCmd: String
        let sessionAgentType = thread.selectedAgentType ?? effectiveAgentType(for: thread.projectId)
        let envExports: String
        if thread.isMain {
            envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        } else {
            envExports = "export MAGENT_WORKTREE_PATH=\(thread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(thread.name) && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        }
        if isAgentSession {
            startCmd = agentStartCommand(
                settings: settings,
                agentType: sessionAgentType,
                envExports: envExports,
                workingDirectory: thread.worktreePath
            )
        } else {
            startCmd = "\(envExports) && cd \(thread.worktreePath) && exec zsh -l"
        }

        try? await tmux.createSession(
            name: sessionName,
            workingDirectory: thread.worktreePath,
            command: startCmd
        )

        await setSessionEnvironment(
            sessionName: sessionName,
            thread: thread,
            projectPath: projectPath,
            projectName: projectName
        )
        await tmux.updateWorkingDirectory(sessionName: sessionName, to: thread.worktreePath)
        enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: thread.worktreePath)

        if isAgentSession {
            await tmux.setupBellPipe(for: sessionName)
        }

        // Run normal injection (terminal command + agent context)
        let injection = effectiveInjection(for: thread.projectId)
        injectAfterStart(
            sessionName: sessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentSession ? injection.agentContext : ""
        )

        return true
    }

    private func setSessionEnvironment(
        sessionName: String,
        thread: MagentThread,
        projectPath: String,
        projectName: String
    ) async {
        if thread.isMain {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_WORKTREE_NAME", value: "main")
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_PROJECT_NAME", value: projectName)
        } else {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_WORKTREE_PATH", value: thread.worktreePath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_WORKTREE_NAME", value: thread.name)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_PROJECT_NAME", value: projectName)
        }
        try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
    }

    private func sessionMatchesThreadContext(
        sessionName: String,
        thread: MagentThread,
        projectPath: String,
        isAgentSession: Bool
    ) async -> Bool {
        let expectedPath = thread.isMain ? projectPath : thread.worktreePath

        if let paneInfo = await tmux.activePaneInfo(sessionName: sessionName),
           !path(paneInfo.path, isWithin: expectedPath) {
            if !isAgentSession && isShellCommand(paneInfo.command) {
                // Existing terminal shell drifted due startup config (e.g. .zshrc cd).
                // Keep the session and correct cwd in-place.
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: expectedPath)
                enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: expectedPath)
                return true
            }
            // Agent sessions or non-shell commands in the wrong directory should be recreated.
            return false
        }

        if thread.isMain {
            if let envProject = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_PROJECT_PATH"),
               !envProject.isEmpty {
                return envProject == projectPath
            }
            if let sessionPath = await tmux.sessionPath(sessionName: sessionName) {
                return path(sessionPath, isWithin: projectPath)
            }
            return true
        }

        if let envWorktree = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_WORKTREE_PATH"),
           !envWorktree.isEmpty {
            guard envWorktree == thread.worktreePath else { return false }
            if let envProject = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_PROJECT_PATH"),
               !envProject.isEmpty {
                return envProject == projectPath
            }
            return true
        }

        if let sessionPath = await tmux.sessionPath(sessionName: sessionName) {
            return path(sessionPath, isWithin: thread.worktreePath)
        }
        return true
    }

    private func isShellCommand(_ command: String) -> Bool {
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh"]
        return shells.contains(command)
    }

    private func path(_ path: String, isWithin root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    /// Some shell startup configs can change cwd after the session starts.
    /// Re-apply working directory shortly after startup to keep tabs anchored to the thread worktree.
    /// Checks the pane's actual cwd and stops early once it's within the expected path.
    func enforceWorkingDirectoryAfterStartup(sessionName: String, path: String) {
        Task {
            for delayNs: UInt64 in [300_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000] {
                try? await Task.sleep(nanoseconds: delayNs)
                if let info = await tmux.activePaneInfo(sessionName: sessionName),
                   self.path(info.path, isWithin: path) {
                    break
                }
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: path)
            }
        }
    }


    // MARK: - Pending CWD Enforcement

    struct PendingCwdEnforcement {
        let path: String
        let expiresAt: Date
        var enforcedPaneIds: Set<String>
    }

    /// Checks pending cwd enforcements registered after thread rename.
    /// For each pending session, sends `cd` to any pane that has returned to a shell
    /// since the last check. Removes the entry once all panes are enforced or the deadline passes.
    private func checkPendingCwdEnforcements() async {
        guard !pendingCwdEnforcements.isEmpty else { return }

        let now = Date()
        var resolved = [String]()

        for (sessionName, var enforcement) in pendingCwdEnforcements {
            if now >= enforcement.expiresAt {
                resolved.append(sessionName)
                continue
            }

            let (newlyEnforced, hasUnenforced) = await tmux.enforceWorkingDirectoryOnNewPanes(
                sessionName: sessionName,
                path: enforcement.path,
                alreadyEnforced: enforcement.enforcedPaneIds
            )

            enforcement.enforcedPaneIds.formUnion(newlyEnforced)
            pendingCwdEnforcements[sessionName] = enforcement

            if !hasUnenforced {
                resolved.append(sessionName)
            }
        }

        for sessionName in resolved {
            pendingCwdEnforcements.removeValue(forKey: sessionName)
        }
    }


    // MARK: - Session Monitor

    func startSessionMonitor() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startSessionMonitor()
            }
            return
        }
        guard sessionMonitorTimer == nil else { return }
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.runSessionMonitorTick()
        }
        // Fire once immediately so we don't wait 3 seconds for the first sync.
        runSessionMonitorTick()
    }

    func stopSessionMonitor() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
    }

    private func runSessionMonitorTick() {
        Task {
            await self.checkForMissingWorktrees()
            await self.checkForDeadSessions()
            await self.checkForAgentCompletions()
            await self.checkForWaitingForInput()
            await self.syncBusySessionsFromProcessState()
            await self.ensureBellPipes()
            await self.checkPendingCwdEnforcements()
            await self.checkTmuxZombieHealth()

            // Refresh dirty states every 10th tick (~30 seconds)
            dirtyCheckTickCounter += 1
            if dirtyCheckTickCounter >= 10 {
                dirtyCheckTickCounter = 0
                await refreshDirtyStates()
            }
        }
    }

    private func checkForDeadSessions() async {
        let liveSessions: Set<String>
        do {
            liveSessions = Set(try await tmux.listSessions())
        } catch {
            // tmux server not running — all sessions are dead
            liveSessions = []
        }

        for thread in threads {
            guard !thread.isArchived else { continue }

            let deadSessions = thread.tmuxSessionNames.filter { !liveSessions.contains($0) }
            guard !deadSessions.isEmpty else { continue }

            for sessionName in deadSessions {
                _ = await recreateSessionIfNeeded(
                    sessionName: sessionName,
                    thread: thread
                )
            }

            // Notify UI so terminal views can be replaced
            NotificationCenter.default.post(
                name: .magentDeadSessionsDetected,
                object: self,
                userInfo: [
                    "deadSessions": deadSessions,
                    "threadId": thread.id
                ]
            )
        }
    }

    private func checkForAgentCompletions() async {
        let sessions = await tmux.consumeAgentCompletionSessions()
        guard !sessions.isEmpty else { return }

        let now = Date()
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        let orderedUniqueSessions = sessions.reduce(into: [String]()) { result, session in
            if !result.contains(session) {
                result.append(session)
            }
        }

        var changed = false
        var changedThreadIds = Set<UUID>()

        for session in orderedUniqueSessions {
            if let previous = recentBellBySession[session], now.timeIntervalSince(previous) < 1.0 {
                continue
            }
            recentBellBySession[session] = now

            guard let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) else {
                continue
            }

            threads[index].lastAgentCompletionAt = now
            threads[index].busySessions.remove(session)
            threads[index].waitingForInputSessions.remove(session)
            notifiedWaitingSessions.remove(session)

            let isActiveThread = threads[index].id == activeThreadId
            let isActiveTab = isActiveThread && threads[index].lastSelectedTmuxSessionName == session
            if !isActiveTab {
                threads[index].unreadCompletionSessions.insert(session)
            }
            changed = true
            changedThreadIds.insert(threads[index].id)

            let projectName = settings.projects.first(where: { $0.id == threads[index].projectId })?.name ?? "Project"
            sendAgentCompletionNotification(for: threads[index], projectName: projectName, playSound: playSound)
        }

        guard changed else { return }
        try? persistence.saveThreads(threads)

        // Agent completed work — refresh dirty states for affected threads
        await refreshDirtyStates()

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            for threadId in changedThreadIds {
                if let thread = threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChangedNotification(for: thread)
                }
            }
            for session in orderedUniqueSessions {
                if let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) {
                    NotificationCenter.default.post(
                        name: .magentAgentCompletionDetected,
                        object: self,
                        userInfo: [
                            "threadId": threads[index].id,
                            "unreadSessions": threads[index].unreadCompletionSessions
                        ]
                    )
                }
            }
        }
    }

    private func sendAgentCompletionNotification(for thread: MagentThread, projectName: String, playSound: Bool) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Finished"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString]

            let request = UNNotificationRequest(
                identifier: "magent-agent-finished-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Play sound directly via NSSound as a fallback — UNNotification sound
        // can be throttled by macOS when many notifications are delivered.
        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Syncs `busySessions` with actual tmux pane state by checking `pane_current_command`.
    /// If the foreground process is a non-shell command, the session is busy.
    /// If it's the login shell for this app session, the agent has exited and the session is idle.
    /// This intentionally avoids treating every shell binary as idle because custom agent wrappers
    /// can run under `bash`/`sh` even while agent work is still in progress.
    func syncBusySessionsFromProcessState() async {
        // Collect all agent sessions across non-archived threads
        var allAgentSessions = Set<String>()
        for thread in threads where !thread.isArchived {
            allAgentSessions.formUnion(thread.agentTmuxSessions)
        }
        guard !allAgentSessions.isEmpty else { return }

        let paneStates = await tmux.activePaneStates(forSessions: allAgentSessions)
        guard !paneStates.isEmpty else { return }

        var changed = false
        var changedThreadIds = Set<UUID>()
        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            for session in threads[i].agentTmuxSessions {
                guard let paneState = paneStates[session] else { continue }
                let command = paneState.command
                let isShell = Self.idleShellCommands.contains(command)
                let titleIndicatesBusy = paneTitleIndicatesBusy(paneState.title)
                if isShell {
                    if titleIndicatesBusy && !threads[i].waitingForInputSessions.contains(session) {
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            changedThreadIds.insert(threads[i].id)
                        }
                        continue
                    }
                    // Agent not running — clear busy and waiting if set
                    if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                        changedThreadIds.insert(threads[i].id)
                    }
                    if threads[i].waitingForInputSessions.contains(session) {
                        threads[i].waitingForInputSessions.remove(session)
                        notifiedWaitingSessions.remove(session)
                        changed = true
                        changedThreadIds.insert(threads[i].id)
                    }
                } else {
                    // Non-shell process running — mark busy only if not in waiting state.
                    // Skip if a completion bell was recently received for this session;
                    // the bell fires just before the process exits, so pane_current_command
                    // can still show the agent binary for a brief window after completion.
                    let recentlyCompleted: Bool = {
                        guard let bellDate = recentBellBySession[session] else { return false }
                        return Date().timeIntervalSince(bellDate) < 5.0
                    }()
                    if !recentlyCompleted && !threads[i].waitingForInputSessions.contains(session) {
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            changedThreadIds.insert(threads[i].id)
                        }
                    }
                }
            }
        }

        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in changedThreadIds {
                    if let thread = threads.first(where: { $0.id == threadId }) {
                        postBusySessionsChangedNotification(for: thread)
                    }
                }
            }
        }
    }

    private func paneTitleIndicatesBusy(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scalar = trimmed.unicodeScalars.first else { return false }
        let v = scalar.value
        // Braille spinner (⠋⠙⠹…) used by Claude Code / Codex while processing.
        if (0x2800...0x28FF).contains(v) { return true }
        // ✳ (U+2733 eight-spoked asterisk) — alternate busy prefix used by Claude Code.
        if v == 0x2733 { return true }
        return false
    }


    // MARK: - Waiting-for-Input Detection

    private func checkForWaitingForInput() async {
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        var changed = false
        var changedThreadIds = Set<UUID>()
        var notifyPairs: [(threadIndex: Int, sessionName: String)] = []

        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            for session in threads[i].agentTmuxSessions {
                let wasWaiting = threads[i].waitingForInputSessions.contains(session)
                let isBusy = threads[i].busySessions.contains(session)

                // Only check busy sessions (or already-waiting sessions to detect resolution)
                guard isBusy || wasWaiting else { continue }

                guard let paneContent = await tmux.capturePane(sessionName: session) else { continue }
                let isWaiting = matchesWaitingForInputPattern(paneContent)

                if isWaiting && !wasWaiting {
                    // Transition: busy → waiting
                    threads[i].busySessions.remove(session)
                    threads[i].waitingForInputSessions.insert(session)
                    changed = true
                    changedThreadIds.insert(threads[i].id)

                    let isActiveThread = threads[i].id == activeThreadId
                    let isActiveTab = isActiveThread && threads[i].lastSelectedTmuxSessionName == session
                    if !isActiveTab && !notifiedWaitingSessions.contains(session) {
                        notifiedWaitingSessions.insert(session)
                        notifyPairs.append((i, session))
                    }
                } else if !isWaiting && wasWaiting {
                    // Transition: waiting → cleared (user provided input)
                    threads[i].waitingForInputSessions.remove(session)
                    notifiedWaitingSessions.remove(session)
                    changed = true
                    changedThreadIds.insert(threads[i].id)
                    // syncBusy will re-mark as busy on the same tick
                }
            }
        }

        guard changed else { return }
        for (threadIndex, _) in notifyPairs {
            let projectName = settings.projects.first(where: { $0.id == threads[threadIndex].projectId })?.name ?? "Project"
            sendAgentWaitingNotification(for: threads[threadIndex], projectName: projectName, playSound: playSound)
        }

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            for threadId in changedThreadIds {
                if let thread = threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChangedNotification(for: thread)
                }
            }
            for i in threads.indices where !threads[i].isArchived && threads[i].hasWaitingForInput {
                NotificationCenter.default.post(
                    name: .magentAgentWaitingForInput,
                    object: self,
                    userInfo: [
                        "threadId": threads[i].id,
                        "waitingSessions": threads[i].waitingForInputSessions
                    ]
                )
            }
        }
    }

    private func matchesWaitingForInputPattern(_ text: String) -> Bool {
        // Trim trailing whitespace/newlines and look at the last non-empty lines
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmedLines = lines.suffix(20).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return false }
        let lastChunk = trimmedLines.suffix(15).joined(separator: "\n")

        // Claude Code plan mode
        if lastChunk.contains("Would you like to proceed?") { return true }

        // Claude Code permission prompts
        if lastChunk.contains("Do you want to") && (lastChunk.contains("Yes") || lastChunk.contains("No")) { return true }

        // Codex approval prompts
        if lastChunk.contains("approve") && lastChunk.contains("deny") { return true }

        // Claude Code AskUserQuestion / interactive prompt: ❯ selector at line start
        // Only match when ❯ is at the start of a line (interactive selector indicator),
        // not just anywhere in terminal (e.g. Claude Code's input prompt character).
        let lastFew = trimmedLines.suffix(6)
        let hasSelectorAtLineStart = lastFew.contains { $0.hasPrefix("\u{276F}") }
        if hasSelectorAtLineStart && lastFew.contains(where: { $0.range(of: #"^\u{276F}?\s*\d+\."#, options: .regularExpression) != nil }) { return true }

        // Claude Code ExitPlanMode / plan approval prompt
        if lastChunk.contains("Do you want me to go ahead") { return true }

        return false
    }

    @MainActor
    func postBusySessionsChangedNotification(for thread: MagentThread) {
        NotificationCenter.default.post(
            name: .magentAgentBusySessionsChanged,
            object: self,
            userInfo: [
                "threadId": thread.id,
                "busySessions": thread.busySessions
            ]
        )
    }

    private func sendAgentWaitingNotification(for thread: MagentThread, projectName: String, playSound: Bool) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Needs Input"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString]

            let request = UNNotificationRequest(
                identifier: "magent-agent-waiting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func checkForMissingWorktrees() async {
        let candidates = threads.filter { !$0.isMain && !$0.isArchived }
        var pruneRepos = Set<String>()
        var archivedAny = false

        for thread in candidates {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: thread.worktreePath, isDirectory: &isDir)
            guard !exists || !isDir.boolValue else { continue }

            let settings = persistence.loadSettings()
            if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
                pruneRepos.insert(project.repoPath)
            }
            try? await archiveThread(thread)
            archivedAny = true
        }

        if archivedAny {
            let settings = persistence.loadSettings()
            if settings.playSoundForAgentCompletion {
                let soundName = settings.agentCompletionSoundName
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                }
            }
        }

        for repoPath in pruneRepos {
            await git.pruneWorktrees(repoPath: repoPath)
        }
    }

}
