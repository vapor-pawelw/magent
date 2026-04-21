import Foundation
import MagentCore

// MARK: - SessionRecreationService

/// Owns tmux session recreation: the known-good session cache, fast-path preparation
/// checks, context-match validation against running tmux sessions, and the create/kill
/// recreation flow. Recreation depends on agent-setup helpers (env/injection/start
/// commands) via callbacks so the service doesn't take a hard dep on AgentSetupService.
final class SessionRecreationService {

    static let knownGoodSessionTTL: TimeInterval = 120

    let store: ThreadStore
    let sessionTracker: SessionTracker
    let persistence: PersistenceService
    let tmux: TmuxService

    // MARK: - Callbacks (wired by ThreadManager)

    var onThreadsChanged: (() -> Void)?

    var agentType: ((MagentThread, String) -> AgentType?)?
    var effectiveAgentType: ((UUID) -> AgentType?)?
    var detectedAgentTypeInSession: ((String) async -> AgentType?)?

    var sessionEnvironmentVariables: ((UUID, String?, String, String, String, AgentType?) -> [(String, String)])?
    var shellExportCommand: (([(String, String)]) -> String)?
    var applySessionEnvironmentVariables: ((String, [(String, String)]) async -> Void)?

    var agentStartCommand: ((AppSettings, UUID, AgentType?, String, String, String?) -> String)?
    var terminalStartCommand: ((String, String) -> String)?

    var effectiveInjection: ((UUID) -> (terminalCommand: String, agentContext: String))?
    var injectAfterStart: ((String, String, String, AgentType?) -> Void)?

    var refreshAgentConversationID: ((UUID, String) async -> Void)?

    init(store: ThreadStore, sessionTracker: SessionTracker, persistence: PersistenceService, tmux: TmuxService) {
        self.store = store
        self.sessionTracker = sessionTracker
        self.persistence = persistence
        self.tmux = tmux
    }

    // MARK: - Fast-path Preparation Check

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
        guard let cached = sessionTracker.knownGoodSessionContexts[sessionName] else { return false }
        guard Date().timeIntervalSince(cached.validatedAt) <= Self.knownGoodSessionTTL else {
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
            return false
        }
        // The cached context must belong to this thread. (Rename rekeys the cache,
        // but a session whose thread ID drifted for any other reason is unsafe to trust.)
        guard cached.threadId == thread.id else { return false }
        // Sessions that were marked dead or evicted must fall through to the slow path
        // so the VC can trigger recreation.
        if thread.deadSessions.contains(sessionName) { return false }
        if sessionTracker.evictedIdleSessions.contains(sessionName) { return false }
        // If recreation is currently in-flight elsewhere (session monitor, etc.), don't
        // fast-path — the in-flight work may be about to flip the session state.
        if sessionTracker.sessionsBeingRecreated.contains(sessionName) { return false }
        return true
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
        guard !sessionTracker.sessionsBeingRecreated.contains(sessionName) else { return false }

        sessionTracker.sessionsBeingRecreated.insert(sessionName)
        defer { sessionTracker.sessionsBeingRecreated.remove(sessionName) }

        let settings = persistence.loadSettings()
        let refreshedThread = store.threads.first(where: { $0.id == thread.id }) ?? thread

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
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
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
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
            try? await tmux.killSession(name: sessionName)
        } else {
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
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
            await refreshAgentConversationID?(refreshedThread.id, sessionName)
        }

        // Re-read thread after refresh — refreshAgentConversationID writes to
        // threads[index] (struct value type), so the earlier snapshot is stale.
        let threadAfterRefresh = store.threads.first(where: { $0.id == thread.id }) ?? refreshedThread
        let startCmd: String
        let sessionAgentType = agentType?(threadAfterRefresh, sessionName)
            ?? effectiveAgentType?(threadAfterRefresh.projectId)
        let resumeSessionID = threadAfterRefresh.sessionConversationIDs[sessionName]
        let sessionEnvironment = sessionEnvironmentVariables?(
            thread.id,
            thread.isMain ? nil : thread.worktreePath,
            projectPath,
            thread.isMain ? "main" : thread.name,
            projectName,
            isAgentSession ? sessionAgentType : nil
        ) ?? []
        let envExports = shellExportCommand?(sessionEnvironment) ?? ""
        if isAgentSession {
            startCmd = agentStartCommand?(
                settings,
                thread.projectId,
                sessionAgentType,
                envExports,
                thread.worktreePath,
                resumeSessionID
            ) ?? ""
        } else {
            startCmd = terminalStartCommand?(envExports, thread.worktreePath) ?? ""
        }

        // Re-check ownership: a rename may have landed during the awaits above,
        // removing this session name from the thread. Bail out to avoid creating
        // an orphan session under the stale old name.
        let revalidatedThread = store.threads.first(where: { $0.id == thread.id }) ?? thread
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
        if let idx = store.threads.firstIndex(where: { $0.id == thread.id }) {
            store.threads[idx].deadSessions.remove(sessionName)
            onThreadsChanged?()
        }

        // Run normal injection (terminal command + agent context)
        let injection = effectiveInjection?(thread.projectId) ?? (terminalCommand: "", agentContext: "")
        injectAfterStart?(
            sessionName,
            injection.terminalCommand,
            isAgentSession ? injection.agentContext : "",
            sessionAgentType
        )

        return true
    }

    // MARK: - Known-Good Cache

    func markSessionContextKnownGood(
        sessionName: String,
        threadId: UUID,
        expectedPath: String,
        projectPath: String,
        isAgentSession: Bool
    ) {
        sessionTracker.knownGoodSessionContexts[sessionName] = KnownGoodSessionContext(
            threadId: threadId,
            expectedPath: expectedPath,
            projectPath: projectPath,
            isAgentSession: isAgentSession,
            validatedAt: Date()
        )
    }

    private func isSessionContextKnownGood(
        sessionName: String,
        threadId: UUID,
        expectedPath: String,
        projectPath: String,
        isAgentSession: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let cached = sessionTracker.knownGoodSessionContexts[sessionName] else { return false }
        guard now.timeIntervalSince(cached.validatedAt) <= Self.knownGoodSessionTTL else {
            sessionTracker.knownGoodSessionContexts.removeValue(forKey: sessionName)
            return false
        }
        return cached.threadId == threadId
            && cached.expectedPath == expectedPath
            && cached.projectPath == projectPath
            && cached.isAgentSession == isAgentSession
    }

    // MARK: - Session Environment

    private func setSessionEnvironment(
        sessionName: String,
        thread: MagentThread,
        projectPath: String,
        projectName: String
    ) async {
        let resolvedAgentType = agentType?(thread, sessionName)
        let sessionEnvironment = sessionEnvironmentVariables?(
            thread.id,
            thread.isMain ? nil : thread.worktreePath,
            projectPath,
            thread.isMain ? "main" : thread.name,
            projectName,
            resolvedAgentType
        ) ?? []
        await applySessionEnvironmentVariables?(sessionName, sessionEnvironment)
        if resolvedAgentType == nil {
            // Ensure terminal sessions don't inherit stale agent-type markers.
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_AGENT_TYPE", value: "")
        }
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
           let expectedAgentType = agentType?(thread, sessionName) {
            if let envAgentType = snapshot?.agentType?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               !envAgentType.isEmpty {
                guard AgentType(rawValue: envAgentType) == expectedAgentType else { return false }
            } else if let runningAgentType = await detectedAgentTypeInSession?(sessionName),
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
