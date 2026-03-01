import Foundation

extension ThreadManager {

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

    private func generateSlugViaAgent(from prompt: String, agentType: AgentType?, projectId: UUID?) async -> String? {
        let truncated = String(prompt.prefix(500))
        let settings = persistence.loadSettings()
        let projectSlug = projectId.flatMap { pid in
            settings.projects.first(where: { $0.id == pid })?.autoRenameSlugPrompt
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let globalSlug = settings.autoRenameSlugPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let customInstruction = (projectSlug?.isEmpty == false ? projectSlug : nil)
            ?? (globalSlug.isEmpty ? nil : globalSlug)
        let instruction = customInstruction ?? AppSettings.defaultSlugPrompt
        let aiPrompt = """
            \(instruction) \
            Output ONLY the prefix SLUG: followed by the slug. No quotes, no explanation. \
            Only output SLUG: EMPTY for pure knowledge questions with no implied action (e.g. "How does X work?", "What is Y?"). \
            Bug reports, observations about broken behavior, and feature requests are actionable — always generate a slug for them. \
            Example: "Fix auth bug in login" → SLUG: fix-auth-login \
            Example: "I want to have a way for agents to communicate with the app so it can create threads automatically" → SLUG: agent-app-communication \
            Example: "I noticed the sidebar chevrons have no padding on app start" → SLUG: fix-sidebar-chevron-padding \
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

    func autoRenameCandidates(from prompt: String, agentType: AgentType?, projectId: UUID? = nil) async -> [String] {
        if let slug = await generateSlugViaAgent(from: prompt, agentType: agentType, projectId: projectId) {
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

        // Look up project for repo path and repo slug
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }
        let slug = Self.repoSlug(from: project.name)

        let sessionRenameMap = Dictionary(uniqueKeysWithValues: currentThread.tmuxSessionNames.map { sessionName in
            (sessionName, renamedSessionName(sessionName, fromThreadName: oldName, toThreadName: trimmed, repoSlug: slug))
        })
        let oldSessionNames = Set(currentThread.tmuxSessionNames)
        let newSessionNames = currentThread.tmuxSessionNames.map { sessionRenameMap[$0] ?? $0 }

        // Check for conflicts with git branch and tmux sessions.
        // Allow if the target branch is the thread's own branch (renaming back to a previous name,
        // or stored branchName is out of sync with the actual worktree branch).
        let actualWorktreeBranch = await git.getCurrentBranch(workingDirectory: currentThread.worktreePath)
        let branchAlreadyOwned = currentThread.branchName == newBranchName
            || actualWorktreeBranch == newBranchName
        if !branchAlreadyOwned, await git.branchExists(repoPath: project.repoPath, branchName: newBranchName) {
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

        // 1. Rename git branch (skip if already on the target branch)
        if !branchAlreadyOwned {
            // Use the actual worktree branch if stored branchName is stale
            let oldBranch = actualWorktreeBranch ?? currentThread.branchName
            try await git.renameBranch(repoPath: project.repoPath, oldName: oldBranch, newName: newBranchName)
        }

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
        // Only auto-rename threads that still have an auto-generated name.
        // Threads created via CLI with an explicit name/description should keep it.
        guard NameGenerator.isAutoGenerated(thread.name) else { return }
        guard thread.agentTmuxSessions.contains(sessionName) else { return }
        guard !autoRenameInProgress.contains(thread.id) else { return }

        let candidates = await autoRenameCandidates(from: prompt, agentType: thread.selectedAgentType, projectId: thread.projectId)
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
        let settings = persistence.loadSettings()
        let slug = Self.repoSlug(from:
            settings.projects.first(where: { $0.id == currentThread.projectId })?.name ?? "project"
        )
        let newSessionName: String
        if currentThread.isMain {
            newSessionName = Self.buildSessionName(repoSlug: slug, threadName: nil, tabSlug: sanitizedTabName)
        } else {
            newSessionName = Self.buildSessionName(repoSlug: slug, threadName: currentThread.name, tabSlug: sanitizedTabName)
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

}
