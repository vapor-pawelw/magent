import Foundation
import MagentCore

// SessionRecreationAction is now a top-level type defined in SessionLifecycleService.
// Stale session cleanup and referencedMagentSessionNames are forwarded to SessionLifecycleService.
extension ThreadManager {

    static let knownGoodSessionTTL: TimeInterval = 120

    /// Fast-path check for `ThreadDetailViewController.ensureSessionPrepared`: returns
    /// true when a freshly-created VC can skip `recreateSessionIfNeeded` entirely and
    /// its `hasSession` shell probe. The check trusts the existing known-good TTL plus
    /// the kill/rename/dead-session/eviction invalidation paths that already scrub the
    /// cache (`killSession`, `toggleSectionKeepAlive`, session cleanup, rename rekey,
    /// etc.). Does NOT touch tmux.
    ///
    /// Without this, every thread switch into a recently-visited thread goes through
    /// an async `tmux has-session` call before the overlay can be dismissed, which is
    /// the bulk of the visible "Starting agent..." flash on revisits.
    func isSessionPreparedFastPath(sessionName: String, thread: MagentThread) -> Bool {
        guard let cached = knownGoodSessionContexts[sessionName] else { return false }
        guard Date().timeIntervalSince(cached.validatedAt) <= Self.knownGoodSessionTTL else {
            knownGoodSessionContexts.removeValue(forKey: sessionName)
            return false
        }
        // The cached context must belong to this thread. (Rename rekeys the cache,
        // but a session whose thread ID drifted for any other reason is unsafe to trust.)
        guard cached.threadId == thread.id else { return false }
        // Sessions that were marked dead or evicted must fall through to the slow path
        // so the VC can trigger recreation.
        if thread.deadSessions.contains(sessionName) { return false }
        if evictedIdleSessions.contains(sessionName) { return false }
        // If recreation is currently in-flight elsewhere (session monitor, etc.), don't
        // fast-path — the in-flight work may be about to flip the session state.
        if sessionsBeingRecreated.contains(sessionName) { return false }
        return true
    }

    // MARK: - Stale Session Cleanup
    // Forwarded to SessionLifecycleService (Phase 4).

    @discardableResult
    func cleanupStaleMagentSessions(minimumStaleAge: TimeInterval = 0, now: Date = Date()) async -> [String] {
        await sessionLifecycleService.cleanupStaleMagentSessions(minimumStaleAge: minimumStaleAge, now: now)
    }

    nonisolated static func cleanupStaleSessions(
        tmux: TmuxService,
        referencedSessions: Set<String>
    ) async {
        await SessionLifecycleService.cleanupStaleSessions(tmux: tmux, referencedSessions: referencedSessions)
    }

    func referencedMagentSessionNames() -> Set<String> {
        sessionLifecycleService.referencedMagentSessionNames()
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

        // Bail out if this session name is no longer part of the thread
        // (e.g. a rename landed while preparation was in-flight).
        guard refreshedThread.tmuxSessionNames.contains(sessionName) else { return false }
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

        // Re-read thread after refresh — refreshAgentConversationID writes to
        // threads[index] (struct value type), so the earlier snapshot is stale.
        let threadAfterRefresh = threads.first(where: { $0.id == thread.id }) ?? refreshedThread
        let startCmd: String
        let sessionAgentType = agentType(for: threadAfterRefresh, sessionName: sessionName)
            ?? effectiveAgentType(for: threadAfterRefresh.projectId)
        let resumeSessionID = threadAfterRefresh.sessionConversationIDs[sessionName]
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

        // Re-check ownership: a rename may have landed during the awaits above,
        // removing this session name from the thread. Bail out to avoid creating
        // an orphan session under the stale old name.
        let revalidatedThread = threads.first(where: { $0.id == thread.id }) ?? thread
        guard revalidatedThread.tmuxSessionNames.contains(sessionName) else { return false }

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

        // Clear dead-session tracking now that the session is alive again.
        if let idx = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[idx].deadSessions.remove(sessionName)
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

    func markSessionContextKnownGood(
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
        let snapshot = await tmux.sessionContextSnapshot(sessionName: sessionName)

        if let ownerThreadID = snapshot?.ownerThreadId,
           !ownerThreadID.isEmpty {
            guard ownerThreadID == thread.id.uuidString else { return false }
        } else if let sessionCreatedAt = snapshot?.createdAt,
                  sessionCreatedAt < thread.createdAt.addingTimeInterval(-1) {
            // A session older than the current thread is from a previous owner
            // when a branch/worktree name gets reused. Do not adopt it.
            return false
        }

        let expectedPath = thread.isMain ? projectPath : thread.worktreePath

        if let panePath = snapshot?.panePath,
           !path(panePath, isWithin: expectedPath) {
            if !isAgentSession, let paneCommand = snapshot?.paneCommand, isShellCommand(paneCommand) {
                // Keep terminal sessions when users navigate away manually.
                return true
            }
            // Agent sessions or non-shell commands in the wrong directory should be recreated.
            return false
        }

        if isAgentSession,
           let expectedAgentType = agentType(for: thread, sessionName: sessionName) {
            if let envAgentType = snapshot?.agentType?
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
            if let envProject = snapshot?.projectPath,
               !envProject.isEmpty {
                return envProject == projectPath
            }
            if let sessionPath = snapshot?.sessionPath {
                return path(sessionPath, isWithin: projectPath)
            }
            return true
        }

        if let envWorktree = snapshot?.worktreePath,
           !envWorktree.isEmpty {
            guard envWorktree == thread.worktreePath else { return false }
            if let envProject = snapshot?.projectPath,
               !envProject.isEmpty {
                return envProject == projectPath
            }
            return true
        }

        if let sessionPath = snapshot?.sessionPath {
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
