import Foundation
import MagentCore

extension ThreadManager {

    struct KnownGoodSessionContext {
        let threadId: UUID
        let expectedPath: String
        let projectPath: String
        let isAgentSession: Bool
        let validatedAt: Date
    }

    private static let knownGoodSessionTTL: TimeInterval = 120

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

    /// Lightweight stale-session cleanup that runs entirely off the main thread.
    /// Takes pre-captured referenced sessions and a tmux service reference so no main-actor
    /// hop is needed. Skips `staleMagentSessionsFirstSeenAt` tracking (only relevant for the
    /// 5-minute poller cadence, not post-archive one-shot cleanup).
    nonisolated static func cleanupStaleSessions(
        tmux: TmuxService,
        referencedSessions: Set<String>
    ) async {
        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return
        }
        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("ma-") && !referencedSessions.contains(sessionName)
        }
        for sessionName in staleSessions {
            try? await tmux.killSession(name: sessionName)
        }
    }

    func referencedMagentSessionNames() -> Set<String> {
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
        let expectedPath = refreshedThread.isMain ? projectPath : refreshedThread.worktreePath

        if isSessionContextKnownGood(
            sessionName: sessionName,
            threadId: refreshedThread.id,
            expectedPath: expectedPath,
            projectPath: projectPath,
            isAgentSession: isAgentSession
        ) {
            if await tmux.hasSession(name: sessionName) {
                return false
            }
            knownGoodSessionContexts.removeValue(forKey: sessionName)
        }

        if await tmux.hasSession(name: sessionName) {
            let sessionMatches = await sessionMatchesThreadContext(
                sessionName: sessionName,
                thread: refreshedThread,
                projectPath: projectPath,
                isAgentSession: isAgentSession
            )
            if sessionMatches {
                markSessionContextKnownGood(
                    sessionName: sessionName,
                    threadId: refreshedThread.id,
                    expectedPath: expectedPath,
                    projectPath: projectPath,
                    isAgentSession: isAgentSession
                )
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
            knownGoodSessionContexts.removeValue(forKey: sessionName)
            try? await tmux.killSession(name: sessionName)
        } else {
            knownGoodSessionContexts.removeValue(forKey: sessionName)
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
        let sessionEnvironment = sessionEnvironmentVariables(
            threadId: thread.id,
            worktreePath: thread.isMain ? nil : thread.worktreePath,
            projectPath: projectPath,
            worktreeName: thread.isMain ? "main" : thread.name,
            projectName: projectName,
            agentType: isAgentSession ? sessionAgentType : nil
        )
        let envExports = shellExportCommand(for: sessionEnvironment)
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

        markSessionContextKnownGood(
            sessionName: sessionName,
            threadId: thread.id,
            expectedPath: expectedPath,
            projectPath: projectPath,
            isAgentSession: isAgentSession
        )

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
        let sessionEnvironment = sessionEnvironmentVariables(
            threadId: thread.id,
            worktreePath: thread.isMain ? nil : thread.worktreePath,
            projectPath: projectPath,
            worktreeName: thread.isMain ? "main" : thread.name,
            projectName: projectName,
            agentType: agentType(for: thread, sessionName: sessionName)
        )
        await applySessionEnvironmentVariables(
            sessionName: sessionName,
            environmentVariables: sessionEnvironment
        )
        if agentType(for: thread, sessionName: sessionName) == nil {
            // Ensure terminal sessions don't inherit stale agent-type markers.
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_AGENT_TYPE", value: "")
        }
    }

    private func isSessionContextKnownGood(
        sessionName: String,
        threadId: UUID,
        expectedPath: String,
        projectPath: String,
        isAgentSession: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let cached = knownGoodSessionContexts[sessionName] else { return false }
        guard now.timeIntervalSince(cached.validatedAt) <= Self.knownGoodSessionTTL else {
            knownGoodSessionContexts.removeValue(forKey: sessionName)
            return false
        }
        return cached.threadId == threadId
            && cached.expectedPath == expectedPath
            && cached.projectPath == projectPath
            && cached.isAgentSession == isAgentSession
    }

    private func markSessionContextKnownGood(
        sessionName: String,
        threadId: UUID,
        expectedPath: String,
        projectPath: String,
        isAgentSession: Bool
    ) {
        knownGoodSessionContexts[sessionName] = KnownGoodSessionContext(
            threadId: threadId,
            expectedPath: expectedPath,
            projectPath: projectPath,
            isAgentSession: isAgentSession,
            validatedAt: Date()
        )
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

        if isAgentSession,
           let expectedAgentType = agentType(for: thread, sessionName: sessionName) {
            if let envAgentType = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_AGENT_TYPE")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               !envAgentType.isEmpty {
                guard AgentType(rawValue: envAgentType) == expectedAgentType else { return false }
            } else if let runningAgentType = await detectedAgentTypeInSession(sessionName),
                      runningAgentType != expectedAgentType {
                return false
            }
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
