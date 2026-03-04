import AppKit
import Foundation
import UserNotifications

extension ThreadManager {

    // MARK: - IPC Agent Docs

    static let ipcAgentDocs = """
    You have access to Magent IPC. Use `/tmp/magent-cli` to manage threads and tabs:
      /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--prompt <text>] [--name <slug>] [--description <text>] [--base-thread <name> | --base-branch <name>]
      /tmp/magent-cli list-projects
      /tmp/magent-cli list-threads [--project <name>]
      /tmp/magent-cli send-prompt --thread <name> --prompt <text>
      /tmp/magent-cli archive-thread --thread <name>
      /tmp/magent-cli delete-thread --thread <name>
      /tmp/magent-cli list-tabs --thread <name>
      /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
      /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
      /tmp/magent-cli current-thread
      /tmp/magent-cli auto-rename-thread --thread <name> --prompt <text>
      /tmp/magent-cli rename-thread --thread <name> --prompt <text>
      /tmp/magent-cli rename-branch --thread <name> --name <text>
      /tmp/magent-cli set-description --thread <name> [--description <text> | --clear]
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
    To branch from an existing thread, pass --base-thread <name>. Use --base-branch <name> only when you need an exact branch literal.
    Use auto-rename-thread (or its rename-thread alias) by default; it generates both branch name and description from one prompt.
    Use rename-branch ONLY when the user specifies an exact branch name.
    Use set-description to manually set or clear only the thread description.
    Section commands without --project operate on global sections. With --project, they operate on project-specific overrides.
    """

    // MARK: - Agent Readiness

    /// Polls tmux pane content for agent-specific readiness signals.
    /// Returns `true` when the agent TUI is detected, or `false` on timeout.
    func waitForAgentReady(
        sessionName: String,
        agentType: AgentType?,
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = await tmux.capturePane(sessionName: sessionName, lastLines: 30) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if isAgentContentReady(trimmed, agentType: agentType) {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    /// Checks whether captured pane content indicates the agent is ready,
    /// using agent-specific signals.
    func isAgentContentReady(_ content: String, agentType: AgentType?) -> Bool {
        switch agentType {
        case .claude:
            return content.contains("╭") || content.contains("\u{276F}")
        case .codex:
            return content.contains("\u{276F}") || content.filter({ !$0.isWhitespace }).count > 100
        case .custom, .none:
            return content.filter({ !$0.isWhitespace }).count > 50
        }
    }

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

    func preAgentInjectionCommand(for projectId: UUID, settings: AppSettings) -> String {
        guard let project = settings.projects.first(where: { $0.id == projectId }),
              let command = project.preAgentInjectionCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return "" }
        return command
    }

    func injectAfterStart(sessionName: String, terminalCommand: String, agentContext: String, initialPrompt: String? = nil, agentType: AgentType? = nil) {
        let hasPrompt = initialPrompt != nil && !initialPrompt!.isEmpty
        guard !terminalCommand.isEmpty || !agentContext.isEmpty || hasPrompt else { return }
        Task {
            // Wait for tmux session to start
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !terminalCommand.isEmpty {
                try? await tmux.sendKeys(sessionName: sessionName, keys: terminalCommand)
            }
            if hasPrompt {
                // When an initial prompt is provided, skip the agent context injection
                // and send only the prompt. The agent context would race with the prompt —
                // submitting as a first prompt that blocks the real one.
                // Wait for the agent TUI to be ready before sending the prompt.
                _ = await waitForAgentReady(sessionName: sessionName, agentType: agentType)
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

    func agentType(for thread: MagentThread, sessionName: String) -> AgentType? {
        if let mapped = thread.sessionAgentTypes[sessionName] {
            return mapped
        }
        if thread.agentTmuxSessions.contains(sessionName) {
            return thread.selectedAgentType
        }
        return nil
    }

    // MARK: - Session-State Rekey/Prune

    /// Rekeys transient, session-scoped state after tmux session renames.
    /// Keeps only sessions that are still agent tabs for this thread.
    @discardableResult
    func remapTransientSessionState(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        guard threads.indices.contains(index) else { return false }
        guard !sessionRenameMap.isEmpty else { return false }

        var changed = false
        let validAgentSessions = Set(threads[index].agentTmuxSessions)

        let remappedBusy = Set(
            threads[index].busySessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedBusy != threads[index].busySessions {
            threads[index].busySessions = remappedBusy
            changed = true
        }

        let remappedWaiting = Set(
            threads[index].waitingForInputSessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedWaiting != threads[index].waitingForInputSessions {
            threads[index].waitingForInputSessions = remappedWaiting
            changed = true
        }

        // Keep notification dedup state aligned with waiting sessions after rename.
        let renamedTargets = Set(sessionRenameMap.values)
        for (oldName, newName) in sessionRenameMap where notifiedWaitingSessions.remove(oldName) != nil {
            if remappedWaiting.contains(newName) {
                notifiedWaitingSessions.insert(newName)
            }
        }
        for target in renamedTargets where !remappedWaiting.contains(target) {
            notifiedWaitingSessions.remove(target)
        }

        return changed
    }

    /// Removes stale transient session state that references non-agent sessions.
    /// Returns true when any thread-visible state changed.
    @discardableResult
    func pruneTransientSessionStateToKnownAgentSessions(threadIndex index: Int) -> Bool {
        guard threads.indices.contains(index) else { return false }

        var changed = false
        let validAgentSessions = Set(threads[index].agentTmuxSessions)

        let prunedBusy = threads[index].busySessions.intersection(validAgentSessions)
        if prunedBusy != threads[index].busySessions {
            threads[index].busySessions = prunedBusy
            changed = true
        }

        let oldWaiting = threads[index].waitingForInputSessions
        let prunedWaiting = oldWaiting.intersection(validAgentSessions)
        if prunedWaiting != oldWaiting {
            let removed = oldWaiting.subtracting(prunedWaiting)
            for session in removed {
                notifiedWaitingSessions.remove(session)
            }
            threads[index].waitingForInputSessions = prunedWaiting
            changed = true
        }

        return changed
    }

    // MARK: - Session Naming (delegates to TmuxSessionNaming)

    /// Renames session names produced by Magent without touching unrelated substrings.
    func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
        TmuxSessionNaming.renamedSessionName(sessionName, fromThreadName: oldName, toThreadName: newName, repoSlug: repoSlug)
    }

    static func sanitizeForTmux(_ name: String) -> String {
        TmuxSessionNaming.sanitizeForTmux(name)
    }

    static func repoSlug(from projectName: String) -> String {
        TmuxSessionNaming.repoSlug(from: projectName)
    }

    static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        TmuxSessionNaming.buildSessionName(repoSlug: repoSlug, threadName: threadName, tabSlug: tabSlug)
    }

    static func isMagentSession(_ name: String) -> Bool {
        TmuxSessionNaming.isMagentSession(name)
    }

    // MARK: - Symlinks (delegates to SymlinkManager)

    func cleanupAllBrokenSymlinks() {
        SymlinkManager.cleanupAll(settings: persistence.loadSettings())
    }

    func createCompatibilitySymlink(from oldPath: String, to newPath: String) {
        SymlinkManager.createCompatibilitySymlink(from: oldPath, to: newPath)
    }

    // MARK: - Claude Hooks

    /// Path to the Magent-specific Claude Code hooks settings file.
    static let claudeHooksSettingsPath = "/tmp/magent-claude-hooks.json"

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

    // MARK: - Codex Config

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

    // MARK: - Codex IPC Instructions

    private static let codexIPCMarkerStart = "<!-- magent-ipc-start -->"
    private static let codexIPCMarkerEnd = "<!-- magent-ipc-end -->"
    private static let codexIPCVersion = "<!-- magent-ipc-v8 -->"

    private static let codexIPCBlock = """
    \(codexIPCMarkerStart)
    \(codexIPCVersion)
    # Magent IPC

    When the `MAGENT_SOCKET` environment variable is set, you are running inside
    a Magent-managed terminal. Use `/tmp/magent-cli` to manage threads and tabs:

    ```
    /tmp/magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--prompt <text>] [--name <slug>] [--description <text>] [--base-thread <name> | --base-branch <name>]
    /tmp/magent-cli list-projects
    /tmp/magent-cli list-threads [--project <name>]
    /tmp/magent-cli send-prompt --thread <name> --prompt <text>
    /tmp/magent-cli archive-thread --thread <name>
    /tmp/magent-cli delete-thread --thread <name>
    /tmp/magent-cli list-tabs --thread <name>
    /tmp/magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]
    /tmp/magent-cli close-tab --thread <name> (--index <n> | --session <name>)
    /tmp/magent-cli current-thread
    /tmp/magent-cli auto-rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-thread --thread <name> --prompt <text>
    /tmp/magent-cli rename-branch --thread <name> --name <text>
    /tmp/magent-cli set-description --thread <name> [--description <text> | --clear]
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
    To branch from an existing thread, pass `--base-thread <name>`. Use `--base-branch <name>` only when you need an exact branch literal.
    Use `auto-rename-thread` (or its `rename-thread` alias) by default; it generates both branch name and description from one prompt.
    Use `rename-branch` ONLY when the user specifies an exact branch name.
    Use `set-description` to manually set or clear only the thread description.
    Section commands without `--project` operate on global sections. With `--project`, they operate on project-specific overrides.
    \(codexIPCMarkerEnd)
    """

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

    // MARK: - Agent Start Command

    private static let managedZdotdirPath = "/tmp/magent-zdotdir"
    private static let managedZdotdirMarker = "# magent-zdotdir-v1"
    private static let managedZdotdirFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
    private static let managedZdotdirLock = NSLock()
    private static let userShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()
    private static let startupShell: String = {
        let shell = userShell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        return shellName.contains("zsh") ? shell : "/bin/zsh"
    }()

    private static func managedZdotfileContents(fileName: String) -> String {
        switch fileName {
        case ".zshrc":
            return """
            \(managedZdotdirMarker)
            export ZDOTDIR="$HOME"
            if [ -f "$HOME/.zshrc" ]; then
              source "$HOME/.zshrc"
            fi
            if [ -n "${MAGENT_START_CWD:-}" ] && [ -d "${MAGENT_START_CWD}" ]; then
              cd -- "${MAGENT_START_CWD}" || true
            fi
            unset MAGENT_START_CWD
            """
        case ".zshenv", ".zprofile", ".zlogin", ".zlogout":
            return """
            \(managedZdotdirMarker)
            if [ -f "$HOME/\(fileName)" ]; then
              source "$HOME/\(fileName)"
            fi
            """
        default:
            return "\(managedZdotdirMarker)\n"
        }
    }

    @discardableResult
    func ensureManagedZdotdir() -> String {
        Self.managedZdotdirLock.lock()
        defer { Self.managedZdotdirLock.unlock() }

        let path = Self.managedZdotdirPath
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            try? fileManager.removeItem(atPath: path)
        }
        try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)

        for fileName in Self.managedZdotdirFiles {
            let filePath = "\(path)/\(fileName)"
            let desired = Self.managedZdotfileContents(fileName: fileName)
            if let existing = try? String(contentsOfFile: filePath, encoding: .utf8),
               existing == desired {
                continue
            }
            try? desired.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        return path
    }

    func cleanupManagedZdotdir() {
        Self.managedZdotdirLock.lock()
        defer { Self.managedZdotdirLock.unlock() }
        try? FileManager.default.removeItem(atPath: Self.managedZdotdirPath)
    }

    func terminalStartCommand(
        envExports: String,
        workingDirectory: String
    ) -> String {
        let shell = ShellExecutor.shellQuote(Self.startupShell)
        let zdotdir = ShellExecutor.shellQuote(ensureManagedZdotdir())
        let startCwd = ShellExecutor.shellQuote(workingDirectory)
        return "\(envExports) && exec env MAGENT_START_CWD=\(startCwd) ZDOTDIR=\(zdotdir) \(shell) -l"
    }

    func agentStartCommand(
        settings: AppSettings,
        projectId: UUID? = nil,
        agentType: AgentType?,
        envExports: String,
        workingDirectory: String
    ) -> String {
        let shell = ShellExecutor.shellQuote(Self.startupShell)
        let zdotdir = ShellExecutor.shellQuote(ensureManagedZdotdir())
        let startCwd = ShellExecutor.shellQuote(workingDirectory)
        let preAgentCommand = projectId.map { preAgentInjectionCommand(for: $0, settings: settings) } ?? ""

        guard let agentType else {
            return terminalStartCommand(envExports: envExports, workingDirectory: workingDirectory)
        }

        var parts = [String]()
        if agentType == .claude {
            parts.append("unset CLAUDECODE")
        }
        if !preAgentCommand.isEmpty {
            // Pre-agent startup commands are best-effort and should not block agent launch.
            parts.append("{ \(preAgentCommand) ; } || true")
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
        parts.append(command)
        let innerCmd = parts.joined(separator: " && ") + "; exec \(shell) -l"
        return "\(envExports) && exec env MAGENT_START_CWD=\(startCwd) ZDOTDIR=\(zdotdir) \(shell) -l -c \(ShellExecutor.shellQuote(innerCmd))"
    }

    // MARK: - Name Availability

    func isNameAvailable(_ name: String, project: Project) async throws -> Bool {
        let nameInUse = threads.contains(where: { $0.name == name })
        let dirExists = FileManager.default.fileExists(
            atPath: "\(project.resolvedWorktreesBasePath())/\(name)"
        )
        guard !nameInUse && !dirExists else { return false }

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: name)
        let slug = Self.repoSlug(from: project.name)
        let settings = persistence.loadSettings()
        let agentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)
        let firstTabSlug = Self.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: agentType))
        let tmuxExists = await tmux.hasSession(name: Self.buildSessionName(repoSlug: slug, threadName: name, tabSlug: firstTabSlug))
        return !branchExists && !tmuxExists
    }

    // MARK: - Agent Trust

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
}

// MARK: - Notification Names

extension Notification.Name {
    static let magentDeadSessionsDetected = Notification.Name("magentDeadSessionsDetected")
    static let magentAgentCompletionDetected = Notification.Name("magentAgentCompletionDetected")
    static let magentAgentWaitingForInput = Notification.Name("magentAgentWaitingForInput")
    static let magentAgentBusySessionsChanged = Notification.Name("magentAgentBusySessionsChanged")
    static let magentAgentRateLimitChanged = Notification.Name("magentAgentRateLimitChanged")
    static let magentGlobalRateLimitSummaryChanged = Notification.Name("magentGlobalRateLimitSummaryChanged")
    static let magentSectionsDidChange = Notification.Name("magentSectionsDidChange")
    static let magentOpenSettings = Notification.Name("magentOpenSettings")
    static let magentShowDiffViewer = Notification.Name("magentShowDiffViewer")
    static let magentHideDiffViewer = Notification.Name("magentHideDiffViewer")
    static let magentNavigateToThread = Notification.Name("magentNavigateToThread")
    static let magentPullRequestInfoChanged = Notification.Name("magentPullRequestInfoChanged")
}

// MARK: - Errors

enum ThreadManagerError: LocalizedError {
    case threadNotFound
    case invalidName
    case invalidDescription
    case duplicateName
    case invalidTabIndex
    case cannotDeleteMainThread
    case nameGenerationFailed
    case worktreePathConflict([String])
    case noExpectedBranch

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "Thread not found"
        case .invalidName:
            return "Invalid name. Name must not be empty or contain slashes."
        case .invalidDescription:
            return "Invalid description. Use 1-8 words with at least one letter."
        case .duplicateName:
            return "A thread with that name already exists."
        case .invalidTabIndex:
            return "Invalid tab index."
        case .cannotDeleteMainThread:
            return "Main threads cannot be deleted."
        case .nameGenerationFailed:
            return "Could not generate a unique thread name. Try again or clean up unused worktrees/branches."
        case .worktreePathConflict(let names):
            let list = names.joined(separator: ", ")
            return "Cannot move worktrees — the following directories already exist in the destination: \(list)"
        case .noExpectedBranch:
            return "No expected branch configured. Set the default branch in project settings."
        }
    }
}
