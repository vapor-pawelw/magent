import Foundation

extension ThreadManager {

    // MARK: - Tmux Session Rename (two-phase to avoid collisions)

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
            for i in liveIndices.reversed() where currentNames[i] != oldNames[i] {
                try? await tmux.renameSession(from: currentNames[i], to: oldNames[i])
            }
            throw error
        }
    }

    // MARK: - Rename

    private static let slugGenerationTrackableAgents: [AgentType] = [.claude, .codex]

    private func slugGenerationAgentOrder(preferred preferredAgent: AgentType?, projectId: UUID?) -> (allTrackable: [AgentType], available: [AgentType]) {
        let settings = persistence.loadSettings()
        let resolvedPreferred: AgentType? = {
            if let preferredAgent { return preferredAgent }
            if let projectId {
                return resolveAgentType(for: projectId, requestedAgentType: nil, settings: settings)
            }
            return settings.effectiveGlobalDefaultAgentType
        }()

        let activeTrackable = settings.availableActiveAgents.filter { Self.slugGenerationTrackableAgents.contains($0) }
        var ordered: [AgentType] = []
        func appendIfTrackable(_ candidate: AgentType?) {
            guard let candidate,
                  activeTrackable.contains(candidate),
                  !ordered.contains(candidate) else {
                return
            }
            ordered.append(candidate)
        }

        // Prefer the selected/default agent first when possible.
        appendIfTrackable(resolvedPreferred)
        // Then try explicitly active built-ins in user-defined order.
        for active in activeTrackable {
            appendIfTrackable(active)
        }

        let available = ordered
        return (allTrackable: ordered, available: available)
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

    private enum SlugGenerationAttemptResult {
        case slug(String)
        case question
        case failed
    }

    private enum FirstPromptRenameAttemptResult {
        case generated(slug: String, taskDescription: GeneratedTaskDescription?)
        case question
        case failed
    }

    private func codexBackgroundExecCommand(escapedPrompt: String) -> String {
        // ShellExecutor uses a minimal PATH; include common user-local install
        // locations so background rename/description jobs can resolve Codex.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = ShellExecutor.shellQuote("\(homeDir)/.local/bin")
        let miseShims = ShellExecutor.shellQuote("\(homeDir)/.local/share/mise/shims")
        return "PATH=\(localBin):\(miseShims):$PATH codex exec \(escapedPrompt) --ephemeral --config model_reasoning_effort=none"
    }

    private func backgroundGenerationWorkingDirectory(projectId: UUID?) -> String? {
        guard let projectId else { return nil }
        let settings = persistence.loadSettings()
        return settings.projects.first(where: { $0.id == projectId })?.repoPath
    }

    private func generateSlugViaAgent(from prompt: String, agentType: AgentType?, projectId: UUID?) async -> SlugGenerationAttemptResult {
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
            Only output SLUG: EMPTY for questions or actions unrelated to the project in this worktree. \
            Task: \(truncated)
            """

        let escapedPrompt = ShellExecutor.shellQuote(aiPrompt)
        let workingDirectory = backgroundGenerationWorkingDirectory(projectId: projectId)
        let command: String
        switch agentType {
        case .codex:
            command = codexBackgroundExecCommand(escapedPrompt: escapedPrompt)
        default:
            // Use claude for .claude, .custom, and nil (claude is a prerequisite for this app)
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence"
        }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await ShellExecutor.execute(command, workingDirectory: workingDirectory)
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

        guard let raw = result, !raw.isEmpty else { return .failed }
        guard let slug = sanitizeSlug(raw) else { return .failed }
        if slug == Self.slugQuestionSentinel {
            return .question
        }
        return .slug(slug)
    }

    /// First-prompt optimization: fetch branch slug + task description in one model call.
    private func generateFirstPromptRenamePayloadViaAgent(
        from prompt: String,
        agentType: AgentType?,
        projectId: UUID?
    ) async -> FirstPromptRenameAttemptResult {
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
            Also generate a short task description (2-8 words) with first letter uppercase. \
            Icon types: feature (new functionality), fix (bug/regression), improvement (non-breaking polish/performance/quality), refactor (internal code restructure), test (adding/updating tests), other (none fit). \
            Evaluate all icon types and use other when no icon type is above 70% confidence. \
            Output exactly three lines and nothing else: \
            SLUG: <slug or EMPTY> \
            DESC: <description or EMPTY> \
            TYPE: <feature|fix|improvement|refactor|test|other> \
            Use SLUG: EMPTY and DESC: EMPTY for pure knowledge questions with no implied action. \
            Bug reports, observations about broken behavior, and feature requests are actionable — always generate a slug. \
            Task: \(truncated)
            """

        let escapedPrompt = ShellExecutor.shellQuote(aiPrompt)
        let workingDirectory = backgroundGenerationWorkingDirectory(projectId: projectId)
        let command: String
        switch agentType {
        case .codex:
            command = codexBackgroundExecCommand(escapedPrompt: escapedPrompt)
        default:
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence"
        }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await ShellExecutor.execute(command, workingDirectory: workingDirectory)
                guard result.exitCode == 0 else { return nil }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let raw = result, !raw.isEmpty else { return .failed }
        guard let slug = sanitizeSlug(raw) else { return .failed }
        if slug == Self.slugQuestionSentinel {
            return .question
        }
        let generatedDescription = sanitizeGeneratedTaskDescription(raw)
        return .generated(slug: slug, taskDescription: generatedDescription)
    }

    enum AutoRenameResult {
        case candidates([String])
        /// The prompt was identified as a question, not a task — no rename needed.
        case question
        /// AI slug generation failed (timeout, error, etc.).
        case failed
    }

    func autoRenameCandidates(
        from prompt: String,
        agentType: AgentType?,
        projectId: UUID? = nil
    ) async -> AutoRenameResult {
        let agentOrder = slugGenerationAgentOrder(preferred: agentType, projectId: projectId)

        let normalCandidates = agentOrder.available
        for candidateAgent in normalCandidates {
            switch await generateSlugViaAgent(from: prompt, agentType: candidateAgent, projectId: projectId) {
            case .slug(let slug):
                return .candidates(renameCandidates(from: slug))
            case .question:
                // A question classification (SLUG: EMPTY) should short-circuit.
                // Retry slug generation only on the next submitted user prompt.
                return .question
            case .failed:
                continue
            }
        }

        return .failed
    }

    private func renameCandidates(from slug: String) -> [String] {
        var candidates = [slug]
        for i in 2...9 {
            candidates.append("\(slug)-\(i)")
        }
        return candidates
    }

    @discardableResult
    private func applyGeneratedRenameMetadataIfNeeded(
        threadId: UUID,
        generatedTaskDescription: GeneratedTaskDescription?
    ) async -> Bool {
        guard let generatedTaskDescription else { return false }
        guard let currentIndex = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        guard threads[currentIndex].taskDescription == nil else { return false }

        threads[currentIndex].taskDescription = generatedTaskDescription.description
        let settings = persistence.loadSettings()
        if settings.autoSetThreadIconFromWorkType,
           !threads[currentIndex].isThreadIconManuallySet {
            threads[currentIndex].threadIcon = generatedTaskDescription.suggestedIcon
        }
        try? persistence.saveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
        return true
    }

    /// Prompt-based rename (manual trigger): generate slug + description + icon
    /// using the same model prompt as first-prompt auto-rename, without
    /// first-prompt eligibility checks.
    @discardableResult
    func renameThreadFromPrompt(
        _ thread: MagentThread,
        prompt: String,
        preferredAgent: AgentType? = nil
    ) async throws -> Bool {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }
        let currentThread = threads[index]
        guard !currentThread.isMain else {
            throw ThreadManagerError.cannotRenameMainThread
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ThreadManagerError.invalidPrompt
        }

        let selectedAgent = preferredAgent ?? currentThread.effectiveAgentType
        let payloadResult = await generateFirstPromptRenamePayloadViaAgent(
            from: trimmedPrompt,
            agentType: selectedAgent,
            projectId: currentThread.projectId
        )

        let slug: String
        let generatedTaskDescription: GeneratedTaskDescription?
        switch payloadResult {
        case .generated(let generatedSlug, let description):
            slug = generatedSlug
            generatedTaskDescription = description
        case .question:
            return false
        case .failed:
            throw ThreadManagerError.nameGenerationFailed
        }

        let candidates = renameCandidates(from: slug).filter { $0 != currentThread.name }
        for candidate in candidates {
            do {
                try await renameThread(currentThread, to: candidate, markFirstPromptRenameHandled: false)
                _ = await applyGeneratedRenameMetadataIfNeeded(
                    threadId: currentThread.id,
                    generatedTaskDescription: generatedTaskDescription
                )
                return true
            } catch ThreadManagerError.duplicateName {
                continue
            }
        }

        throw ThreadManagerError.duplicateName
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
        _ = remapTransientSessionState(threadIndex: index, sessionRenameMap: sessionRenameMap)
        threads[index].unreadCompletionSessions = Set(
            threads[index].unreadCompletionSessions.map { sessionRenameMap[$0] ?? $0 }
        )
        threads[index].rateLimitedSessions = Dictionary(
            uniqueKeysWithValues: threads[index].rateLimitedSessions.map { key, value in
                (sessionRenameMap[key] ?? key, value)
            }
        )
        threads[index].sessionAgentTypes = Dictionary(
            uniqueKeysWithValues: threads[index].sessionAgentTypes.map { key, value in
                (sessionRenameMap[key] ?? key, value)
            }
        )
        threads[index].sessionConversationIDs = Dictionary(
            uniqueKeysWithValues: threads[index].sessionConversationIDs.map { key, value in
                (sessionRenameMap[key] ?? key, value)
            }
        )
        // Re-key custom tab names to reflect new session names
        var newCustomTabNames: [String: String] = [:]
        for (oldKey, value) in threads[index].customTabNames {
            let newKey = sessionRenameMap[oldKey] ?? oldKey
            newCustomTabNames[newKey] = value
        }
        threads[index].customTabNames = newCustomTabNames
        _ = remapSubmittedPromptHistory(threadIndex: index, sessionRenameMap: sessionRenameMap)
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

    /// Returns true when first-prompt handling already covered task-description generation
    /// and the caller should skip independent description generation for this prompt.
    func autoRenameThreadAfterFirstPromptIfNeeded(
        threadId: UUID,
        sessionName: String,
        prompt: String
    ) async -> Bool {
        guard persistence.loadSettings().autoRenameBranches else { return false }
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        let thread = threads[index]

        guard !thread.isMain else { return false }
        guard !thread.didAutoRenameFromFirstPrompt else { return false }

        // If the user already provided a description, treat first-prompt
        // auto-rename as handled and avoid skip banners/retries.
        let hasTaskDescription = !(thread.taskDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        if hasTaskDescription {
            markFirstPromptAutoRenameHandled(threadId: thread.id)
            return true
        }

        // If the thread name no longer matches the worktree directory basename,
        // it was already renamed (manually or otherwise) — skip auto-rename.
        guard thread.name == (thread.worktreePath as NSString).lastPathComponent else { return false }
        // Only auto-rename threads that still have an auto-generated name.
        // Threads created via CLI with an explicit name/description should keep it.
        guard NameGenerator.isAutoGenerated(thread.name) else { return false }
        guard thread.agentTmuxSessions.contains(sessionName) else { return false }
        guard !autoRenameInProgress.contains(thread.id) else { return false }

        // If the current git branch was already renamed to a custom value
        // (for example outside Magent), skip first-prompt auto-rename and
        // mark it handled so we do not keep retrying on each submitted prompt.
        let currentBranch = await git.getCurrentBranch(workingDirectory: thread.worktreePath)
        let effectiveBranch = currentBranch ?? thread.branchName
        if !effectiveBranch.isEmpty, !NameGenerator.isAutoGenerated(effectiveBranch) {
            markFirstPromptAutoRenameHandled(threadId: thread.id)
            return false
        }

        let preferredAgent = thread.sessionAgentTypes[sessionName] ?? thread.effectiveAgentType

        let result = await generateFirstPromptRenamePayloadViaAgent(
            from: prompt,
            agentType: preferredAgent,
            projectId: thread.projectId
        )
        let slug: String
        let generatedTaskDescription: GeneratedTaskDescription?
        switch result {
        case .generated(let generatedSlug, let description):
            slug = generatedSlug
            generatedTaskDescription = description
        case .question:
            // Treated as handled for this prompt to avoid a second model call.
            return true
        case .failed:
            // Keep first-prompt auto-rename one-time and avoid noisy warnings when
            // optional background slug generation fails for environment/model reasons.
            markFirstPromptAutoRenameHandled(threadId: thread.id)
            // Let the separate description path run as a fallback.
            return false
        }
        let candidates = renameCandidates(from: slug)

        autoRenameInProgress.insert(thread.id)
        defer { autoRenameInProgress.remove(thread.id) }

        for candidate in candidates where candidate != thread.name {
            do {
                try await renameThread(thread, to: candidate, markFirstPromptRenameHandled: true)
                _ = await applyGeneratedRenameMetadataIfNeeded(
                    threadId: thread.id,
                    generatedTaskDescription: generatedTaskDescription
                )
                return true
            } catch ThreadManagerError.duplicateName {
                continue
            } catch {
                return false
            }
        }

        // Rename was requested but no candidate was usable; allow fallback description path.
        return false
    }

    private func markFirstPromptAutoRenameHandled(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard !threads[index].didAutoRenameFromFirstPrompt else { return }
        threads[index].didAutoRenameFromFirstPrompt = true
        try? persistence.saveThreads(threads)
    }

    // MARK: - Task Description

    private static let descPrefix = "DESC:"
    private static let workTypePrefix = "TYPE:"
    private static let iconPrefix = "ICON:"
    private static let knownWorkTypeNames = Set(ThreadIcon.allCases.map(\.rawValue))
    private static let maxTaskDescriptionWords = 8

    private struct GeneratedTaskDescription {
        let description: String
        let suggestedIcon: ThreadIcon
    }

    private func normalizeTaskDescription(_ value: String) -> String? {
        let sanitized = value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty, sanitized.uppercased() != "EMPTY" else { return nil }

        let words = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let limitedWords = Array(words.prefix(Self.maxTaskDescriptionWords))
        let normalized = limitedWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { return nil }
        guard normalized.contains(where: { $0.isLetter }) else { return nil }
        return normalized
    }

    private func capitalizeFirstCharacter(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }

    private func valueAfterFirstPrefix(in raw: String, prefixes: [String]) -> String? {
        let matches = prefixes.compactMap { raw.range(of: $0, options: .caseInsensitive) }
        guard let firstMatch = matches.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let afterPrefix = raw[firstMatch.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterPrefix.isEmpty else { return nil }
        let line = afterPrefix.components(separatedBy: .newlines).first ?? String(afterPrefix)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeGeneratedWorkType(_ value: String?) -> ThreadIcon {
        guard let value else { return .other }
        let token = value
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" })
            .first
            .map(String.init)

        guard let token, Self.knownWorkTypeNames.contains(token) else {
            return .other
        }
        return ThreadIcon(rawValue: token) ?? .other
    }

    private func sanitizeGeneratedTaskDescription(_ raw: String) -> GeneratedTaskDescription? {
        guard let prefixRange = raw.range(of: Self.descPrefix, options: .caseInsensitive) else { return nil }
        let afterPrefix = raw[prefixRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !afterPrefix.isEmpty, afterPrefix.uppercased() != "EMPTY" else { return nil }

        let line = afterPrefix.components(separatedBy: .newlines).first ?? String(afterPrefix)
        var normalizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in [Self.workTypePrefix, Self.iconPrefix] {
            if let markerRange = normalizedLine.range(of: marker, options: .caseInsensitive) {
                normalizedLine = String(normalizedLine[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let description = normalizeTaskDescription(normalizedLine) else { return nil }
        let capitalizedDescription = capitalizeFirstCharacter(description)
        let suggestedType = valueAfterFirstPrefix(in: raw, prefixes: [Self.workTypePrefix, Self.iconPrefix])
        let suggestedIcon = normalizeGeneratedWorkType(suggestedType)
        return GeneratedTaskDescription(description: capitalizedDescription, suggestedIcon: suggestedIcon)
    }

    private func generateTaskDescription(from prompt: String, agentType: AgentType?, projectId: UUID?) async -> GeneratedTaskDescription? {
        let truncated = String(prompt.prefix(500))
        let aiPrompt = """
            Generate a short task description (2-8 words) in natural casing, with the first letter uppercase. \
            Icon types: feature (new functionality), fix (bug/regression), improvement (non-breaking polish/performance/quality), refactor (internal code restructure), test (adding/updating tests), other (none fit). \
            Evaluate all icon types, pick the highest-confidence one, and use other when no icon type is above 70% confidence. \
            Output exactly: \
            DESC: <description or EMPTY> \
            TYPE: <feature|fix|improvement|refactor|test|other> \
            For pure knowledge questions, output DESC: EMPTY and TYPE: other.
            Task: \(truncated)
            """

        let escapedPrompt = ShellExecutor.shellQuote(aiPrompt)
        let workingDirectory = backgroundGenerationWorkingDirectory(projectId: projectId)
        let command: String
        switch agentType {
        case .codex:
            command = codexBackgroundExecCommand(escapedPrompt: escapedPrompt)
        default:
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence"
        }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await ShellExecutor.execute(command, workingDirectory: workingDirectory)
                guard result.exitCode == 0 else { return nil }
                return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let raw = result, !raw.isEmpty else { return nil }
        return sanitizeGeneratedTaskDescription(raw)
    }

    @discardableResult
    private func generateAndPersistTaskDescription(
        threadId: UUID,
        prompt: String,
        overwriteExisting: Bool
    ) async -> String? {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return nil }
        let thread = threads[index]

        guard !thread.isMain else { return nil }
        if !overwriteExisting, thread.taskDescription != nil { return nil }

        let settings = persistence.loadSettings()
        let shouldAutoSetIcon = settings.autoSetThreadIconFromWorkType
        let agentOrder = slugGenerationAgentOrder(preferred: thread.effectiveAgentType, projectId: thread.projectId)
        guard !agentOrder.allTrackable.isEmpty, !agentOrder.available.isEmpty else { return nil }

        for candidateAgent in agentOrder.available {
            if let generated = await generateTaskDescription(from: prompt, agentType: candidateAgent, projectId: thread.projectId) {
                // Re-check index — thread array may have changed during async work
                guard let currentIndex = threads.firstIndex(where: { $0.id == threadId }) else { return nil }
                threads[currentIndex].taskDescription = generated.description
                if shouldAutoSetIcon, !threads[currentIndex].isThreadIconManuallySet {
                    threads[currentIndex].threadIcon = generated.suggestedIcon
                }
                try? persistence.saveThreads(threads)
                await MainActor.run {
                    delegate?.threadManager(self, didUpdateThreads: threads)
                }
                return generated.description
            }
        }
        return nil
    }

    func generateTaskDescriptionIfNeeded(threadId: UUID, prompt: String) async {
        guard persistence.loadSettings().autoSetThreadDescription else { return }
        _ = await generateAndPersistTaskDescription(
            threadId: threadId,
            prompt: prompt,
            overwriteExisting: false
        )
    }

    @discardableResult
    func regenerateTaskDescription(threadId: UUID, prompt: String) async -> String? {
        await generateAndPersistTaskDescription(
            threadId: threadId,
            prompt: prompt,
            overwriteExisting: true
        )
    }

    func setTaskDescription(threadId: UUID, description: String?) throws {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }

        let normalizedDescription: String?
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                normalizedDescription = nil
            } else {
                guard let normalized = normalizeTaskDescription(trimmed) else {
                    throw ThreadManagerError.invalidDescription
                }
                normalizedDescription = normalized
            }
        } else {
            normalizedDescription = nil
        }

        threads[index].taskDescription = normalizedDescription
        try persistence.saveThreads(threads)

        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    func setThreadIcon(threadId: UUID, icon: ThreadIcon, markAsManualOverride: Bool = true) throws {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }
        let shouldUpdateIcon = threads[index].threadIcon != icon
        let shouldUpdateManualFlag = markAsManualOverride && !threads[index].isThreadIconManuallySet
        guard shouldUpdateIcon || shouldUpdateManualFlag else { return }

        if shouldUpdateIcon {
            threads[index].threadIcon = icon
        }
        if markAsManualOverride {
            threads[index].isThreadIconManuallySet = true
        }
        try persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
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
        if let info = currentThread.rateLimitedSessions[sessionName] {
            threads[index].rateLimitedSessions.removeValue(forKey: sessionName)
            threads[index].rateLimitedSessions[resolvedSessionName] = info
        }
        if let agentType = currentThread.sessionAgentTypes[sessionName] {
            threads[index].sessionAgentTypes.removeValue(forKey: sessionName)
            threads[index].sessionAgentTypes[resolvedSessionName] = agentType
        }
        if let conversationID = currentThread.sessionConversationIDs[sessionName] {
            threads[index].sessionConversationIDs.removeValue(forKey: sessionName)
            threads[index].sessionConversationIDs[resolvedSessionName] = conversationID
        }
        if let promptHistory = currentThread.submittedPromptsBySession[sessionName] {
            threads[index].submittedPromptsBySession.removeValue(forKey: sessionName)
            threads[index].submittedPromptsBySession[resolvedSessionName] = promptHistory
        }
        _ = remapTransientSessionState(
            threadIndex: index,
            sessionRenameMap: [sessionName: resolvedSessionName]
        )

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
