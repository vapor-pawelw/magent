import AppKit
import Foundation
import UserNotifications

extension ThreadManager {

    // MARK: - IPC Agent Docs

    static let ipcAgentDocs = """
    You have access to Magent IPC. Use `/tmp/magent-cli` to manage threads and tabs:
      /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom] [--prompt <text>] [--name <slug>] [--description <text>]
      /tmp/magent-cli list-projects
      /tmp/magent-cli list-threads [--project <name>]
      /tmp/magent-cli send-prompt --thread <name> --prompt <text>
      /tmp/magent-cli archive-thread --thread <name>
      /tmp/magent-cli delete-thread --thread <name>
      /tmp/magent-cli list-tabs --thread <name>
      /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
      /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
      /tmp/magent-cli current-thread
      /tmp/magent-cli rename-thread --thread <name> --description <text>
      /tmp/magent-cli rename-thread-exact --thread <name> --name <text>
      /tmp/magent-cli thread-info --thread <name>
      /tmp/magent-cli list-sections [--project <name>]
      /tmp/magent-cli add-section --name <name> [--color <hex>] [--project <name>]
      /tmp/magent-cli remove-section --name <name> [--project <name>]
      /tmp/magent-cli reorder-section --name <name> --position <n> [--project <name>]
      /tmp/magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]
      /tmp/magent-cli hide-section --name <name> [--project <name>]
      /tmp/magent-cli show-section --name <name> [--project <name>]
    Use current-thread to discover your thread name (do not rely on the worktree directory name — it may differ after renames).
    When creating threads, use --description to name them upfront (AI generates a slug respecting project naming rules). Only use --name when the user explicitly provides a literal name. Omit both for a random name.
    Use rename-thread by default (generates a slug from the description). Only use rename-thread-exact when the user specifies an exact name.
    rename-thread-exact is ONLY for when the user gives a literal name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about (e.g. "rename this to something about authentication"), use rename-thread with that description instead.
    Section commands without --project operate on global sections. With --project, they operate on project-specific overrides.
    """

    // MARK: - Injection

    func effectiveInjection(for projectId: UUID) -> (terminalCommand: String, agentContext: String) {
        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == projectId })
        let termCmd = (project?.terminalInjectionCommand?.isEmpty == false)
            ? project!.terminalInjectionCommand! : settings.terminalInjectionCommand
        let agentCtx = (project?.agentContextInjection?.isEmpty == false)
            ? project!.agentContextInjection! : settings.agentContextInjection
        return (termCmd, agentCtx)
    }

    func injectAfterStart(sessionName: String, terminalCommand: String, agentContext: String, initialPrompt: String? = nil) {
        let hasPrompt = initialPrompt != nil && !initialPrompt!.isEmpty
        guard !terminalCommand.isEmpty || !agentContext.isEmpty || hasPrompt else { return }
        Task {
            // Wait for shell/agent to initialize
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !terminalCommand.isEmpty {
                try? await tmux.sendKeys(sessionName: sessionName, keys: terminalCommand)
            }
            if hasPrompt {
                // When an initial prompt is provided, skip the agent context injection
                // and send only the prompt. The agent context would race with the prompt —
                // submitting as a first prompt that blocks the real one.
                // Give the agent extra time to finish initializing its TUI.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                // Send text and Enter separately — the Enter key gets lost if sent in the
                // same send-keys call while the TUI is still processing buffered input.
                try? await tmux.sendText(sessionName: sessionName, text: initialPrompt!)
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await tmux.sendEnter(sessionName: sessionName)
            } else if !agentContext.isEmpty {
                // No initial prompt — send agent context as usual
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


    // MARK: - Helpers

    /// Renames session names produced by Magent without touching unrelated substrings.
    /// This avoids accidental rewrites when thread names overlap with the "magent" prefix.
    func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
        let oldPrefix = Self.buildSessionName(repoSlug: repoSlug, threadName: oldName)
        let newPrefix = Self.buildSessionName(repoSlug: repoSlug, threadName: newName)

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
    func renameTmuxSessions(from oldNames: [String], to newNames: [String]) async throws {
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
                let tempName = "ma-rename-\(UUID().uuidString.lowercased())"
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
    func cleanupAllBrokenSymlinks() {
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

    func createCompatibilitySymlink(from oldPath: String, to newPath: String) {
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

    private static let codexIPCMarkerStart = "<!-- magent-ipc-start -->"
    private static let codexIPCMarkerEnd = "<!-- magent-ipc-end -->"
    private static let codexIPCVersion = "<!-- magent-ipc-v6 -->"

    private static let codexIPCBlock = """
    \(codexIPCMarkerStart)
    \(codexIPCVersion)
    # Magent IPC

    When the `MAGENT_SOCKET` environment variable is set, you are running inside
    a Magent-managed terminal. Use `/tmp/magent-cli` to manage threads and tabs:

    ```
    /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom] [--prompt <text>] [--name <slug>] [--description <text>]
    /tmp/magent-cli list-projects
    /tmp/magent-cli list-threads [--project <name>]
    /tmp/magent-cli send-prompt --thread <name> --prompt <text>
    /tmp/magent-cli archive-thread --thread <name>
    /tmp/magent-cli delete-thread --thread <name>
    /tmp/magent-cli list-tabs --thread <name>
    /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
    /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
    /tmp/magent-cli current-thread
    /tmp/magent-cli rename-thread --thread <name> --description <text>
    /tmp/magent-cli rename-thread-exact --thread <name> --name <text>
    /tmp/magent-cli thread-info --thread <name>
    /tmp/magent-cli list-sections [--project <name>]
    /tmp/magent-cli add-section --name <name> [--color <hex>] [--project <name>]
    /tmp/magent-cli remove-section --name <name> [--project <name>]
    /tmp/magent-cli reorder-section --name <name> --position <n> [--project <name>]
    /tmp/magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]
    /tmp/magent-cli hide-section --name <name> [--project <name>]
    /tmp/magent-cli show-section --name <name> [--project <name>]
    ```

    Use `current-thread` to discover your thread name (do not rely on the worktree directory name — it may differ after renames).
    When creating threads, use `--description` to name them upfront (AI generates a slug respecting project naming rules). Only use `--name` when the user explicitly provides a literal name. Omit both for a random name.
    Use `rename-thread` by default (generates a slug from the description).
    Only use `rename-thread-exact` when the user specifies an exact name.
    `rename-thread-exact` is ONLY for when the user gives a literal name (e.g. "rename this to kimchi-ramen"). If the user describes what the thread is about (e.g. "rename this to something about authentication"), use `rename-thread` with that description instead.
    Section commands without `--project` operate on global sections. With `--project`, they operate on project-specific overrides.
    \(codexIPCMarkerEnd)
    """

    /// Writes or updates the Magent IPC section in `~/.codex/AGENTS.md` so Codex
    /// agents auto-discover `magent-cli`. Preserves any existing user content;
    /// only the delimited Magent section is managed.
    func installCodexIPCInstructions() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let filePath = codexDir.appendingPathComponent("AGENTS.md").path

        if let existing = try? String(contentsOfFile: filePath, encoding: .utf8) {
            // Already up to date
            if existing.contains(Self.codexIPCVersion) { return }

            // Replace outdated Magent section if present
            if let startRange = existing.range(of: Self.codexIPCMarkerStart),
               let endRange = existing.range(of: Self.codexIPCMarkerEnd),
               startRange.lowerBound <= endRange.lowerBound {
                var updated = existing
                updated.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: Self.codexIPCBlock)
                try? updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            } else {
                // Append to existing user content
                var updated = existing
                if !updated.hasSuffix("\n") { updated += "\n" }
                updated += "\n" + Self.codexIPCBlock + "\n"
                try? updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            }
        } else {
            // No file — create with just the IPC section
            try? FileManager.default.createDirectory(
                atPath: codexDir.path,
                withIntermediateDirectories: true
            )
            try? Self.codexIPCBlock.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }

    /// Builds the shell command to start the selected agent with any required agent-specific setup.
    private static let userShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    func agentStartCommand(
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
            if settings.ipcPromptInjectionEnabled {
                command += " --append-system-prompt \(ShellExecutor.shellQuote(Self.ipcAgentDocs))"
            }
        }
        // Wrap the agent command in a login shell so user profile files are sourced
        // (sets up PATH, user aliases, etc.) before the agent binary is resolved.
        let innerCmd = parts.joined(separator: " && ") + " && " + command + "; exec \(shell) -l"
        return "exec \(shell) -l -c \(ShellExecutor.shellQuote(innerCmd))"
    }

    /// Checks if a thread name is available (no conflicts with existing threads, worktrees, branches, or tmux sessions).
    func isNameAvailable(_ name: String, project: Project) async throws -> Bool {
        let nameInUse = threads.contains(where: { $0.name == name })
        let dirExists = FileManager.default.fileExists(
            atPath: "\(project.resolvedWorktreesBasePath())/\(name)"
        )
        guard !nameInUse && !dirExists else { return false }

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: name)
        let slug = Self.repoSlug(from: project.name)
        let firstTabSlug = Self.sanitizeForTmux(MagentThread.defaultDisplayName(at: 0))
        let tmuxExists = await tmux.hasSession(name: Self.buildSessionName(repoSlug: slug, threadName: name, tabSlug: firstTabSlug))
        return !branchExists && !tmuxExists
    }

    /// Runs agent-specific post-setup (e.g. pre-trusting directories for Claude Code).
    func trustDirectoryIfNeeded(_ path: String, agentType: AgentType?) {
        switch agentType {
        case .claude:
            ClaudeTrustHelper.trustDirectory(path)
        case .codex:
            CodexTrustHelper.trustDirectory(path)
        case .custom, .none:
            break
        }
    }

    func resolveAgentType(
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

    func isTabNameTaken(_ name: String, existingNames: [String]) async -> Bool {
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

    static func repoSlug(from projectName: String) -> String {
        var slug = sanitizeForTmux(projectName)
        if slug.count > 16 {
            slug = String(slug.prefix(16))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug
    }

    static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        var parts = ["ma", repoSlug]
        if let threadName {
            parts.append(threadName)
        }
        if let tabSlug {
            parts.append(tabSlug)
        }
        return parts.joined(separator: "-")
    }

    static func isMagentSession(_ name: String) -> Bool {
        name.hasPrefix("ma-") || name.hasPrefix("magent-")
    }

    // MARK: - Tmux Zombie Health

    func checkTmuxZombieHealth() async {
        let now = Date()
        guard now.timeIntervalSince(lastTmuxZombieHealthCheckAt) >= 15 else { return }
        lastTmuxZombieHealthCheckAt = now
        guard !isRestartingTmuxForRecovery else { return }

        let summaries = await tmux.zombieParentSummaries()
        let threshold = 200
        guard let worst = summaries.max(by: { $0.zombieCount < $1.zombieCount }),
              worst.zombieCount >= threshold else {
            didShowTmuxZombieWarning = false
            return
        }
        guard !didShowTmuxZombieWarning else { return }
        didShowTmuxZombieWarning = true

        await MainActor.run {
            BannerManager.shared.show(
                message: "tmux health issue: \(worst.zombieCount) defunct processes on parent \(worst.parentPid). Restart and recover sessions.",
                style: .warning,
                duration: nil,
                actions: [
                    BannerAction(title: "Restart tmux + Recover") { [weak self] in
                        Task { await self?.restartTmuxAndRecoverSessions() }
                    },
                    BannerAction(title: "Ignore") { [weak self] in
                        self?.didShowTmuxZombieWarning = false
                    },
                ]
            )
        }
    }

    func restartTmuxAndRecoverSessions() async {
        guard !isRestartingTmuxForRecovery else { return }
        isRestartingTmuxForRecovery = true
        didShowTmuxZombieWarning = false

        await MainActor.run {
            BannerManager.shared.show(
                message: "Restarting tmux and recovering sessions...",
                style: .warning,
                duration: nil,
                isDismissible: false
            )
            stopSessionMonitor()
        }

        await tmux.killServer()

        var recreatedCount = 0
        let activeThreads = threads.filter { !$0.isArchived }
        for thread in activeThreads {
            for sessionName in thread.tmuxSessionNames {
                let recreated = await recreateSessionIfNeeded(sessionName: sessionName, thread: thread)
                if recreated {
                    recreatedCount += 1
                }
            }
        }

        await ensureBellPipes()
        await syncBusySessionsFromProcessState()
        _ = await cleanupStaleMagentSessions()
        try? persistence.saveThreads(threads)

        isRestartingTmuxForRecovery = false

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            BannerManager.shared.show(
                message: "tmux restarted. Recovered \(recreatedCount) session\(recreatedCount == 1 ? "" : "s").",
                style: .info
            )
            startSessionMonitor()
        }
    }
}

extension Notification.Name {
    static let magentDeadSessionsDetected = Notification.Name("magentDeadSessionsDetected")
    static let magentAgentCompletionDetected = Notification.Name("magentAgentCompletionDetected")
    static let magentAgentWaitingForInput = Notification.Name("magentAgentWaitingForInput")
    static let magentAgentBusySessionsChanged = Notification.Name("magentAgentBusySessionsChanged")
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
