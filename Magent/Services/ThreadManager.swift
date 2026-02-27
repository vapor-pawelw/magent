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

    private let persistence = PersistenceService.shared
    private let git = GitService.shared
    private let tmux = TmuxService.shared

    private(set) var threads: [MagentThread] = []
    private var activeThreadId: UUID?
    private var recentBellBySession: [String: Date] = [:]
    private var autoRenameInProgress: Set<UUID> = []
    private var pendingCwdEnforcements: [String: PendingCwdEnforcement] = [:]
    /// Dedup tracker — prevents repeated "waiting for input" notifications for the same session.
    private var notifiedWaitingSessions: Set<String> = []

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

    // MARK: - Rename

    private func naiveAutoRenameCandidates(from prompt: String) -> [String] {
        let words = prompt
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        let baseWords = Array(words.prefix(3))
        var candidates: [String] = []

        func append(_ parts: [String]) {
            let trimmed = parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !trimmed.isEmpty else { return }
            let candidate = trimmed.joined(separator: "-")
            guard !candidate.isEmpty else { return }
            guard !candidates.contains(candidate) else { return }
            candidates.append(candidate)
        }

        append(baseWords)

        if baseWords.count == 3 {
            append(Array(baseWords.prefix(2)))
        }

        if let first = baseWords.first {
            if baseWords.count >= 2 {
                let twoWords = Array(baseWords.prefix(2))
                for i in 2...9 {
                    append(twoWords + ["\(i)"])
                }
            } else {
                for i in 2...9 {
                    append([first, "\(i)"])
                }
            }
        }

        return candidates
    }

    private static let slugPrefix = "SLUG:"

    private func sanitizeSlug(_ raw: String) -> String? {
        // Require the SLUG: prefix — if absent, the output is an error or unexpected
        guard let prefixRange = raw.range(of: Self.slugPrefix) else { return nil }
        let afterPrefix = raw[prefixRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Agent signals "this is a question, not a task" → return sentinel
        if afterPrefix.uppercased() == "EMPTY" || afterPrefix.isEmpty {
            return Self.slugQuestionSentinel
        }

        // Take first line only
        let line = afterPrefix.components(separatedBy: .newlines).first ?? afterPrefix

        // Strip quotes and backticks
        var slug = line
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Lowercase, replace non-alphanumeric with hyphens
        slug = slug.lowercased()
        slug = slug.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()

        // Collapse consecutive hyphens and trim leading/trailing hyphens
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Validate: 2–50 chars, must contain at least one letter, at most 5 segments
        guard slug.count >= 2, slug.count <= 50 else { return nil }
        guard slug.contains(where: { $0.isLetter }) else { return nil }
        guard slug.split(separator: "-").count <= 5 else { return nil }

        return slug
    }

    /// Sentinel returned by `generateSlugViaAgent` when the agent determines
    /// the prompt is a plain question rather than an actionable task.
    private static let slugQuestionSentinel = ""

    private func generateSlugViaAgent(from prompt: String, agentType: AgentType?) async -> String? {
        let truncated = String(prompt.prefix(500))
        let customInstruction = persistence.loadSettings().autoRenameSlugPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = customInstruction.isEmpty ? AppSettings.defaultSlugPrompt : customInstruction
        let aiPrompt = """
            \(instruction) \
            Output ONLY the prefix SLUG: followed by the slug. No quotes, no explanation. \
            If the input is a plain question (not an actionable task or job), output exactly: SLUG: EMPTY \
            Example: "Fix auth bug in login" → SLUG: fix-auth-login \
            Example: "I want to have a way for agents to communicate with the app so it can create threads automatically" → SLUG: agent-app-communication \
            Example: "How does the auth system work?" → SLUG: EMPTY
            Task: \(truncated)
            """

        let escapedPrompt = ShellExecutor.shellQuote(aiPrompt)
        let command: String
        switch agentType {
        case .codex:
            command = "codex exec \(escapedPrompt) --model o4-mini --ephemeral"
        default:
            // Use claude for .claude, .custom, and nil (claude is a prerequisite for this app)
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence"
        }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await ShellExecutor.execute(command)
                guard result.exitCode == 0 else { return nil }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            // Return whichever finishes first
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let raw = result, !raw.isEmpty else { return nil }
        return sanitizeSlug(raw)
    }

    private func autoRenameCandidates(from prompt: String, agentType: AgentType?) async -> [String] {
        if let slug = await generateSlugViaAgent(from: prompt, agentType: agentType) {
            // Agent signalled "question, not a task" → skip rename entirely (no fallback)
            guard slug != Self.slugQuestionSentinel else { return [] }
            var candidates = [slug]
            for i in 2...9 {
                candidates.append("\(slug)-\(i)")
            }
            return candidates
        }
        return naiveAutoRenameCandidates(from: prompt)
    }

    func renameThread(
        _ thread: MagentThread,
        to newName: String,
        markFirstPromptRenameHandled: Bool = true
    ) async throws {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw ThreadManagerError.invalidName
        }
        let currentThread = threads[index]
        guard !threads.contains(where: { $0.name == trimmed && $0.id != currentThread.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let oldName = currentThread.name
        let newBranchName = trimmed
        let worktreePath = currentThread.worktreePath
        let parentDir = (worktreePath as NSString).deletingLastPathComponent
        let symlinkPath = (parentDir as NSString).appendingPathComponent(trimmed)
        let sessionRenameMap = Dictionary(uniqueKeysWithValues: currentThread.tmuxSessionNames.map { sessionName in
            (sessionName, renamedSessionName(sessionName, fromThreadName: oldName, toThreadName: trimmed))
        })
        let oldSessionNames = Set(currentThread.tmuxSessionNames)
        let newSessionNames = currentThread.tmuxSessionNames.map { sessionRenameMap[$0] ?? $0 }

        // Look up project for repo path
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }

        // Check for conflicts with git branch and tmux sessions
        if await git.branchExists(repoPath: project.repoPath, branchName: newBranchName) {
            throw ThreadManagerError.duplicateName
        }
        if Set(newSessionNames).count != newSessionNames.count {
            throw ThreadManagerError.duplicateName
        }
        for (oldSessionName, newSessionName) in zip(currentThread.tmuxSessionNames, newSessionNames)
        where oldSessionName != newSessionName {
            if !oldSessionNames.contains(newSessionName), await tmux.hasSession(name: newSessionName) {
                throw ThreadManagerError.duplicateName
            }
        }

        // 1. Rename git branch
        try await git.renameBranch(repoPath: project.repoPath, oldName: currentThread.branchName, newName: newBranchName)

        // 2. Create a symlink from the new name to the actual worktree directory.
        // The worktree itself is NOT moved — running agents keep their cwd intact.
        if symlinkPath != worktreePath {
            createCompatibilitySymlink(from: symlinkPath, to: worktreePath)
        }

        // 3. Rename each tmux session
        try await renameTmuxSessions(from: currentThread.tmuxSessionNames, to: newSessionNames)

        // 4. Update pinned and agent sessions to reflect new names
        let newPinnedSessions = currentThread.pinnedTmuxSessions.map { sessionRenameMap[$0] ?? $0 }
        let newAgentSessions = currentThread.agentTmuxSessions.map { sessionRenameMap[$0] ?? $0 }

        // Re-setup bell pipe with new session names for agent sessions
        for agentSession in newAgentSessions {
            await tmux.setupBellPipe(for: agentSession)
        }

        // 5. Update thread name env var on each session (worktree path unchanged)
        for sessionName in newSessionNames {
            try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_WORKTREE_NAME", value: trimmed)
        }

        // 6. Update model fields and persist (worktreePath stays the same)
        threads[index].name = trimmed
        threads[index].branchName = newBranchName
        threads[index].tmuxSessionNames = newSessionNames
        threads[index].agentTmuxSessions = newAgentSessions
        threads[index].pinnedTmuxSessions = newPinnedSessions
        threads[index].unreadCompletionSessions = Set(
            threads[index].unreadCompletionSessions.map { sessionRenameMap[$0] ?? $0 }
        )
        // Re-key custom tab names to reflect new session names
        var newCustomTabNames: [String: String] = [:]
        for (oldKey, value) in threads[index].customTabNames {
            let newKey = sessionRenameMap[oldKey] ?? oldKey
            newCustomTabNames[newKey] = value
        }
        threads[index].customTabNames = newCustomTabNames
        if let selectedName = threads[index].lastSelectedTmuxSessionName {
            threads[index].lastSelectedTmuxSessionName = sessionRenameMap[selectedName] ?? selectedName
        }
        if markFirstPromptRenameHandled {
            threads[index].didAutoRenameFromFirstPrompt = true
        }

        try persistence.saveThreads(threads)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    func autoRenameThreadAfterFirstPromptIfNeeded(
        threadId: UUID,
        sessionName: String,
        prompt: String
    ) async {
        guard persistence.loadSettings().autoRenameWorktrees else { return }
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]

        guard !thread.isMain else { return }
        guard !thread.didAutoRenameFromFirstPrompt else { return }
        // If the thread name no longer matches the worktree directory basename,
        // it was already renamed (manually or otherwise) — skip auto-rename.
        guard thread.name == (thread.worktreePath as NSString).lastPathComponent else { return }
        guard thread.agentTmuxSessions.contains(sessionName) else { return }
        guard !autoRenameInProgress.contains(thread.id) else { return }

        let candidates = await autoRenameCandidates(from: prompt, agentType: thread.selectedAgentType)
        guard !candidates.isEmpty else { return }

        autoRenameInProgress.insert(thread.id)
        defer { autoRenameInProgress.remove(thread.id) }

        for candidate in candidates where candidate != thread.name {
            do {
                try await renameThread(thread, to: candidate, markFirstPromptRenameHandled: true)
                return
            } catch ThreadManagerError.duplicateName {
                continue
            } catch {
                return
            }
        }
    }

    // MARK: - Rename Tab

    func renameTab(threadId: UUID, sessionName: String, newDisplayName: String) async throws {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]
        guard let sessionIndex = currentThread.tmuxSessionNames.firstIndex(of: sessionName) else {
            throw ThreadManagerError.invalidTabIndex
        }

        let trimmed = newDisplayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ThreadManagerError.invalidName
        }

        // Compute new tmux session name
        let sanitizedTabName = Self.sanitizeForTmux(trimmed)
        let newSessionName: String
        if currentThread.isMain {
            let settings = persistence.loadSettings()
            let projectName = Self.sanitizeForTmux(
                settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
            )
            if sessionIndex == 0 {
                newSessionName = "magent-main-\(projectName)-\(sanitizedTabName)"
            } else {
                newSessionName = "magent-main-\(projectName)-\(sanitizedTabName)"
            }
        } else {
            newSessionName = "magent-\(currentThread.name)-\(sanitizedTabName)"
        }

        // Check uniqueness
        guard newSessionName != sessionName else {
            // Display name changed but session name is the same — just update the display name
            threads[index].customTabNames[sessionName] = trimmed
            try persistence.saveThreads(threads)
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
            return
        }

        // Auto-resolve collisions: keep requested base and append numeric suffix as needed.
        let resolvedSessionName = await resolveUniqueTabSessionName(
            baseName: newSessionName,
            replacing: sessionName,
            in: currentThread
        )
        guard let resolvedSessionName else {
            throw ThreadManagerError.duplicateName
        }

        // Rename tmux session
        try await renameTmuxSessions(from: [sessionName], to: [resolvedSessionName])

        // Update all references
        threads[index].tmuxSessionNames[sessionIndex] = resolvedSessionName
        if currentThread.agentTmuxSessions.contains(sessionName) {
            threads[index].agentTmuxSessions = currentThread.agentTmuxSessions.map {
                $0 == sessionName ? resolvedSessionName : $0
            }
        }
        if currentThread.pinnedTmuxSessions.contains(sessionName) {
            threads[index].pinnedTmuxSessions = currentThread.pinnedTmuxSessions.map {
                $0 == sessionName ? resolvedSessionName : $0
            }
        }
        if currentThread.lastSelectedTmuxSessionName == sessionName {
            threads[index].lastSelectedTmuxSessionName = resolvedSessionName
        }
        if currentThread.unreadCompletionSessions.contains(sessionName) {
            threads[index].unreadCompletionSessions.remove(sessionName)
            threads[index].unreadCompletionSessions.insert(resolvedSessionName)
        }

        // Update custom tab names: remove old key, store under new key
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].customTabNames[resolvedSessionName] = trimmed

        // Re-setup bell monitoring if this was an agent session
        if threads[index].agentTmuxSessions.contains(resolvedSessionName) {
            await tmux.setupBellPipe(for: resolvedSessionName)
        }

        try persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    /// Returns a unique tmux session name for tab rename by keeping the requested base
    /// and appending "-N" when needed. Returns nil if no unique name is found.
    private func resolveUniqueTabSessionName(
        baseName: String,
        replacing sessionName: String,
        in thread: MagentThread
    ) async -> String? {
        let reservedNames = Set(thread.tmuxSessionNames).subtracting([sessionName])

        func isAvailable(_ candidate: String) async -> Bool {
            if candidate == sessionName { return true }
            if reservedNames.contains(candidate) { return false }
            return !(await tmux.hasSession(name: candidate))
        }

        if await isAvailable(baseName) {
            return baseName
        }

        for suffix in 2...999 {
            let candidate = "\(baseName)-\(suffix)"
            if await isAvailable(candidate) {
                return candidate
            }
        }

        return nil
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

    // MARK: - Worktree Sync

    func syncThreadsWithWorktrees(for project: Project) async {
        let basePath = project.resolvedWorktreesBasePath()
        let fm = FileManager.default

        // Discover directories in the worktrees base path
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else { return }

        // Build a map of symlink target → latest symlink name.
        // Rename creates symlinks from the new name pointing to the original worktree directory,
        // so the latest symlink name represents the most recent thread name.
        var latestSymlinkName: [String: (name: String, date: Date)] = [:]
        for entry in contents {
            let entryPath = (basePath as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: entryPath),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: entryPath) else { continue }
            let resolved = dest.hasPrefix("/") ? dest : (basePath as NSString).appendingPathComponent(dest)
            let created = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date ?? .distantPast
            if let existing = latestSymlinkName[resolved], existing.date > created { continue }
            latestSymlinkName[resolved] = (name: entry, date: created)
        }

        var changed = false
        let existingPaths = Set(threads.filter { $0.projectId == project.id }.map(\.worktreePath))

        for dirName in contents {
            let fullPath = (basePath as NSString).appendingPathComponent(dirName)

            // Skip symlinks — these are rename aliases, not real worktrees
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                continue
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check if this is a git worktree (has a .git file, not directory)
            let gitPath = (fullPath as NSString).appendingPathComponent(".git")
            var gitIsDir: ObjCBool = false
            let gitExists = fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir)
            guard gitExists && !gitIsDir.boolValue else { continue }

            // Skip if we already have a thread for this path
            guard !existingPaths.contains(fullPath) else { continue }

            // If a symlink points here, the worktree was renamed — use the symlink name
            let threadName = latestSymlinkName[fullPath]?.name ?? dirName
            let branchName = threadName

            let settings = persistence.loadSettings()
            let thread = MagentThread(
                projectId: project.id,
                name: threadName,
                worktreePath: fullPath,
                branchName: branchName,
                sectionId: settings.defaultSection?.id
            )
            threads.append(thread)
            changed = true
        }

        // Archive threads whose worktree directories no longer exist on disk
        // (skip main threads — those point at the repo itself)
        for i in threads.indices {
            guard threads[i].projectId == project.id,
                  !threads[i].isMain,
                  !threads[i].isArchived else { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: threads[i].worktreePath, isDirectory: &isDir) && isDir.boolValue
            if !exists {
                threads[i].isArchived = true
                changed = true
            }
        }

        if changed {
            // Remove archived from active list
            threads = threads.filter { !$0.isArchived }

            // Save all (including newly archived) to persistence
            var allThreads = persistence.loadThreads()
            // Merge: update archived flags, add new threads
            for thread in threads where !allThreads.contains(where: { $0.id == thread.id }) {
                allThreads.append(thread)
            }
            // Update archived flags
            for i in allThreads.indices {
                if !threads.contains(where: { $0.id == allThreads[i].id }) && allThreads[i].projectId == project.id && !allThreads[i].isMain {
                    allThreads[i].isArchived = true
                }
            }
            try? persistence.saveThreads(allThreads)

            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
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

    /// Kills live tmux sessions prefixed with "magent" that are not referenced by any non-archived thread/tab.
    @discardableResult
    func cleanupStaleMagentSessions() async -> [String] {
        let referencedSessions = referencedMagentSessionNames()

        let liveSessions: [String]
        do {
            liveSessions = try await tmux.listSessions()
        } catch {
            return []
        }

        let staleSessions = liveSessions.filter { sessionName in
            sessionName.hasPrefix("magent") && !referencedSessions.contains(sessionName)
        }

        guard !staleSessions.isEmpty else { return [] }

        for sessionName in staleSessions {
            try? await tmux.killSession(name: sessionName)
        }

        return staleSessions
    }

    private func referencedMagentSessionNames() -> Set<String> {
        var names = Set<String>()

        // Include both in-memory and persisted threads so cleanup is safe during transitional states.
        let allNonArchivedThreads = threads.filter { !$0.isArchived } + persistence.loadThreads().filter { !$0.isArchived }
        for thread in allNonArchivedThreads {
            for sessionName in thread.tmuxSessionNames where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            for sessionName in thread.agentTmuxSessions where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            for sessionName in thread.pinnedTmuxSessions where sessionName.hasPrefix("magent") {
                names.insert(sessionName)
            }
            if let selectedSession = thread.lastSelectedTmuxSessionName, selectedSession.hasPrefix("magent") {
                names.insert(selectedSession)
            }
        }

        return names
    }

    /// Ensures a tmux session exists and belongs to the expected thread context.
    /// Recreates dead or mismatched sessions.
    /// Returns true if the session was recreated.
    func recreateSessionIfNeeded(
        sessionName: String,
        thread: MagentThread
    ) async -> Bool {
        // Skip if already being recreated
        guard !sessionsBeingRecreated.contains(sessionName) else { return false }

        sessionsBeingRecreated.insert(sessionName)
        defer { sessionsBeingRecreated.remove(sessionName) }

        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectPath = project?.repoPath ?? thread.worktreePath
        let projectName = project?.name ?? "project"
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)

        if await tmux.hasSession(name: sessionName) {
            let sessionMatches = await sessionMatchesThreadContext(
                sessionName: sessionName,
                thread: thread,
                projectPath: projectPath,
                isAgentSession: isAgentSession
            )
            if sessionMatches {
                await setSessionEnvironment(
                    sessionName: sessionName,
                    thread: thread,
                    projectPath: projectPath,
                    projectName: projectName
                )
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: thread.worktreePath)
                enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: thread.worktreePath)
                if isAgentSession {
                    await tmux.setupBellPipe(for: sessionName)
                }
                return false
            }

            // Session name exists but points at another thread/project context.
            try? await tmux.killSession(name: sessionName)
        }

        let startCmd: String
        let sessionAgentType = thread.selectedAgentType ?? effectiveAgentType(for: thread.projectId)
        let envExports: String
        if thread.isMain {
            envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName)"
        } else {
            envExports = "export MAGENT_WORKTREE_PATH=\(thread.worktreePath) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(thread.name) && export MAGENT_PROJECT_NAME=\(projectName)"
        }
        if isAgentSession {
            startCmd = agentStartCommand(
                settings: settings,
                agentType: sessionAgentType,
                envExports: envExports,
                workingDirectory: thread.worktreePath
            )
        } else {
            startCmd = "\(envExports) && cd \(thread.worktreePath) && exec zsh -l"
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
        await tmux.updateWorkingDirectory(sessionName: sessionName, to: thread.worktreePath)
        enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: thread.worktreePath)

        if isAgentSession {
            await tmux.setupBellPipe(for: sessionName)
        }

        // Run normal injection (terminal command + agent context)
        let injection = effectiveInjection(for: thread.projectId)
        injectAfterStart(
            sessionName: sessionName,
            terminalCommand: injection.terminalCommand,
            agentContext: isAgentSession ? injection.agentContext : ""
        )

        return true
    }

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
    }

    private func sessionMatchesThreadContext(
        sessionName: String,
        thread: MagentThread,
        projectPath: String,
        isAgentSession: Bool
    ) async -> Bool {
        let expectedPath = thread.isMain ? projectPath : thread.worktreePath

        if let paneInfo = await tmux.activePaneInfo(sessionName: sessionName),
           !path(paneInfo.path, isWithin: expectedPath) {
            if !isAgentSession && isShellCommand(paneInfo.command) {
                // Existing terminal shell drifted due startup config (e.g. .zshrc cd).
                // Keep the session and correct cwd in-place.
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: expectedPath)
                enforceWorkingDirectoryAfterStartup(sessionName: sessionName, path: expectedPath)
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

    /// Some shell startup configs can change cwd after the session starts.
    /// Re-apply working directory shortly after startup to keep tabs anchored to the thread worktree.
    /// Checks the pane's actual cwd and stops early once it's within the expected path.
    private func enforceWorkingDirectoryAfterStartup(sessionName: String, path: String) {
        Task {
            for delayNs: UInt64 in [300_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000] {
                try? await Task.sleep(nanoseconds: delayNs)
                if let info = await tmux.activePaneInfo(sessionName: sessionName),
                   self.path(info.path, isWithin: path) {
                    break
                }
                await tmux.updateWorkingDirectory(sessionName: sessionName, to: path)
            }
        }
    }

    // MARK: - Pending CWD Enforcement

    private struct PendingCwdEnforcement {
        let path: String
        let expiresAt: Date
        var enforcedPaneIds: Set<String>
    }

    /// Checks pending cwd enforcements registered after thread rename.
    /// For each pending session, sends `cd` to any pane that has returned to a shell
    /// since the last check. Removes the entry once all panes are enforced or the deadline passes.
    private func checkPendingCwdEnforcements() async {
        guard !pendingCwdEnforcements.isEmpty else { return }

        let now = Date()
        var resolved = [String]()

        for (sessionName, var enforcement) in pendingCwdEnforcements {
            if now >= enforcement.expiresAt {
                resolved.append(sessionName)
                continue
            }

            let (newlyEnforced, hasUnenforced) = await tmux.enforceWorkingDirectoryOnNewPanes(
                sessionName: sessionName,
                path: enforcement.path,
                alreadyEnforced: enforcement.enforcedPaneIds
            )

            enforcement.enforcedPaneIds.formUnion(newlyEnforced)
            pendingCwdEnforcements[sessionName] = enforcement

            if !hasUnenforced {
                resolved.append(sessionName)
            }
        }

        for sessionName in resolved {
            pendingCwdEnforcements.removeValue(forKey: sessionName)
        }
    }

    // MARK: - Session Monitor

    private var sessionMonitorTimer: Timer?

    func startSessionMonitor() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startSessionMonitor()
            }
            return
        }
        guard sessionMonitorTimer == nil else { return }
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.runSessionMonitorTick()
        }
        // Fire once immediately so we don't wait 3 seconds for the first sync.
        runSessionMonitorTick()
    }

    func stopSessionMonitor() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
    }

    private func runSessionMonitorTick() {
        Task {
            await self.checkForMissingWorktrees()
            await self.checkForDeadSessions()
            await self.checkForAgentCompletions()
            await self.checkForWaitingForInput()
            await self.syncBusySessionsFromProcessState()
            await self.ensureBellPipes()
            await self.checkPendingCwdEnforcements()
        }
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
                    thread: thread
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

    private func checkForAgentCompletions() async {
        let sessions = await tmux.consumeAgentCompletionSessions()
        guard !sessions.isEmpty else { return }

        let now = Date()
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        let orderedUniqueSessions = sessions.reduce(into: [String]()) { result, session in
            if !result.contains(session) {
                result.append(session)
            }
        }

        var changed = false

        for session in orderedUniqueSessions {
            if let previous = recentBellBySession[session], now.timeIntervalSince(previous) < 1.0 {
                continue
            }
            recentBellBySession[session] = now

            guard let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) else {
                continue
            }

            threads[index].lastAgentCompletionAt = now
            threads[index].busySessions.remove(session)
            threads[index].waitingForInputSessions.remove(session)
            notifiedWaitingSessions.remove(session)

            let isActiveThread = threads[index].id == activeThreadId
            let isActiveTab = isActiveThread && threads[index].lastSelectedTmuxSessionName == session
            if !isActiveTab {
                threads[index].unreadCompletionSessions.insert(session)
            }
            changed = true

            let projectName = settings.projects.first(where: { $0.id == threads[index].projectId })?.name ?? "Project"
            sendAgentCompletionNotification(for: threads[index], projectName: projectName, playSound: playSound)
        }

        guard changed else { return }
        try? persistence.saveThreads(threads)
        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            for session in orderedUniqueSessions {
                if let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) {
                    NotificationCenter.default.post(
                        name: .magentAgentCompletionDetected,
                        object: self,
                        userInfo: [
                            "threadId": threads[index].id,
                            "unreadSessions": threads[index].unreadCompletionSessions
                        ]
                    )
                }
            }
        }
    }

    private func sendAgentCompletionNotification(for thread: MagentThread, projectName: String, playSound: Bool) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Finished"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString]

            let request = UNNotificationRequest(
                identifier: "magent-agent-finished-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Play sound directly via NSSound as a fallback — UNNotification sound
        // can be throttled by macOS when many notifications are delivered.
        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// Syncs `busySessions` with actual tmux pane state by checking `pane_current_command`.
    /// If the foreground process is a non-shell command, the session is busy.
    /// If it's a shell (zsh, bash, etc.), the agent has exited and the session is idle.
    private func syncBusySessionsFromProcessState() async {
        // Collect all agent sessions across non-archived threads
        var allAgentSessions = Set<String>()
        for thread in threads where !thread.isArchived {
            allAgentSessions.formUnion(thread.agentTmuxSessions)
        }
        guard !allAgentSessions.isEmpty else { return }

        let commands = await tmux.activeCommands(forSessions: allAgentSessions)
        guard !commands.isEmpty else { return }

        var changed = false
        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            for session in threads[i].agentTmuxSessions {
                guard let command = commands[session] else { continue }
                let isShell = TmuxService.shellCommands.contains(command)
                if isShell {
                    // Agent not running — clear busy and waiting if set
                    if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                    }
                    if threads[i].waitingForInputSessions.contains(session) {
                        threads[i].waitingForInputSessions.remove(session)
                        notifiedWaitingSessions.remove(session)
                        changed = true
                    }
                } else {
                    // Non-shell process running — mark busy only if not in waiting state.
                    // Skip if a completion bell was recently received for this session;
                    // the bell fires just before the process exits, so pane_current_command
                    // can still show the agent binary for a brief window after completion.
                    let recentlyCompleted: Bool = {
                        guard let bellDate = recentBellBySession[session] else { return false }
                        return Date().timeIntervalSince(bellDate) < 5.0
                    }()
                    if !recentlyCompleted && !threads[i].waitingForInputSessions.contains(session) {
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                        }
                    }
                }
            }
        }

        if changed {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    // MARK: - Waiting-for-Input Detection

    private func checkForWaitingForInput() async {
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        var changed = false
        var notifyPairs: [(threadIndex: Int, sessionName: String)] = []

        for i in threads.indices {
            guard !threads[i].isArchived else { continue }
            for session in threads[i].agentTmuxSessions {
                let wasWaiting = threads[i].waitingForInputSessions.contains(session)
                let isBusy = threads[i].busySessions.contains(session)

                // Only check busy sessions (or already-waiting sessions to detect resolution)
                guard isBusy || wasWaiting else { continue }

                guard let paneContent = await tmux.capturePane(sessionName: session) else { continue }
                let isWaiting = matchesWaitingForInputPattern(paneContent)

                if isWaiting && !wasWaiting {
                    // Transition: busy → waiting
                    threads[i].busySessions.remove(session)
                    threads[i].waitingForInputSessions.insert(session)
                    changed = true

                    let isActiveThread = threads[i].id == activeThreadId
                    let isActiveTab = isActiveThread && threads[i].lastSelectedTmuxSessionName == session
                    if !isActiveTab && !notifiedWaitingSessions.contains(session) {
                        notifiedWaitingSessions.insert(session)
                        notifyPairs.append((i, session))
                    }
                } else if !isWaiting && wasWaiting {
                    // Transition: waiting → cleared (user provided input)
                    threads[i].waitingForInputSessions.remove(session)
                    notifiedWaitingSessions.remove(session)
                    changed = true
                    // syncBusy will re-mark as busy on the same tick
                }
            }
        }

        guard changed else { return }
        for (threadIndex, session) in notifyPairs {
            let projectName = settings.projects.first(where: { $0.id == threads[threadIndex].projectId })?.name ?? "Project"
            sendAgentWaitingNotification(for: threads[threadIndex], projectName: projectName, playSound: playSound)
        }

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            for i in threads.indices where !threads[i].isArchived && threads[i].hasWaitingForInput {
                NotificationCenter.default.post(
                    name: .magentAgentWaitingForInput,
                    object: self,
                    userInfo: [
                        "threadId": threads[i].id,
                        "waitingSessions": threads[i].waitingForInputSessions
                    ]
                )
            }
        }
    }

    private func matchesWaitingForInputPattern(_ text: String) -> Bool {
        // Trim trailing whitespace/newlines and look at the last non-empty lines
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmedLines = lines.suffix(20).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return false }
        let lastChunk = trimmedLines.suffix(15).joined(separator: "\n")

        // Claude Code plan mode
        if lastChunk.contains("Would you like to proceed?") { return true }

        // Claude Code permission prompts
        if lastChunk.contains("Do you want to") && (lastChunk.contains("Yes") || lastChunk.contains("No")) { return true }

        // Codex approval prompts
        if lastChunk.contains("approve") && lastChunk.contains("deny") { return true }

        // Claude Code AskUserQuestion / interactive prompt: ❯ with numbered options
        if lastChunk.contains("\u{276F}") && lastChunk.range(of: #"\d+\."#, options: .regularExpression) != nil { return true }

        // Claude Code ExitPlanMode / plan approval prompt
        if lastChunk.contains("Do you want me to go ahead") { return true }

        return false
    }

    private func sendAgentWaitingNotification(for thread: MagentThread, projectName: String, playSound: Bool) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Needs Input"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString]

            let request = UNNotificationRequest(
                identifier: "magent-agent-waiting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func checkForMissingWorktrees() async {
        let candidates = threads.filter { !$0.isMain && !$0.isArchived }
        var pruneRepos = Set<String>()
        var archivedAny = false

        for thread in candidates {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: thread.worktreePath, isDirectory: &isDir)
            guard !exists || !isDir.boolValue else { continue }

            let settings = persistence.loadSettings()
            if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
                pruneRepos.insert(project.repoPath)
            }
            try? await archiveThread(thread)
            archivedAny = true
        }

        if archivedAny {
            let settings = persistence.loadSettings()
            if settings.playSoundForAgentCompletion {
                let soundName = settings.agentCompletionSoundName
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                }
            }
        }

        for repoPath in pruneRepos {
            await git.pruneWorktrees(repoPath: repoPath)
        }
    }

    // MARK: - Helpers

    /// Renames session names produced by Magent without touching unrelated substrings.
    /// This avoids accidental rewrites when thread names overlap with the "magent" prefix.
    private func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String) -> String {
        let oldPrefix = "magent-\(oldName)"
        let newPrefix = "magent-\(newName)"

        if sessionName == oldPrefix {
            return newPrefix
        }
        if sessionName.hasPrefix(oldPrefix + "-") {
            return newPrefix + String(sessionName.dropFirst(oldPrefix.count))
        }
        return sessionName
    }

    /// Renames tmux sessions in two phases to avoid collisions during rename.
    /// Dead sessions are skipped; they will be recreated lazily with the new name.
    private func renameTmuxSessions(from oldNames: [String], to newNames: [String]) async throws {
        precondition(oldNames.count == newNames.count)

        var currentNames = oldNames
        var liveIndices: [Int] = []

        for i in oldNames.indices where oldNames[i] != newNames[i] {
            if await tmux.hasSession(name: oldNames[i]) {
                liveIndices.append(i)
            }
        }

        do {
            for i in liveIndices {
                let tempName = "magent-rename-\(UUID().uuidString.lowercased())"
                try await tmux.renameSession(from: oldNames[i], to: tempName)
                currentNames[i] = tempName
            }

            for i in liveIndices {
                try await tmux.renameSession(from: currentNames[i], to: newNames[i])
                currentNames[i] = newNames[i]
            }
        } catch {
            // Best-effort rollback so the model doesn't diverge from live tmux state.
            for i in liveIndices.reversed() where currentNames[i] != oldNames[i] {
                try? await tmux.renameSession(from: currentNames[i], to: oldNames[i])
            }
            throw error
        }
    }

    /// Removes broken symlinks from all projects' worktrees base directories.
    private func cleanupAllBrokenSymlinks() {
        let settings = persistence.loadSettings()
        for project in settings.projects {
            cleanupBrokenSymlinks(in: project.resolvedWorktreesBasePath())
        }
    }

    /// Removes broken symlinks from the worktrees base directory.
    /// Rename operations leave symlinks (old-name → actual-worktree-dir) that become
    /// stale once the worktree is archived/removed.
    private func cleanupBrokenSymlinks(in directory: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries {
            let fullPath = (directory as NSString).appendingPathComponent(entry)
            let url = URL(fileURLWithPath: fullPath)
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink == true else { continue }
            // Broken symlink: the target no longer exists
            if !fm.fileExists(atPath: fullPath) {
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    private func createCompatibilitySymlink(from oldPath: String, to newPath: String) {
        let fileManager = FileManager.default
        let oldURL = URL(fileURLWithPath: oldPath)

        if let values = try? oldURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            try? fileManager.removeItem(atPath: oldPath)
        }

        guard !fileManager.fileExists(atPath: oldPath) else { return }
        try? fileManager.createSymbolicLink(atPath: oldPath, withDestinationPath: newPath)
    }

    /// Path to the Magent-specific Claude Code hooks settings file.
    private static let claudeHooksSettingsPath = "/tmp/magent-claude-hooks.json"

    /// Writes (or refreshes) the Claude Code hooks JSON that Magent injects via `--settings`.
    /// The `Stop` hook writes the tmux session name to the agent-completion event log so
    /// Magent can detect when Claude finishes responding.
    func installClaudeHooksSettings() {
        let marker = "magent-hooks-v1"
        let path = Self.claudeHooksSettingsPath
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing.contains(marker) {
            return
        }
        let eventsPath = "/tmp/magent-agent-completion-events.log"
        // The Stop hook runs `tmux display-message` to get the session name and
        // appends it to the event log. Guarded by MAGENT_WORKTREE_NAME so it
        // only fires inside Magent-managed sessions.
        let json = """
        {
            "_comment": "\(marker)",
            "hooks": {
                "Stop": [
                    {
                        "hooks": [
                            {
                                "type": "command",
                                "command": "[ -n \\"$MAGENT_WORKTREE_NAME\\" ] && tmux display-message -p '#{session_name}' >> \(eventsPath) || true",
                                "timeout": 5
                            }
                        ]
                    }
                ]
            }
        }
        """
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Ensures the Codex CLI config has `tui.notification_method = "bel"` so the
    /// pipe-pane bell watcher can detect when Codex finishes a turn.
    func ensureCodexBellNotification() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let configPath = configDir.appendingPathComponent("config.toml").path

        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            // No config file — create a minimal one with just the tui section.
            try? FileManager.default.createDirectory(atPath: configDir.path, withIntermediateDirectories: true)
            let minimal = "\n[tui]\nnotification_method = \"bel\"\n"
            try? minimal.write(toFile: configPath, atomically: true, encoding: .utf8)
            return
        }

        // Already has the setting — nothing to do.
        if contents.contains("notification_method") {
            return
        }

        // Append [tui] section with the bel setting.
        var updated = contents
        if !updated.hasSuffix("\n") { updated += "\n" }
        if contents.contains("[tui]") {
            // [tui] section exists but without notification_method — insert after it.
            updated = updated.replacingOccurrences(
                of: "[tui]",
                with: "[tui]\nnotification_method = \"bel\""
            )
        } else {
            updated += "\n[tui]\nnotification_method = \"bel\"\n"
        }
        try? updated.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Builds the shell command to start the selected agent with any required agent-specific setup.
    private static let userShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    private func agentStartCommand(
        settings: AppSettings,
        agentType: AgentType?,
        envExports: String,
        workingDirectory: String
    ) -> String {
        let shell = Self.userShell
        var parts = [envExports, "cd \(workingDirectory)"]
        guard let agentType else {
            parts.append("exec \(shell) -l")
            return parts.joined(separator: " && ")
        }
        if agentType == .claude {
            parts.append("unset CLAUDECODE")
        }
        var command = settings.command(for: agentType)
        if agentType == .claude {
            command += " --settings \(Self.claudeHooksSettingsPath)"
        }
        // Wrap the agent command in a login shell so user profile files are sourced
        // (sets up PATH, user aliases, etc.) before the agent binary is resolved.
        let innerCmd = parts.joined(separator: " && ") + " && " + command + "; exec \(shell) -l"
        return "exec \(shell) -l -c \(ShellExecutor.shellQuote(innerCmd))"
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
    static let magentAgentCompletionDetected = Notification.Name("magentAgentCompletionDetected")
    static let magentAgentWaitingForInput = Notification.Name("magentAgentWaitingForInput")
    static let magentSectionsDidChange = Notification.Name("magentSectionsDidChange")
    static let magentOpenSettings = Notification.Name("magentOpenSettings")
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
