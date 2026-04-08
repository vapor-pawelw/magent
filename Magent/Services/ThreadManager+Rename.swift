import Foundation
import MagentCore

/// Cached result of an AI rename-payload generation for a specific (thread, prompt) pair.
/// Avoids repeat agent calls when the same prompt is re-used for rename on the same thread.
struct CachedRenameResult {
    let slug: String
    let taskDescription: ThreadManager.GeneratedTaskDescription?
}

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

        // Claude is a prerequisite for the app and generateSlugViaAgent routes all
        // non-codex agent types (including .custom) through the claude CLI anyway.
        // Always append .claude as a final fallback so rename works even when the
        // project/global default is a custom agent with no built-in agents active.
        if !ordered.contains(.claude) {
            ordered.append(.claude)
        }
        let available = ordered
        return (allTrackable: ordered, available: available)
    }

    /// Prefix applied to auto-generated task descriptions when the thread has active draft tabs.
    static let draftDescriptionPrefix = "DRAFT: "

    private static let slugPrefix = "SLUG:"

    private func sanitizeSlug(_ raw: String) -> String? {
        // Require the SLUG: prefix — if absent, the output is an error or unexpected
        guard let prefixRange = raw.range(of: Self.slugPrefix) else { return nil }
        let afterPrefix = raw[prefixRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // For multi-line payloads, only the first line belongs to the slug field.
        let line = afterPrefix.components(separatedBy: .newlines).first ?? afterPrefix
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // EMPTY means the model couldn't generate a slug — treat as failure
        if trimmedLine.uppercased() == "EMPTY" || trimmedLine.isEmpty {
            return nil
        }

        // Strip quotes and backticks
        var slug = trimmedLine
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")

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

    // MARK: - Background shell execution with timeout

    private enum ShellTimedResult {
        case success(String)
        case exitFailure(code: Int32, stderr: String)
        case timeout
    }

    private func executeWithTimeout(command: String, workingDirectory: String?, timeoutNanos: UInt64) async -> ShellTimedResult {
        await withTaskGroup(of: ShellTimedResult?.self) { group in
            group.addTask {
                let result = await ShellExecutor.execute(command, workingDirectory: workingDirectory)
                guard result.exitCode == 0 else {
                    return .exitFailure(code: result.exitCode, stderr: result.stderr)
                }
                return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timeout
        }
    }

    private enum SlugGenerationAttemptResult {
        case slug(String)
        case failed(reason: String)
    }

    private enum FirstPromptRenameAttemptResult {
        case generated(slug: String, taskDescription: GeneratedTaskDescription?)
        case failed(reason: String)
    }

    private func codexBackgroundExecCommand(escapedPrompt: String) -> String {
        // ShellExecutor uses a minimal PATH; include common user-local install
        // locations so background rename/description jobs can resolve Codex.
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = ShellExecutor.shellQuote("\(homeDir)/.local/bin")
        let miseShims = ShellExecutor.shellQuote("\(homeDir)/.local/share/mise/shims")
        return "PATH=\(localBin):\(miseShims):$PATH codex exec \(escapedPrompt) --ephemeral --config model_reasoning_effort=none < /dev/null"
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
        let aiPrompt: String
        aiPrompt = """
            \(instruction) \
            Output ONLY the prefix SLUG: followed by the slug. No quotes, no explanation. \
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
            // --tools "" prevents any tool invocations, keeping the response purely textual.
            // --setting-sources "" skips loading CLAUDE.md/AGENTS.md entirely so the system
            // prompt stays minimal — large workspace instruction files were the primary cause
            // of slug-generation calls timing out.
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence --tools \"\" --setting-sources \"\" < /dev/null"
        }

        let agentLabel = agentType.map(String.init(describing:)) ?? "claude"
        let shellResult = await executeWithTimeout(command: command, workingDirectory: workingDirectory, timeoutNanos: 60_000_000_000)

        switch shellResult {
        case .timeout:
            return .failed(reason: "\(agentLabel) timed out (60 s)")
        case .exitFailure(let code, let stderr):
            let snippet = String(stderr.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: "\(agentLabel) exited \(code): \(snippet)")
        case .success(let raw):
            guard !raw.isEmpty else { return .failed(reason: "\(agentLabel) returned empty output") }
            guard let slug = sanitizeSlug(raw) else {
                return .failed(reason: "\(agentLabel) output could not be parsed as a slug")
            }
            return .slug(slug)
        }
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
        let commonPayloadInstructions = """
            Also generate a short task description (2-8 words) with first letter uppercase. \
            The description should read like a clear branch/sidebar label for the work to do, and should describe the same task as the slug. \
            Prefer concrete phrases such as "Fix ...", "Add ...", "Improve ...", or a specific feature/bug name. Avoid vague abstract wording like "readiness", "handling", "management", or "support" unless that exact concept is the task. \
            Icon types: feature (new functionality), fix (bug/regression), improvement (non-breaking polish/performance/quality), refactor (internal code restructure), test (adding/updating tests), other (none fit). \
            Evaluate all icon types and use other when no icon type is above 70% confidence. \
            Output exactly three lines and nothing else:
            """
        let aiPrompt: String
        aiPrompt = """
            \(instruction) \
            \(commonPayloadInstructions) \
            SLUG: <slug> \
            DESC: <description> \
            TYPE: <feature|fix|improvement|refactor|test|other> \
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
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence --tools \"\" --setting-sources \"\" < /dev/null"
        }

        let agentLabel = agentType.map(String.init(describing:)) ?? "claude"
        let shellResult = await executeWithTimeout(command: command, workingDirectory: workingDirectory, timeoutNanos: 60_000_000_000)

        switch shellResult {
        case .timeout:
            return .failed(reason: "\(agentLabel) timed out (60 s)")
        case .exitFailure(let code, let stderr):
            let snippet = String(stderr.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: "\(agentLabel) exited \(code): \(snippet)")
        case .success(let raw):
            guard !raw.isEmpty else { return .failed(reason: "\(agentLabel) returned empty output") }
            guard let slug = sanitizeSlug(raw) else {
                return .failed(reason: "\(agentLabel) output could not be parsed as a slug")
            }
            let generatedDescription = sanitizeGeneratedTaskDescription(raw)
            return .generated(slug: slug, taskDescription: generatedDescription)
        }
    }

    enum AutoRenameResult {
        case candidates([String])
        /// AI slug generation failed (timeout, error, etc.).
        case failed(diagnostic: String?)
    }

    func autoRenameCandidates(
        from prompt: String,
        agentType: AgentType?,
        projectId: UUID? = nil
    ) async -> AutoRenameResult {
        let agentOrder = slugGenerationAgentOrder(preferred: agentType, projectId: projectId)

        var lastReason: String?
        let normalCandidates = agentOrder.available
        for candidateAgent in normalCandidates {
            switch await generateSlugViaAgent(from: prompt, agentType: candidateAgent, projectId: projectId) {
            case .slug(let slug):
                return .candidates(renameCandidates(from: slug))
            case .failed(let reason):
                lastReason = reason
                continue
            }
        }

        return .failed(diagnostic: lastReason)
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
        generatedTaskDescription: GeneratedTaskDescription?,
        prefixDraft: Bool = false,
        forceOverwrite: Bool = false,
        applyDescription: Bool = true,
        applyIcon: Bool = true
    ) async -> Bool {
        guard let generatedTaskDescription else { return false }
        guard let currentIndex = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        // Skip if description already exists — unless this is a manual rename that
        // should always update the description to match the new branch name.
        guard forceOverwrite || threads[currentIndex].taskDescription == nil else { return false }

        var didApply = false
        if applyDescription {
            let shouldPrefixDraft = prefixDraft || threads[currentIndex].hasDraftTabs
            let description = shouldPrefixDraft
                ? Self.draftDescriptionPrefix + generatedTaskDescription.description
                : generatedTaskDescription.description
            threads[currentIndex].taskDescription = description
            didApply = true
        }
        if applyIcon {
            let settings = persistence.loadSettings()
            if settings.autoSetThreadIconFromWorkType,
               !threads[currentIndex].isThreadIconManuallySet {
                threads[currentIndex].threadIcon = generatedTaskDescription.suggestedIcon
                didApply = true
            }
        }
        guard didApply else { return false }
        try? persistence.saveActiveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
        return true
    }

    /// Prompt-based rename (manual trigger): generate slug + description + icon
    /// using the same model prompt as first-prompt auto-rename, without
    /// first-prompt eligibility checks.
    ///
    /// - Parameters:
    ///   - renameBranch: When false, skip the git branch rename. Defaults to true.
    ///   - renameDescription: When false, skip updating the task description. Defaults to true.
    ///   - renameIcon: When false, skip updating the thread icon. Defaults to true.
    @discardableResult
    func renameThreadFromPrompt(
        _ thread: MagentThread,
        prompt: String,
        preferredAgent: AgentType? = nil,
        prefixDraft: Bool = false,
        renameBranch: Bool = true,
        renameDescription: Bool = true,
        renameIcon: Bool = true
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

        // Show the sidebar pulse animation while the AI call is in flight,
        // matching the visual feedback given by the auto-rename path.
        autoRenameInProgress.insert(currentThread.id)
        defer { autoRenameInProgress.remove(currentThread.id) }
        await MainActor.run { delegate?.threadManager(self, didUpdateThreads: threads) }

        let resolvedPreferred = preferredAgent ?? effectiveAgentType(for: currentThread.projectId)
        let agentOrder = slugGenerationAgentOrder(preferred: resolvedPreferred, projectId: currentThread.projectId)
        let cKey = promptCacheKey(for: trimmedPrompt)
        var payloadResult: FirstPromptRenameAttemptResult = .failed(reason: "no agents available")
        if let cached = promptRenameResultCache[currentThread.id]?[cKey] {
            payloadResult = .generated(slug: cached.slug, taskDescription: cached.taskDescription)
        } else {
            for candidateAgent in agentOrder.available {
                let result = await generateFirstPromptRenamePayloadViaAgent(
                    from: trimmedPrompt,
                    agentType: candidateAgent,
                    projectId: currentThread.projectId
                )
                cacheRenameResult(result, threadId: currentThread.id, cacheKey: cKey)
                switch result {
                case .generated:
                    payloadResult = result
                case .failed:
                    continue
                }
                break
            }
        }

        let slug: String
        let generatedTaskDescription: GeneratedTaskDescription?
        switch payloadResult {
        case .generated(let generatedSlug, let description):
            slug = generatedSlug
            generatedTaskDescription = description
        case .failed(let reason):
            throw ThreadManagerError.nameGenerationFailed(diagnostic: reason)
        }

        if renameBranch {
            let candidates = renameCandidates(from: slug).filter { $0 != currentThread.branchName }
            var didRename = false
            for candidate in candidates {
                do {
                    try await renameThread(currentThread, to: candidate, markFirstPromptRenameHandled: false)
                    didRename = true
                    break
                } catch ThreadManagerError.duplicateName {
                    continue
                }
            }
            if !didRename, renameDescription || renameIcon {
                // Branch rename failed but we still want metadata — apply it without branch change.
            } else if !didRename {
                throw ThreadManagerError.duplicateName
            }
        }

        if renameDescription || renameIcon {
            _ = await applyGeneratedRenameMetadataIfNeeded(
                threadId: currentThread.id,
                generatedTaskDescription: generatedTaskDescription,
                prefixDraft: prefixDraft,
                forceOverwrite: true,
                applyDescription: renameDescription,
                applyIcon: renameIcon
            )
        }

        return true
    }

    /// Renames only the git branch for a thread. The thread name (= worktree directory
    /// basename) is never changed — it stays as the original auto-generated name forever.
    /// Tmux sessions and worktree paths are unaffected.
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
        let newBranchName = trimmed

        // Look up project for repo path
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == currentThread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }

        // Check for conflicts with git branch.
        // Allow if the target branch is the thread's own branch (renaming back to a previous name,
        // or stored branchName is out of sync with the actual worktree branch).
        let actualWorktreeBranch = await git.getCurrentBranch(workingDirectory: currentThread.worktreePath)
        let branchAlreadyOwned = currentThread.branchName == newBranchName
            || actualWorktreeBranch == newBranchName
        if !branchAlreadyOwned, await git.branchExists(repoPath: project.repoPath, branchName: newBranchName) {
            throw ThreadManagerError.duplicateName
        }

        // Rename git branch (skip if already on the target branch)
        let oldBranch = actualWorktreeBranch ?? currentThread.branchName
        if !branchAlreadyOwned {
            try await git.renameBranch(repoPath: project.repoPath, oldName: oldBranch, newName: newBranchName)
        }

        // Update branch fields only — thread name, tmux sessions, and worktree path are unchanged.
        threads[index].branchName = newBranchName
        threads[index].actualBranch = newBranchName
        if markFirstPromptRenameHandled {
            threads[index].didAutoRenameFromFirstPrompt = true
        }

        // Retarget other threads in the same project whose baseBranch pointed at the old branch.
        if !branchAlreadyOwned {
            retargetBaseBranches(oldBranch: oldBranch, newBranch: newBranchName, projectId: currentThread.projectId)
        }

        try persistence.saveActiveThreads(threads)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        await verifyDetectedJiraTickets(forThreadIds: [thread.id])
    }

    // MARK: - Base Branch Retargeting

    /// Updates all threads in the same project whose baseBranch references the old branch name
    /// to point at the new branch name instead. Updates both the persisted `baseBranch` on the
    /// thread model and the `detectedBaseBranch` override in the worktree metadata cache.
    private func retargetBaseBranches(oldBranch: String, newBranch: String, projectId: UUID) {
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == projectId }) else { return }
        let basePath = project.resolvedWorktreesBasePath()
        var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
        var cacheChanged = false

        for i in threads.indices where threads[i].projectId == projectId {
            // Retarget thread.baseBranch (set at creation time).
            if let base = threads[i].baseBranch, base == oldBranch {
                threads[i].baseBranch = newBranch
            }

            // Retarget worktree cache override (set via context menu, CLI, or PR target).
            let key = threads[i].worktreeKey
            if var meta = cache.worktrees[key], meta.detectedBaseBranch == oldBranch {
                meta.detectedBaseBranch = newBranch
                cache.worktrees[key] = meta
                cacheChanged = true
            }
        }

        if cacheChanged {
            persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        }
    }

    /// Returns true when first-prompt handling already covered task-description generation
    /// and the caller should skip independent description generation for this prompt.
    func autoRenameThreadAfterFirstPromptIfNeeded(
        threadId: UUID,
        sessionName: String,
        prompt: String
    ) async -> Bool {
        await performAutoRename(threadId: threadId, requireSession: sessionName, prompt: prompt, prefixDraft: false)
    }

    /// Auto-renames a thread using the draft prompt text. Unlike the session-based variant,
    /// this does not require an active tmux session — the rename fires immediately when the
    /// thread is created with a draft tab. The generated description is prefixed with "DRAFT: ".
    func autoRenameThreadFromDraftPromptIfNeeded(
        threadId: UUID,
        prompt: String
    ) async -> Bool {
        await performAutoRename(threadId: threadId, requireSession: nil, prompt: prompt, prefixDraft: true)
    }

    /// Shared auto-rename implementation.
    /// - Parameters:
    ///   - requireSession: When non-nil, the thread must have this session in `agentTmuxSessions`.
    ///   - prefixDraft: When true, the generated description is prefixed with "DRAFT: ".
    private func performAutoRename(
        threadId: UUID,
        requireSession: String?,
        prompt: String,
        prefixDraft: Bool
    ) async -> Bool {
        guard persistence.loadSettings().autoRenameBranches else { return false }
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        let thread = threads[index]

        guard !thread.isMain else { return false }
        guard !thread.didAutoRenameFromFirstPrompt else { return false }

        // Only auto-rename branches that still have an auto-generated name.
        // Threads created via CLI with an explicit name/description should keep their branch.
        guard NameGenerator.isAutoGenerated(thread.branchName) else { return false }
        if let sessionName = requireSession {
            guard thread.agentTmuxSessions.contains(sessionName) else { return false }
        }
        guard !autoRenameInProgress.contains(thread.id) else { return false }

        // Lock before the first await so concurrent TOC-refresh callbacks cannot
        // both slip through the guard above and start duplicate AI calls.
        autoRenameInProgress.insert(thread.id)
        defer { autoRenameInProgress.remove(thread.id) }

        // If the current git branch was already renamed to a custom value
        // (for example outside Magent), skip first-prompt auto-rename and
        // mark it handled so we do not keep retrying on each submitted prompt.
        let currentBranch = await git.getCurrentBranch(workingDirectory: thread.worktreePath)
        let effectiveBranch = currentBranch ?? thread.branchName
        if !effectiveBranch.isEmpty, !NameGenerator.isAutoGenerated(effectiveBranch) {
            markFirstPromptAutoRenameHandled(threadId: thread.id)
            return false
        }

        guard let refreshedIndex = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        let refreshedThread = threads[refreshedIndex]
        guard !refreshedThread.isMain else { return false }
        guard !refreshedThread.didAutoRenameFromFirstPrompt else { return false }
        guard NameGenerator.isAutoGenerated(refreshedThread.branchName) else { return false }
        if let sessionName = requireSession {
            guard refreshedThread.agentTmuxSessions.contains(sessionName) else { return false }
        }

        // Try agents in preferred-first order; fall back to other built-in generators
        // (Claude/Codex) if the preferred one fails — per AGENTS.md fallback convention.
        let preferredAgent = effectiveAgentType(for: refreshedThread.projectId)
        let agentOrder = slugGenerationAgentOrder(preferred: preferredAgent, projectId: refreshedThread.projectId)

        var slug: String?
        var generatedTaskDescription: GeneratedTaskDescription?
        let cKey = promptCacheKey(for: prompt)
        if let cached = promptRenameResultCache[refreshedThread.id]?[cKey] {
            // Cache hit — reuse previous AI result without another agent call.
            slug = cached.slug
            generatedTaskDescription = cached.taskDescription
        } else {
            for candidateAgent in agentOrder.available {
                let result = await generateFirstPromptRenamePayloadViaAgent(
                    from: prompt,
                    agentType: candidateAgent,
                    projectId: refreshedThread.projectId
                )
                cacheRenameResult(result, threadId: refreshedThread.id, cacheKey: cKey)
                switch result {
                case .generated(let generatedSlug, let description):
                    slug = generatedSlug
                    generatedTaskDescription = description
                case .failed:
                    continue
                }
                break
            }
        }

        guard let resolvedSlug = slug else {
            // All agents failed; mark handled and let separate description path run as fallback.
            markFirstPromptAutoRenameHandled(threadId: refreshedThread.id)
            // No diagnostic surfaced here — auto-rename failures show via the
            // autoRenameFailedBannerShownThreadIds banner path below.
            return false
        }

        let candidates = renameCandidates(from: resolvedSlug)

        for candidate in candidates where candidate != refreshedThread.branchName {
            do {
                try await renameThread(refreshedThread, to: candidate, markFirstPromptRenameHandled: true)
                _ = await applyGeneratedRenameMetadataIfNeeded(
                    threadId: refreshedThread.id,
                    generatedTaskDescription: generatedTaskDescription,
                    prefixDraft: prefixDraft
                )
                return true
            } catch ThreadManagerError.duplicateName {
                continue
            } catch {
                if !autoRenameFailedBannerShownThreadIds.contains(refreshedThread.id) {
                    autoRenameFailedBannerShownThreadIds.insert(refreshedThread.id)
                    await MainActor.run {
                        BannerManager.shared.show(
                            message: "Auto-rename failed for \"\(refreshedThread.name)\": \(error.localizedDescription)",
                            style: .error
                        )
                    }
                }
                return false
            }
        }

        // Rename was requested but no candidate was usable; allow fallback description path.
        return false
    }

    /// Strips the "DRAFT: " prefix from the thread's task description when draft tabs are consumed.
    func stripDraftDescriptionPrefixIfNeeded(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard let desc = threads[index].taskDescription,
              desc.hasPrefix(Self.draftDescriptionPrefix) else { return }
        // Only strip if the thread no longer has draft tabs.
        guard !threads[index].hasDraftTabs else { return }
        threads[index].taskDescription = String(desc.dropFirst(Self.draftDescriptionPrefix.count))
        try? persistence.saveActiveThreads(threads)
        Task { @MainActor in
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    private func markFirstPromptAutoRenameHandled(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard !threads[index].didAutoRenameFromFirstPrompt else { return }
        threads[index].didAutoRenameFromFirstPrompt = true
        try? persistence.saveActiveThreads(threads)
    }

    // MARK: - Rename payload cache

    /// Stable cache key: whitespace-collapsed, trimmed, lowercased prompt.
    private func promptCacheKey(for prompt: String) -> String {
        prompt
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Stores a non-failed AI result so future rename requests with the same prompt skip the agent call.
    private func cacheRenameResult(_ result: FirstPromptRenameAttemptResult, threadId: UUID, cacheKey: String) {
        var cache = promptRenameResultCache[threadId] ?? [:]
        switch result {
        case .generated(let slug, let description):
            cache[cacheKey] = CachedRenameResult(slug: slug, taskDescription: description)
        case .failed:
            return  // Don't cache failures — retry should call the agent again
        }
        promptRenameResultCache[threadId] = cache
    }

    // MARK: - Task Description

    private static let descPrefix = "DESC:"
    private static let workTypePrefix = "TYPE:"
    private static let iconPrefix = "ICON:"
    private static let knownWorkTypeNames = Set(ThreadIcon.allCases.map(\.rawValue))
    private static let maxTaskDescriptionWords = 8

    struct GeneratedTaskDescription {
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
            The description should read like a clear branch/sidebar label for the work to do. \
            Prefer concrete phrases such as "Fix ...", "Add ...", "Improve ...", or a specific feature/bug name. Avoid vague abstract wording like "readiness", "handling", "management", or "support" unless that exact concept is the task. \
            Icon types: feature (new functionality), fix (bug/regression), improvement (non-breaking polish/performance/quality), refactor (internal code restructure), test (adding/updating tests), other (none fit). \
            Evaluate all icon types, pick the highest-confidence one, and use other when no icon type is above 70% confidence. \
            Output exactly: \
            DESC: <description> \
            TYPE: <feature|fix|improvement|refactor|test|other> \
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
            command = "PATH=\(homeDir)/.local/bin:$PATH claude -p \(escapedPrompt) --model haiku --no-session-persistence --tools \"\" --setting-sources \"\" < /dev/null"
        }

        let shellResult = await executeWithTimeout(command: command, workingDirectory: workingDirectory, timeoutNanos: 60_000_000_000)

        guard case .success(let raw) = shellResult, !raw.isEmpty else { return nil }
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
        let agentOrder = slugGenerationAgentOrder(preferred: effectiveAgentType(for: thread.projectId), projectId: thread.projectId)
        guard !agentOrder.allTrackable.isEmpty, !agentOrder.available.isEmpty else { return nil }

        for candidateAgent in agentOrder.available {
            if let generated = await generateTaskDescription(from: prompt, agentType: candidateAgent, projectId: thread.projectId) {
                // Re-check index — thread array may have changed during async work
                guard let currentIndex = threads.firstIndex(where: { $0.id == threadId }) else { return nil }
                let description = threads[currentIndex].hasDraftTabs
                    ? Self.draftDescriptionPrefix + generated.description
                    : generated.description
                threads[currentIndex].taskDescription = description
                if shouldAutoSetIcon, !threads[currentIndex].isThreadIconManuallySet {
                    threads[currentIndex].threadIcon = generated.suggestedIcon
                }
                try? persistence.saveActiveThreads(threads)
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

        let finalDescription: String?
        if let description {
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            finalDescription = trimmed.isEmpty ? nil : trimmed
        } else {
            finalDescription = nil
        }

        threads[index].taskDescription = finalDescription
        try persistence.saveActiveThreads(threads)

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
        try persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    func setThreadSignEmoji(threadId: UUID, signEmoji: String?) throws {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }
        guard threads[index].signEmoji != signEmoji else { return }
        threads[index].signEmoji = signEmoji
        try persistence.saveActiveThreads(threads)
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
            try persistence.saveActiveThreads(threads)
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
        if currentThread.protectedTmuxSessions.contains(sessionName) {
            threads[index].protectedTmuxSessions.remove(sessionName)
            threads[index].protectedTmuxSessions.insert(resolvedSessionName)
        }
        if currentThread.lastSelectedTabIdentifier == sessionName {
            threads[index].lastSelectedTabIdentifier = resolvedSessionName
        }
        if currentThread.unreadCompletionSessions.contains(sessionName) {
            threads[index].unreadCompletionSessions.remove(sessionName)
            threads[index].unreadCompletionSessions.insert(resolvedSessionName)
        }
        if let info = currentThread.rateLimitedSessions[sessionName] {
            threads[index].rateLimitedSessions.removeValue(forKey: sessionName)
            threads[index].rateLimitedSessions[resolvedSessionName] = info
        }
        if let conversationID = currentThread.sessionConversationIDs[sessionName] {
            threads[index].sessionConversationIDs.removeValue(forKey: sessionName)
            threads[index].sessionConversationIDs[resolvedSessionName] = conversationID
        }
        if let sessionAgentType = currentThread.sessionAgentTypes[sessionName] {
            threads[index].sessionAgentTypes.removeValue(forKey: sessionName)
            threads[index].sessionAgentTypes[resolvedSessionName] = sessionAgentType
        }
        if let sessionCreatedAt = currentThread.sessionCreatedAts[sessionName] {
            threads[index].sessionCreatedAts.removeValue(forKey: sessionName)
            threads[index].sessionCreatedAts[resolvedSessionName] = sessionCreatedAt
        }
        if currentThread.freshAgentSessions.contains(sessionName) {
            threads[index].freshAgentSessions.remove(sessionName)
            threads[index].freshAgentSessions.insert(resolvedSessionName)
        }
        if currentThread.forwardedTmuxSessions.contains(sessionName) {
            threads[index].forwardedTmuxSessions.remove(sessionName)
            threads[index].forwardedTmuxSessions.insert(resolvedSessionName)
        }
        if let promptHistory = currentThread.submittedPromptsBySession[sessionName] {
            threads[index].submittedPromptsBySession.removeValue(forKey: sessionName)
            threads[index].submittedPromptsBySession[resolvedSessionName] = promptHistory
        }
        _ = remapTransientSessionState(
            threadIndex: index,
            sessionRenameMap: [sessionName: resolvedSessionName]
        )
        _ = remapInitialPromptInjectionState(sessionRenameMap: [sessionName: resolvedSessionName])

        // Re-key known-good session context cache so the renamed session
        // isn't re-validated (and potentially killed) on next tab switch.
        if let cachedContext = knownGoodSessionContexts.removeValue(forKey: sessionName) {
            knownGoodSessionContexts[resolvedSessionName] = cachedContext
        }

        // Update custom tab names: remove old key, store under new key
        threads[index].customTabNames.removeValue(forKey: sessionName)
        threads[index].customTabNames[resolvedSessionName] = trimmed

        // Legacy rollback path only: if tmux bell pipes are re-enabled, rename must
        // also retarget the pipe so any fallback completion events keep the new name.
        if threads[index].agentTmuxSessions.contains(resolvedSessionName) {
            await tmux.forceSetupBellPipe(for: resolvedSessionName)
        }

        try persistence.saveActiveThreads(threads)
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

    // MARK: - Bell-triggered auto-rename for non-visible threads

    /// Extracts the first user prompt from raw pane content by looking for `❯` or `›` prompt markers.
    /// This is a lightweight version of the TOC parser, sufficient for first-prompt auto-rename
    /// when the thread is not displayed (no ThreadDetailViewController).
    /// Supports multiline prompts: continuation lines are indented with 2+ spaces.
    func extractFirstPromptFromPane(_ paneContent: String) -> String? {
        let codexMarker: Character = "\u{203A}" // ›
        let claudeMarker: Character = "\u{276F}" // ❯
        let markers: [Character] = [claudeMarker, codexMarker]

        let lines = paneContent.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.drop(while: { $0.isWhitespace })
            guard let first = trimmed.first, markers.contains(first) else {
                lineIndex += 1
                continue
            }
            let firstLine = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !firstLine.isEmpty else {
                lineIndex += 1
                continue
            }

            // Collect continuation lines (2+ leading spaces, no prompt marker).
            var promptLines = [firstLine]
            var continuationIndex = lineIndex + 1
            while continuationIndex < lines.count {
                let contLine = lines[continuationIndex]
                let contTrimmed = contLine.drop(while: { $0.isWhitespace })
                let contText = String(contTrimmed).trimmingCharacters(in: .whitespacesAndNewlines)

                if contText.isEmpty {
                    // Blank line — look ahead: keep going only if next non-blank
                    // line is still a continuation (2+ spaces, no marker).
                    let peekIndex = continuationIndex + 1
                    if peekIndex < lines.count {
                        let peekLine = lines[peekIndex]
                        let peekLeading = peekLine.prefix(while: { $0.isWhitespace }).count
                        let peekTrimmed = peekLine.drop(while: { $0.isWhitespace })
                        if peekLeading >= 2,
                           let peekFirst = peekTrimmed.first,
                           !markers.contains(peekFirst) {
                            promptLines.append("")
                            continuationIndex += 1
                            continue
                        }
                    }
                    break
                }

                let leadingSpaces = contLine.prefix(while: { $0.isWhitespace }).count
                guard leadingSpaces >= 2 else { break }
                // Must not start with a prompt marker (that would be the next prompt).
                if let contFirst = contTrimmed.first, markers.contains(contFirst) { break }

                promptLines.append(contText)
                continuationIndex += 1
            }

            let fullPrompt = promptLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fullPrompt.isEmpty {
                return fullPrompt
            }
            lineIndex = continuationIndex
        }
        return nil
    }

    /// Called from `checkForAgentCompletions` when a bell fires for a thread that
    /// hasn't been auto-renamed yet. Captures pane content, extracts the first prompt,
    /// and triggers auto-rename — no ThreadDetailViewController required.
    func triggerAutoRenameFromBellIfNeeded(threadId: UUID, sessionName: String) async {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]
        guard !thread.isMain, !thread.didAutoRenameFromFirstPrompt else { return }
        guard persistence.loadSettings().autoRenameBranches else { return }

        // Capture enough pane history to find the first prompt.
        guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 200) else { return }
        guard let prompt = extractFirstPromptFromPane(paneContent) else { return }

        // Verify an agent is actually running (same guard as TOC path).
        guard await detectedAgentTypeInSession(sessionName) != nil else { return }

        _ = await autoRenameThreadAfterFirstPromptIfNeeded(
            threadId: threadId,
            sessionName: sessionName,
            prompt: prompt
        )
    }
}
