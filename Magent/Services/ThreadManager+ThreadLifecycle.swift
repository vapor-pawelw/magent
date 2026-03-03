import Foundation

extension ThreadManager {

    // MARK: - Thread Creation

    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        initialPrompt: String? = nil,
        requestedName: String? = nil
    ) async throws -> MagentThread {
        var name = ""
        var foundUnique = false

        if let requested = requestedName?.trimmingCharacters(in: .whitespaces), !requested.isEmpty {
            // Use the requested name, with numeric suffix fallback for conflicts.
            guard !requested.contains("/") else { throw ThreadManagerError.invalidName }
            let candidates = [requested] + (2...9).map { "\(requested)-\($0)" }
            for candidate in candidates {
                if try await isNameAvailable(candidate, project: project) {
                    name = candidate
                    foundUnique = true
                    break
                }
            }
        } else {
            // Generate a sequential Pokemon name from a persisted counter.
            // On conflict, skip to the next Pokemon (up to 3 tries).
            // If all 3 fail, add a numeric suffix to the last tried name.
            let basePath = project.resolvedWorktreesBasePath()
            var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
            var counter = cache.nameCounter
            let pokemonCount = NameGenerator.pokemonNames.count
            var conflictStreak = 0

            for _ in 0..<3 {
                let candidate = NameGenerator.generate(counter: counter)
                counter = (counter + 1) % pokemonCount
                if try await isNameAvailable(candidate, project: project) {
                    name = candidate
                    foundUnique = true
                    break
                }
                conflictStreak += 1
            }

            // All 3 sequential names conflicted — use the last name with a numeric suffix.
            if !foundUnique {
                let lastBase = NameGenerator.generate(counter: (counter - 1 + pokemonCount) % pokemonCount)
                for suffix in 2...99 {
                    let candidate = "\(lastBase)-\(suffix)"
                    if try await isNameAvailable(candidate, project: project) {
                        name = candidate
                        foundUnique = true
                        break
                    }
                }
            }

            cache.nameCounter = counter
            persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        }

        guard foundUnique else {
            throw ThreadManagerError.nameGenerationFailed
        }

        let branchName = name
        let worktreePath = "\(project.resolvedWorktreesBasePath())/\(name)"
        let repoSlug = Self.repoSlug(from: project.name)

        // Create git worktree branching off the project's default branch
        let baseBranch = project.defaultBranch?.isEmpty == false ? project.defaultBranch : nil
        _ = try await git.createWorktree(
            repoPath: project.repoPath,
            branchName: branchName,
            worktreePath: worktreePath,
            baseBranch: baseBranch
        )

        // Record fork-point commit in the worktree metadata cache
        let forkPointResult = await ShellExecutor.execute("git rev-parse HEAD", workingDirectory: worktreePath)
        let forkPoint = forkPointResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if forkPointResult.exitCode == 0, !forkPoint.isEmpty {
            let basePath = project.resolvedWorktreesBasePath()
            var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
            cache.worktrees[name] = WorktreeMetadata(forkPointCommit: forkPoint, createdAt: Date())
            persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        }

        let settings = persistence.loadSettings()
        let selectedAgentType: AgentType?
        if useAgentCommand {
            selectedAgentType = resolveAgentType(
                for: project.id,
                requestedAgentType: requestedAgentType,
                settings: settings
            )
        } else {
            selectedAgentType = nil
        }

        let firstTabDisplayName = useAgentCommand
            ? TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
            : "Terminal"
        let firstTabSlug = Self.sanitizeForTmux(firstTabDisplayName)
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: name, tabSlug: firstTabSlug)

        // Pre-trust the worktree directory so the selected agent doesn't show a trust dialog
        trustDirectoryIfNeeded(worktreePath, agentType: selectedAgentType)

        // Create tmux session with selected agent command (or shell if no active agents)
        let envExports = "export MAGENT_WORKTREE_PATH=\(worktreePath) && export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=\(name) && export MAGENT_PROJECT_NAME=\(project.name) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        let startCmd: String
        if useAgentCommand {
            startCmd = agentStartCommand(
                settings: settings,
                agentType: selectedAgentType,
                envExports: envExports,
                workingDirectory: worktreePath
            )
        } else {
            startCmd = "\(envExports) && cd \(worktreePath) && exec zsh -l"
        }
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: worktreePath,
            command: startCmd
        )
        enforceWorkingDirectoryAfterStartup(sessionName: tmuxSessionName, path: worktreePath)

        // Also set on the tmux session so new panes/windows inherit them
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_PATH", value: worktreePath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: project.name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
        if let selectedAgentType {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_AGENT_TYPE", value: selectedAgentType.rawValue)
        }

        let sessionAgentTypes: [String: AgentType]
        if useAgentCommand, let selectedAgentType {
            sessionAgentTypes = [tmuxSessionName: selectedAgentType]
        } else {
            sessionAgentTypes = [:]
        }

        let thread = MagentThread(
            projectId: project.id,
            name: name,
            worktreePath: worktreePath,
            branchName: branchName,
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: useAgentCommand && selectedAgentType != nil ? [tmuxSessionName] : [],
            sessionAgentTypes: sessionAgentTypes,
            sectionId: settings.defaultSection(for: project.id)?.id,
            selectedAgentType: selectedAgentType,
            lastSelectedTmuxSessionName: tmuxSessionName,
            customTabNames: [tmuxSessionName: firstTabDisplayName],
            baseBranch: baseBranch
        )

        threads.append(thread)

        // Place at bottom of the default section's unpinned group
        if let lastIndex = threads.indices.last {
            let sectionId = effectiveSectionId(for: threads[lastIndex])
            let maxOrder = threads
                .filter {
                    $0.id != thread.id &&
                    !$0.isMain && !$0.isArchived &&
                    $0.projectId == project.id &&
                    !$0.isPinned &&
                    effectiveSectionId(for: $0) == sectionId
                }
                .map(\.displayOrder)
                .max() ?? -1
            threads[lastIndex].displayOrder = maxOrder + 1
        }

        try persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: thread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, initialPrompt: initialPrompt, agentType: selectedAgentType)

        return thread
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let settings = persistence.loadSettings()
        let selectedAgentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)

        let repoSlug = Self.repoSlug(from: project.name)
        let firstTabDisplayName = TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
        let firstTabSlug = Self.sanitizeForTmux(firstTabDisplayName)
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: firstTabSlug)

        // Kill orphaned tmux session if it exists from a previous run
        if await tmux.hasSession(name: tmuxSessionName) {
            try? await tmux.killSession(name: tmuxSessionName)
        }

        trustDirectoryIfNeeded(project.repoPath, agentType: selectedAgentType)
        let envExports = "export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(project.name) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        let startCmd = agentStartCommand(
            settings: settings,
            agentType: selectedAgentType,
            envExports: envExports,
            workingDirectory: project.repoPath
        )
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: project.repoPath,
            command: startCmd
        )
        enforceWorkingDirectoryAfterStartup(sessionName: tmuxSessionName, path: project.repoPath)

        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: "main")
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: project.name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
        if let selectedAgentType {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_AGENT_TYPE", value: selectedAgentType.rawValue)
        }

        let mainSessionAgentTypes: [String: AgentType]
        if let selectedAgentType {
            mainSessionAgentTypes = [tmuxSessionName: selectedAgentType]
        } else {
            mainSessionAgentTypes = [:]
        }

        let thread = MagentThread(
            projectId: project.id,
            name: "main",
            worktreePath: project.repoPath,
            branchName: "",
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: selectedAgentType != nil ? [tmuxSessionName] : [],
            sessionAgentTypes: mainSessionAgentTypes,
            isMain: true,
            selectedAgentType: selectedAgentType,
            lastSelectedTmuxSessionName: tmuxSessionName,
            customTabNames: [tmuxSessionName: firstTabDisplayName]
        )

        // Insert main threads at front
        threads.insert(thread, at: 0)
        try persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: thread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, agentType: selectedAgentType)

        return thread
    }

    func ensureMainThreads() async {
        let settings = persistence.loadSettings()
        for project in settings.projects {
            if !threads.contains(where: { $0.isMain && $0.projectId == project.id }) {
                _ = try? await createMainThread(project: project)
            }
        }
    }

    // MARK: - Archive Thread

    func archiveThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        if let ticketKey = thread.jiraTicketKey {
            excludeJiraTicket(key: ticketKey, projectId: thread.projectId)
        }

        // Remove from active list
        threads.removeAll { $0.id == thread.id }

        // Mark as archived in persistence
        var allThreads = persistence.loadThreads()
        if let i = allThreads.firstIndex(where: { $0.id == thread.id }) {
            allThreads[i].isArchived = true
            allThreads[i].tmuxSessionNames = []
        }
        try persistence.saveThreads(allThreads)

        await MainActor.run {
            delegate?.threadManager(self, didArchiveThread: thread)
        }

        // Cleanup after UI has switched away from this thread.
        for sessionName in thread.tmuxSessionNames {
            try? await tmux.killSession(name: sessionName)
        }

        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
            pruneWorktreeCache(for: project)
        }

        cleanupAllBrokenSymlinks()
        await cleanupStaleMagentSessions()
    }

    // MARK: - Delete Thread

    func deleteThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        if let ticketKey = thread.jiraTicketKey {
            excludeJiraTicket(key: ticketKey, projectId: thread.projectId)
        }

        // Remove from active list
        threads.remove(at: index)

        // Remove from persisted JSON entirely
        var allThreads = persistence.loadThreads()
        allThreads.removeAll { $0.id == thread.id }
        try persistence.saveThreads(allThreads)

        await MainActor.run {
            delegate?.threadManager(self, didDeleteThread: thread)
        }

        // Cleanup after UI has switched away from this thread.
        for sessionName in thread.tmuxSessionNames {
            try? await tmux.killSession(name: sessionName)
        }

        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
            if !thread.branchName.isEmpty {
                try? await git.deleteBranch(repoPath: project.repoPath, branchName: thread.branchName)
            }
            pruneWorktreeCache(for: project)
        }

        cleanupAllBrokenSymlinks()
        await cleanupStaleMagentSessions()
    }

    // MARK: - Worktree Recovery

    enum RecoveryResult {
        case recovered
        case mainThreadMissing
        case projectNotFound
        case failed(Error)
    }

    func recoverWorktree(for thread: MagentThread) async -> RecoveryResult {
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
            return .projectNotFound
        }

        if thread.isMain {
            return .mainThreadMissing
        }

        // Verify the main repo still exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.repoPath, isDirectory: &isDir), isDir.boolValue else {
            return .mainThreadMissing
        }

        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            return .failed(ThreadManagerError.threadNotFound)
        }

        do {
            // Prune stale worktree references
            await git.pruneWorktrees(repoPath: project.repoPath)

            // Kill any stale tmux sessions for this thread
            for sessionName in threads[index].tmuxSessionNames {
                try? await tmux.killSession(name: sessionName)
            }
            threads[index].tmuxSessionNames = []
            threads[index].lastSelectedTmuxSessionName = nil

            // Re-create the worktree
            let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: thread.branchName)
            if branchExists {
                _ = try await git.addWorktreeForExistingBranch(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath
                )
            } else {
                let baseBranch = project.defaultBranch?.isEmpty == false ? project.defaultBranch : nil
                _ = try await git.createWorktree(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath,
                    baseBranch: baseBranch
                )
            }

            // Trust the directory for the agent if needed
            trustDirectoryIfNeeded(thread.worktreePath, agentType: thread.selectedAgentType)

            // Persist updated threads
            try persistence.saveThreads(threads)

            return .recovered
        } catch {
            return .failed(error)
        }
    }
}
