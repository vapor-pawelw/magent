import Foundation

extension ThreadManager {

    enum SessionRecreationAction {
        case recreateMissingAgentSession
        case recreateMismatchedAgentSession
        case recreateMissingTerminalSession
        case recreateMismatchedTerminalSession

        var loadingOverlayDetail: String {
            switch self {
            case .recreateMissingAgentSession:
                return "Recovering a missing tmux session and restoring the saved agent conversation."
            case .recreateMismatchedAgentSession:
                return "Replacing a stale tmux session that points at the wrong worktree, then restoring the saved conversation."
            case .recreateMissingTerminalSession:
                return "Recovering a missing tmux session for this tab."
            case .recreateMismatchedTerminalSession:
                return "Replacing a stale tmux session that points at the wrong worktree."
            }
        }
    }

    // MARK: - Stale Session Cleanup

    /// Kills live tmux sessions prefixed with "ma-" that are not referenced by any non-archived thread/tab.
    @discardableResult
    func cleanupStaleMagentSessions(minimumStaleAge: TimeInterval = 0, now: Date = Date()) async -> [String] {
        let referencedSessions = referencedMagentSessionNames()

        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return []
        }

        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("ma-") && !referencedSessions.contains(sessionName)
        }

        guard !staleSessions.isEmpty else { return [] }

        let staleSet = Set(staleSessions)
        staleMagentSessionsFirstSeenAt = staleMagentSessionsFirstSeenAt.filter { staleSet.contains($0.key) }

        let sessionsToKill: [String]
        if minimumStaleAge > 0 {
            var matured = [String]()
            for sessionName in staleSessions {
                let firstSeen = staleMagentSessionsFirstSeenAt[sessionName] ?? now
                staleMagentSessionsFirstSeenAt[sessionName] = firstSeen
                if now.timeIntervalSince(firstSeen) >= minimumStaleAge {
                    matured.append(sessionName)
                }
            }
            sessionsToKill = matured
        } else {
            sessionsToKill = staleSessions
        }

        guard !sessionsToKill.isEmpty else { return [] }

        for sessionName in sessionsToKill {
            try? await tmux.killSession(name: sessionName)
            staleMagentSessionsFirstSeenAt.removeValue(forKey: sessionName)
        }

        return sessionsToKill
    }

    private func referencedMagentSessionNames() -> Set<String> {
        var names = Set<String>()

        // Include both in-memory and persisted threads so cleanup is safe during transitional states.
        let allNonArchivedThreads = threads.filter { !$0.isArchived } + persistence.loadThreads().filter { !$0.isArchived }
        for thread in allNonArchivedThreads {
            for sessionName in thread.tmuxSessionNames where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            for sessionName in thread.agentTmuxSessions where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            for sessionName in thread.pinnedTmuxSessions where sessionName.hasPrefix("ma-") {
                names.insert(sessionName)
            }
            if let selectedSession = thread.lastSelectedTmuxSessionName, selectedSession.hasPrefix("ma-") {
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
        thread: MagentThread,
        onAction: (@MainActor @Sendable (SessionRecreationAction?) -> Void)? = nil
    ) async -> Bool {
        // Skip if already being recreated
        guard !sessionsBeingRecreated.contains(sessionName) else { return false }

        sessionsBeingRecreated.insert(sessionName)
        defer { sessionsBeingRecreated.remove(sessionName) }

        let settings = persistence.loadSettings()
        let refreshedThread = threads.first(where: { $0.id == thread.id }) ?? thread
        let project = settings.projects.first(where: { $0.id == refreshedThread.projectId })
        let projectPath = project?.repoPath ?? thread.worktreePath
        let projectName = project?.name ?? "project"
        let isAgentSession = refreshedThread.agentTmuxSessions.contains(sessionName)

        if await tmux.hasSession(name: sessionName) {
            let sessionMatches = await sessionMatchesThreadContext(
                sessionName: sessionName,
                thread: refreshedThread,
                projectPath: projectPath,
                isAgentSession: isAgentSession
            )
            if sessionMatches {
                await setSessionEnvironment(
                    sessionName: sessionName,
                    thread: refreshedThread,
                    projectPath: projectPath,
                    projectName: projectName
                )
                if isAgentSession {
                    await tmux.setupBellPipe(for: sessionName)
                }
                return false
            }

            if let onAction {
                await MainActor.run {
                    onAction(isAgentSession ? .recreateMismatchedAgentSession : .recreateMismatchedTerminalSession)
                }
            }

            // Session name exists but points at another thread/project context.
            try? await tmux.killSession(name: sessionName)
        } else {
            if let onAction {
                await MainActor.run {
                    onAction(isAgentSession ? .recreateMissingAgentSession : .recreateMissingTerminalSession)
                }
            }
        }

        // Refreshing persisted resume IDs can touch agent-owned state on disk and
        // occasionally takes much longer than a simple tmux health check. Keep it
        // off the fast path for already-live sessions, but still do it before
        // recreating a missing/mismatched agent session so resume remains intact.
        if isAgentSession {
            await refreshAgentConversationID(threadId: refreshedThread.id, sessionName: sessionName)
        }

        let startCmd: String
        let sessionAgentType = agentType(for: refreshedThread, sessionName: sessionName)
            ?? effectiveAgentType(for: refreshedThread.projectId)
        let resumeSessionID = refreshedThread.sessionConversationIDs[sessionName]
        let envExports: String
        if thread.isMain {
            envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_THREAD_ID=\(thread.id.uuidString) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        } else {
            envExports = "export MAGENT_WORKTREE_PATH=\(thread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(thread.name) && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_THREAD_ID=\(thread.id.uuidString) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        }
        if isAgentSession {
            startCmd = agentStartCommand(
                settings: settings,
                projectId: thread.projectId,
                agentType: sessionAgentType,
                envExports: envExports,
                workingDirectory: thread.worktreePath,
                resumeSessionID: resumeSessionID
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
        try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_THREAD_ID", value: thread.id.uuidString)
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
        if let ownerThreadID = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_THREAD_ID"),
           !ownerThreadID.isEmpty {
            guard ownerThreadID == thread.id.uuidString else { return false }
        } else if let sessionCreatedAt = await tmux.sessionCreatedAt(sessionName: sessionName),
                  sessionCreatedAt < thread.createdAt.addingTimeInterval(-1) {
            // A session older than the current thread is from a previous owner
            // when a branch/worktree name gets reused. Do not adopt it.
            return false
        }

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
