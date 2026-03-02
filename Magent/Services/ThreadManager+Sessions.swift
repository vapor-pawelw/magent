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
            Self.isMagentSession(sessionName) && !referencedSessions.contains(sessionName)
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
            for sessionName in thread.tmuxSessionNames where Self.isMagentSession(sessionName) {
                names.insert(sessionName)
            }
            for sessionName in thread.agentTmuxSessions where Self.isMagentSession(sessionName) {
                names.insert(sessionName)
            }
            for sessionName in thread.pinnedTmuxSessions where Self.isMagentSession(sessionName) {
                names.insert(sessionName)
            }
            if let selectedSession = thread.lastSelectedTmuxSessionName, Self.isMagentSession(selectedSession) {
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
        let sessionAgentType = agentType(for: thread, sessionName: sessionName)
            ?? thread.selectedAgentType
            ?? effectiveAgentType(for: thread.projectId)
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
            agentContext: isAgentSession ? injection.agentContext : "",
            agentType: sessionAgentType
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
        if let agent = agentType(for: thread, sessionName: sessionName) {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_AGENT_TYPE", value: agent.rawValue)
        } else {
            // Ensure terminal sessions don't inherit stale agent-type markers.
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_AGENT_TYPE", value: "")
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
            await self.checkForRateLimitedSessions()
            await self.syncBusySessionsFromProcessState()
            await self.ensureBellPipes()
            await self.checkPendingCwdEnforcements()
            await self.checkTmuxZombieHealth()

            // Refresh dirty and delivered states every 10th tick (~30 seconds)
            dirtyCheckTickCounter += 1
            if dirtyCheckTickCounter >= 10 {
                dirtyCheckTickCounter = 0
                await refreshDirtyStates()
                await refreshDeliveredStates()
                await refreshBranchStates()
            }

            // Jira sync every 20th tick (~60 seconds)
            _jiraSyncTickCounter += 1
            if _jiraSyncTickCounter >= 20 {
                _jiraSyncTickCounter = 0
                await runJiraSyncTick()
            }

            // PR sync every 20th tick (~60 seconds)
            _prSyncTickCounter += 1
            if _prSyncTickCounter >= 20 {
                _prSyncTickCounter = 0
                await runPRSyncTick()
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
            if settings.autoReorderThreadsOnAgentCompletion {
                bumpThreadToTopOfSection(threads[index].id)
            }
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
            sendAgentCompletionNotification(for: threads[index], projectName: projectName, playSound: playSound, sessionName: session)
        }

        guard changed else { return }
        try? persistence.saveThreads(threads)

        // Agent completed work — refresh dirty and delivered states for affected threads
        await refreshDirtyStates()
        for threadId in changedThreadIds {
            await refreshDeliveredState(for: threadId)
        }

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

    private func sendAgentCompletionNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Finished"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

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

        // Collect pane PIDs for all shell sessions (both title-busy and non-busy).
        // Child-process checks detect agents inside shell wrappers AND verify
        // that a stale spinner title isn't a false busy signal.
        var shellPidsToCheck = Set<pid_t>()
        for thread in threads where !thread.isArchived {
            for session in thread.agentTmuxSessions {
                guard let paneState = paneStates[session] else { continue }
                let isShell = Self.idleShellCommands.contains(paneState.command)
                if isShell && paneState.pid > 0 {
                    shellPidsToCheck.insert(paneState.pid)
                }
            }
        }
        let childrenByPid = await tmux.childPids(forParents: shellPidsToCheck)

        var changed = false
        var busyChangedThreadIds = Set<UUID>()
        var rateLimitChangedThreadIds = Set<UUID>()
        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            for session in threads[i].agentTmuxSessions {
                guard let paneState = paneStates[session] else { continue }
                let sessionAgent = agentType(for: threads[i], sessionName: session)
                    ?? threads[i].selectedAgentType
                    ?? effectiveAgentType(for: threads[i].projectId)

                // Codex busy semantics: only "esc to interrupt" means busy.
                if sessionAgent == .codex {
                    let hasInterruptBusySignal = await paneShowsEscToInterrupt(sessionName: session)
                    if hasInterruptBusySignal && !threads[i].waitingForInputSessions.contains(session) {
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        let recoveredIds = clearRateLimitAfterRecovery(threadIndex: i, sessionName: session)
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                    } else if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    continue
                }

                let command = paneState.command
                let isShell = Self.idleShellCommands.contains(command)
                let titleIndicatesBusy = paneTitleIndicatesBusy(paneState.title)
                if isShell {
                    if titleIndicatesBusy && !threads[i].waitingForInputSessions.contains(session) {
                        // Both ✳ and braille spinner characters can persist in the pane
                        // title after the agent finishes. Always verify via pane content
                        // that the agent isn't just sitting at an empty prompt.
                        if let content = await tmux.capturePane(sessionName: session),
                           isAgentIdleAtPrompt(content) {
                            // Agent is idle — clear any stale busy state
                            if threads[i].busySessions.contains(session) {
                                threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                            continue
                        }
                        // Pane content didn't show a ❯ prompt — but if the agent has
                        // fully exited (shell has no child processes), the spinner title
                        // is stale. This handles the case where the agent exits and we
                        // land at a plain shell prompt (%, $) that isAgentIdleAtPrompt
                        // doesn't recognize.
                        let hasChildren = paneState.pid > 0
                            && !(childrenByPid[paneState.pid]?.isEmpty ?? true)
                        if !hasChildren {
                            if threads[i].busySessions.contains(session) {
                                threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                            continue
                        }
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        let recoveredIds = clearRateLimitAfterRecovery(threadIndex: i, sessionName: session)
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                        continue
                    }
                    // Title doesn't indicate busy — check if the shell has child processes
                    // (agent running inside the shell wrapper, e.g. zsh -c 'claude ...')
                    if paneState.pid > 0, !(childrenByPid[paneState.pid]?.isEmpty ?? true) {
                        // Shell has children — but the agent could be idle at its prompt
                        // (e.g. Claude Code waiting for user input while still running as
                        // a child process of the wrapper shell).
                        if let content = await tmux.capturePane(sessionName: session),
                           isAgentIdleAtPrompt(content) {
                            if threads[i].busySessions.contains(session) {
                                threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                        } else {
                            if !threads[i].busySessions.contains(session) {
                                threads[i].busySessions.insert(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                            let recoveredIds = clearRateLimitAfterRecovery(threadIndex: i, sessionName: session)
                            if !recoveredIds.isEmpty {
                                rateLimitChangedThreadIds.formUnion(recoveredIds)
                                changed = true
                            }
                        }
                        continue
                    }
                    // Agent not running — clear busy and waiting if set
                    if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    if threads[i].waitingForInputSessions.contains(session) {
                        threads[i].waitingForInputSessions.remove(session)
                        notifiedWaitingSessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                } else {
                    // Non-shell process running (e.g. node, claude, or a version string
                    // like "2.1.63" that Claude Code sets as its process title).
                    // Skip if a completion bell was recently received for this session;
                    // the bell fires just before the process exits, so pane_current_command
                    // can still show the agent binary for a brief window after completion.
                    let recentlyCompleted: Bool = {
                        guard let bellDate = recentBellBySession[session] else { return false }
                        return Date().timeIntervalSince(bellDate) < 5.0
                    }()
                    if !recentlyCompleted && !threads[i].waitingForInputSessions.contains(session) {
                        // The agent process can still be the foreground command even when
                        // idle at its prompt (e.g. Claude Code showing ❯). Verify via
                        // pane content that the agent is actually working.
                        if let content = await tmux.capturePane(sessionName: session),
                           isAgentIdleAtPrompt(content) {
                            if threads[i].busySessions.contains(session) {
                                threads[i].busySessions.remove(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                        } else {
                            if !threads[i].busySessions.contains(session) {
                                threads[i].busySessions.insert(session)
                                changed = true
                                busyChangedThreadIds.insert(threads[i].id)
                            }
                            let recoveredIds = clearRateLimitAfterRecovery(threadIndex: i, sessionName: session)
                            if !recoveredIds.isEmpty {
                                rateLimitChangedThreadIds.formUnion(recoveredIds)
                                changed = true
                            }
                        }
                    }
                }
            }
        }

        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in busyChangedThreadIds {
                    if let thread = threads.first(where: { $0.id == threadId }) {
                        postBusySessionsChangedNotification(for: thread)
                    }
                }
                for threadId in rateLimitChangedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: self,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
            await publishRateLimitSummaryIfNeeded()
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

    /// Checks whether the agent appears to be idle at its input prompt by looking
    /// at the pane content. The definitive busy signal is the "esc to interrupt"
    /// status bar text that Claude Code shows while processing. If that text is
    /// present, the agent is busy. If a ❯ prompt is visible without
    /// "esc to interrupt", the agent is idle (even if the user has typed text
    /// at the prompt but hasn't submitted it yet).
    private func isAgentIdleAtPrompt(_ paneContent: String) -> Bool {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let nonEmpty = lines.suffix(15)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // "esc to interrupt" is shown in the status bar while Claude processes
        // → definitely busy, regardless of prompt visibility.
        // In bypass mode the status bar appends "· esc to interrupt" only while
        // the agent is actively processing; when idle it just shows the bypass
        // text without it. So "esc to interrupt" is a reliable busy signal
        // regardless of bypass mode.
        let hasBusyIndicator = nonEmpty.contains(where: {
            $0.localizedCaseInsensitiveContains("esc to interrupt")
        })
        if hasBusyIndicator {
            return false
        }

        // ❯ prompt visible without the busy status bar → agent is idle
        let hasPrompt = nonEmpty.contains(where: { $0.hasPrefix("\u{276F}") })
        return hasPrompt
    }

    private func paneShowsEscToInterrupt(sessionName: String) async -> Bool {
        guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 40) else {
            return false
        }

        return paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .contains { line in
                String(line).localizedCaseInsensitiveContains("esc to interrupt")
            }
    }


    // MARK: - Rate-Limit Detection

    private struct RateLimitDetection {
        var info: AgentRateLimitInfo
        var fingerprint: String
        var hasRelativeReset: Bool
        var hasExplicitDateAnchor: Bool
    }

    /// Called when the rate-limit detection setting is toggled in Settings.
    /// Immediately clears state (if disabled) or runs a full scan (if enabled).
    func applyRateLimitDetectionSettingChange() {
        Task { await checkForRateLimitedSessions() }
    }

    private func checkForRateLimitedSessions() async {
        let detectionEnabled = persistence.loadSettings().enableRateLimitDetection
        if !detectionEnabled {
            // Clear any existing rate-limit state so sidebar indicators disappear,
            // but continue scanning panes below to keep the fingerprint cache warm.
            var changed = false
            for i in threads.indices where !threads[i].rateLimitedSessions.isEmpty {
                threads[i].rateLimitedSessions.removeAll()
                changed = true
            }
            let hadGlobal = !globalAgentRateLimits.isEmpty
            globalAgentRateLimits.removeAll()
            if changed || hadGlobal {
                lastPublishedRateLimitSummary = nil
                await MainActor.run {
                    delegate?.threadManager(self, didUpdateThreads: threads)
                    NotificationCenter.default.post(name: .magentAgentRateLimitChanged, object: nil)
                    NotificationCenter.default.post(name: .magentGlobalRateLimitSummaryChanged, object: nil)
                }
            }
        }
        let now = Date()
        var changedThreadIds = Set<UUID>()
        var didChangeGlobalCache = pruneExpiredGlobalRateLimits(now: now, changedThreadIds: &changedThreadIds)

        // Lazy-load the persisted fingerprint cache on first use.
        if !rateLimitCacheLoaded {
            rateLimitFingerprintCache = persistence.loadRateLimitCache()
            rateLimitCacheLoaded = true
        }

        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            let thread = threads[i]
            var updatedRateLimits = thread.rateLimitedSessions
            let validSessions = Set(thread.tmuxSessionNames)

            for sessionName in thread.tmuxSessionNames {
                guard thread.agentTmuxSessions.contains(sessionName) else {
                    if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(thread.id)
                    }
                    continue
                }

                guard let sessionAgent = agentType(for: thread, sessionName: sessionName),
                      isRateLimitTrackable(agent: sessionAgent) else {
                    if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(thread.id)
                    }
                    continue
                }

                if detectionEnabled {
                    let cachedGlobalInfo = activeGlobalRateLimit(for: sessionAgent, now: now)
                    if let cachedGlobalInfo, updatedRateLimits[sessionName] != cachedGlobalInfo {
                        updatedRateLimits[sessionName] = cachedGlobalInfo
                        changedThreadIds.insert(thread.id)
                    }
                }

                guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 120),
                      let detection = rateLimitDetection(from: paneContent, now: now) else {
                    if detectionEnabled, updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(thread.id)
                    }
                    continue
                }

                // Check persisted fingerprint cache: if we've seen this exact text before,
                // use the concrete resetAt from first detection instead of re-parsing.
                if let cachedResetAt = rateLimitFingerprintCache[detection.fingerprint] {
                    if cachedResetAt <= now {
                        // Already expired — skip detection entirely.
                        if detectionEnabled, updatedRateLimits.removeValue(forKey: sessionName) != nil {
                            changedThreadIds.insert(thread.id)
                        }
                        continue
                    }
                    // Fingerprint already cached with valid time — update visible state only.
                    guard detectionEnabled else { continue }
                    var info = detection.info
                    info.resetAt = cachedResetAt

                    // Preserve original detectedAt from in-memory state if available.
                    if let existing = updatedRateLimits[sessionName] {
                        info.detectedAt = existing.detectedAt
                    }

                    if updatedRateLimits[sessionName] != info {
                        updatedRateLimits[sessionName] = info
                        changedThreadIds.insert(thread.id)
                    }
                    if globalAgentRateLimits[sessionAgent] != info {
                        globalAgentRateLimits[sessionAgent] = info
                        didChangeGlobalCache = true
                    }
                    continue
                }

                // First time seeing this fingerprint — anchor the resetAt as a concrete date.
                // Always cache, even when detection is disabled, so re-enabling works correctly.
                rateLimitFingerprintCache[detection.fingerprint] = detection.info.resetAt
                rateLimitCacheDirty = true

                guard detectionEnabled else { continue }

                let info = detection.info

                // Discard if reset time is already in the past (already cached above).
                if info.resetAt <= now {
                    if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(thread.id)
                    }
                    continue
                }

                if updatedRateLimits[sessionName] != info {
                    updatedRateLimits[sessionName] = info
                    changedThreadIds.insert(thread.id)
                }
                if globalAgentRateLimits[sessionAgent] != info {
                    globalAgentRateLimits[sessionAgent] = info
                    didChangeGlobalCache = true
                }
            }

            for sessionName in Array(updatedRateLimits.keys) where !validSessions.contains(sessionName) {
                updatedRateLimits.removeValue(forKey: sessionName)
                changedThreadIds.insert(thread.id)
            }

            if updatedRateLimits != thread.rateLimitedSessions {
                threads[i].rateLimitedSessions = updatedRateLimits
                changedThreadIds.insert(thread.id)
            }
        }

        if !changedThreadIds.isEmpty {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in changedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: self,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
        }

        if didChangeGlobalCache {
            lastPublishedRateLimitSummary = nil
        }
        await publishRateLimitSummaryIfNeeded()

        // Persist fingerprint cache if it changed.
        if rateLimitCacheDirty {
            rateLimitCacheDirty = false
            persistence.saveRateLimitCache(rateLimitFingerprintCache)
        }
    }

    private func isRateLimitTrackable(agent: AgentType) -> Bool {
        return agent == .claude || agent == .codex
    }

    private func activeGlobalRateLimit(for agent: AgentType, now: Date) -> AgentRateLimitInfo? {
        guard let info = globalAgentRateLimits[agent] else { return nil }
        guard info.resetAt > now else { return nil }
        return info
    }

    @discardableResult
    private func pruneExpiredGlobalRateLimits(now: Date, changedThreadIds: inout Set<UUID>) -> Bool {
        let expiredAgents = globalAgentRateLimits.compactMap { entry -> AgentType? in
            guard entry.value.resetAt <= now else { return nil }
            return entry.key
        }
        guard !expiredAgents.isEmpty else { return false }

        for agent in expiredAgents {
            globalAgentRateLimits.removeValue(forKey: agent)
            clearRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
        }
        sendRateLimitLiftedNotification(for: expiredAgents)
        return true
    }

    private func sendRateLimitLiftedNotification(for agents: [AgentType]) {
        let settings = persistence.loadSettings()
        guard settings.notifyOnRateLimitLifted else { return }

        let agentNames = agents.map(\.rawValue).joined(separator: ", ")

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Rate Limit Lifted"
            content.body = agents.count == 1
                ? "\(agents[0].rawValue.capitalized) is ready to use again"
                : "\(agentNames) are ready to use again"
            content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.rateLimitLiftedSoundName))

            let request = UNNotificationRequest(
                identifier: "magent-rate-limit-lifted-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        let soundName = settings.rateLimitLiftedSoundName
        DispatchQueue.main.async {
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }

    private func publishRateLimitSummaryIfNeeded() async {
        let summary = globalRateLimitSummaryText()
        guard summary != lastPublishedRateLimitSummary else { return }
        lastPublishedRateLimitSummary = summary
        await MainActor.run {
            NotificationCenter.default.post(
                name: .magentGlobalRateLimitSummaryChanged,
                object: self
            )
        }
    }

    private func clearRateLimitMarkers(for agent: AgentType, changedThreadIds: inout Set<UUID>) {
        for i in threads.indices {
            var filtered = threads[i].rateLimitedSessions
            let keysToRemove = filtered.keys.filter { sessionName in
                agentType(for: threads[i], sessionName: sessionName) == agent
            }
            guard !keysToRemove.isEmpty else { continue }
            for key in keysToRemove {
                filtered.removeValue(forKey: key)
            }
            threads[i].rateLimitedSessions = filtered
            changedThreadIds.insert(threads[i].id)
        }
    }

    /// If an agent starts processing work after being rate-limited, clear the rate-limit
    /// cache for that agent globally and remove markers from all tabs using it.
    @discardableResult
    private func clearRateLimitAfterRecovery(threadIndex: Int, sessionName: String) -> Set<UUID> {
        guard threads.indices.contains(threadIndex) else { return [] }
        let thread = threads[threadIndex]
        guard let agent = agentType(for: thread, sessionName: sessionName),
              isRateLimitTrackable(agent: agent) else {
            return []
        }

        let hadSessionMarker = thread.rateLimitedSessions[sessionName] != nil
        let hadGlobalMarker = globalAgentRateLimits[agent] != nil
        guard hadSessionMarker || hadGlobalMarker else { return [] }

        globalAgentRateLimits.removeValue(forKey: agent)
        lastPublishedRateLimitSummary = nil

        var changedThreadIds = Set<UUID>()
        clearRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
        return changedThreadIds
    }

    private func rateLimitDetection(from paneContent: String, now: Date) -> RateLimitDetection? {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let tail = lines.suffix(80).map(String.init)
        let normalizedRecentTail = tail.suffix(20).joined(separator: "\n").lowercased()

        // Strong indicators — unambiguously mean the agent is blocked.
        let hasStrongIndicator = normalizedRecentTail.contains("too many requests")
            || normalizedRecentTail.contains("quota exceeded")
            || normalizedRecentTail.contains("retry after")
            || normalizedRecentTail.contains("try again in")
            || normalizedRecentTail.contains("limit reached")
            || normalizedRecentTail.contains("limit exceeded")
            || normalizedRecentTail.contains("rate limited")
            || normalizedRecentTail.contains("hit your usage limit")
            || normalizedRecentTail.contains("hit your rate limit")
            || normalizedRecentTail.contains("you've hit your limit")
            || normalizedRecentTail.contains("you’ve hit your limit")
            || (normalizedRecentTail.contains("hit your limit") && normalizedRecentTail.contains("reset"))
            || normalizedRecentTail.contains("you've been rate")

        // Weak indicators — "rate limit" / "usage limit" can appear in informational
        // displays (e.g. Claude Code status line, or agent output discussing rate limits).
        // Require additional blocking context to avoid false positives.
        if !hasStrongIndicator {
            let hasWeakKeyword = normalizedRecentTail.contains("rate limit")
                || normalizedRecentTail.contains("usage limit")
            let hasBlockingContext = normalizedRecentTail.contains("exceeded")
                || normalizedRecentTail.contains("reached")
                || normalizedRecentTail.contains("throttl")
                || normalizedRecentTail.contains("blocked")
                || normalizedRecentTail.contains("paused")
                || normalizedRecentTail.contains("wait")
                    && normalizedRecentTail.contains("until")
            guard hasWeakKeyword && hasBlockingContext else { return nil }
        }

        let focusText = rateLimitFocusText(from: tail)
        let relativeResetAt = parseRelativeResetDate(from: focusText, now: now)
        let explicitResult = parseExplicitResetDate(from: focusText, now: now)
        let absoluteResetAt = parseAbsoluteResetDate(from: focusText, now: now)

        let resetAt: Date
        let hasExplicitDateAnchor: Bool
        if let rel = relativeResetAt {
            resetAt = rel
            hasExplicitDateAnchor = true // relative durations are anchored to "now"
        } else if let exp = explicitResult {
            resetAt = exp.date
            hasExplicitDateAnchor = exp.hasDayToken
        } else if let abs = absoluteResetAt {
            resetAt = abs
            hasExplicitDateAnchor = focusTextHasDateMarkers(focusText)
        } else {
            // No parseable reset time — skip detection entirely (resetAt is mandatory).
            return nil
        }

        // Cap bare-time resets at 8 hours to avoid stale overnight detections
        // (e.g. "resets 4pm" parsed as today's 4pm when the message is from yesterday).
        let maxBareTimeDuration: TimeInterval = 8 * 3600
        if !hasExplicitDateAnchor && resetAt > now.addingTimeInterval(maxBareTimeDuration) {
            return nil
        }

        let resetDescription = extractRateLimitResetDescription(from: focusText)
        let fingerprint = rateLimitFingerprint(from: focusText, fallback: resetDescription)
        return RateLimitDetection(
            info: AgentRateLimitInfo(resetAt: resetAt, resetDescription: resetDescription, detectedAt: now),
            fingerprint: fingerprint,
            hasRelativeReset: relativeResetAt != nil,
            hasExplicitDateAnchor: hasExplicitDateAnchor
        )
    }

    private func rateLimitFocusText(from tail: [String]) -> String {
        let focusLines = tail.filter { line in
            let normalized = line.lowercased()
            return normalized.contains("rate")
                || normalized.contains("limit")
                || normalized.contains("quota")
                || normalized.contains("retry")
                || normalized.contains("try again")
                || normalized.contains("reset")
                || normalized.contains("available")
                || normalized.contains("until")
        }
        return (focusLines.isEmpty ? tail.suffix(20) : focusLines.suffix(12))
            .joined(separator: "\n")
    }

    private func rateLimitFingerprint(from focusText: String, fallback: String?) -> String {
        let normalizedFocus = focusText
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFocus.isEmpty {
            return normalizedFocus
        }
        let normalizedFallback = fallback?
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedFallback, !normalizedFallback.isEmpty {
            return normalizedFallback
        }
        return "__empty_rate_limit_fingerprint__"
    }

    private func parseRelativeResetDate(from text: String, now: Date) -> Date? {
        let normalized = text.lowercased()
        let triggerPattern = #"(?:try again|retry|resets?|reset|available)\s+(?:in|after)\s+([^\n\.;,]+)"#
        guard let triggerRegex = try? NSRegularExpression(pattern: triggerPattern, options: []) else { return nil }
        let searchRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

        for match in triggerRegex.matches(in: normalized, options: [], range: searchRange) {
            guard match.numberOfRanges >= 2,
                  let durationRange = Range(match.range(at: 1), in: normalized) else { continue }
            let durationText = String(normalized[durationRange])
            if let seconds = parseDurationSeconds(from: durationText), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }

        // Fallback for common API wording (e.g. "retry after 30s").
        if let seconds = parseDurationSeconds(from: normalized), seconds > 0,
           normalized.contains("retry after") || normalized.contains("try again in") {
            return now.addingTimeInterval(seconds)
        }

        return nil
    }

    private func parseDurationSeconds(from text: String) -> TimeInterval? {
        let tokenPattern = #"(\d+)\s*(days?|d|hours?|hrs?|hr|h|minutes?|mins?|min|m|seconds?|secs?|sec|s)\b"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var seconds: TimeInterval = 0
        var matchedAny = false

        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges >= 3,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange]) else {
                continue
            }
            matchedAny = true

            switch text[unitRange] {
            case "d", "day", "days":
                seconds += value * 86_400
            case "h", "hr", "hrs", "hour", "hours":
                seconds += value * 3_600
            case "m", "min", "mins", "minute", "minutes":
                seconds += value * 60
            case "s", "sec", "secs", "second", "seconds":
                seconds += value
            default:
                continue
            }
        }

        return matchedAny ? seconds : nil
    }

    /// Parses explicit reset times like:
    /// "You've hit your limit · resets 4pm (Europe/Warsaw)".
    /// If no day token is provided, the reset is assumed to be today in the parsed timezone.
    private func focusTextHasDateMarkers(_ text: String) -> Bool {
        let lower = text.lowercased()
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if monthNames.contains(where: { lower.contains($0) }) { return true }
        if lower.range(of: #"\b20\d{2}\b"#, options: .regularExpression) != nil { return true }
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                        "tomorrow"]
        if dayNames.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    private func parseExplicitResetDate(from text: String, now: Date) -> (date: Date, hasDayToken: Bool)? {
        let pattern = #"resets?\s+(?:at\s+)?(?:(today|tomorrow|mon(?:day)?|tues?(?:day)?|wed(?:nesday)?|thurs?(?:day)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\s+)?(\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)(?:\s*\(([^)\n]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let clockRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let dayToken: String? = {
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }()
            let timezoneToken: String? = {
                guard match.numberOfRanges >= 4,
                      let range = Range(match.range(at: 3), in: text) else { return nil }
                return String(text[range])
            }()

            guard let clock = parseResetClockComponents(from: String(text[clockRange])) else { continue }

            let timezone = parseResetTimeZone(from: timezoneToken) ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone

            let dayOffset = parseResetDayOffset(from: dayToken, now: now, calendar: calendar)
            var dateComponents = calendar.dateComponents([.year, .month, .day], from: now)
            dateComponents.timeZone = timezone
            dateComponents.hour = clock.hour
            dateComponents.minute = clock.minute
            dateComponents.second = 0

            guard let baseDate = calendar.date(from: dateComponents) else { continue }
            let hasDayToken = dayToken != nil
            if dayOffset == 0 {
                return (date: baseDate, hasDayToken: hasDayToken)
            }
            if let shifted = calendar.date(byAdding: .day, value: dayOffset, to: baseDate) {
                return (date: shifted, hasDayToken: hasDayToken)
            }
        }

        return nil
    }

    private func parseResetClockComponents(from text: String) -> (hour: Int, minute: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{1,2})(?::([0-5]\d))?\s*([ap]\.?m\.?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 4,
              let hourRange = Range(match.range(at: 1), in: trimmed),
              let hourValue = Int(trimmed[hourRange]) else {
            return nil
        }

        let minuteValue: Int = {
            guard let minuteRange = Range(match.range(at: 2), in: trimmed),
                  let minute = Int(trimmed[minuteRange]) else {
                return 0
            }
            return minute
        }()

        let meridiem = Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) }
        if let meridiem {
            let normalized = meridiem
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...12).contains(hourValue) else { return nil }
            if normalized.hasPrefix("p") {
                return (hour: hourValue == 12 ? 12 : hourValue + 12, minute: minuteValue)
            }
            if normalized.hasPrefix("a") {
                return (hour: hourValue == 12 ? 0 : hourValue, minute: minuteValue)
            }
            return nil
        }

        guard (0...23).contains(hourValue) else { return nil }
        return (hour: hourValue, minute: minuteValue)
    }

    private func parseResetTimeZone(from token: String?) -> TimeZone? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let tz = TimeZone(identifier: trimmed) {
            return tz
        }

        let underscored = trimmed.replacingOccurrences(of: " ", with: "_")
        if let tz = TimeZone(identifier: underscored) {
            return tz
        }

        return TimeZone(abbreviation: trimmed.uppercased())
    }

    private func parseResetDayOffset(from token: String?, now: Date, calendar: Calendar) -> Int {
        guard let token else { return 0 }
        let normalized = token
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == "today" {
            return 0
        }
        if normalized == "tomorrow" {
            return 1
        }
        guard let targetWeekday = weekdayIndex(forResetDayToken: normalized) else {
            // Unknown day token: keep today semantics.
            return 0
        }

        let currentWeekday = calendar.component(.weekday, from: now)
        return (targetWeekday - currentWeekday + 7) % 7
    }

    private func weekdayIndex(forResetDayToken token: String) -> Int? {
        if token.hasPrefix("sun") { return 1 }
        if token.hasPrefix("mon") { return 2 }
        if token.hasPrefix("tue") { return 3 }
        if token.hasPrefix("wed") { return 4 }
        if token.hasPrefix("thu") { return 5 }
        if token.hasPrefix("fri") { return 6 }
        if token.hasPrefix("sat") { return 7 }
        return nil
    }

    private func parseAbsoluteResetDate(from text: String, now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let relevantLines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let normalized = line.lowercased()
                return normalized.contains("reset")
                    || normalized.contains("available")
                    || normalized.contains("until")
                    || normalized.contains("try again")
                    || normalized.contains("retry")
            }
        let detectorText = relevantLines.isEmpty ? text : relevantLines.joined(separator: "\n")
        let range = NSRange(detectorText.startIndex..<detectorText.endIndex, in: detectorText)

        return detector.matches(in: detectorText, options: [], range: range)
            .compactMap(\.date)
            .filter { $0 > now.addingTimeInterval(-60) }
            .sorted()
            .first
    }

    private func extractRateLimitResetDescription(from text: String) -> String? {
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidate = lines.reversed().first { line in
            let normalized = line.lowercased()
            return normalized.contains("reset")
                || normalized.contains("available")
                || normalized.contains("until")
                || normalized.contains("retry")
                || normalized.contains("try again")
        } ?? lines.last

        guard let candidate else { return nil }
        let normalizedWhitespace = candidate.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace.isEmpty ? nil : normalizedWhitespace
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
        for (threadIndex, sessionName) in notifyPairs {
            let projectName = settings.projects.first(where: { $0.id == threads[threadIndex].projectId })?.name ?? "Project"
            sendAgentWaitingNotification(for: threads[threadIndex], projectName: projectName, playSound: playSound, sessionName: sessionName)
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

    private func sendAgentWaitingNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Needs Input"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

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
