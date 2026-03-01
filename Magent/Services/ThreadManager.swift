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
    static let idleShellCommands: Set<String> = {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        guard !shellName.isEmpty else { return ["zsh", "-zsh"] }
        return [shellName, "-\(shellName)"]
    }()
    var dirtyCheckTickCounter: Int = 0

    // MARK: - Lifecycle

    func loadThreads() {
        threads = persistence.loadThreads().filter { !$0.isArchived }
    }

    func restoreThreads() async {
        loadThreads()
        installClaudeHooksSettings()
        ensureCodexBellNotification()
        let preSettings = persistence.loadSettings()
        if preSettings.ipcPromptInjectionEnabled {
            installCodexIPCInstructions()
        }

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

        // Migrate session names from old magent- prefix to new ma- format
        await migrateSessionNamesToNewFormat()

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

        // Populate dirty and delivered states at launch so indicators show immediately.
        await refreshDirtyStates()
        await refreshDeliveredStates()

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    // MARK: - Session Name Migration

    /// One-time migration: renames tmux sessions from the old `magent-` format to the new `ma-` format.
    private func migrateSessionNamesToNewFormat() async {
        let needsMigration = threads.contains { thread in
            thread.tmuxSessionNames.contains { $0.hasPrefix("magent-") }
        }
        guard needsMigration else { return }

        let settings = persistence.loadSettings()
        var changed = false

        for i in threads.indices {
            let thread = threads[i]
            guard thread.tmuxSessionNames.contains(where: { $0.hasPrefix("magent-") }) else { continue }
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { continue }

            let slug = Self.repoSlug(from: project.name)
            var renameMap: [String: String] = [:]
            var usedNames = Set<String>()

            for (tabIndex, sessionName) in thread.tmuxSessionNames.enumerated() {
                guard sessionName.hasPrefix("magent-") else {
                    usedNames.insert(sessionName)
                    continue
                }

                let customName = thread.customTabNames[sessionName]
                let displayName = (customName?.isEmpty == false)
                    ? customName!
                    : MagentThread.defaultDisplayName(at: tabIndex)
                let tabSlug = Self.sanitizeForTmux(displayName)

                let threadNamePart = thread.isMain ? nil : thread.name
                let baseName = Self.buildSessionName(repoSlug: slug, threadName: threadNamePart, tabSlug: tabSlug)

                var candidate = baseName
                if usedNames.contains(candidate) {
                    var suffix = 2
                    while usedNames.contains("\(baseName)-\(suffix)") {
                        suffix += 1
                    }
                    candidate = "\(baseName)-\(suffix)"
                }
                usedNames.insert(candidate)

                if candidate != sessionName {
                    renameMap[sessionName] = candidate
                }
            }

            guard !renameMap.isEmpty else { continue }

            // Rename live tmux sessions
            let oldNames = thread.tmuxSessionNames
            let newNames = oldNames.map { renameMap[$0] ?? $0 }
            try? await renameTmuxSessions(from: oldNames, to: newNames)

            // Update all references
            threads[i].tmuxSessionNames = newNames
            threads[i].agentTmuxSessions = threads[i].agentTmuxSessions.map { renameMap[$0] ?? $0 }
            threads[i].pinnedTmuxSessions = threads[i].pinnedTmuxSessions.map { renameMap[$0] ?? $0 }
            threads[i].unreadCompletionSessions = Set(
                threads[i].unreadCompletionSessions.map { renameMap[$0] ?? $0 }
            )
            var newCustomTabNames: [String: String] = [:]
            for (key, value) in threads[i].customTabNames {
                newCustomTabNames[renameMap[key] ?? key] = value
            }
            threads[i].customTabNames = newCustomTabNames
            if let selected = threads[i].lastSelectedTmuxSessionName {
                threads[i].lastSelectedTmuxSessionName = renameMap[selected] ?? selected
            }
            changed = true
        }

        if changed {
            try? persistence.saveThreads(threads)
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
            // Generate a unique name that doesn't conflict with existing worktrees, branches, or tmux sessions.
            // For each random base name, try the bare name first, then numeric suffixes (-2, -3, …).
            // If all suffixes are taken, generate a new random base and repeat.
            for _ in 0..<5 {
                let baseName = NameGenerator.generate()
                let candidates = [baseName] + (2...9).map { "\(baseName)-\($0)" }
                for candidate in candidates {
                    if try await isNameAvailable(candidate, project: project) {
                        name = candidate
                        foundUnique = true
                        break
                    }
                }
                if foundUnique { break }
            }
        }

        guard foundUnique else {
            throw ThreadManagerError.nameGenerationFailed
        }

        let branchName = name
        let worktreePath = "\(project.resolvedWorktreesBasePath())/\(name)"
        let repoSlug = Self.repoSlug(from: project.name)
        let firstTabSlug = Self.sanitizeForTmux(MagentThread.defaultDisplayName(at: 0))
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: name, tabSlug: firstTabSlug)

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
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, initialPrompt: initialPrompt)

        return thread
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let repoSlug = Self.repoSlug(from: project.name)
        let firstTabSlug = Self.sanitizeForTmux(MagentThread.defaultDisplayName(at: 0))
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: firstTabSlug)

        // Kill orphaned tmux session if it exists from a previous run
        if await tmux.hasSession(name: tmuxSessionName) {
            try? await tmux.killSession(name: tmuxSessionName)
        }

        let settings = persistence.loadSettings()
        let selectedAgentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)
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
        requestedAgentType: AgentType? = nil,
        initialPrompt: String? = nil
    ) async throws -> Tab {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]

        // Find the next unused tab index — check both model and live tmux sessions
        let existingNames = currentThread.tmuxSessionNames
        let tabIndex = existingNames.count
        let settings = persistence.loadSettings()

        let tmuxSessionName: String
        let startCmd: String

        var selectedAgentType = currentThread.selectedAgentType
        let repoSlug = Self.repoSlug(from:
            settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
        )
        // Derive tab slug from default display name for this tab index
        let defaultDisplayName = MagentThread.defaultDisplayName(at: tabIndex)
        let tabSlug = Self.sanitizeForTmux(defaultDisplayName)
        if currentThread.isMain {
            let baseName = Self.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: tabSlug)
            var candidate = baseName
            var suffix = 2
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                candidate = "\(baseName)-\(suffix)"
                suffix += 1
            }
            tmuxSessionName = candidate
            let projectPath = currentThread.worktreePath
            let projectName = settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            let envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName) && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
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
            let baseName = Self.buildSessionName(repoSlug: repoSlug, threadName: currentThread.name, tabSlug: tabSlug)
            var candidate = baseName
            var suffix = 2
            while await isTabNameTaken(candidate, existingNames: existingNames) {
                candidate = "\(baseName)-\(suffix)"
                suffix += 1
            }
            tmuxSessionName = candidate
            let project = settings.projects.first(where: { $0.id == currentThread.projectId })
            let projectPath = project?.repoPath ?? currentThread.worktreePath
            let envExports = "export MAGENT_WORKTREE_PATH=\(currentThread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(currentThread.name) && export MAGENT_PROJECT_NAME=\(project?.name ?? "project") && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"
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
        try? await tmux.setEnvironment(sessionName: tmuxSessionName, key: "MAGENT_SOCKET", value: IPCSocketServer.socketPath)
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
            agentContext: isAgentTab ? injection.agentContext : "",
            initialPrompt: initialPrompt
        )

        return tab
    }

    func reorderTabs(for threadId: UUID, newOrder: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].tmuxSessionNames = newOrder
        try? persistence.saveThreads(threads)
    }

    /// Registers a fallback session name for a thread that had no sessions.
    /// This ensures the session is tracked in tmuxSessionNames (so close-tab works)
    /// and in agentTmuxSessions (so recreateSessionIfNeeded creates an agent, not a terminal).
    func registerFallbackSession(_ sessionName: String, for threadId: UUID, agentType: AgentType?) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard !threads[index].tmuxSessionNames.contains(sessionName) else { return }
        threads[index].tmuxSessionNames.append(sessionName)
        if agentType != nil {
            threads[index].agentTmuxSessions.append(sessionName)
            threads[index].agentHasRun = true
        }
        threads[index].lastSelectedTmuxSessionName = sessionName
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

    @MainActor
    func markSessionBusy(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].agentTmuxSessions.contains(sessionName) else { return }
        // Clear waiting state — user submitted a prompt
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        guard !threads[index].busySessions.contains(sessionName) else { return }
        threads[index].busySessions.insert(sessionName)
        delegate?.threadManager(self, didUpdateThreads: threads)
        postBusySessionsChangedNotification(for: threads[index])
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

        // Place at bottom of the matching pin group in the target section
        let maxOrder = threads
            .filter {
                $0.id != thread.id &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .max() ?? -1
        threads[index].displayOrder = maxOrder + 1

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isPinned.toggle()

        // Place at bottom of the new pin group
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread)
        let maxOrder = threads
            .filter {
                $0.id != thread.id &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .max() ?? -1
        threads[index].displayOrder = maxOrder + 1

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Reorders a thread to a specific index within its pin group in a section.
    /// Reassigns sequential displayOrders for all threads in both pin groups of that section.
    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[threadIndex]
        let projectId = thread.projectId
        let isPinned = thread.isPinned

        // Get all threads in the same section, project, and pin group (excluding the dragged thread)
        var group = threads.filter {
            $0.id != threadId &&
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            $0.isPinned == isPinned &&
            effectiveSectionId(for: $0) == sectionId
        }
        // Sort by current display order so we insert relative to existing positions
        group.sort { $0.displayOrder < $1.displayOrder }

        let clampedIndex = max(0, min(targetIndex, group.count))
        group.insert(thread, at: clampedIndex)

        // Reassign sequential displayOrders for this group
        for (order, t) in group.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        // Also reassign sequential displayOrders for the other pin group in the same section
        var otherGroup = threads.filter {
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            $0.isPinned == !isPinned &&
            effectiveSectionId(for: $0) == sectionId
        }
        otherGroup.sort { $0.displayOrder < $1.displayOrder }
        for (order, t) in otherGroup.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Bumps a thread to the top of its pin group within its section by setting
    /// displayOrder to min(group) - 1.
    func bumpThreadToTopOfSection(_ threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread)

        let groupMin = threads
            .filter {
                $0.id != threadId &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .min() ?? 0

        threads[index].displayOrder = groupMin - 1
    }

    /// Returns the effective section ID for a thread, falling back to the first visible section
    /// for the thread's project when the thread has no section or an unrecognized one.
    private func effectiveSectionId(for thread: MagentThread) -> UUID? {
        let settings = persistence.loadSettings()
        let projectSections = settings.sections(for: thread.projectId)
        let knownIds = Set(projectSections.map(\.id))
        if let sid = thread.sectionId, knownIds.contains(sid) {
            return sid
        }
        return settings.visibleSections(for: thread.projectId).first?.id
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
        try await removeTab(threadIndex: index, sessionName: sessionName)
    }

    func removeTab(from thread: MagentThread, sessionName: String) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        guard threads[index].tmuxSessionNames.contains(sessionName) else {
            throw ThreadManagerError.invalidTabIndex
        }

        try await removeTab(threadIndex: index, sessionName: sessionName)
    }

    private func removeTab(threadIndex index: Int, sessionName: String) async throws {
        try? await tmux.killSession(name: sessionName)

        // Also remove from pinned, agent, unread completion, waiting, and custom tab names if present
        threads[index].pinnedTmuxSessions.removeAll { $0 == sessionName }
        threads[index].agentTmuxSessions.removeAll { $0 == sessionName }
        threads[index].unreadCompletionSessions.remove(sessionName)
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].tmuxSessionNames.removeAll { $0 == sessionName }
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

    func refreshDeliveredStates() async {
        var changed = false
        for i in threads.indices where !threads[i].isArchived && !threads[i].isMain {
            let baseBranch = resolveBaseBranch(for: threads[i])
            let delivered = await git.isFullyDelivered(worktreePath: threads[i].worktreePath, baseBranch: baseBranch)
            if threads[i].isFullyDelivered != delivered {
                threads[i].isFullyDelivered = delivered
                changed = true
            }
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    /// Refreshes the delivered state for a single thread. Returns true if the value changed.
    @discardableResult
    func refreshDeliveredState(for threadId: UUID) async -> Bool {
        guard let i = threads.firstIndex(where: { $0.id == threadId }),
              !threads[i].isArchived, !threads[i].isMain else { return false }
        let baseBranch = resolveBaseBranch(for: threads[i])
        let delivered = await git.isFullyDelivered(worktreePath: threads[i].worktreePath, baseBranch: baseBranch)
        guard threads[i].isFullyDelivered != delivered else { return false }
        threads[i].isFullyDelivered = delivered
        return true
    }

    func refreshDiffStats(for threadId: UUID) async -> [FileDiffEntry] {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        let baseBranch = resolveBaseBranch(for: thread)
        return await git.diffStats(worktreePath: thread.worktreePath, baseBranch: baseBranch)
    }

}
