import Foundation

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

    private let persistence = PersistenceService.shared
    private let git = GitService.shared
    private let tmux = TmuxService.shared

    private(set) var threads: [MagentThread] = []

    // MARK: - Lifecycle

    func loadThreads() {
        threads = persistence.loadThreads().filter { !$0.isArchived }
    }

    func restoreThreads() async {
        loadThreads()

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
        }

        // Do NOT prune dead tmux session names — the attach-or-create pattern
        // in ThreadDetailViewController will recreate them when the user opens the thread.

        try? persistence.saveThreads(threads)

        // Ensure every project has a main thread
        await ensureMainThreads()

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    // MARK: - Thread Creation

    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true
    ) async throws -> MagentThread {
        // Generate a unique name that doesn't conflict with existing worktrees, branches, or tmux sessions
        var name = NameGenerator.generate()
        var foundUnique = false
        for _ in 0..<5 {
            let branchCandidate = name
            let worktreeCandidate = "\(project.worktreesBasePath)/\(name)"
            let tmuxCandidate = "magent-\(name)"

            let nameInUse = threads.contains(where: { $0.name == name })
            let dirExists = FileManager.default.fileExists(atPath: worktreeCandidate)
            let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: branchCandidate)
            let tmuxExists = await tmux.hasSession(name: tmuxCandidate)

            if !nameInUse && !dirExists && !branchExists && !tmuxExists {
                foundUnique = true
                break
            }
            name = NameGenerator.generate()
        }
        guard foundUnique else {
            throw ThreadManagerError.nameGenerationFailed
        }

        let branchName = name
        let worktreePath = "\(project.worktreesBasePath)/\(name)"
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
        let envExports = "export WORKTREE_PATH=\(worktreePath) && export PROJECT_PATH=\(project.repoPath) && export WORKTREE_NAME=\(name)"
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

        // Also set on the tmux session so new panes/windows inherit them
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_PATH", value: worktreePath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_NAME", value: name)

        let thread = MagentThread(
            projectId: project.id,
            name: name,
            worktreePath: worktreePath,
            branchName: branchName,
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: useAgentCommand && selectedAgentType != nil ? [tmuxSessionName] : [],
            sectionId: settings.defaultSection?.id,
            selectedAgentType: selectedAgentType,
            lastSelectedTmuxSessionName: tmuxSessionName
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
        let envExports = "export PROJECT_PATH=\(project.repoPath) && export WORKTREE_NAME=main"
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

        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "PROJECT_PATH", value: project.repoPath)
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_NAME", value: "main")

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

        // Find the next unused tab index — check both model and live tmux sessions
        let existingNames = threads[index].tmuxSessionNames
        var tabIndex = existingNames.count
        let settings = persistence.loadSettings()

        let tmuxSessionName: String
        let startCmd: String

        var selectedAgentType = thread.selectedAgentType
        if thread.isMain {
            let sanitizedName = Self.sanitizeForTmux(
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            var candidate = "magent-main-\(sanitizedName)-tab-\(tabIndex)"
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                tabIndex += 1
                candidate = "magent-main-\(sanitizedName)-tab-\(tabIndex)"
            }
            tmuxSessionName = candidate
            let projectPath = thread.worktreePath
            let envExports = "export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=main"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: thread.projectId,
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
            var candidate = "magent-\(thread.name)-tab-\(tabIndex)"
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                tabIndex += 1
                candidate = "magent-\(thread.name)-tab-\(tabIndex)"
            }
            tmuxSessionName = candidate
            let projectPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath ?? thread.worktreePath
            let envExports = "export WORKTREE_PATH=\(thread.worktreePath) && export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=\(thread.name)"
            if useAgentCommand {
                selectedAgentType = resolveAgentType(
                    for: thread.projectId,
                    requestedAgentType: requestedAgentType ?? thread.selectedAgentType,
                    settings: settings
                )
                startCmd = agentStartCommand(
                    settings: settings,
                    agentType: selectedAgentType,
                    envExports: envExports,
                    workingDirectory: thread.worktreePath
                )
            } else {
                startCmd = "\(envExports) && cd \(thread.worktreePath) && exec zsh -l"
            }
        }

        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: thread.worktreePath,
            command: startCmd
        )

        if thread.isMain {
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "PROJECT_PATH", value: thread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_NAME", value: "main")
        } else {
            let projectPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath ?? thread.worktreePath
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_PATH", value: thread.worktreePath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "WORKTREE_NAME", value: thread.name)
        }

        threads[index].tmuxSessionNames.append(tmuxSessionName)
        let shouldMarkAsAgentTab = (thread.isMain || useAgentCommand) && selectedAgentType != nil
        if shouldMarkAsAgentTab {
            threads[index].agentTmuxSessions.append(tmuxSessionName)
        }
        if selectedAgentType != nil {
            threads[index].selectedAgentType = selectedAgentType
        }
        try persistence.saveThreads(threads)

        let tab = Tab(
            threadId: thread.id,
            tmuxSessionName: tmuxSessionName,
            index: tabIndex
        )

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        // Inject terminal command (always) and agent context (only for agent tabs)
        let injection = effectiveInjection(for: thread.projectId)
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

    // MARK: - Section Management

    @MainActor
    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].sectionId = sectionId
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

    // MARK: - Rename

    func renameThread(_ thread: MagentThread, to newName: String) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw ThreadManagerError.invalidName
        }
        guard !threads.contains(where: { $0.name == trimmed && $0.id != thread.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let oldName = thread.name
        let newBranchName = trimmed
        let oldWorktreePath = thread.worktreePath
        let parentDir = (oldWorktreePath as NSString).deletingLastPathComponent
        let newWorktreePath = (parentDir as NSString).appendingPathComponent(trimmed)

        // Look up project for repo path
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }

        // Check for conflicts with existing worktree directory, git branch, and tmux sessions
        if FileManager.default.fileExists(atPath: newWorktreePath) {
            throw ThreadManagerError.duplicateName
        }
        if await git.branchExists(repoPath: project.repoPath, branchName: newBranchName) {
            throw ThreadManagerError.duplicateName
        }
        let newPrimarySession = "magent-\(trimmed)"
        if await tmux.hasSession(name: newPrimarySession) {
            throw ThreadManagerError.duplicateName
        }

        // 1. Rename git branch
        try await git.renameBranch(repoPath: project.repoPath, oldName: thread.branchName, newName: newBranchName)

        // 2. Move worktree (physically moves directory, running processes keep working)
        try await git.moveWorktree(repoPath: project.repoPath, oldPath: oldWorktreePath, newPath: newWorktreePath)

        // 3. Rename each tmux session
        var newSessionNames: [String] = []
        for sessionName in thread.tmuxSessionNames {
            let newSessionName = sessionName.replacingOccurrences(of: oldName, with: trimmed)
            try? await tmux.renameSession(from: sessionName, to: newSessionName)
            newSessionNames.append(newSessionName)
        }

        // 4. Update pinned and agent sessions to reflect new names
        var newPinnedSessions: [String] = []
        for pinnedName in thread.pinnedTmuxSessions {
            newPinnedSessions.append(pinnedName.replacingOccurrences(of: oldName, with: trimmed))
        }
        var newAgentSessions: [String] = []
        for agentName in thread.agentTmuxSessions {
            newAgentSessions.append(agentName.replacingOccurrences(of: oldName, with: trimmed))
        }

        // 5. Update env vars on each session
        for sessionName in newSessionNames {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_PATH", value: newWorktreePath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_NAME", value: trimmed)
        }

        // 6. Trust new path for the agent if needed
        trustDirectoryIfNeeded(newWorktreePath, agentType: thread.selectedAgentType)

        // 7. Update model fields and persist
        threads[index].name = trimmed
        threads[index].branchName = newBranchName
        threads[index].worktreePath = newWorktreePath
        threads[index].tmuxSessionNames = newSessionNames
        threads[index].agentTmuxSessions = newAgentSessions
        threads[index].pinnedTmuxSessions = newPinnedSessions
        if let selectedName = threads[index].lastSelectedTmuxSessionName {
            threads[index].lastSelectedTmuxSessionName = selectedName.replacingOccurrences(of: oldName, with: trimmed)
        }

        try persistence.saveThreads(threads)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
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

        // Also remove from pinned and agent sessions if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].agentTmuxSessions.removeAll { $0 == sessionName }
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

    // MARK: - Injection

    private func effectiveInjection(for projectId: UUID) -> (terminalCommand: String, agentContext: String) {
        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == projectId })
        let termCmd = (project?.terminalInjectionCommand?.isEmpty == false)
            ? project!.terminalInjectionCommand! : settings.terminalInjectionCommand
        let agentCtx = (project?.agentContextInjection?.isEmpty == false)
            ? project!.agentContextInjection! : settings.agentContextInjection
        return (termCmd, agentCtx)
    }

    private func injectAfterStart(sessionName: String, terminalCommand: String, agentContext: String) {
        guard !terminalCommand.isEmpty || !agentContext.isEmpty else { return }
        Task {
            // Wait for shell/agent to initialize
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !terminalCommand.isEmpty {
                try? await tmux.sendKeys(sessionName: sessionName, keys: terminalCommand)
            }
            if !agentContext.isEmpty {
                // Additional delay if we also sent a terminal command
                if !terminalCommand.isEmpty {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                try? await tmux.sendKeys(sessionName: sessionName, keys: agentContext)
            }
        }
    }

    // MARK: - Agent Type

    func effectiveAgentType(for projectId: UUID) -> AgentType? {
        let settings = persistence.loadSettings()
        return resolveAgentType(for: projectId, requestedAgentType: nil, settings: settings)
    }

    // MARK: - Session Recreation

    private var sessionsBeingRecreated: Set<String> = []

    /// Checks if a tmux session is dead and recreates it if so.
    /// Returns true if the session was recreated.
    func recreateSessionIfNeeded(
        sessionName: String,
        thread: MagentThread,
        thenResume: Bool
    ) async -> Bool {
        // Skip if already being recreated or still alive
        guard !sessionsBeingRecreated.contains(sessionName) else { return false }
        if await tmux.hasSession(name: sessionName) { return false }

        sessionsBeingRecreated.insert(sessionName)
        defer { sessionsBeingRecreated.remove(sessionName) }

        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectPath = project?.repoPath ?? thread.worktreePath
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)

        let startCmd: String
        let sessionAgentType = thread.selectedAgentType ?? effectiveAgentType(for: thread.projectId)
        if isAgentSession {
            let envExports: String
            if thread.isMain {
                envExports = "export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=main"
            } else {
                envExports = "export WORKTREE_PATH=\(thread.worktreePath) && export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=\(thread.name)"
            }
            startCmd = agentStartCommand(
                settings: settings,
                agentType: sessionAgentType,
                envExports: envExports,
                workingDirectory: thread.worktreePath
            )
        } else {
            let envExports: String
            if thread.isMain {
                envExports = "export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=main"
            } else {
                envExports = "export WORKTREE_PATH=\(thread.worktreePath) && export PROJECT_PATH=\(projectPath) && export WORKTREE_NAME=\(thread.name)"
            }
            startCmd = "\(envExports) && cd \(thread.worktreePath) && exec zsh -l"
        }

        try? await tmux.createSession(
            name: sessionName,
            workingDirectory: thread.worktreePath,
            command: startCmd
        )

        // Set tmux environment variables
        if thread.isMain {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_NAME", value: "main")
        } else {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_PATH", value: thread.worktreePath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "PROJECT_PATH", value: projectPath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_NAME", value: thread.name)
        }

        // Run normal injection (terminal command + agent context)
        let injection = effectiveInjection(for: thread.projectId)
        injectAfterStart(
            sessionName: sessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentSession ? injection.agentContext : ""
        )

        // For Claude agent sessions, inject /resume to restore the conversation
        if thenResume && isAgentSession {
            let agentType = sessionAgentType
            if agentType?.supportsResume == true {
                injectResume(sessionName: sessionName)
            }
        }

        return true
    }

    private func injectResume(sessionName: String) {
        Task {
            let maxWait: TimeInterval = 20
            let pollInterval: UInt64 = 500_000_000
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < maxWait {
                try? await Task.sleep(nanoseconds: pollInterval)
                let result = await ShellExecutor.execute(
                    "tmux capture-pane -t '\(sessionName)' -p 2>/dev/null"
                )
                guard result.exitCode == 0 else { continue }
                let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.contains("╭") || output.contains("Claude") || output.count > 50 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    try? await tmux.sendKeys(sessionName: sessionName, keys: "/resume")
                    return
                }
            }
            // Timed out — best-effort attempt
            try? await tmux.sendKeys(sessionName: sessionName, keys: "/resume")
        }
    }

    // MARK: - Session Monitor

    private var sessionMonitorTimer: Timer?

    func startSessionMonitor() {
        guard sessionMonitorTimer == nil else { return }
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.checkForDeadSessions() }
        }
    }

    func stopSessionMonitor() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
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
                    thread: thread,
                    thenResume: true
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

    // MARK: - Helpers

    /// Builds the shell command to start the selected agent with any required agent-specific setup.
    private func agentStartCommand(
        settings: AppSettings,
        agentType: AgentType?,
        envExports: String,
        workingDirectory: String
    ) -> String {
        var parts = [envExports, "cd \(workingDirectory)"]
        guard let agentType else {
            parts.append("exec zsh -l")
            return parts.joined(separator: " && ")
        }
        if agentType == .claude {
            parts.append("unset CLAUDECODE")
        }
        parts.append(settings.command(for: agentType))
        return parts.joined(separator: " && ")
    }

    /// Runs agent-specific post-setup (e.g. pre-trusting directories for Claude Code).
    private func trustDirectoryIfNeeded(_ path: String, agentType: AgentType?) {
        switch agentType {
        case .claude:
            ClaudeTrustHelper.trustDirectory(path)
        case .codex:
            CodexTrustHelper.trustDirectory(path)
        case .custom, .none:
            break
        }
    }

    private func resolveAgentType(
        for projectId: UUID,
        requestedAgentType: AgentType?,
        settings: AppSettings
    ) -> AgentType? {
        let activeAgents = settings.availableActiveAgents
        guard !activeAgents.isEmpty else { return nil }
        if activeAgents.count == 1 {
            return activeAgents[0]
        }
        if let requestedAgentType, activeAgents.contains(requestedAgentType) {
            return requestedAgentType
        }

        let project = settings.projects.first(where: { $0.id == projectId })
        if let projectDefault = project?.agentType, activeAgents.contains(projectDefault) {
            return projectDefault
        }
        if let globalDefault = settings.effectiveGlobalDefaultAgentType, activeAgents.contains(globalDefault) {
            return globalDefault
        }
        return activeAgents[0]
    }

    private func isTabNameTaken(_ name: String, existingNames: [String]) async -> Bool {
        if existingNames.contains(name) { return true }
        return await tmux.hasSession(name: name)
    }

    static func sanitizeForTmux(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .lowercased()
    }
}

extension Notification.Name {
    static let magentDeadSessionsDetected = Notification.Name("magentDeadSessionsDetected")
}

enum ThreadManagerError: LocalizedError {
    case threadNotFound
    case invalidName
    case duplicateName
    case invalidTabIndex
    case cannotDeleteMainThread
    case nameGenerationFailed

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "Thread not found"
        case .invalidName:
            return "Invalid name. Name must not be empty or contain slashes."
        case .duplicateName:
            return "A thread with that name already exists."
        case .invalidTabIndex:
            return "Invalid tab index."
        case .cannotDeleteMainThread:
            return "Main threads cannot be deleted."
        case .nameGenerationFailed:
            return "Could not generate a unique thread name. Try again or clean up unused worktrees/branches."
        }
    }
}
