import Foundation

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

        // Verify which tmux sessions still exist
        for i in threads.indices {
            var thread = threads[i]
            var activeSessions: [String] = []
            for sessionName in thread.tmuxSessionNames {
                if await tmux.hasSession(name: sessionName) {
                    activeSessions.append(sessionName)
                }
            }
            thread.tmuxSessionNames = activeSessions
            threads[i] = thread
        }

        try? persistence.saveThreads(threads)

        // Ensure every project has a main thread
        await ensureMainThreads()

        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
    }

    // MARK: - Thread Creation

    func createThread(project: Project) async throws -> MagentThread {
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

        // Pre-trust the worktree directory so claude doesn't show the trust dialog
        ClaudeTrustHelper.trustDirectory(worktreePath)

        // Create tmux session with agent command as initial process
        let settings = persistence.loadSettings()
        let envExports = "export WORKTREE_PATH=\(worktreePath) && export PROJECT_PATH=\(project.repoPath) && export WORKTREE_NAME=\(name)"
        let startCmd = "\(envExports) && cd \(worktreePath) && unset CLAUDECODE && \(settings.agentCommand)"
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
            sectionId: settings.defaultSection?.id
        )

        threads.append(thread)
        try persistence.saveThreads(threads)
        let d = delegate
        DispatchQueue.main.async { d?.threadManager(self, didCreateThread: thread) }

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
        let envExports = "export PROJECT_PATH=\(project.repoPath) && export WORKTREE_NAME=main"
        let startCmd = "\(envExports) && cd \(project.repoPath) && unset CLAUDECODE && \(settings.agentCommand)"
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
            isMain: true
        )

        // Insert main threads at front
        threads.insert(thread, at: 0)
        try persistence.saveThreads(threads)
        let d = delegate
        DispatchQueue.main.async { d?.threadManager(self, didCreateThread: thread) }

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

    func addTab(to thread: MagentThread, useAgentCommand: Bool = false) async throws -> Tab {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        // Find the next unused tab index — check both model and live tmux sessions
        let existingNames = threads[index].tmuxSessionNames
        var tabIndex = existingNames.count
        let settings = persistence.loadSettings()

        let tmuxSessionName: String
        let startCmd: String

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
            startCmd = "\(envExports) && cd \(projectPath) && unset CLAUDECODE && \(settings.agentCommand)"
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
                startCmd = "\(envExports) && cd \(thread.worktreePath) && unset CLAUDECODE && \(settings.agentCommand)"
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
        try persistence.saveThreads(threads)

        let tab = Tab(
            threadId: thread.id,
            tmuxSessionName: tmuxSessionName,
            index: tabIndex
        )

        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
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

    // MARK: - Section Management

    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].sectionId = sectionId
        try? persistence.saveThreads(threads)
        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
    }

    func reassignThreads(fromSection oldSectionId: UUID, toSection newSectionId: UUID) {
        var changed = false
        for i in threads.indices where threads[i].sectionId == oldSectionId {
            threads[i].sectionId = newSectionId
            changed = true
        }
        guard changed else { return }
        try? persistence.saveThreads(threads)
        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
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

        // 4. Update pinned sessions to reflect new names
        var newPinnedSessions: [String] = []
        for pinnedName in thread.pinnedTmuxSessions {
            newPinnedSessions.append(pinnedName.replacingOccurrences(of: oldName, with: trimmed))
        }

        // 5. Update env vars on each session
        for sessionName in newSessionNames {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_PATH", value: newWorktreePath)
            try? await tmux.setEnvironment(sessionName: sessionName, key: "WORKTREE_NAME", value: trimmed)
        }

        // 6. Trust new path
        ClaudeTrustHelper.trustDirectory(newWorktreePath)

        // 7. Update model fields and persist
        threads[index].name = trimmed
        threads[index].branchName = newBranchName
        threads[index].worktreePath = newWorktreePath
        threads[index].tmuxSessionNames = newSessionNames
        threads[index].pinnedTmuxSessions = newPinnedSessions

        try persistence.saveThreads(threads)

        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
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

        // Also remove from pinned sessions if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].tmuxSessionNames.remove(at: tabIndex)
        try persistence.saveThreads(threads)

        let d = delegate
        let t = threads
        DispatchQueue.main.async { d?.threadManager(self, didUpdateThreads: t) }
    }

    // MARK: - Archive Thread

    func archiveThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        // Kill all tmux sessions
        for sessionName in thread.tmuxSessionNames {
            try? await tmux.killSession(name: sessionName)
        }

        // Remove git worktree but keep the branch
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
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

        let d = delegate
        DispatchQueue.main.async { d?.threadManager(self, didArchiveThread: thread) }
    }

    // MARK: - Delete Thread

    func deleteThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        // Kill all tmux sessions for this thread
        for sessionName in thread.tmuxSessionNames {
            try? await tmux.killSession(name: sessionName)
        }

        // Remove git worktree and delete branch
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
            if !thread.branchName.isEmpty {
                try? await git.deleteBranch(repoPath: project.repoPath, branchName: thread.branchName)
            }
        }

        // Remove from active list
        threads.remove(at: index)

        // Remove from persisted JSON entirely
        var allThreads = persistence.loadThreads()
        allThreads.removeAll { $0.id == thread.id }
        try persistence.saveThreads(allThreads)

        let d = delegate
        DispatchQueue.main.async { d?.threadManager(self, didDeleteThread: thread) }
    }

    // MARK: - Helpers

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
