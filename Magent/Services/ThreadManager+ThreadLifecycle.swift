import Cocoa
import Foundation
import MagentCore

extension ThreadManager {

    private static let archivedThreadBannerDuration: TimeInterval = 10.0

    // MARK: - Thread Creation

    func createThread(
        project: Project,
        requestedAgentType: AgentType? = nil,
        useAgentCommand: Bool = true,
        initialPrompt: String? = nil,
        shouldSubmitInitialPrompt: Bool = true,
        initialDraftTab: PersistedDraftTab? = nil,
        requestedName: String? = nil,
        requestedBaseBranch: String? = nil,
        pendingPromptFileURL: URL? = nil,
        requestedSectionId: UUID? = nil,
        insertAfterThreadId: UUID? = nil,
        insertAtTopOfVisibleGroup: Bool = false,
        skipAutoSelect: Bool = false,
        initialWebURL: URL? = nil,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        localFileSyncEntriesOverride: [LocalFileSyncEntry]? = nil
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
            // Generate a sequential Pokemon name from a persisted counter.
            // On conflict, skip to the next Pokemon (up to 3 tries).
            // If all 3 fail, add a numeric suffix to the last tried name.
            let basePath = project.resolvedWorktreesBasePath()
            var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
            var counter = cache.nameCounter
            let pokemonCount = NameGenerator.pokemonNames.count
            var conflictStreak = 0

            for _ in 0..<3 {
                let candidate = NameGenerator.generate(counter: counter)
                counter = (counter + 1) % pokemonCount
                if try await isNameAvailable(candidate, project: project) {
                    name = candidate
                    foundUnique = true
                    break
                }
                conflictStreak += 1
            }

            // All 3 sequential names conflicted — use the last name with a numeric suffix.
            if !foundUnique {
                let lastBase = NameGenerator.generate(counter: (counter - 1 + pokemonCount) % pokemonCount)
                for suffix in 2...99 {
                    let candidate = "\(lastBase)-\(suffix)"
                    if try await isNameAvailable(candidate, project: project) {
                        name = candidate
                        foundUnique = true
                        break
                    }
                }
            }

            cache.nameCounter = counter
            persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        }

        guard foundUnique else {
            throw ThreadManagerError.nameGenerationFailed
        }

        let branchName = name
        let worktreePath = "\(project.resolvedWorktreesBasePath())/\(name)"
        let repoSlug = Self.repoSlug(from: project.name)

        // Phase 1: Register the thread in the sidebar immediately so the app stays responsive.
        // The thread has no tmux sessions yet; those are created in phase 2 below.
        let threadID = UUID()
        let settings = persistence.loadSettings()
        // Include the requested base branch on the pending thread so that the
        // changes panel shows the correct target branch immediately (before Phase 2
        // resolves the final value).
        let pendingBaseBranch: String? = {
            let trimmed = requestedBaseBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
            let projectDefault = project.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let projectDefault, !projectDefault.isEmpty { return projectDefault }
            return nil
        }()
        let pendingThread = MagentThread(
            id: threadID,
            projectId: project.id,
            name: name,
            worktreePath: worktreePath,
            branchName: branchName,
            tmuxSessionNames: [],
            sectionId: requestedSectionId ?? settings.defaultSection(for: project.id)?.id,
            baseBranch: pendingBaseBranch
        )
        pendingThreadIds.insert(threadID)
        var pendingThreadWithBusy = pendingThread
        pendingThreadWithBusy.magentBusySessions.insert(MagentThread.threadSetupSentinel)
        threads.append(pendingThreadWithBusy)
        if let lastIndex = threads.indices.last {
            if let insertAfterThreadId {
                placeThreadAfterSibling(threadId: threads[lastIndex].id, afterThreadId: insertAfterThreadId)
            } else if insertAtTopOfVisibleGroup {
                bumpThreadToTopOfSection(threads[lastIndex].id)
            } else {
                bumpThreadToTopOfSection(threads[lastIndex].id)
            }
        }
        if skipAutoSelect {
            skipNextAutoSelect = true
        }
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: pendingThreadWithBusy)
        }

        // Phase 2: Perform git and tmux setup. On failure, clean up the pending thread.
        do {
            // Create git worktree branching off the requested base branch, or the
            // project's default branch when no explicit base is provided.
            let explicitBaseBranch = requestedBaseBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch: String?
            if let explicitBaseBranch, !explicitBaseBranch.isEmpty {
                baseBranch = explicitBaseBranch
            } else if let projectDefault = project.defaultBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !projectDefault.isEmpty {
                baseBranch = projectDefault
            } else {
                baseBranch = nil
            }
            _ = try await git.createWorktree(
                repoPath: project.repoPath,
                branchName: branchName,
                worktreePath: worktreePath,
                baseBranch: baseBranch
            )

            let localFileSyncEntriesSnapshot: [LocalFileSyncEntry] = {
                guard let override = localFileSyncEntriesOverride else {
                    return project.normalizedLocalFileSyncEntries
                }
                // Merge source thread snapshot with current project paths:
                // - keep source paths that are still configured in the project
                // - append any new project paths not in the source snapshot
                // This matches the effectiveLocalSyncPaths contract (never sync
                // paths removed from project config).
                let currentEntries = project.normalizedLocalFileSyncEntries
                let currentPaths = Set(currentEntries.map(\.path))
                var merged = Project.normalizeLocalFileSyncEntries(override).filter { currentPaths.contains($0.path) }
                let mergedPaths = Set(merged.map(\.path))
                for entry in currentEntries where !mergedPaths.contains(entry.path) {
                    merged.append(entry)
                }
                return merged
            }()
            let (syncSourcePath, _) = resolveBaseBranchSyncTarget(
                baseBranch: baseBranch,
                excludingThreadId: threadID,
                projectId: project.id,
                project: project
            )
            let sourceOverride = syncSourcePath != project.repoPath ? syncSourcePath : nil
            let missingLocalSyncPaths: [String]
            do {
                missingLocalSyncPaths = try await syncConfiguredLocalPathsIntoWorktree(
                    project: project,
                    worktreePath: worktreePath,
                    syncEntries: localFileSyncEntriesSnapshot,
                    sourceRootOverride: sourceOverride
                )
            } catch {
                try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: worktreePath)
                throw error
            }

            // Record fork-point commit in the worktree metadata cache
            let forkPointResult = await ShellExecutor.execute("git rev-parse HEAD", workingDirectory: worktreePath)
            let forkPoint = forkPointResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if forkPointResult.exitCode == 0, !forkPoint.isEmpty {
                let basePath = project.resolvedWorktreesBasePath()
                var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
                cache.worktrees[name] = WorktreeMetadata(forkPointCommit: forkPoint, createdAt: Date())
                persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
            }

            // Non-terminal thread: skip tmux session creation and persist the initial web/draft tab.
            if initialWebURL != nil || initialDraftTab != nil {
                let webTab: PersistedWebTab?
                if let webURL = initialWebURL {
                    let identifier = "web:\(UUID().uuidString)"
                    let title = webURL.host ?? "Web"
                    webTab = PersistedWebTab(identifier: identifier, url: webURL, title: title, iconType: .web)
                } else {
                    webTab = nil
                }

                var thread = MagentThread(
                    id: threadID,
                    projectId: project.id,
                    name: name,
                    worktreePath: worktreePath,
                    branchName: branchName,
                    tmuxSessionNames: [],
                    sectionId: requestedSectionId ?? settings.defaultSection(for: project.id)?.id,
                    baseBranch: baseBranch,
                    localFileSyncEntriesSnapshot: localFileSyncEntriesSnapshot
                )
                if let webTab {
                    thread.persistedWebTabs.append(webTab)
                    thread.lastSelectedTabIdentifier = webTab.identifier
                }
                if let initialDraftTab {
                    thread.persistedDraftTabs = [initialDraftTab]
                    thread.lastSelectedTabIdentifier = initialDraftTab.identifier
                }

                pendingThreadIds.remove(threadID)
                if let idx = threads.firstIndex(where: { $0.id == threadID }) {
                    threads[idx].mergePhase2Setup(from: thread)
                    // Draft/web threads never go through tmux setup or injectAfterStart,
                    // so the threadSetupSentinel added at phase 1 must be cleared here.
                    threads[idx].magentBusySessions.remove(MagentThread.threadSetupSentinel)
                }

                try persistence.saveActiveThreads(threads)
                await MainActor.run {
                    delegate?.threadManager(self, didUpdateThreads: threads)
                    NotificationCenter.default.post(
                        name: .magentThreadCreationFinished,
                        object: nil,
                        userInfo: {
                            var info: [String: Any] = ["threadId": threadID]
                            if let webTab {
                                info["initialWebTabIdentifier"] = webTab.identifier
                            }
                            return info
                        }()
                    )
                    if !missingLocalSyncPaths.isEmpty {
                        let noun = missingLocalSyncPaths.count == 1 ? "path" : "paths"
                        BannerManager.shared.show(
                            message: "Thread created, but \(missingLocalSyncPaths.count) local sync \(noun) were missing in the source repo.",
                            style: .warning,
                            duration: 8.0,
                            details: missingLocalSyncPaths.joined(separator: "\n"),
                            detailsCollapsedTitle: "Show missing paths",
                            detailsExpandedTitle: "Hide missing paths"
                        )
                    }
                }
                return thread
            }

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

            let firstTabDisplayName = useAgentCommand
                ? TmuxSessionNaming.defaultTabDisplayName(
                    for: selectedAgentType,
                    modelLabel: resolvedModelLabel(for: selectedAgentType, modelId: modelId),
                    reasoningLevel: reasoningLevel
                )
                : "Terminal"
            let firstTabSlug = Self.sanitizeForTmux(firstTabDisplayName)
            let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: name, tabSlug: firstTabSlug)
            let sessionCreatedAt = Date()

            // Pre-trust the worktree directory so the selected agent doesn't show a trust dialog
            trustDirectoryIfNeeded(worktreePath, agentType: selectedAgentType)

            // Create tmux session with selected agent command (or shell if no active agents)
            let sessionEnvironment = sessionEnvironmentVariables(
                threadId: threadID,
                worktreePath: worktreePath,
                projectPath: project.repoPath,
                worktreeName: name,
                projectName: project.name,
                agentType: selectedAgentType
            )
            let envExports = shellExportCommand(for: sessionEnvironment)
            let startCmd: String
            if useAgentCommand {
                startCmd = agentStartCommand(
                    settings: settings,
                    projectId: project.id,
                    agentType: selectedAgentType,
                    envExports: envExports,
                    workingDirectory: worktreePath,
                    modelId: modelId,
                    reasoningLevel: reasoningLevel
                )
            } else {
                startCmd = terminalStartCommand(
                    envExports: envExports,
                    workingDirectory: worktreePath
                )
            }
            try await tmux.createSession(
                name: tmuxSessionName,
                workingDirectory: worktreePath,
                command: startCmd
            )

            // Also set on the tmux session so new panes/windows inherit them.
            await applySessionEnvironmentVariables(
                sessionName: tmuxSessionName,
                environmentVariables: sessionEnvironment
            )

            // Mark the session as known-good immediately so that setupTabs →
            // ensureSessionPrepared → recreateSessionIfNeeded short-circuits
            // instead of racing with the prompt injection task.
            let isAgentSession = useAgentCommand && selectedAgentType != nil
            markSessionContextKnownGood(
                sessionName: tmuxSessionName,
                threadId: threadID,
                expectedPath: worktreePath,
                projectPath: project.repoPath,
                isAgentSession: isAgentSession
            )
            if isAgentSession {
                await tmux.setupBellPipe(for: tmuxSessionName)
            }

            let thread = MagentThread(
                id: threadID,
                projectId: project.id,
                name: name,
                worktreePath: worktreePath,
                branchName: branchName,
                tmuxSessionNames: [tmuxSessionName],
                agentTmuxSessions: useAgentCommand && selectedAgentType != nil ? [tmuxSessionName] : [],
                sessionAgentTypes: selectedAgentType.map { [tmuxSessionName: $0] } ?? [:],
                sessionCreatedAts: [tmuxSessionName: sessionCreatedAt],
                sectionId: requestedSectionId ?? settings.defaultSection(for: project.id)?.id,
                lastSelectedTabIdentifier: tmuxSessionName,
                customTabNames: [tmuxSessionName: firstTabDisplayName],
                baseBranch: baseBranch,
                submittedPromptsBySession: {
                    guard useAgentCommand,
                          let initialPrompt,
                          !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return [:]
                    }
                    return [tmuxSessionName: [
                        initialPrompt
                            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    ]]
                }(),
                localFileSyncEntriesSnapshot: localFileSyncEntriesSnapshot
            )

            pendingThreadIds.remove(threadID)
            if let idx = threads.firstIndex(where: { $0.id == threadID }) {
                threads[idx].mergePhase2Setup(from: thread)
                // Transition magent busy from thread-setup sentinel to session-level busy.
                // The session stays magent-busy until injectAfterStart completes (prompt
                // injection or agent-readiness detection for non-prompt threads).
                threads[idx].magentBusySessions = [tmuxSessionName]
            }
            sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt

            try persistence.saveActiveThreads(threads)
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                NotificationCenter.default.post(
                    name: .magentThreadCreationFinished,
                    object: nil,
                    userInfo: ["threadId": threadID]
                )
                if !missingLocalSyncPaths.isEmpty {
                    let noun = missingLocalSyncPaths.count == 1 ? "path" : "paths"
                    BannerManager.shared.show(
                        message: "Thread created, but \(missingLocalSyncPaths.count) local sync \(noun) were missing in the source repo.",
                        style: .warning,
                        duration: 8.0,
                        details: missingLocalSyncPaths.joined(separator: "\n"),
                        detailsCollapsedTitle: "Show missing paths",
                        detailsExpandedTitle: "Hide missing paths"
                    )
                }
                // Register cleanup before injectAfterStart fires magentAgentKeysInjected,
                // preventing the notification from racing past the listener setup.
                registerPendingPromptCleanup(fileURL: pendingPromptFileURL, sessionName: tmuxSessionName)
            }

            // Inject terminal command and agent context
            let injection = effectiveInjection(for: project.id)
            injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, initialPrompt: initialPrompt, shouldSubmitInitialPrompt: shouldSubmitInitialPrompt, agentType: selectedAgentType)
            if initialPrompt?.isEmpty == false, useAgentCommand {
                scheduleAgentConversationIDRefresh(threadId: thread.id, sessionName: tmuxSessionName)
            }

            // Trigger auto-rename early — using the initial prompt from the launch sheet — so
            // the thread gets a meaningful name before the agent even starts processing.
            // Runs in an unstructured Task so it doesn't delay createThread's return.
            // Deduplication: didAutoRenameFromFirstPrompt is set to true by the rename job,
            // so the TOC-based trigger later sees the flag and skips the same prompt.
            // Serialization: autoRenameInProgress prevents concurrent rename AI calls.
            if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty,
               useAgentCommand,
               selectedAgentType != nil {
                let threadId = thread.id
                let sessionName = tmuxSessionName
                Task {
                    _ = await autoRenameThreadAfterFirstPromptIfNeeded(
                        threadId: threadId,
                        sessionName: sessionName,
                        prompt: prompt
                    )
                }
            }

            return thread
        } catch {
            // Clean up the pending thread from in-memory state; it was never persisted.
            pendingThreadIds.remove(threadID)
            threads.removeAll { $0.id == threadID }
            await MainActor.run {
                delegate?.threadManager(self, didDeleteThread: pendingThread)
                NotificationCenter.default.post(
                    name: .magentThreadCreationFinished,
                    object: nil,
                    userInfo: ["threadId": threadID, "error": error.localizedDescription]
                )
            }
            throw error
        }
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let settings = persistence.loadSettings()
        let threadID = UUID()
        let selectedAgentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)

        let repoSlug = Self.repoSlug(from: project.name)
        let firstTabDisplayName = TmuxSessionNaming.defaultTabDisplayName(
            for: selectedAgentType,
            modelLabel: resolvedModelLabel(for: selectedAgentType, modelId: nil),
            reasoningLevel: nil
        )
        let firstTabSlug = Self.sanitizeForTmux(firstTabDisplayName)
        let tmuxSessionName = Self.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: firstTabSlug)

        // Kill orphaned tmux session if it exists from a previous run
        if await tmux.hasSession(name: tmuxSessionName) {
            try? await tmux.killSession(name: tmuxSessionName)
        }

        trustDirectoryIfNeeded(project.repoPath, agentType: selectedAgentType)
        let sessionEnvironment = sessionEnvironmentVariables(
            threadId: threadID,
            projectPath: project.repoPath,
            worktreeName: "main",
            projectName: project.name,
            agentType: selectedAgentType
        )
        let envExports = shellExportCommand(for: sessionEnvironment)
        let startCmd = agentStartCommand(
            settings: settings,
            projectId: project.id,
            agentType: selectedAgentType,
            envExports: envExports,
            workingDirectory: project.repoPath
        )
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: project.repoPath,
            command: startCmd
        )
        let sessionCreatedAt = Date()
        // Main thread is always an agent session.

        await applySessionEnvironmentVariables(
            sessionName: tmuxSessionName,
            environmentVariables: sessionEnvironment
        )

        let thread = MagentThread(
            id: threadID,
            projectId: project.id,
            name: "main",
            worktreePath: project.repoPath,
            branchName: "",
            tmuxSessionNames: [tmuxSessionName],
            agentTmuxSessions: selectedAgentType != nil ? [tmuxSessionName] : [],
            sessionAgentTypes: selectedAgentType.map { [tmuxSessionName: $0] } ?? [:],
            sessionCreatedAts: [tmuxSessionName: sessionCreatedAt],
            isMain: true,
            lastSelectedTabIdentifier: tmuxSessionName,
            customTabNames: [tmuxSessionName: firstTabDisplayName]
        )

        // Insert main threads at front — mark magent busy until injection/readiness completes.
        var busyThread = thread
        busyThread.magentBusySessions.insert(tmuxSessionName)
        threads.insert(busyThread, at: 0)
        sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt
        try persistence.saveActiveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didCreateThread: busyThread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection(for: project.id)
        injectAfterStart(sessionName: tmuxSessionName, terminalCommand: injection.terminalCommand, agentContext: injection.agentContext, agentType: selectedAgentType)

        return thread
    }

    func ensureMainThreads() async {
        let settings = persistence.loadSettings()
        for project in settings.projects {
            if !threads.contains(where: { $0.isMain && $0.projectId == project.id }) {
                _ = try? await createMainThread(project: project)
            }
        }
    }

    // MARK: - Archive Thread

    /// Marks the thread as archiving and notifies the delegate so the sidebar cell updates.
    func markThreadArchiving(id: UUID) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isArchiving = true
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Clears the archiving flag on a thread that is still in the active list (called on failure).
    func clearThreadArchivingState(id: UUID) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        guard threads[i].isArchiving else { return }
        threads[i].isArchiving = false
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// - Parameters:
    ///   - awaitLocalSync: When `true`, local-file sync runs eagerly (off the main actor
    ///     but awaited) so the result/warning can be returned to the caller. When `false`
    ///     and `force` is `true`, the sync is deferred to a fire-and-forget background
    ///     task and the method returns immediately after UI teardown. IPC callers pass
    ///     `true` so the CLI can report sync warnings; UI callers leave it `false` for
    ///     snappy interaction.
    func archiveThread(
        _ thread: MagentThread,
        promptForLocalSyncConflicts: Bool = false,
        force: Bool = false,
        syncLocalPathsBackToRepo: Bool? = nil,
        awaitLocalSync: Bool = false
    ) async throws -> String? {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        // If the archive fails before the thread is removed from the list, clear the archiving flag.
        var archiveCompleted = false
        defer {
            if !archiveCompleted {
                clearThreadArchivingState(id: thread.id)
            }
        }

        var archiveWarning: String?
        let settings = persistence.loadSettings()
        let shouldSyncLocalPathsBackToRepo = syncLocalPathsBackToRepo ?? settings.syncLocalPathsOnArchive

        // ── Pre-archive sync (blocking paths only). ────────────────────────
        // Interactive conflict prompting and force:false both require the sync to
        // complete before the archive proceeds — the user might cancel, or the caller
        // expects a failure to abort the archive.
        // force:true + awaitLocalSync:true also syncs eagerly so the warning can be
        // returned (used by the IPC/CLI path).
        let shouldSyncEagerly = promptForLocalSyncConflicts || !force || awaitLocalSync
        if shouldSyncLocalPathsBackToRepo, shouldSyncEagerly,
           let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            let syncEntries = effectiveLocalSyncEntries(for: thread, project: project)
            let copySyncPaths = syncEntries.filter { $0.mode == .copy }.map(\.path)
            // Resolve the sync destination: base-branch sibling worktree if available,
            // otherwise the main repo path.
            let (syncTargetPath, _) = resolveBaseBranchSyncTarget(for: thread, project: project)
            let destOverride = syncTargetPath != project.repoPath ? syncTargetPath : nil
            if !copySyncPaths.isEmpty, promptForLocalSyncConflicts {
                do {
                    try await syncConfiguredLocalPathsFromWorktree(
                        project: project,
                        worktreePath: thread.worktreePath,
                        syncEntries: syncEntries,
                        promptForConflicts: true,
                        destinationRootOverride: destOverride
                    )
                } catch ThreadManagerError.archiveCancelled {
                    throw ThreadManagerError.archiveCancelled
                } catch ThreadManagerError.localFileSyncFailed(let message) {
                    guard force else {
                        throw ThreadManagerError.localFileSyncFailed(message)
                    }
                    archiveWarning = "Archived without completing local sync: \(message)"
                }
            } else if !copySyncPaths.isEmpty {
                // Non-interactive: @concurrent runs off the main actor so the UI stays responsive.
                do {
                    try await Self.runLocalSync(
                        projectRepoPath: syncTargetPath,
                        worktreePath: thread.worktreePath,
                        syncPaths: copySyncPaths
                    )
                } catch {
                    guard force else {
                        throw ThreadManagerError.localFileSyncFailed(error.localizedDescription)
                    }
                    archiveWarning = "Archived without completing local sync: \(error.localizedDescription)"
                }
            }
        }

        // Resolve deferred sync state while the thread is still in `threads` —
        // resolveBaseBranchSyncTarget reads the active thread list.
        let deferredSyncPaths: [String]?
        let deferredSyncDestination: String?
        if !shouldSyncEagerly, shouldSyncLocalPathsBackToRepo,
           let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            deferredSyncPaths = effectiveLocalSyncEntries(for: thread, project: project)
                .filter { $0.mode == .copy }
                .map(\.path)
            let (syncTargetPath, _) = resolveBaseBranchSyncTarget(for: thread, project: project)
            deferredSyncDestination = syncTargetPath
        } else {
            deferredSyncPaths = nil
            deferredSyncDestination = nil
        }

        // ── Persist archive state before touching in-memory state. ─────────
        // This ensures restoreArchivedThread can always find the record on disk,
        // and saveActiveThreads (which merges isArchived records) cannot drop it.
        let archivedAt = Date()
        try await persistArchiveState(
            threadId: thread.id,
            projectId: thread.projectId,
            jiraTicketKey: thread.jiraTicketKey,
            archivedAt: archivedAt
        )

        // ── UI teardown — all synchronous on main actor, no awaits. ────────

        // Prompt-injection bookkeeping is global to ThreadManager rather than persisted on
        // the thread, so archive/delete must clear it explicitly when a thread disappears.
        clearTrackedInitialPromptInjection(forSessions: thread.tmuxSessionNames)

        // Evict any cached ghostty terminal views for this thread's sessions BEFORE the
        // cleanup task kills the tmux sessions. Ghostty calls _exit() when the PTY fd closes
        // on a live surface, which silently terminates the entire process.
        ReusableTerminalViewCache.shared.evictSessions(thread.tmuxSessionNames)

        // Remove from active list
        threads.removeAll { $0.id == thread.id }

        NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
        delegate?.threadManager(self, didArchiveThread: thread)

        promptRenameResultCache.removeValue(forKey: thread.id)
        cleanupPendingPromptRecoveries(for: thread.id)

        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "Unknown Project"
        showArchivedThreadBanner(for: thread, projectName: projectName, warning: archiveWarning)

        // ── Fire-and-forget cleanup (local sync for deferred path, tmux     ──
        // ── kills, worktree removal, symlink/stale-session sweeps).         ──
        let capturedProject = settings.projects.first(where: { $0.id == thread.projectId })
        let capturedTmux = tmux
        let capturedGit = git
        let capturedSettings = settings
        let capturedActiveWorktreeNames = worktreeActiveNames(for: thread.projectId)
        let capturedReferencedSessions = referencedMagentSessionNames()
        let capturedThreadName = thread.name
        let capturedTmuxSessionNames = thread.tmuxSessionNames
        let capturedWorktreePath = thread.worktreePath
        Task {
            await Self.performArchiveCleanup(
                deferredSyncDestination: deferredSyncDestination,
                deferredSyncPaths: deferredSyncPaths,
                project: capturedProject,
                worktreePath: capturedWorktreePath,
                threadName: capturedThreadName,
                tmuxSessionNames: capturedTmuxSessionNames,
                tmux: capturedTmux,
                git: capturedGit,
                settings: capturedSettings,
                activeWorktreeNames: capturedActiveWorktreeNames,
                referencedSessions: capturedReferencedSessions
            )
        }

        archiveCompleted = true
        return archiveWarning
    }

    func restoreArchivedThread(id threadId: UUID) async throws -> MagentThread {
        if let existing = threads.first(where: { $0.id == threadId }) {
            return existing
        }

        let settings = persistence.loadSettings()
        var allThreads = persistence.loadThreads()
        guard let archivedIndex = allThreads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }

        var restoredThread = allThreads[archivedIndex]
        guard restoredThread.isArchived else {
            throw ThreadManagerError.duplicateName
        }

        guard let project = settings.projects.first(where: { $0.id == restoredThread.projectId }) else {
            throw ThreadManagerError.threadNotFound
        }

        if threads.contains(where: { $0.projectId == restoredThread.projectId && $0.name == restoredThread.name }) {
            throw ThreadManagerError.duplicateName
        }

        await git.pruneWorktrees(repoPath: project.repoPath)

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: restoredThread.branchName)
        if branchExists {
            _ = try await git.addWorktreeForExistingBranch(
                repoPath: project.repoPath,
                branchName: restoredThread.branchName,
                worktreePath: restoredThread.worktreePath
            )
        } else {
            let persistedBaseBranch = restoredThread.baseBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let baseBranch: String?
            if let persistedBaseBranch, !persistedBaseBranch.isEmpty {
                baseBranch = persistedBaseBranch
            } else if let projectDefault = project.defaultBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                      !projectDefault.isEmpty {
                baseBranch = projectDefault
            } else {
                baseBranch = nil
            }
            _ = try await git.createWorktree(
                repoPath: project.repoPath,
                branchName: restoredThread.branchName,
                worktreePath: restoredThread.worktreePath,
                baseBranch: baseBranch
            )
        }

        restoredThread.isArchived = false
        restoredThread.archivedAt = nil
        Self.clearPersistedSessionState(for: &restoredThread)
        restoredThread.unreadCompletionSessions.removeAll()
        restoredThread.lastAgentCompletionAt = nil
        restoredThread.isDirty = false
        restoredThread.isFullyDelivered = false
        restoredThread.jiraUnassigned = false
        restoredThread.actualBranch = nil
        restoredThread.expectedBranch = nil
        restoredThread.hasBranchMismatch = false
        restoredThread.rateLimitedSessions = [:]
        restoredThread.pullRequestInfo = nil
        restoredThread.pullRequestLookupStatus = .unknown
        restoredThread.busySessions.removeAll()
        restoredThread.waitingForInputSessions.removeAll()

        // Re-load allThreads and re-locate the index — the array may have shifted during the
        // preceding awaits (worktree creation, branch check, prune).
        allThreads = persistence.loadThreads()
        guard let freshArchivedIndex = allThreads.firstIndex(where: { $0.id == restoredThread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        allThreads[freshArchivedIndex] = restoredThread
        try persistence.saveThreads(allThreads)
        await MainActor.run {
            NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
        }

        threads.append(restoredThread)
        bumpThreadToTopOfSection(restoredThread.id)
        // Sync any changes bumpThreadToTopOfSection made back into the persisted list.
        // Re-locate by ID instead of reusing freshArchivedIndex — the local allThreads array
        // is unchanged, but a defensive lookup prevents silent breakage if a future edit
        // inserts another persistence reload between here and line 695.
        if let restoredActiveIndex = threads.firstIndex(where: { $0.id == restoredThread.id }) {
            restoredThread = threads[restoredActiveIndex]
            if let persistIndex = allThreads.firstIndex(where: { $0.id == restoredThread.id }) {
                allThreads[persistIndex] = restoredThread
            }
        }
        try persistence.saveThreads(allThreads)

        trustDirectoryIfNeeded(restoredThread.worktreePath, agentType: effectiveAgentType(for: restoredThread.projectId))
        pruneWorktreeCache(for: project)

        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
            BannerManager.shared.show(
                attributedMessage: restoredThreadBannerAttributedMessage(for: restoredThread),
                style: .info,
                duration: Self.archivedThreadBannerDuration
            )
            NotificationCenter.default.post(
                name: .magentNavigateToThread,
                object: nil,
                userInfo: ["threadId": restoredThread.id]
            )
        }

        return restoredThread
    }

    // MARK: - Delete Thread

    func deleteThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        if let ticketKey = thread.jiraTicketKey {
            excludeJiraTicket(key: ticketKey, projectId: thread.projectId)
        }

        // Evict cached ghostty surfaces before killing sessions (see archiveThread comment).
        ReusableTerminalViewCache.shared.evictSessions(thread.tmuxSessionNames)

        // Prompt-injection bookkeeping is global to ThreadManager rather than persisted on
        // the thread, so archive/delete must clear it explicitly when a thread disappears.
        clearTrackedInitialPromptInjection(forSessions: thread.tmuxSessionNames)

        // Remove from active list
        threads.remove(at: index)

        // Mark as archived in persistence rather than removing entirely.
        // The worktree cleanup below is fire-and-forget — if it fails, the
        // directory survives and syncThreadsWithWorktrees would re-discover it
        // as a new thread unless the archived record is still present.
        var allThreads = persistence.loadThreads()
        if let idx = allThreads.firstIndex(where: { $0.id == thread.id }) {
            allThreads[idx].isArchived = true
            allThreads[idx].archivedAt = allThreads[idx].archivedAt ?? Date()
        }
        try persistence.saveThreads(allThreads)

        await MainActor.run {
            delegate?.threadManager(self, didDeleteThread: thread)
        }

        promptRenameResultCache.removeValue(forKey: thread.id)
        cleanupPendingPromptRecoveries(for: thread.id)

        // Run slow cleanup in a detached task so it does not inherit the caller's UI context.
        // Capture everything needed so the detached task never hops back to the main actor.
        let capturedTmux = tmux
        let capturedGit = git
        let capturedSettings = persistence.loadSettings()
        let capturedProject = capturedSettings.projects.first(where: { $0.id == thread.projectId })
        // Snapshot — may go slightly stale before the detached task runs, but the window is
        // negligible and avoids hopping back to the main actor mid-cleanup. See archive path.
        let capturedActiveWorktreeNames = worktreeActiveNames(for: thread.projectId)
        let capturedReferencedSessions = referencedMagentSessionNames()
        Task.detached {
            for sessionName in thread.tmuxSessionNames {
                try? await capturedTmux.killSession(name: sessionName)
            }

            if let project = capturedProject {
                try? await capturedGit.removeWorktree(repoPath: project.repoPath, worktreePath: thread.worktreePath)
                if !thread.branchName.isEmpty {
                    try? await capturedGit.deleteBranch(repoPath: project.repoPath, branchName: thread.branchName)
                }
                BackgroundWorktreeCachePruner.prune(
                    worktreesBasePath: project.resolvedWorktreesBasePath(),
                    activeNames: capturedActiveWorktreeNames
                )
            }

            SymlinkManager.cleanupAll(settings: capturedSettings)
            await Self.cleanupStaleSessions(
                tmux: capturedTmux,
                referencedSessions: capturedReferencedSessions
            )
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
            threads[index].sessionConversationIDs = [:]
            threads[index].sessionCreatedAts = [:]
            threads[index].freshAgentSessions = []
            threads[index].forwardedTmuxSessions = []
            threads[index].submittedPromptsBySession = [:]
            threads[index].lastSelectedTabIdentifier = nil

            // Re-create the worktree
            let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: thread.branchName)
            if branchExists {
                _ = try await git.addWorktreeForExistingBranch(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath
                )
            } else {
                let persistedBaseBranch = threads[index].baseBranch?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let baseBranch: String?
                if let persistedBaseBranch, !persistedBaseBranch.isEmpty {
                    baseBranch = persistedBaseBranch
                } else if let projectDefault = project.defaultBranch?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                          !projectDefault.isEmpty {
                    baseBranch = projectDefault
                } else {
                    baseBranch = nil
                }
                _ = try await git.createWorktree(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath,
                    baseBranch: baseBranch
                )
            }

            // Trust the directory for the agent if needed
            trustDirectoryIfNeeded(thread.worktreePath, agentType: effectiveAgentType(for: thread.projectId))

            // Persist updated threads
            try persistence.saveActiveThreads(threads)

            return .recovered
        } catch {
            return .failed(error)
        }
    }

    /// Clears transient session state from a thread. Nonisolated so it can be called
    /// from both main-actor and nonisolated contexts.
    nonisolated private static func clearPersistedSessionState(for thread: inout MagentThread) {
        thread.tmuxSessionNames = []
        thread.agentTmuxSessions = []
        thread.sessionConversationIDs = [:]
        thread.sessionAgentTypes = [:]
        thread.sessionCreatedAts = [:]
        thread.freshAgentSessions = []
        thread.forwardedTmuxSessions = []
        thread.pinnedTmuxSessions = []
        thread.protectedTmuxSessions = []
        thread.lastSelectedTabIdentifier = nil
        thread.customTabNames = [:]
        thread.submittedPromptsBySession = [:]
    }

    /// Excludes a Jira ticket from future assignment. Nonisolated so it can be called
    /// from both main-actor and @concurrent contexts.
    nonisolated static func excludeJiraTicketInPersistence(key: String, projectId: UUID, persistence: PersistenceService) {
        var settings = persistence.loadSettings()
        if let idx = settings.projects.firstIndex(where: { $0.id == projectId }) {
            settings.projects[idx].jiraExcludedTicketKeys.insert(key)
            try? persistence.saveSettings(settings)
        }
    }

    /// Writes archive state to persistence off the main actor so the sidebar stays
    /// responsive. PersistenceService is non-isolated so all calls here are safe.
    @concurrent private func persistArchiveState(
        threadId: UUID,
        projectId: UUID,
        jiraTicketKey: String?,
        archivedAt: Date
    ) async throws {
        let persistence = PersistenceService.shared

        if let ticketKey = jiraTicketKey {
            Self.excludeJiraTicketInPersistence(key: ticketKey, projectId: projectId, persistence: persistence)
        }

        var allThreads = persistence.loadThreads()
        if let i = allThreads.firstIndex(where: { $0.id == threadId }) {
            allThreads[i].isArchived = true
            allThreads[i].archivedAt = archivedAt
            Self.clearPersistedSessionState(for: &allThreads[i])
        }
        try persistence.saveThreads(allThreads)
    }

    // MARK: - Archive Helpers (@concurrent)

    /// Runs local-file sync off the main actor. Structured replacement for `Task.detached { ... }.value`.
    @concurrent private static func runLocalSync(
        projectRepoPath: String,
        worktreePath: String,
        syncPaths: [String]
    ) async throws {
        try await BackgroundLocalSyncWorker.syncConfiguredLocalPathsFromWorktree(
            projectRepoPath: projectRepoPath,
            worktreePath: worktreePath,
            syncPaths: syncPaths
        )
    }

    /// Performs post-archive cleanup entirely off the main actor: deferred local sync,
    /// tmux session kills, worktree removal, symlink/stale-session sweeps.
    @concurrent private static func performArchiveCleanup(
        deferredSyncDestination: String?,
        deferredSyncPaths: [String]?,
        project: Project?,
        worktreePath: String,
        threadName: String,
        tmuxSessionNames: [String],
        tmux: TmuxService,
        git: GitService,
        settings: AppSettings,
        activeWorktreeNames: Set<String>,
        referencedSessions: Set<String>
    ) async {
        // Deferred local sync for fire-and-forget path — best-effort, warning on failure.
        if let syncPaths = deferredSyncPaths, !syncPaths.isEmpty,
           let deferredSyncDestination {
            do {
                try await BackgroundLocalSyncWorker.syncConfiguredLocalPathsFromWorktree(
                    projectRepoPath: deferredSyncDestination,
                    worktreePath: worktreePath,
                    syncPaths: syncPaths
                )
            } catch {
                await MainActor.run {
                    BannerManager.shared.show(
                        message: "Thread '\(threadName)': local sync failed after archive — \(error.localizedDescription)",
                        style: .warning,
                        duration: archivedThreadBannerDuration
                    )
                }
            }
        }
        // Kill sessions concurrently.
        await withTaskGroup(of: Void.self) { group in
            for sessionName in tmuxSessionNames {
                group.addTask { try? await tmux.killSession(name: sessionName) }
            }
        }
        if let project {
            try? await git.removeWorktree(repoPath: project.repoPath, worktreePath: worktreePath)
            BackgroundWorktreeCachePruner.prune(
                worktreesBasePath: project.resolvedWorktreesBasePath(),
                activeNames: activeWorktreeNames
            )
        }
        SymlinkManager.cleanupAll(settings: settings)
        await cleanupStaleSessions(
            tmux: tmux,
            referencedSessions: referencedSessions
        )
    }

    private func archivedThreadBannerAttributedMessage(
        for thread: MagentThread,
        warning: String?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Header line: "Thread archived"
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        ]
        result.append(NSAttributedString(string: "Thread archived\n", attributes: headerAttrs))

        // Description or thread name — prominent
        let titleText: String
        if let desc = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            titleText = desc
        } else {
            titleText = thread.name
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        result.append(NSAttributedString(string: titleText, attributes: titleAttrs))

        // Branch · worktree — secondary monospace line
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
        ]
        let worktreeName = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        result.append(NSAttributedString(string: "\n\(thread.branchName)  ·  \(worktreeName)", attributes: secondaryAttrs))

        // Warning line if present
        if let warning, !warning.isEmpty {
            let warningAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
            result.append(NSAttributedString(string: "\n⚠ \(warning)", attributes: warningAttrs))
        }

        return result
    }

    private func archivedThreadBannerDetails(
        for thread: MagentThread,
        projectName: String
    ) -> String {
        var lines: [String] = []
        lines.append("Project: \(projectName)")
        if let baseBranch = thread.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !baseBranch.isEmpty {
            lines.append("Base: \(baseBranch)")
        }
        if AppFeatures.jiraSyncEnabled,
           let ticketKey = thread.jiraTicketKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketKey.isEmpty {
            lines.append("Jira: \(ticketKey)")
        }
        lines.append("Tabs: \(thread.tmuxSessionNames.count)")
        lines.append("Worktree: \(thread.worktreePath)")
        return lines.joined(separator: "\n")
    }

    private func restoredThreadBannerAttributedMessage(for thread: MagentThread) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
        ]
        result.append(NSAttributedString(string: "Thread restored\n", attributes: headerAttrs))

        let titleText: String
        if let desc = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            titleText = desc
        } else {
            titleText = thread.name
        }
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        ]
        result.append(NSAttributedString(string: titleText, attributes: titleAttrs))

        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
        ]
        let worktreeName = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        result.append(NSAttributedString(string: "\n\(thread.branchName)  ·  \(worktreeName)", attributes: secondaryAttrs))

        return result
    }

    func restoreArchivedThreadFromUserAction(id threadId: UUID, threadName: String) async -> Bool {
        do {
            _ = try await restoreArchivedThread(id: threadId)
            return true
        } catch {
            await MainActor.run {
                BannerManager.shared.show(
                    message: "Failed to restore thread '\(threadName)': \(error.localizedDescription)",
                    style: .error,
                    duration: Self.archivedThreadBannerDuration
                )
            }
            return false
        }
    }

    private func showArchivedThreadBanner(for thread: MagentThread, projectName: String, warning: String?) {
        let attributed = archivedThreadBannerAttributedMessage(for: thread, warning: warning)
        let details = archivedThreadBannerDetails(for: thread, projectName: projectName)

        BannerManager.shared.show(
            attributedMessage: attributed,
            style: warning == nil ? .info : .warning,
            duration: Self.archivedThreadBannerDuration,
            isDismissible: true,
            actions: [
                BannerAction(title: "Restore") { [weak self] in
                    Task { [weak self] in
                        _ = await self?.restoreArchivedThreadFromUserAction(id: thread.id, threadName: thread.name)
                    }
                }
            ],
            details: details,
            detailsCollapsedTitle: "More Info",
            detailsExpandedTitle: "Less Info"
        )
    }
}
