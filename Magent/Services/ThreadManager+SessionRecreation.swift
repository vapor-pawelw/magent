import Foundation

extension ThreadManager {

    // MARK: - Stale Session Cleanup

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

    // MARK: - Session Recreation

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
            startCmd = terminalStartCommand(
                envExports: envExports,
                workingDirectory: thread.worktreePath
            )
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

    // MARK: - Session Environment

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

    // MARK: - Session Context Matching

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
                // Keep terminal sessions when users navigate away manually.
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
}
