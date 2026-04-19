import Cocoa
import Foundation
import MagentCore

final class ThreadLifecycleService {

    let store: ThreadStore
    let sessionTracker: SessionTracker
    let persistence: PersistenceService
    let tmux: TmuxService
    let git: GitService

    // MARK: - Delegate callbacks

    var onThreadsChanged: (() -> Void)?
    var onThreadCreated: ((MagentThread) -> Void)?
    var onThreadArchived: ((MagentThread) -> Void)?
    var onThreadDeleted: ((MagentThread) -> Void)?

    // MARK: - Cross-service closures (injected by ThreadManager)

    // Agent setup
    var resolveAgentType: ((UUID, AgentType?, AppSettings) -> AgentType?)?
    var agentStartCommand: ((AppSettings, UUID?, AgentType?, String, String, String?, String?) -> String)?
    var terminalStartCommand: ((String, String) -> String)?
    var trustDirectoryIfNeeded: ((String, AgentType?) -> Void)?
    var effectiveAgentType: ((UUID) -> AgentType?)?
    var resolvedModelLabel: ((AgentType?, String?) -> String?)?
    var sessionEnvironmentVariables: ((UUID, String?, String, String, String, AgentType?) -> [(String, String)])?
    var shellExportCommand: (([(String, String)]) -> String)?
    var applySessionEnvironmentVariables: ((String, [(String, String)]) async -> Void)?
    var markSessionContextKnownGood: ((String, UUID, String, String, Bool) -> Void)?
    var effectiveInjection: ((UUID) -> (terminalCommand: String, agentContext: String))?
    var injectAfterStart: ((String, String, String, String?, Bool, AgentType?) -> Void)?
    var scheduleAgentConversationIDRefresh: ((UUID, String) -> Void)?
    var registerPendingPromptCleanup: ((URL?, String) -> Void)?

    // Rename / auto-rename
    var autoRenameThreadAfterFirstPromptIfNeeded: ((UUID, String, String) async -> Bool)?
    var cleanupRenameStateForThread: ((UUID) -> Void)?

    // Agent setup cleanup
    var cleanupAgentSetupForThread: ((UUID) -> Void)?
    var clearTrackedInitialPromptInjectionForSessions: (([String]) -> Void)?

    // Sidebar ordering
    var placeThreadAfterSibling: ((UUID, UUID) -> Void)?
    var bumpThreadToTopOfSection: ((UUID) -> Void)?

    // Local file sync
    var syncConfiguredLocalPathsIntoWorktree: ((Project, String, [LocalFileSyncEntry], String?) async throws -> [String])?
    var effectiveLocalSyncEntries: ((MagentThread, Project) -> [LocalFileSyncEntry])?
    var resolveBaseBranchSyncTargetForThread: ((MagentThread, Project) -> (path: String, label: String))?
    var resolveBaseBranchSyncTargetForBranch: ((String?, UUID, UUID, Project) -> (path: String, label: String))?
    var syncConfiguredLocalPathsFromWorktreeAsync: ((Project, String, [LocalFileSyncEntry], Bool, String?) async throws -> Void)?

    // Git state
    var worktreeActiveNames: ((UUID) -> Set<String>)?
    var referencedMagentSessionNames: (() -> Set<String>)?
    var pruneWorktreeCache: ((Project) -> Void)?
    var ensureBranchSymlink: ((String, String, String) -> Void)?

    // Jira
    var excludeJiraTicket: ((String, UUID) -> Void)?
    var verifyDetectedJiraTickets: ((Set<UUID>) async -> Void)?

    // Session state
    var notifiedWaitingSessionsRemove: (([String]) -> Void)?
    var rateLimitLiftPendingResumeSessionsRemove: (([String]) -> Void)?

    // MARK: - Init

    init(store: ThreadStore, sessionTracker: SessionTracker, persistence: PersistenceService, tmux: TmuxService, git: GitService) {
        self.store = store
        self.sessionTracker = sessionTracker
        self.persistence = persistence
        self.tmux = tmux
        self.git = git
    }

    // MARK: - Ghostty Surface Teardown (shared archive/delete helper)

    /// Frees every `ghostty_surface_t` owned by `thread` before its tmux sessions
    /// are killed. Ghostty calls `_exit()` when a PTY closes on a live surface,
    /// silently terminating the whole app, so this must run synchronously on the
    /// main actor before any `tmux.killSession` is spawned.
    ///
    /// Covers all three hierarchies that can hold live surfaces for a thread:
    ///   1. `ReusableTerminalViewCache` (cached detached surfaces with
    ///      `preserveSurfaceOnDetach = true`).
    ///   2. Pop-out windows owned by `PopoutWindowManager` — both thread-level
    ///      and tab-level. These live in separate `NSWindow` hierarchies that
    ///      are invisible to the main `SplitViewController` teardown.
    ///   3. The main-window detail VC — torn down separately by the delegate's
    ///      `didArchiveThread` / `didDeleteThread` handler replacing the content
    ///      with `showEmptyState(skipTerminalCache: true)`.
    ///
    /// A second cache eviction is required after returning pop-outs because
    /// `closePoppedOutThread` / `returnTabToThread` re-cache the surfaces via
    /// `cacheTerminalViewsForReuse` with `preserveSurfaceOnDetach = true`.
    ///
    /// See docs/libghostty-integration.md → "Surface Lifecycle: Thread
    /// Archive/Delete Contract" for full rationale.
    func releaseLivingGhosttySurfaces(for thread: MagentThread) {
        if PopoutWindowManager.shared.isThreadPoppedOut(thread.id) {
            PopoutWindowManager.shared.returnThreadToMain(thread.id)
        }
        for sessionName in thread.tmuxSessionNames
            where PopoutWindowManager.shared.isTabDetached(sessionName: sessionName) {
            PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
        }
        ReusableTerminalViewCache.shared.evictSessions(thread.tmuxSessionNames)
    }

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

            for _ in 0..<3 {
                let candidate = NameGenerator.generate(counter: counter)
                counter = (counter + 1) % pokemonCount
                if try await isNameAvailable(candidate, project: project) {
                    name = candidate
                    foundUnique = true
                    break
                }
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
            throw ThreadManagerError.nameGenerationFailed(diagnostic: nil)
        }

        let branchName = name
        let worktreePath = "\(project.resolvedWorktreesBasePath())/\(name)"
        let repoSlug = ThreadManager.repoSlug(from: project.name)

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
        store.pendingThreadIds.insert(threadID)
        var pendingThreadWithBusy = pendingThread
        pendingThreadWithBusy.magentBusySessions.insert(MagentThread.threadSetupSentinel)
        store.threads.append(pendingThreadWithBusy)
        if let lastIndex = store.threads.indices.last {
            if let insertAfterThreadId {
                placeThreadAfterSibling?(store.threads[lastIndex].id, insertAfterThreadId)
            } else if insertAtTopOfVisibleGroup {
                bumpThreadToTopOfSection?(store.threads[lastIndex].id)
            } else {
                bumpThreadToTopOfSection?(store.threads[lastIndex].id)
            }
        }
        if skipAutoSelect {
            store.skipNextAutoSelect = true
        }
        await MainActor.run {
            onThreadCreated?(pendingThreadWithBusy)
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
            let (syncSourcePath, _) = resolveBaseBranchSyncTargetForBranch?(baseBranch, threadID, project.id, project)
                ?? (project.repoPath, "")
            let sourceOverride = syncSourcePath != project.repoPath ? syncSourcePath : nil
            let missingLocalSyncPaths: [String]
            do {
                missingLocalSyncPaths = try await syncConfiguredLocalPathsIntoWorktree?(project, worktreePath, localFileSyncEntriesSnapshot, sourceOverride) ?? []
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

                store.pendingThreadIds.remove(threadID)
                if let idx = store.threads.firstIndex(where: { $0.id == threadID }) {
                    store.threads[idx].mergePhase2Setup(from: thread)
                    // Draft/web threads never go through tmux setup or injectAfterStart,
                    // so the threadSetupSentinel added at phase 1 must be cleared here.
                    store.threads[idx].magentBusySessions.remove(MagentThread.threadSetupSentinel)
                }

                try persistence.saveActiveThreads(store.threads)
                await MainActor.run {
                    self.onThreadsChanged?()
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
                selectedAgentType = resolveAgentType?(project.id, requestedAgentType, settings)
            } else {
                selectedAgentType = nil
            }

            let firstTabDisplayName = useAgentCommand
                ? TmuxSessionNaming.defaultTabDisplayName(
                    for: selectedAgentType,
                    modelLabel: resolvedModelLabel?(selectedAgentType, modelId),
                    reasoningLevel: reasoningLevel
                )
                : "Terminal"
            let firstTabSlug = ThreadManager.sanitizeForTmux(firstTabDisplayName)
            let tmuxSessionName = ThreadManager.buildSessionName(repoSlug: repoSlug, threadName: name, tabSlug: firstTabSlug)
            let sessionCreatedAt = Date()

            // Pre-trust the worktree directory so the selected agent doesn't show a trust dialog
            trustDirectoryIfNeeded?(worktreePath, selectedAgentType)

            // Create tmux session with selected agent command (or shell if no active agents)
            let sessionEnvironment = sessionEnvironmentVariables?(
                threadID,
                worktreePath,
                project.repoPath,
                name,
                project.name,
                selectedAgentType
            ) ?? []
            let envExports = shellExportCommand?(sessionEnvironment) ?? ""
            let startCmd: String
            if useAgentCommand {
                startCmd = agentStartCommand?(settings, project.id, selectedAgentType, envExports, worktreePath, modelId, reasoningLevel) ?? ""
            } else {
                startCmd = terminalStartCommand?(envExports, worktreePath) ?? ""
            }
            try await tmux.createSession(
                name: tmuxSessionName,
                workingDirectory: worktreePath,
                command: startCmd
            )

            // Also set on the tmux session so new panes/windows inherit them.
            await applySessionEnvironmentVariables?(tmuxSessionName, sessionEnvironment)

            // Mark the session as known-good immediately so that setupTabs →
            // ensureSessionPrepared → recreateSessionIfNeeded short-circuits
            // instead of racing with the prompt injection task.
            let isAgentSession = useAgentCommand && selectedAgentType != nil
            markSessionContextKnownGood?(tmuxSessionName, threadID, worktreePath, project.repoPath, isAgentSession)
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

            store.pendingThreadIds.remove(threadID)
            if let idx = store.threads.firstIndex(where: { $0.id == threadID }) {
                store.threads[idx].mergePhase2Setup(from: thread)
                // Transition magent busy from thread-setup sentinel to session-level busy.
                // The session stays magent-busy until injectAfterStart completes (prompt
                // injection or agent-readiness detection for non-prompt threads).
                store.threads[idx].magentBusySessions = [tmuxSessionName]
            }
            // Seed visit timestamp — pending-thread auto-selection can happen before phase 2,
            // so the usual setActiveThread visit stamp may never fire for this session.
            sessionTracker.sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt

            try persistence.saveActiveThreads(store.threads)
            await MainActor.run {
                self.onThreadsChanged?()
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
                self.registerPendingPromptCleanup?(pendingPromptFileURL, tmuxSessionName)
            }

            // Inject terminal command and agent context
            let injection = effectiveInjection?(project.id) ?? (terminalCommand: "", agentContext: "")
            injectAfterStart?(tmuxSessionName, injection.terminalCommand, injection.agentContext, initialPrompt, shouldSubmitInitialPrompt, selectedAgentType)
            if initialPrompt?.isEmpty == false, useAgentCommand {
                scheduleAgentConversationIDRefresh?(thread.id, tmuxSessionName)
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
                Task { [weak self] in
                    _ = await self?.autoRenameThreadAfterFirstPromptIfNeeded?(threadId, sessionName, prompt)
                }
            }

            return thread
        } catch {
            // Clean up the pending thread from in-memory state; it was never persisted.
            store.pendingThreadIds.remove(threadID)
            store.threads.removeAll { $0.id == threadID }
            await MainActor.run {
                self.onThreadDeleted?(pendingThread)
                NotificationCenter.default.post(
                    name: .magentThreadCreationFinished,
                    object: nil,
                    userInfo: ["threadId": threadID, "error": error.localizedDescription]
                )
            }
            throw error
        }
    }

    private func isNameAvailable(_ name: String, project: Project) async throws -> Bool {
        let nameInUse = store.threads.contains(where: { $0.name == name })
        let dirExists = FileManager.default.fileExists(
            atPath: "\(project.resolvedWorktreesBasePath())/\(name)"
        )
        guard !nameInUse && !dirExists else { return false }

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: name)
        let slug = ThreadManager.repoSlug(from: project.name)
        let settings = persistence.loadSettings()
        let agentType = resolveAgentType?(project.id, nil, settings)
        let firstTabSlug = ThreadManager.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: agentType))
        let tmuxExists = await tmux.hasSession(name: ThreadManager.buildSessionName(repoSlug: slug, threadName: name, tabSlug: firstTabSlug))
        return !branchExists && !tmuxExists
    }

    // MARK: - Main Thread

    func createMainThread(project: Project) async throws -> MagentThread {
        // Guard: no existing main thread for this project
        guard !store.threads.contains(where: { $0.isMain && $0.projectId == project.id }) else {
            throw ThreadManagerError.duplicateName
        }

        let settings = persistence.loadSettings()
        let threadID = UUID()
        let selectedAgentType = resolveAgentType?(project.id, nil, settings)

        let repoSlug = ThreadManager.repoSlug(from: project.name)
        let firstTabDisplayName = TmuxSessionNaming.defaultTabDisplayName(
            for: selectedAgentType,
            modelLabel: resolvedModelLabel?(selectedAgentType, nil),
            reasoningLevel: nil
        )
        let firstTabSlug = ThreadManager.sanitizeForTmux(firstTabDisplayName)
        let tmuxSessionName = ThreadManager.buildSessionName(repoSlug: repoSlug, threadName: nil, tabSlug: firstTabSlug)

        // Kill orphaned tmux session if it exists from a previous run
        if await tmux.hasSession(name: tmuxSessionName) {
            try? await tmux.killSession(name: tmuxSessionName)
        }

        trustDirectoryIfNeeded?(project.repoPath, selectedAgentType)
        let sessionEnvironment = sessionEnvironmentVariables?(
            threadID,
            nil,
            project.repoPath,
            "main",
            project.name,
            selectedAgentType
        ) ?? []
        let envExports = shellExportCommand?(sessionEnvironment) ?? ""
        let startCmd = agentStartCommand?(settings, project.id, selectedAgentType, envExports, project.repoPath, nil, nil) ?? ""
        try await tmux.createSession(
            name: tmuxSessionName,
            workingDirectory: project.repoPath,
            command: startCmd
        )
        let sessionCreatedAt = Date()
        // Main thread is always an agent session.

        await applySessionEnvironmentVariables?(tmuxSessionName, sessionEnvironment)

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
        store.threads.insert(busyThread, at: 0)
        // Seed visit timestamp immediately so this new session isn't evicted as ancient.
        sessionTracker.sessionLastVisitedAt[tmuxSessionName] = sessionCreatedAt
        try persistence.saveActiveThreads(store.threads)
        await MainActor.run {
            self.onThreadCreated?(busyThread)
        }

        // Inject terminal command and agent context
        let injection = effectiveInjection?(project.id) ?? (terminalCommand: "", agentContext: "")
        injectAfterStart?(tmuxSessionName, injection.terminalCommand, injection.agentContext, nil, true, selectedAgentType)

        return thread
    }

    func ensureMainThreads() async {
        let settings = persistence.loadSettings()
        for project in settings.projects {
            if !store.threads.contains(where: { $0.isMain && $0.projectId == project.id }) {
                _ = try? await createMainThread(project: project)
            }
        }
    }

    // MARK: - Archive Thread

    static let archivedThreadBannerDuration: TimeInterval = 10.0

    /// Marks the thread as archiving and notifies the delegate so the sidebar cell updates.
    func markThreadArchiving(id: UUID) {
        guard let i = store.threads.firstIndex(where: { $0.id == id }) else { return }
        store.threads[i].isArchiving = true
        onThreadsChanged?()
    }

    /// Clears the archiving flag on a thread that is still in the active list (called on failure).
    func clearThreadArchivingState(id: UUID) {
        guard let i = store.threads.firstIndex(where: { $0.id == id }) else { return }
        guard store.threads[i].isArchiving else { return }
        store.threads[i].isArchiving = false
        onThreadsChanged?()
    }

    private func archiveAutoCommitMessage(for thread: MagentThread, resolvedBranchName: String?) -> String {
        let branchName = resolvedBranchName ?? thread.branchName
        let worktreeName = URL(fileURLWithPath: thread.worktreePath).lastPathComponent
        return "Uncommitted changes on \(branchName) (\(worktreeName))"
    }

    func suggestedArchiveCommitMessage(for thread: MagentThread) async -> String {
        let resolvedBranchName = await git.getCurrentBranch(workingDirectory: thread.worktreePath)
        return archiveAutoCommitMessage(for: thread, resolvedBranchName: resolvedBranchName)
    }

    private func autoCommitBeforeForcedArchiveIfNeeded(
        _ thread: MagentThread,
        commitMessage: String
    ) async throws {
        let isDirty = await git.isDirty(worktreePath: thread.worktreePath)
        guard isDirty else { return }
        _ = try await git.commitAllChanges(worktreePath: thread.worktreePath, message: commitMessage)
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
        forceCommitMessage: String? = nil,
        syncLocalPathsBackToRepo: Bool? = nil,
        awaitLocalSync: Bool = false
    ) async throws -> String? {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        // If the archive fails before the thread is removed from the list, clear the archiving flag.
        // Keep this before any throwing preflight checks so early validation failures
        // (dirty-worktree refusal) also clear the "Archiving..." UI state.
        var archiveCompleted = false
        defer {
            if !archiveCompleted {
                clearThreadArchivingState(id: thread.id)
            }
        }

        // Dirty-worktree guard. Archiving runs `git worktree remove --force`, which
        // unconditionally deletes the worktree directory.
        // - Default + CLI: refuse dirty worktrees until the user commits/discards manually.
        // - GUI force path: when caller provides an explicit commit message, create
        //   that commit first, then continue archive.
        let isDirty = await git.isDirty(worktreePath: thread.worktreePath)
        if isDirty {
            guard force, let forceCommitMessage else {
                throw ThreadManagerError.dirtyWorktree(worktreePath: thread.worktreePath)
            }
            let trimmedCommitMessage = forceCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommitMessage.isEmpty else {
                throw ThreadManagerError.dirtyWorktree(worktreePath: thread.worktreePath)
            }
            try await autoCommitBeforeForcedArchiveIfNeeded(thread, commitMessage: trimmedCommitMessage)
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
            let syncEntries = effectiveLocalSyncEntries?(thread, project) ?? []
            let copySyncPaths = syncEntries.filter { $0.mode == .copy }.map(\.path)
            // Resolve the sync destination: base-branch sibling worktree if available,
            // otherwise the main repo path.
            let (syncTargetPath, _) = resolveBaseBranchSyncTargetForThread?(thread, project) ?? (project.repoPath, "")
            let destOverride = syncTargetPath != project.repoPath ? syncTargetPath : nil
            if !copySyncPaths.isEmpty, promptForLocalSyncConflicts {
                do {
                    try await syncConfiguredLocalPathsFromWorktreeAsync?(project, thread.worktreePath, syncEntries, true, destOverride)
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

        // Resolve deferred sync state while the thread is still in `store.threads` —
        // resolveBaseBranchSyncTargetForThread reads the active thread list.
        let deferredSyncPaths: [String]?
        let deferredSyncDestination: String?
        if !shouldSyncEagerly, shouldSyncLocalPathsBackToRepo,
           let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            deferredSyncPaths = (effectiveLocalSyncEntries?(thread, project) ?? [])
                .filter { $0.mode == .copy }
                .map(\.path)
            let (syncTargetPath, _) = resolveBaseBranchSyncTargetForThread?(thread, project) ?? (project.repoPath, "")
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
        clearTrackedInitialPromptInjectionForSessions?(thread.tmuxSessionNames)
        notifiedWaitingSessionsRemove?(thread.tmuxSessionNames)
        rateLimitLiftPendingResumeSessionsRemove?(thread.tmuxSessionNames)

        // Free every ghostty surface for this thread (cache, pop-out windows) BEFORE
        // the cleanup task kills the tmux sessions. Ghostty calls _exit() when a PTY
        // fd closes on a live surface, silently terminating the entire process.
        releaseLivingGhosttySurfaces(for: thread)

        // Remove from active list
        store.threads.removeAll { $0.id == thread.id }

        NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
        onThreadArchived?(thread)

        cleanupRenameStateForThread?(thread.id)
        cleanupAgentSetupForThread?(thread.id)

        let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "Unknown Project"
        showArchivedThreadBanner(for: thread, projectName: projectName, warning: archiveWarning)

        // ── Fire-and-forget cleanup (local sync for deferred path, tmux     ──
        // ── kills, worktree removal, symlink/stale-session sweeps).         ──
        let capturedProject = settings.projects.first(where: { $0.id == thread.projectId })
        let capturedTmux = tmux
        let capturedGit = git
        let capturedSettings = settings
        let capturedActiveWorktreeNames = worktreeActiveNames?(thread.projectId) ?? []
        let capturedReferencedSessions = referencedMagentSessionNames?() ?? []
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
        if let existing = store.threads.first(where: { $0.id == threadId }) {
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

        if store.threads.contains(where: { $0.projectId == restoredThread.projectId && $0.name == restoredThread.name }) {
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

        store.threads.append(restoredThread)
        bumpThreadToTopOfSection?(restoredThread.id)
        // Sync any changes bumpThreadToTopOfSection made back into the persisted list.
        // Re-locate by ID instead of reusing freshArchivedIndex — the local allThreads array
        // is unchanged, but a defensive lookup prevents silent breakage if a future edit
        // inserts another persistence reload between here and line 695.
        if let restoredActiveIndex = store.threads.firstIndex(where: { $0.id == restoredThread.id }) {
            restoredThread = store.threads[restoredActiveIndex]
            if let persistIndex = allThreads.firstIndex(where: { $0.id == restoredThread.id }) {
                allThreads[persistIndex] = restoredThread
            }
        }
        try persistence.saveThreads(allThreads)

        trustDirectoryIfNeeded?(restoredThread.worktreePath, effectiveAgentType?(restoredThread.projectId))
        pruneWorktreeCache?(project)

        await MainActor.run {
            self.onThreadsChanged?()
            BannerManager.shared.show(
                attributedMessage: restoredThreadBannerAttributedMessage(for: restoredThread),
                style: .info,
                duration: Self.archivedThreadBannerDuration
            )
            NotificationCenter.default.post(
                name: .magentNavigateToThread,
                object: nil,
                userInfo: [
                    "threadId": restoredThread.id,
                    "revealSidebarIfHidden": true,
                ]
            )
        }

        return restoredThread
    }

    // MARK: - Delete Thread

    func deleteThread(_ thread: MagentThread) async throws {
        guard !thread.isMain else {
            throw ThreadManagerError.cannotDeleteMainThread
        }

        guard let index = store.threads.firstIndex(where: { $0.id == thread.id }) else {
            throw ThreadManagerError.threadNotFound
        }

        if let ticketKey = thread.jiraTicketKey {
            excludeJiraTicket?(ticketKey, thread.projectId)
        }

        // Free every ghostty surface for this thread (cache, pop-out windows) BEFORE
        // the cleanup task kills the tmux sessions. Same contract as archiveThread.
        releaseLivingGhosttySurfaces(for: thread)

        // Prompt-injection bookkeeping is global to ThreadManager rather than persisted on
        // the thread, so archive/delete must clear it explicitly when a thread disappears.
        clearTrackedInitialPromptInjectionForSessions?(thread.tmuxSessionNames)
        notifiedWaitingSessionsRemove?(thread.tmuxSessionNames)
        rateLimitLiftPendingResumeSessionsRemove?(thread.tmuxSessionNames)

        // Remove from active list
        store.threads.remove(at: index)

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
            // Mirror archiveThread: PopoutWindowManager.startObserving listens for
            // this notification to clean up any pop-out windows whose thread is no
            // longer present. Omitting it leaves pop-out surfaces alive until the
            // detached cleanup task kills their tmux sessions — ghostty _exit().
            NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
            self.onThreadDeleted?(thread)
        }

        cleanupRenameStateForThread?(thread.id)
        cleanupAgentSetupForThread?(thread.id)

        // Run slow cleanup in a detached task so it does not inherit the caller's UI context.
        // Capture everything needed so the detached task never hops back to the main actor.
        let capturedTmux = tmux
        let capturedGit = git
        let capturedSettings = persistence.loadSettings()
        let capturedProject = capturedSettings.projects.first(where: { $0.id == thread.projectId })
        // Snapshot — may go slightly stale before the detached task runs, but the window is
        // negligible and avoids hopping back to the main actor mid-cleanup. See archive path.
        let capturedActiveWorktreeNames = worktreeActiveNames?(thread.projectId) ?? []
        let capturedReferencedSessions = referencedMagentSessionNames?() ?? []
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
            await ThreadManager.cleanupStaleSessions(
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

        guard let index = store.threads.firstIndex(where: { $0.id == thread.id }) else {
            return .failed(ThreadManagerError.threadNotFound)
        }

        do {
            // Prune stale worktree references
            await git.pruneWorktrees(repoPath: project.repoPath)

            // Kill any stale tmux sessions for this thread
            for sessionName in store.threads[index].tmuxSessionNames {
                try? await tmux.killSession(name: sessionName)
            }
            store.threads[index].tmuxSessionNames = []
            store.threads[index].sessionConversationIDs = [:]
            store.threads[index].sessionCreatedAts = [:]
            store.threads[index].freshAgentSessions = []
            store.threads[index].forwardedTmuxSessions = []
            store.threads[index].submittedPromptsBySession = [:]
            store.threads[index].lastSelectedTabIdentifier = nil

            // Re-create the worktree
            let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: thread.branchName)
            if branchExists {
                _ = try await git.addWorktreeForExistingBranch(
                    repoPath: project.repoPath,
                    branchName: thread.branchName,
                    worktreePath: thread.worktreePath
                )
            } else {
                let persistedBaseBranch = store.threads[index].baseBranch?
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
            trustDirectoryIfNeeded?(thread.worktreePath, effectiveAgentType?(thread.projectId))

            // Persist updated threads
            try persistence.saveActiveThreads(store.threads)

            return .recovered
        } catch {
            return .failed(error)
        }
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

    // MARK: - Static helpers

    /// Clears transient session state from a thread. Nonisolated so it can be called
    /// from both main-actor and nonisolated contexts.
    nonisolated static func clearPersistedSessionState(for thread: inout MagentThread) {
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

    // MARK: - Archive persistence (off main actor)

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
            ThreadManager.excludeJiraTicketInPersistence(key: ticketKey, projectId: projectId, persistence: persistence)
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
        await ThreadManager.cleanupStaleSessions(
            tmux: tmux,
            referencedSessions: referencedSessions
        )
    }

    // MARK: - Banner helpers

    private func showArchivedThreadBanner(for thread: MagentThread, projectName: String, warning: String?) {
        let attributed = archivedThreadBannerAttributedMessage(for: thread, warning: warning)
        let details = archivedThreadBannerDetails(for: thread, projectName: projectName)
        let threadId = thread.id
        let threadName = thread.name

        BannerManager.shared.show(
            attributedMessage: attributed,
            style: warning == nil ? .info : .warning,
            duration: Self.archivedThreadBannerDuration,
            isDismissible: true,
            actions: [
                BannerAction(title: "Restore") { [weak self] in
                    Task { [weak self] in
                        _ = await self?.restoreArchivedThreadFromUserAction(id: threadId, threadName: threadName)
                    }
                }
            ],
            details: details,
            detailsCollapsedTitle: "More Info",
            detailsExpandedTitle: "Less Info"
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
}
