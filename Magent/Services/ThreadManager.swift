import AppKit
import Foundation
import UserNotifications

@MainActor
protocol ThreadManagerDelegate: AnyObject {
    func threadManager(_ manager: ThreadManager, didCreateThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didArchiveThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didDeleteThread thread: MagentThread)
    func threadManager(_ manager: ThreadManager, didUpdateThreads threads: [MagentThread])
}

final class ThreadManager {

    static let shared = ThreadManager()

    weak var delegate: ThreadManagerDelegate?

    let persistence = PersistenceService.shared
    let git = GitService.shared
    let tmux = TmuxService.shared

    var threads: [MagentThread] = []
    var activeThreadId: UUID?
    var recentBellBySession: [String: Date] = [:]
    var autoRenameInProgress: Set<UUID> = []
    var pendingCwdEnforcements: [String: PendingCwdEnforcement] = [:]
    /// Dedup tracker — prevents repeated "waiting for input" notifications for the same session.
    var notifiedWaitingSessions: Set<String> = []
    var sessionsBeingRecreated: Set<String> = []
    var sessionMonitorTimer: Timer?
    var lastTmuxZombieHealthCheckAt: Date = .distantPast
    var didShowTmuxZombieWarning = false
    var isRestartingTmuxForRecovery = false
    var dirtyCheckTickCounter: Int = 0

    // MARK: - Lifecycle

    func loadThreads() {
        threads = persistence.loadThreads().filter { !$0.isArchived }
    }

    func restoreThreads() async {
        loadThreads()
        installClaudeHooksSettings()
        ensureCodexBellNotification()

        // Migrate old threads that have no agentTmuxSessions recorded.
        // Heuristic: the first session was always created as the agent tab.
        let settings = persistence.loadSettings()
        for i in threads.indices {
            if threads[i].agentTmuxSessions.isEmpty && !threads[i].tmuxSessionNames.isEmpty {
                threads[i].agentTmuxSessions = [threads[i].tmuxSessionNames[0]]
            }
            if threads[i].selectedAgentType == nil && !threads[i].agentTmuxSessions.isEmpty {
                threads[i].selectedAgentType = resolveAgentType(
                    for: threads[i].projectId,
                    requestedAgentType: nil,
                    settings: settings
                )
            }
            // Migrate: existing threads with agent sessions must have had the agent run.
            if !threads[i].agentHasRun && !threads[i].agentTmuxSessions.isEmpty {
                threads[i].agentHasRun = true
            }
        }

        // Do NOT prune dead tmux session names — the attach-or-create pattern
        // in ThreadDetailViewController will recreate them when the user opens the thread.

        try? persistence.saveThreads(threads)

        // Sync threads with worktrees on disk for each valid project
        for project in settings.projects where project.isValid {
            await syncThreadsWithWorktrees(for: project)
        }

        // Ensure every project has a main thread
        await ensureMainThreads()

        // Remove orphaned Magent tmux sessions that no longer map to an active thread/tab.
        await cleanupStaleMagentSessions()

        // Set up bell detection pipes on all live agent sessions.
        await ensureBellPipes()

        // Sync busy state from actual tmux processes so spinners show immediately
        // after restart (busySessions is transient and starts empty on launch).
        await syncBusySessionsFromProcessState()

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    /// Ensures every live agent tmux session has a pipe-pane bell watcher set up.
    /// Called at startup and periodically from the session monitor.
    func ensureBellPipes() async {
        let pipedSessions = await tmux.sessionsWithActivePipe()
        for thread in threads where !thread.isArchived {
            for sessionName in thread.agentTmuxSessions {
                guard !pipedSessions.contains(sessionName) else { continue }
                // Only set up if the session is actually alive
                guard await tmux.hasSession(name: sessionName) else { continue }
                await tmux.setupBellPipe(for: sessionName)
            }
        }
    }

    // MARK: - Thread Creation

    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true
    ) async throws -> MagentThread {
        // Generate a unique name that doesn't conflict with existing worktrees, branches, or tmux sessions.
        // For each random base name, try the bare name first, then numeric suffixes (-2, -3, …).
        // If all suffixes are taken, generate a new random base and repeat.
        var name = ""
        var foundUnique = false
        for _ in 0..<5 {
            let baseName = NameGenerator.generate()
            let candidates = [baseName] + (2...9).map { "\(baseName)-\($0)" }
            for candidate in candidates {
                // Fast in-memory / filesystem checks first
                let nameInUse = threads.contains(where: { $0.name == candidate })
                let dirExists = FileManager.default.fileExists(
                    atPath: "\(project.resolvedWorktreesBasePath())/\(candidate)"
                )
                guard !nameInUse && !dirExists else { continue }

                // Expensive checks only when fast checks pass
                let branchExists = await git.branchExists(
                    repoPath: project.repoPath, branchName: candidate
                )
                let tmuxExists = await tmux.hasSession(name: "magent-\(candidate)")
                if !branchExists && !tmuxExists {
                    name = candidate
                    foundUnique = true
                    break
                }
            }
            if foundUnique { break }
        }
        guard foundUnique else {
            throw ThreadManagerError.nameGenerationFailed
        }

        let branchName = name
        let worktreePath = "\(project.resolvedWorktreesBasePath())/\(name)"
        let tmuxSessionName = "magent-\(name)"

        // Create git worktree branching off the project's default branch
        let baseBranch = project.defaultBranch?.isEmpty == false ? project.defaultBranch : nil
        _ = try await git.createWorktree(
            repoPath: project.repoPath,
            branchName: branchName,
            worktreePath: worktreePath,
            baseBranch: baseBranch
        )

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

        // Pre-trust the worktree directory so the selected agent doesn't show a trust dialog
        trustDirectoryIfNeeded(worktreePath, agentType: selectedAgentType)

        // Create tmux session with selected agent command (or shell if no active agents)
        let envExports = "export MAGENT_WORKTREE_PATH=\(worktreePath) && export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=\(name) && export MAGENT_PROJECT_NAME=\(project.name)"
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

        let thread = MagentThread(
            projectId: project.id,
            name: name,
            worktreePath: worktreePath,
            branchName: branchName,
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: useAgentCommand && selectedAgentType != nil ? [tmuxSessionName] : [],
            sectionId: settings.defaultSection?.id,
            selectedAgentType: selectedAgentType,
            lastSelectedTmuxSessionName: tmuxSessionName,
            baseBranch: baseBranch
        )

        threads.append(thread)
        try persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: thread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext)

        return thread
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let sanitizedName = Self.sanitizeForTmux(project.name)
        let tmuxSessionName = "magent-main-\(sanitizedName)"

        // Kill orphaned tmux session if it exists from a previous run
        if await tmux.hasSession(name: tmuxSessionName) {
            try? await tmux.killSession(name: tmuxSessionName)
        }

        let settings = persistence.loadSettings()
        let selectedAgentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)
        trustDirectoryIfNeeded(project.repoPath, agentType: selectedAgentType)
        let envExports = "export MAGENT_PROJECT_PATH=\(project.repoPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(project.name)"
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

        let thread = MagentThread(
            projectId: project.id,
            name: "main",
            worktreePath: project.repoPath,
            branchName: "",
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: selectedAgentType != nil ? [tmuxSessionName] : [],
            isMain: true,
            selectedAgentType: selectedAgentType,
            lastSelectedTmuxSessionName: tmuxSessionName
        )

        // Insert main threads at front
        threads.insert(thread, at: 0)
        try persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: thread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext)

        return thread
    }

    private func ensureMainThreads() async {
        let settings = persistence.loadSettings()
        for project in settings.projects {
            if !threads.contains(where: { $0.isMain && $0.projectId == project.id }) {
                _ = try? await createMainThread(project: project)
            }
        }
    }

    // MARK: - Tab Management

    func addTab(
        to thread: MagentThread,
        useAgentCommand: Bool = false,
        requestedAgentType: AgentType? = nil
    ) async throws -> Tab {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]

        // Find the next unused tab index — check both model and live tmux sessions
        let existingNames = currentThread.tmuxSessionNames
        var tabIndex = existingNames.count
        let settings = persistence.loadSettings()

        let tmuxSessionName: String
        let startCmd: String

        var selectedAgentType = currentThread.selectedAgentType
        if currentThread.isMain {
            let sanitizedName = Self.sanitizeForTmux(
                settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            )
            var candidate = "magent-main-\(sanitizedName)-tab-\(tabIndex)"
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                tabIndex += 1
                candidate = "magent-main-\(sanitizedName)-tab-\(tabIndex)"
            }
            tmuxSessionName = candidate
            let projectPath = currentThread.worktreePath
            let projectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            let envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName)"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType,
                    settings: settings
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    agentType: selectedAgentType,
                    envExports: envExports,
                    workingDirectory: projectPath
                )
            } else {
                selectedAgentType = nil
                startCmd = "\(envExports) && cd \(projectPath) && exec zsh -l"
            }
        } else {
            var candidate = "magent-\(currentThread.name)-tab-\(tabIndex)"
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                tabIndex += 1
                candidate = "magent-\(currentThread.name)-tab-\(tabIndex)"
            }
            tmuxSessionName = candidate
            let project = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = project?.repoPath ?? currentThread.worktreePath
            let envExports = "export MAGENT_WORKTREE_PATH=\(currentThread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(currentThread.name) && export MAGENT_PROJECT_NAME=\(project?.name ?? "project")"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: currentThread.projectId,
                    requestedAgentType: requestedAgentType ?? currentThread.selectedAgentType,
                    settings: settings
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    agentType: selectedAgentType,
                    envExports: envExports,
                    workingDirectory: currentThread.worktreePath
                )
            } else {
                startCmd = "\(envExports) && cd \(currentThread.worktreePath) && exec zsh -l"
            }
        }

        if useAgentCommand {
            trustDirectoryIfNeeded(currentThread.worktreePath, agentType: selectedAgentType)
        }

        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: currentThread.worktreePath,
            command: startCmd
        )

        if currentThread.isMain {
            let mainProjectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: currentThread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: "main")
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: mainProjectName)
        } else {
            let tabProject = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = tabProject?.repoPath ?? currentThread.worktreePath
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_PATH", value: currentThread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_WORKTREE_NAME", value: currentThread.name)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_PROJECT_NAME", value: tabProject?.name ?? "project")
        }
        await tmux.updateWorkingDirectory(sessionName: tmuxSessionName, to: currentThread.worktreePath)
        enforceWorkingDirectoryAfterStartup(sessionName: tmuxSessionName, path: currentThread.worktreePath)

        threads[index].tmuxSessionNames.append(tmuxSessionName)
        let shouldMarkAsAgentTab = (currentThread.isMain || useAgentCommand) && selectedAgentType != nil
        if shouldMarkAsAgentTab {
            threads[index].agentTmuxSessions.append(tmuxSessionName)
            threads[index].agentHasRun = true
        }
        if selectedAgentType != nil {
            threads[index].selectedAgentType = selectedAgentType
        }
        try persistence.saveThreads(threads)

        let tab = Tab(
            threadId: currentThread.id,
            tmuxSessionName: tmuxSessionName,
            index: tabIndex
        )

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        // Inject terminal command (always) and agent context (only for agent tabs)
        let injection = effectiveInjection(for: currentThread.projectId)
        let isAgentTab = shouldMarkAsAgentTab
        injectAfterStart(
            sessionName: tmuxSessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentTab ? injection.agentContext : ""
        )

        return tab
    }

    func reorderTabs(for threadId: UUID, newOrder: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].tmuxSessionNames = newOrder
        try? persistence.saveThreads(threads)
    }

    func updatePinnedTabs(for threadId: UUID, pinnedSessions: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].pinnedTmuxSessions = pinnedSessions
        try? persistence.saveThreads(threads)
    }

    func updateLastSelectedSession(for threadId: UUID, sessionName: String?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        if threads[index].lastSelectedTmuxSessionName == sessionName { return }
        threads[index].lastSelectedTmuxSessionName = sessionName
        try? persistence.saveThreads(threads)
    }

    @MainActor
    func setActiveThread(_ threadId: UUID?) {
        activeThreadId = threadId
    }

    @MainActor
    func markThreadCompletionSeen(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].hasUnreadAgentCompletion else { return }
        threads[index].unreadCompletionSessions.removeAll()
        try? persistence.saveThreads(threads)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionCompletionSeen(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].unreadCompletionSessions.contains(sessionName) else { return }
        threads[index].unreadCompletionSessions.remove(sessionName)
        try? persistence.saveThreads(threads)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionWaitingSeen(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].waitingForInputSessions.contains(sessionName) else { return }
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    func markSessionBusy(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].agentTmuxSessions.contains(sessionName) else { return }
        // Clear waiting state — user submitted a prompt
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        guard !threads[index].busySessions.contains(sessionName) else { return }
        threads[index].busySessions.insert(sessionName)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    // MARK: - Dock Badge

    @MainActor
    func updateDockBadge() {
        let unreadCount = threads.filter({ !$0.isArchived && ($0.hasUnreadAgentCompletion || $0.hasWaitingForInput) }).count
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }

    // MARK: - Section Management

    @MainActor
    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].sectionId = sectionId
        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isPinned.toggle()
        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func reassignThreads(fromSection oldSectionId: UUID, toSection newSectionId: UUID) {
        var changed = false
        for i in threads.indices where threads[i].sectionId == oldSectionId {
            threads[i].sectionId = newSectionId
            changed = true
        }
        guard changed else { return }
        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }


    // MARK: - Close Tab

    func removeTab(from thread: MagentThread, at tabIndex: Int) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        guard tabIndex >= 0, tabIndex < threads[index].tmuxSessionNames.count else {
            throw ThreadManagerError.invalidTabIndex
        }

        let sessionName = threads[index].tmuxSessionNames[tabIndex]
        try? await tmux.killSession(name: sessionName)

        // Also remove from pinned, agent, unread completion, waiting, and custom tab names if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].agentTmuxSessions.removeAll { $0 == sessionName }
        threads[index].unreadCompletionSessions.remove(sessionName)
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].tmuxSessionNames.remove(at: tabIndex)
        if threads[index].lastSelectedTmuxSessionName == sessionName {
            threads[index].lastSelectedTmuxSessionName = threads[index].tmuxSessionNames.first
        }
        try persistence.saveThreads(threads)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    // MARK: - Archive Thread

    func archiveThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
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

    // MARK: - Base Branch & Dirty State

    func resolveBaseBranch(for thread: MagentThread) -> String {
        if let base = thread.baseBranch, !base.isEmpty {
            return base
        }
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }),
           let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
            return defaultBranch
        }
        return "main"
    }

    func refreshDirtyStates() async {
        var changed = false
        for i in threads.indices where !threads[i].isArchived && !threads[i].isMain {
            let dirty = await git.isDirty(worktreePath: threads[i].worktreePath)
            if threads[i].isDirty != dirty {
                threads[i].isDirty = dirty
                changed = true
            }
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    func refreshDiffStats(for threadId: UUID) async -> [FileDiffEntry] {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        let baseBranch = resolveBaseBranch(for: thread)
        return await git.diffStats(worktreePath: thread.worktreePath, baseBranch: baseBranch)
    }

}
