import Cocoa
import Foundation
import MagentCore

extension ThreadManager {

    private static let archivedThreadBannerDuration: TimeInterval = 10.0

    // MARK: - Thread Creation

    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        initialPrompt: String? = nil,
        requestedName: String? = nil,
        requestedBaseBranch: String? = nil
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

        // Create git worktree branching off the requested base branch, or the
        // project's default branch when no explicit base is provided.
        let explicitBaseBranch = requestedBaseBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBranch: String?
        if let explicitBaseBranch, !explicitBaseBranch.isEmpty {
            baseBranch = explicitBaseBranch
        } else if let projectDefault = project.defaultBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectDefault.isEmpty {
            baseBranch = projectDefault
        } else {
            baseBranch = nil
        }
        _ = try await git.createWorktree(
            repoPath: project.repoPath,
            branchName: branchName,
            worktreePath: worktreePath,
            baseBranch: baseBranch
        )

        let localFileSyncPathsSnapshot = project.normalizedLocalFileSyncPaths
        do {
            try await syncConfiguredLocalPathsIntoWorktree(
                project: project,
                worktreePath: worktreePath,
                syncPaths: localFileSyncPathsSnapshot
            )
        } catch {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: worktreePath)
            throw error
        }

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

        let threadID = UUID()
        let firstTabDisplayName = useAgentCommand
            ? TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType)
            : "Terminal"
        let firstTabSlug = Self.sanitizeForTmux(firstTabDisplayName)
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: name, tabSlug: firstTabSlug)

        // Pre-trust the worktree directory so the selected agent doesn't show a trust dialog
        trustDirectoryIfNeeded(worktreePath, agentType: selectedAgentType)

        // Create tmux session with selected agent command (or shell if no active agents)
        let envExports = "export MAGENT_WORKTREE_PATH=\(worktreePath) && export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=\(name) && export MAGENT_PROJECT_NAME=\(project.name) && export MAGENT_THREAD_ID=\(threadID.uuidString) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        let startCmd: String
        if useAgentCommand {
            startCmd = agentStartCommand(
                settings: settings,
                projectId: project.id,
                agentType: selectedAgentType,
                envExports: envExports,
                workingDirectory: worktreePath
            )
        } else {
            startCmd = terminalStartCommand(
                envExports: envExports,
                workingDirectory: worktreePath
            )
        }
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: worktreePath,
            command: startCmd
        )

        // Also set on the tmux session so new panes/windows inherit them
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_PATH", value: worktreePath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: project.name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_THREAD_ID", value: threadID.uuidString)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
        if let selectedAgentType {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_AGENT_TYPE", value: selectedAgentType.rawValue)
        }

        let thread = MagentThread(
            id: threadID,
            projectId: project.id,
            name: name,
            worktreePath: worktreePath,
            branchName: branchName,
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: useAgentCommand && selectedAgentType != nil ? [tmuxSessionName] : [],
            sessionAgentTypes: selectedAgentType.map { [tmuxSessionName: $0] } ?? [:],
            sectionId: settings.defaultSection(for: project.id)?.id,
            lastSelectedTmuxSessionName: tmuxSessionName,
            customTabNames: [tmuxSessionName: firstTabDisplayName],
            baseBranch: baseBranch,
            submittedPromptsBySession: {
                guard useAgentCommand,
                      let initialPrompt,
                      !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return [:]
                }
                return [tmuxSessionName: [
                    initialPrompt
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                ]]
            }(),
            localFileSyncPathsSnapshot: localFileSyncPathsSnapshot
        )

        threads.append(thread)

        // Place at the bottom of the default section's visible group.
        if let lastIndex = threads.indices.last {
            placeThreadAtBottomOfSidebarGroup(threadId: threads[lastIndex].id)
        }

        try persistence.saveActiveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: thread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, initialPrompt: initialPrompt, agentType: selectedAgentType)
        if initialPrompt?.isEmpty == false, useAgentCommand {
            scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: tmuxSessionName)
        }

        return thread
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let settings = persistence.loadSettings()
        let threadID = UUID()
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
        let envExports = "export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(project.name) && export MAGENT_THREAD_ID=\(threadID.uuidString) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
        let startCmd = agentStartCommand(
            settings: settings,
            projectId: project.id,
            agentType: selectedAgentType,
            envExports: envExports,
            workingDirectory: project.repoPath
        )
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: project.repoPath,
            command: startCmd
        )
        // Main thread is always an agent session.

        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: "main")
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: project.name)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_THREAD_ID", value: threadID.uuidString)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
        if let selectedAgentType {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_AGENT_TYPE", value: selectedAgentType.rawValue)
        }

        let thread = MagentThread(
            id: threadID,
            projectId: project.id,
            name: "main",
            worktreePath: project.repoPath,
            branchName: "",
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: selectedAgentType != nil ? [tmuxSessionName] : [],
            sessionAgentTypes: selectedAgentType.map { [tmuxSessionName: $0] } ?? [:],
            isMain: true,
            lastSelectedTmuxSessionName: tmuxSessionName,
            customTabNames: [tmuxSessionName: firstTabDisplayName]
        )

        // Insert main threads at front
        threads.insert(thread, at: 0)
        try persistence.saveActiveThreads(threads)
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

    func archiveThread(
        _ thread: MagentThread,
        promptForLocalSyncConflicts: Bool = false,
        force: Bool = false,
        syncLocalPathsBackToRepo: Bool? = nil
    ) async throws -> String? {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        var archiveWarning: String?
        let settings = persistence.loadSettings()
        let shouldSyncLocalPathsBackToRepo = syncLocalPathsBackToRepo ?? settings.syncLocalPathsOnArchive
        if shouldSyncLocalPathsBackToRepo, let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            do {
                try await syncConfiguredLocalPathsFromWorktree(
                    project: project,
                    worktreePath: thread.worktreePath,
                    syncPaths: effectiveLocalSyncPaths(for: thread, project: project),
                    promptForConflicts: promptForLocalSyncConflicts
                )
            } catch ThreadManagerError.archiveCancelled {
                throw ThreadManagerError.archiveCancelled
            } catch ThreadManagerError.localFileSyncFailed(let message) {
                guard force else {
                    throw ThreadManagerError.localFileSyncFailed(message)
                }
                archiveWarning = "Archived without completing local sync: \(message)"
            }
        }

        if let ticketKey = thread.jiraTicketKey {
            excludeJiraTicket(key: ticketKey, projectId: thread.projectId)
        }

        let archivedAt = Date()

        // Remove from active list
        threads.removeAll { $0.id == thread.id }

        // Mark as archived in persistence
        var allThreads = persistence.loadThreads()
        if let i = allThreads.firstIndex(where: { $0.id == thread.id }) {
            allThreads[i].isArchived = true
            allThreads[i].archivedAt = archivedAt
            clearPersistedSessionState(for: &allThreads[i])
        }
        try persistence.saveThreads(allThreads)
        await MainActor.run {
            NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
        }

        await MainActor.run {
            delegate?.threadManager(self, didArchiveThread: thread)
        }

        // Cleanup after UI has switched away from this thread.
        for sessionName in thread.tmuxSessionNames {
            try? await tmux.killSession(name: sessionName)
        }

        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
            pruneWorktreeCache(for: project)
        }

        cleanupAllBrokenSymlinks()
        await cleanupStaleMagentSessions()
        showArchivedThreadBanner(for: thread, warning: archiveWarning)

        return archiveWarning
    }

    func restoreArchivedThread(id threadId: UUID) async throws -> MagentThread {
        if let existing = threads.first(where: { $0.id == threadId }) {
            return existing
        }

        let settings = persistence.loadSettings()
        var allThreads = persistence.loadThreads()
        guard let archivedIndex = allThreads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }

        var restoredThread = allThreads[archivedIndex]
        guard restoredThread.isArchived else {
            throw ThreadManagerError.duplicateName
        }

        guard let project = settings.projects.first(where: { $0.id == restoredThread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }

        if threads.contains(where: { $0.projectId == restoredThread.projectId && $0.name == restoredThread.name }) {
            throw ThreadManagerError.duplicateName
        }

        await git.pruneWorktrees(repoPath: project.repoPath)

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: restoredThread.branchName)
        if branchExists {
            _ = try await git.addWorktreeForExistingBranch(
                repoPath: project.repoPath,
                branchName: restoredThread.branchName,
                worktreePath: restoredThread.worktreePath
            )
        } else {
            let persistedBaseBranch = restoredThread.baseBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch: String?
            if let persistedBaseBranch, !persistedBaseBranch.isEmpty {
                baseBranch = persistedBaseBranch
            } else if let projectDefault = project.defaultBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !projectDefault.isEmpty {
                baseBranch = projectDefault
            } else {
                baseBranch = nil
            }
            _ = try await git.createWorktree(
                repoPath: project.repoPath,
                branchName: restoredThread.branchName,
                worktreePath: restoredThread.worktreePath,
                baseBranch: baseBranch
            )
        }

        restoredThread.isArchived = false
        restoredThread.archivedAt = nil
        clearPersistedSessionState(for: &restoredThread)
        restoredThread.unreadCompletionSessions.removeAll()
        restoredThread.lastAgentCompletionAt = nil
        restoredThread.isDirty = false
        restoredThread.isFullyDelivered = false
        restoredThread.jiraUnassigned = false
        restoredThread.actualBranch = nil
        restoredThread.expectedBranch = nil
        restoredThread.hasBranchMismatch = false
        restoredThread.rateLimitedSessions = [:]
        restoredThread.pullRequestInfo = nil
        restoredThread.busySessions.removeAll()
        restoredThread.waitingForInputSessions.removeAll()

        allThreads[archivedIndex] = restoredThread
        try persistence.saveThreads(allThreads)
        await MainActor.run {
            NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
        }

        threads.append(restoredThread)
        bumpThreadToTopOfSection(restoredThread.id)
        if let restoredActiveIndex = threads.firstIndex(where: { $0.id == restoredThread.id }) {
            restoredThread = threads[restoredActiveIndex]
            allThreads[archivedIndex] = restoredThread
        }
        try persistence.saveThreads(allThreads)

        trustDirectoryIfNeeded(restoredThread.worktreePath, agentType: effectiveAgentType(for: restoredThread.projectId))
        pruneWorktreeCache(for: project)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
            BannerManager.shared.show(
                attributedMessage: restoredThreadBannerAttributedMessage(for: restoredThread),
                style: .info,
                duration: Self.archivedThreadBannerDuration
            )
            NotificationCenter.default.post(
                name: .magentNavigateToThread,
                object: nil,
                userInfo: ["threadId": restoredThread.id]
            )
        }

        return restoredThread
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
            threads[index].sessionConversationIDs = [:]
            threads[index].submittedPromptsBySession = [:]
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
                let persistedBaseBranch = threads[index].baseBranch?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let baseBranch: String?
                if let persistedBaseBranch, !persistedBaseBranch.isEmpty {
                    baseBranch = persistedBaseBranch
                } else if let projectDefault = project.defaultBranch?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                          !projectDefault.isEmpty {
                    baseBranch = projectDefault
                } else {
                    baseBranch = nil
                }
                _ = try await git.createWorktree(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath,
                    baseBranch: baseBranch
                )
            }

            // Trust the directory for the agent if needed
            trustDirectoryIfNeeded(thread.worktreePath, agentType: effectiveAgentType(for: thread.projectId))

            // Persist updated threads
            try persistence.saveActiveThreads(threads)

            return .recovered
        } catch {
            return .failed(error)
        }
    }

    private func clearPersistedSessionState(for thread: inout MagentThread) {
        thread.tmuxSessionNames = []
        thread.agentTmuxSessions = []
        thread.sessionConversationIDs = [:]
        thread.sessionAgentTypes = [:]
        thread.pinnedTmuxSessions = []
        thread.lastSelectedTmuxSessionName = nil
        thread.customTabNames = [:]
        thread.submittedPromptsBySession = [:]
    }

    private func archivedThreadBannerAttributedMessage(
        for thread: MagentThread,
        warning: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Header line: "Thread archived"
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        ]
        result.append(NSAttributedString(string: "Thread archived\n", attributes: headerAttrs))

        // Description or thread name — prominent
        let titleText: String
        if let desc = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            titleText = desc
        } else {
            titleText = thread.name
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        result.append(NSAttributedString(string: titleText, attributes: titleAttrs))

        // Branch · worktree — secondary monospace line
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
        ]
        let worktreeName = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        result.append(NSAttributedString(string: "\n\(thread.branchName)  ·  \(worktreeName)", attributes: secondaryAttrs))

        // Warning line if present
        if let warning, !warning.isEmpty {
            let warningAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
            result.append(NSAttributedString(string: "\n⚠ \(warning)", attributes: warningAttrs))
        }

        return result
    }

    private func archivedThreadBannerDetails(
        for thread: MagentThread,
        projectName: String
    ) -> String {
        var lines: [String] = []
        lines.append("Project: \(projectName)")
        if let baseBranch = thread.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baseBranch.isEmpty {
            lines.append("Base: \(baseBranch)")
        }
        if AppFeatures.jiraIntegrationEnabled,
           let ticketKey = thread.jiraTicketKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketKey.isEmpty {
            lines.append("Jira: \(ticketKey)")
        }
        lines.append("Tabs: \(thread.tmuxSessionNames.count)")
        lines.append("Worktree: \(thread.worktreePath)")
        return lines.joined(separator: "\n")
    }

    private func restoredThreadBannerAttributedMessage(for thread: MagentThread) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        ]
        result.append(NSAttributedString(string: "Thread restored\n", attributes: headerAttrs))

        let titleText: String
        if let desc = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            titleText = desc
        } else {
            titleText = thread.name
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        result.append(NSAttributedString(string: titleText, attributes: titleAttrs))

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
        ]
        let worktreeName = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        result.append(NSAttributedString(string: "\n\(thread.branchName)  ·  \(worktreeName)", attributes: secondaryAttrs))

        return result
    }

    func restoreArchivedThreadFromUserAction(id threadId: UUID, threadName: String) async -> Bool {
        do {
            _ = try await restoreArchivedThread(id: threadId)
            return true
        } catch {
            await MainActor.run {
                BannerManager.shared.show(
                    message: "Failed to restore thread '\(threadName)': \(error.localizedDescription)",
                    style: .error,
                    duration: Self.archivedThreadBannerDuration
                )
            }
            return false
        }
    }

    private func showArchivedThreadBanner(for thread: MagentThread, warning: String?) {
        let projectName = persistence.loadSettings()
            .projects
            .first(where: { $0.id == thread.projectId })?
            .name ?? "Unknown Project"

        let attributed = archivedThreadBannerAttributedMessage(for: thread, warning: warning)
        let details = archivedThreadBannerDetails(for: thread, projectName: projectName)

        Task { @MainActor [weak self] in
            BannerManager.shared.show(
                attributedMessage: attributed,
                style: warning == nil ? .info : .warning,
                duration: Self.archivedThreadBannerDuration,
                isDismissible: true,
                actions: [
                    BannerAction(title: "Restore") { [weak self] in
                        Task { [weak self] in
                            _ = await self?.restoreArchivedThreadFromUserAction(id: thread.id, threadName: thread.name)
                        }
                    }
                ],
                details: details,
                detailsCollapsedTitle: "More Info",
                detailsExpandedTitle: "Less Info"
            )
        }
    }
}
