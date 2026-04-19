import Foundation
import MagentCore

/// Standalone service owning all git-state tracking logic.
/// Extracted from `ThreadManager+GitState`.
///
/// The caller (ThreadManager) is responsible for delegate calls
/// (`didUpdateThreads`) after mutations — methods here call `onThreadsChanged()`
/// to signal that something changed.
final class GitStateService {

    // MARK: - Dependencies

    let store: ThreadStore
    let persistence: PersistenceService
    let git: GitService

    // MARK: - State

    /// Pending base-branch resets keyed by thread ID.
    /// Set when the resolved base branch is missing and we fell back to the project default.
    /// Cleared when the user acknowledges the banner or the original branch reappears.
    var baseBranchResets: [UUID: ThreadManager.BaseBranchReset] = [:]

    // MARK: - Callbacks

    /// Called whenever thread state has changed and the caller should propagate to delegate/UI.
    var onThreadsChanged: (() -> Void)?

    /// Called from `refreshBranchStates` with the set of thread IDs whose actual branches
    /// changed, so ThreadManager can forward to `verifyDetectedJiraTickets`.
    var onBranchesChanged: ((Set<UUID>) async -> Void)?

    /// Called from `refreshBranchStates` when a branch-name compatibility symlink needs
    /// to be ensured. Parameters: (branchName, worktreePath, worktreesBasePath).
    var onBranchSymlinkNeeded: ((String, String, String) -> Void)?

    /// Resolves the cached remote for a project ID. Used by `refreshDeliveredStates`
    /// to avoid a tight dependency on ThreadManager's `_cachedRemoteByProjectId`.
    var cachedRemoteResolver: ((UUID) -> GitRemote?)?

    // MARK: - Init

    init(store: ThreadStore, persistence: PersistenceService, tmux: TmuxService, git: GitService) {
        self.store = store
        self.persistence = persistence
        self.git = git
    }

    // MARK: - Base Branch

    /// Returns the resolved base branch for a thread.
    /// Priority: manual override (cache) → stored baseBranch (from creation) → project default → "main".
    /// Base branch is never auto-detected — it only changes via explicit user action
    /// (context menu, CLI, "Use PR target").
    func resolveBaseBranch(for thread: MagentThread) -> String {
        let settings = persistence.loadSettings()
        // 1. Manual override stored in worktree cache (set via context menu, CLI, or PR target).
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            let cache = persistence.loadWorktreeCache(worktreesBasePath: project.resolvedWorktreesBasePath())
            if let meta = cache.worktrees[thread.worktreeKey],
               let override = meta.detectedBaseBranch,
               !override.isEmpty {
                return Self.stripRemotePrefix(override)
            }
        }
        // 2. Thread's stored base branch from creation time.
        if let base = thread.baseBranch, !base.isEmpty {
            return Self.stripRemotePrefix(base)
        }
        // 3. Project default branch.
        if let project = settings.projects.first(where: { $0.id == thread.projectId }),
           let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
            return defaultBranch
        }
        return "main"
    }

    /// Strips a leading "origin/" prefix from a branch name so it can be compared against
    /// local branch names (thread.currentBranch). The detectedBaseBranch cache can store
    /// remote-tracking refs like "origin/feature-branch" from git fork-point detection.
    static func stripRemotePrefix(_ branch: String) -> String {
        if branch.hasPrefix("origin/") {
            return String(branch.dropFirst("origin/".count))
        }
        return branch
    }

    // MARK: - Dirty State

    func refreshDirtyStates() async {
        let snapshot = store.threads.filter { !$0.isArchived }
        // Run all git-status checks concurrently — sequential per-thread awaits add up fast
        // with many threads. GitService is Sendable so safe to call from child tasks.
        var dirtyById: [UUID: Bool] = [:]
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for thread in snapshot {
                let path = thread.worktreePath
                let id = thread.id
                group.addTask {
                    let dirty = await self.git.isDirty(worktreePath: path)
                    return (id, dirty)
                }
            }
            for await (id, dirty) in group {
                dirtyById[id] = dirty
            }
        }
        var changed = false
        var persistedChanged = false
        for (id, dirty) in dirtyById {
            guard let i = store.threads.firstIndex(where: { $0.id == id }) else { continue }
            if store.threads[i].isDirty != dirty {
                store.threads[i].isDirty = dirty
                changed = true
            }
            // Set hasEverDoneWork the first time the worktree becomes dirty.
            if dirty && !store.threads[i].isMain && !store.threads[i].hasEverDoneWork {
                store.threads[i].hasEverDoneWork = true
                persistedChanged = true
                changed = true
            }
        }
        if persistedChanged {
            persistence.debouncedSaveActiveThreads(store.threads)
        }
        if changed {
            onThreadsChanged?()
        }
    }

    /// Refreshes the dirty state for a single thread. Returns true if the value changed.
    @discardableResult
    func refreshDirtyState(for threadId: UUID) async -> Bool {
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }),
              !store.threads[idx].isArchived else { return false }
        let thread = store.threads[idx]
        let dirty = await git.isDirty(worktreePath: thread.worktreePath)
        guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { return false }
        var changed = false
        if store.threads[i].isDirty != dirty {
            store.threads[i].isDirty = dirty
            changed = true
        }
        if dirty && !store.threads[i].isMain && !store.threads[i].hasEverDoneWork {
            store.threads[i].hasEverDoneWork = true
            persistence.debouncedSaveActiveThreads(store.threads)
            changed = true
        }
        return changed
    }

    // MARK: - Delivered State

    func refreshDeliveredStates() async {
        let settings = persistence.loadSettings()
        // Load caches keyed by project id; track whether each cache was mutated.
        var cacheByProjectId: [UUID: (cache: WorktreeMetadataCache, basePath: String, dirty: Bool)] = [:]
        for project in settings.projects {
            let basePath = project.resolvedWorktreesBasePath()
            cacheByProjectId[project.id] = (
                cache: persistence.loadWorktreeCache(worktreesBasePath: basePath),
                basePath: basePath,
                dirty: false
            )
        }

        let snapshot = store.threads.filter { !$0.isArchived && !$0.isMain }

        // Per-thread result from the parallel git work phase.
        struct ThreadDeliveryResult {
            let threadId: UUID
            let projectId: UUID
            let worktreeKey: String
            let currentBranch: String
            let resolvedBaseBranch: String
            // Non-nil when the originally resolved base branch was missing and we fell back.
            let baseBranchFallback: ThreadManager.BaseBranchReset?
            // The original old base from a previous reset was found to exist again (transient issue resolved).
            let oldBaseRestored: Bool
            // hasEverDoneWork was false in snapshot but is now true.
            let newlyHasEverDoneWork: Bool
            // We found commits ahead this cycle — delivery is false by definition.
            let knownHasCommitsAhead: Bool
            // isFullyDelivered result; nil when the check was skipped.
            let isFullyDelivered: Bool?
        }

        // Pre-compute per-thread inputs from snapshot + caches so child tasks only read
        // captured value-type data and never touch shared mutable state.
        struct ThreadInput {
            let thread: MagentThread
            let resolvedBaseBranch: String
            let fallbackBaseBranch: String    // project default, used if resolvedBaseBranch is missing
            let forkPoint: String?            // for migration check
            let persistedResetOldBase: String? // original base from a previous reset, to check if it came back
        }

        var inputs: [ThreadInput] = []
        for thread in snapshot {
            guard FileManager.default.fileExists(atPath: thread.worktreePath) else { continue }
            guard cacheByProjectId[thread.projectId] != nil else { continue }
            let meta = cacheByProjectId[thread.projectId]?.cache.worktrees[thread.worktreeKey]

            // Restore persisted base branch reset info for banner display.
            if let resetFrom = meta?.baseBranchResetFrom, !resetFrom.isEmpty,
               let override = meta?.detectedBaseBranch {
                baseBranchResets[thread.id] = ThreadManager.BaseBranchReset(oldBase: resetFrom, newBase: override)
            }

            let resolved = resolveBaseBranch(for: thread)
            inputs.append(ThreadInput(
                thread: thread,
                resolvedBaseBranch: resolved,
                fallbackBaseBranch: resolveBaseBranchFromConfig(for: thread, settings: settings),
                forkPoint: meta?.forkPointCommit,
                persistedResetOldBase: meta?.baseBranchResetFrom
            ))
        }

        // Run all git work concurrently — each task only reads captured value-type inputs.
        var results: [ThreadDeliveryResult] = []
        await withTaskGroup(of: ThreadDeliveryResult?.self) { group in
            for input in inputs {
                let thread = input.thread
                let snapshotHasEverDoneWork = thread.hasEverDoneWork
                let snapshotIsDirty = thread.isDirty
                let initialBase = input.resolvedBaseBranch
                let fallbackBase = input.fallbackBaseBranch
                let persistedOldBase = input.persistedResetOldBase
                group.addTask {
                    // Phase 0: validate base branch exists; fall back to project default if missing.
                    var resolvedBase = initialBase
                    var baseBranchFallback: ThreadManager.BaseBranchReset?
                    var oldBaseRestored = false
                    // Check both the ref as-is and with origin/ prefix.
                    // baseBranch can be stored as "main", "origin/main", or "develop".
                    var baseExists = await self.git.branchExists(
                        repoPath: thread.worktreePath,
                        branchName: initialBase
                    )
                    if !baseExists && !initialBase.hasPrefix("origin/") {
                        baseExists = await self.git.branchExists(
                            repoPath: thread.worktreePath,
                            branchName: "origin/\(initialBase)"
                        )
                    }
                    if !baseExists {
                        resolvedBase = fallbackBase
                        baseBranchFallback = ThreadManager.BaseBranchReset(oldBase: initialBase, newBase: fallbackBase)
                    } else if let oldBase = persistedOldBase, !oldBase.isEmpty {
                        // Current base exists, but we have a persisted reset from a previous cycle.
                        // Check if the original old base came back (transient fetch issue resolved).
                        var oldExists = await self.git.branchExists(
                            repoPath: thread.worktreePath,
                            branchName: oldBase
                        )
                        if !oldExists && !oldBase.hasPrefix("origin/") {
                            oldExists = await self.git.branchExists(
                                repoPath: thread.worktreePath,
                                branchName: "origin/\(oldBase)"
                            )
                        }
                        oldBaseRestored = oldExists
                    }

                    // Phase 1: hasEverDoneWork check (only if not already set in snapshot).
                    var newlyHasEverDoneWork = false
                    var knownHasCommitsAhead = false
                    if !snapshotHasEverDoneWork {
                        let logResult = await ShellExecutor.execute(
                            "git log \(resolvedBase)..HEAD --oneline -n 1",
                            workingDirectory: thread.worktreePath
                        )
                        let hasCommits = logResult.exitCode == 0
                            && !logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if hasCommits || snapshotIsDirty {
                            newlyHasEverDoneWork = true
                            knownHasCommitsAhead = hasCommits
                        } else if let forkPoint = input.forkPoint, !forkPoint.isEmpty {
                            // Migration: work was done + delivered before hasEverDoneWork existed.
                            if let head = await self.git.currentCommit(worktreePath: thread.worktreePath),
                               head != forkPoint {
                                newlyHasEverDoneWork = true
                            }
                        }
                    }

                    // Phase 2: isFullyDelivered check.
                    let hasWorkDone = snapshotHasEverDoneWork || newlyHasEverDoneWork
                    let isFullyDelivered: Bool?
                    if !hasWorkDone {
                        isFullyDelivered = nil  // no work yet — will clear delivered flag in apply phase
                    } else if knownHasCommitsAhead {
                        isFullyDelivered = nil  // commits exist → not delivered; skip redundant check
                    } else {
                        isFullyDelivered = await self.git.isFullyDelivered(
                            worktreePath: thread.worktreePath,
                            baseBranch: resolvedBase
                        )
                    }

                    return ThreadDeliveryResult(
                        threadId: thread.id,
                        projectId: thread.projectId,
                        worktreeKey: thread.worktreeKey,
                        currentBranch: thread.currentBranch,
                        resolvedBaseBranch: resolvedBase,
                        baseBranchFallback: baseBranchFallback,
                        oldBaseRestored: oldBaseRestored,
                        newlyHasEverDoneWork: newlyHasEverDoneWork,
                        knownHasCommitsAhead: knownHasCommitsAhead,
                        isFullyDelivered: isFullyDelivered
                    )
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }

        // Apply all results sequentially, mutating thread state and caches.
        var changed = false
        var persistedThreadsChanged = false
        for result in results {
            guard let i = store.threads.firstIndex(where: { $0.id == result.threadId }) else { continue }

            // When base branch was missing, update the cache to the fallback value
            // and record the reset so we can show a banner for the selected thread.
            if let fallback = result.baseBranchFallback,
               fallback.oldBase != fallback.newBase {
                if var projectEntry = cacheByProjectId[result.projectId] {
                    var meta = projectEntry.cache.worktrees[result.worktreeKey] ?? WorktreeMetadata()
                    meta.detectedBaseBranch = fallback.newBase
                    meta.baseBranchResetFrom = fallback.oldBase
                    projectEntry.cache.worktrees[result.worktreeKey] = meta
                    projectEntry.dirty = true
                    cacheByProjectId[result.projectId] = projectEntry
                }
                baseBranchResets[store.threads[i].id] = ThreadManager.BaseBranchReset(
                    oldBase: fallback.oldBase,
                    newBase: fallback.newBase
                )
            } else if result.oldBaseRestored {
                // The original old base branch came back (transient fetch issue resolved) —
                // auto-clear the stale reset without requiring user acknowledgment.
                baseBranchResets.removeValue(forKey: store.threads[i].id)
                if var projectEntry = cacheByProjectId[result.projectId] {
                    var meta = projectEntry.cache.worktrees[result.worktreeKey] ?? WorktreeMetadata()
                    meta.baseBranchResetFrom = nil
                    meta.detectedBaseBranch = nil
                    projectEntry.cache.worktrees[result.worktreeKey] = meta
                    projectEntry.dirty = true
                    cacheByProjectId[result.projectId] = projectEntry
                }
            }

            if result.newlyHasEverDoneWork && !store.threads[i].hasEverDoneWork {
                store.threads[i].hasEverDoneWork = true
                persistedThreadsChanged = true
                changed = true
            }

            let hasWorkDone = store.threads[i].hasEverDoneWork
            if !hasWorkDone {
                if store.threads[i].isFullyDelivered {
                    store.threads[i].isFullyDelivered = false
                    changed = true
                }
                continue
            }

            if result.knownHasCommitsAhead {
                if store.threads[i].isFullyDelivered {
                    store.threads[i].isFullyDelivered = false
                    changed = true
                }
                continue
            }

            if let delivered = result.isFullyDelivered,
               store.threads[i].isFullyDelivered != delivered {
                store.threads[i].isFullyDelivered = delivered
                changed = true
            }
        }

        // Save mutated caches.
        for (_, entry) in cacheByProjectId where entry.dirty {
            persistence.saveWorktreeCache(entry.cache, worktreesBasePath: entry.basePath)
        }
        if persistedThreadsChanged {
            persistence.debouncedSaveActiveThreads(store.threads)
        }
        if changed {
            onThreadsChanged?()
        }
    }

    /// Refreshes the delivered state for a single thread. Returns true if the value changed.
    @discardableResult
    func refreshDeliveredState(for threadId: UUID) async -> Bool {
        guard let idx = store.threads.firstIndex(where: { $0.id == threadId }),
              !store.threads[idx].isArchived, !store.threads[idx].isMain else { return false }
        let thread = store.threads[idx]
        guard thread.hasEverDoneWork else {
            if store.threads[idx].isFullyDelivered {
                store.threads[idx].isFullyDelivered = false
                return true
            }
            return false
        }
        let baseBranch = resolveBaseBranch(for: thread)
        let delivered = await git.isFullyDelivered(
            worktreePath: thread.worktreePath,
            baseBranch: baseBranch
        )
        guard let i = store.threads.firstIndex(where: { $0.id == threadId }) else { return false }
        guard store.threads[i].isFullyDelivered != delivered else { return false }
        store.threads[i].isFullyDelivered = delivered
        return true
    }

    // MARK: - Branch State

    func refreshBranchStates() async {
        let settings = persistence.loadSettings()
        let snapshot = store.threads.filter { !$0.isArchived }

        struct BranchResult {
            let id: UUID
            let actual: String?
            let detectedDefault: String?  // only set for main threads without a configured default
        }

        // Run all getCurrentBranch (and detectDefaultBranch for main threads) concurrently.
        var results: [BranchResult] = []
        await withTaskGroup(of: BranchResult?.self) { group in
            for thread in snapshot {
                let worktreePath = thread.worktreePath
                guard FileManager.default.fileExists(atPath: worktreePath) else { continue }
                let id = thread.id
                let isMain = thread.isMain
                let projectDefault = settings.projects
                    .first(where: { $0.id == thread.projectId })?.defaultBranch
                group.addTask {
                    let actual = await self.git.getCurrentBranch(workingDirectory: worktreePath)
                    var detectedDefault: String? = nil
                    if isMain && (projectDefault == nil || projectDefault!.isEmpty) {
                        detectedDefault = await self.git.detectDefaultBranch(repoPath: worktreePath)
                    }
                    return BranchResult(id: id, actual: actual, detectedDefault: detectedDefault)
                }
            }
            for await result in group {
                if let result { results.append(result) }
            }
        }

        var changed = false
        var branchChangedThreadIds: Set<UUID> = []
        for result in results {
            guard let i = store.threads.firstIndex(where: { $0.id == result.id }) else { continue }

            let expected: String?
            if store.threads[i].isMain {
                if let project = settings.projects.first(where: { $0.id == store.threads[i].projectId }),
                   let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
                    expected = defaultBranch
                } else {
                    expected = result.detectedDefault
                }
            } else {
                expected = store.threads[i].branchName
            }

            let resolvedExpected = store.threads[i].isMain ? expected : store.threads[i].branchName
            let mismatch: Bool
            if let resolvedExpected, let actual = result.actual,
               !resolvedExpected.isEmpty, !actual.isEmpty {
                mismatch = actual != resolvedExpected
            } else {
                mismatch = false
            }

            if store.threads[i].actualBranch != result.actual
                || store.threads[i].expectedBranch != resolvedExpected
                || store.threads[i].hasBranchMismatch != mismatch {
                let branchActuallyChanged = store.threads[i].actualBranch != result.actual
                store.threads[i].actualBranch = result.actual
                store.threads[i].expectedBranch = resolvedExpected
                store.threads[i].hasBranchMismatch = mismatch
                changed = true
                if branchActuallyChanged {
                    branchChangedThreadIds.insert(result.id)
                }
            }

            // Keep a branch-name compatibility symlink in the worktrees base dir.
            // This self-heals worktrees whose checked-out branch differs from the
            // permanent worktree directory name.
            if !store.threads[i].isMain,
               let project = settings.projects.first(where: { $0.id == store.threads[i].projectId }) {
                let actualTrimmed = result.actual?.trimmingCharacters(in: .whitespacesAndNewlines)
                let branchForSymlink = (actualTrimmed?.isEmpty == false)
                    ? (actualTrimmed ?? store.threads[i].branchName)
                    : store.threads[i].branchName
                onBranchSymlinkNeeded?(
                    branchForSymlink,
                    store.threads[i].worktreePath,
                    project.resolvedWorktreesBasePath()
                )
            }
        }

        if changed {
            onThreadsChanged?()
        }
        if !branchChangedThreadIds.isEmpty {
            NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            await onBranchesChanged?(branchChangedThreadIds)
        }
    }

    func resolveExpectedBranch(for thread: MagentThread) -> String? {
        // Prefer the cached expected branch from the polling cycle
        if let cached = thread.expectedBranch, !cached.isEmpty {
            return cached
        }
        if thread.isMain {
            let settings = persistence.loadSettings()
            if let project = settings.projects.first(where: { $0.id == thread.projectId }),
               let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
                return defaultBranch
            }
            return nil
        }
        return thread.branchName
    }

    /// Updates the expected branch for a thread to match its current actual branch,
    /// clearing the mismatch. For main threads, updates the project's default branch.
    func acceptActualBranch(threadId: UUID) {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }),
              let actual = store.threads[index].actualBranch, !actual.isEmpty else { return }

        if store.threads[index].isMain {
            var settings = persistence.loadSettings()
            if let projIdx = settings.projects.firstIndex(where: { $0.id == store.threads[index].projectId }) {
                settings.projects[projIdx].defaultBranch = actual
                try? persistence.saveSettings(settings)
            }
        } else {
            store.threads[index].branchName = actual
            let settings = persistence.loadSettings()
            if let project = settings.projects.first(where: { $0.id == store.threads[index].projectId }) {
                onBranchSymlinkNeeded?(
                    actual,
                    store.threads[index].worktreePath,
                    project.resolvedWorktreesBasePath()
                )
            }
            try? persistence.saveActiveThreads(store.threads)
        }

        store.threads[index].expectedBranch = actual
        store.threads[index].hasBranchMismatch = false
        onThreadsChanged?()
    }

    func switchToExpectedBranch(threadId: UUID) async throws {
        guard let index = store.threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }
        let thread = store.threads[index]
        guard let expected = resolveExpectedBranch(for: thread) else {
            throw ThreadManagerError.noExpectedBranch
        }
        try await git.checkoutBranch(workingDirectory: thread.worktreePath, branchName: expected)

        // Refresh branch state immediately
        let actual = await git.getCurrentBranch(workingDirectory: thread.worktreePath)
        store.threads[index].actualBranch = actual
        store.threads[index].hasBranchMismatch = actual != nil && actual != expected
        onThreadsChanged?()
    }

    func refreshDiffStats(for threadId: UUID) async -> [FileDiffEntry] {
        guard let thread = store.threads.first(where: { $0.id == threadId }) else { return [] }
        let baseBranch = resolveBaseBranch(for: thread)
        return await git.diffStats(worktreePath: thread.worktreePath, baseBranch: baseBranch)
    }

    // MARK: - Manual Base Branch Override

    /// Sets the base branch for a thread, updating the worktree metadata cache.
    func setBaseBranch(_ baseBranch: String, for threadId: UUID) {
        guard let thread = store.threads.first(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }
        let basePath = project.resolvedWorktreesBasePath()
        var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
        var meta = cache.worktrees[thread.worktreeKey] ?? WorktreeMetadata()
        meta.detectedBaseBranch = Self.stripRemotePrefix(baseBranch)
        cache.worktrees[thread.worktreeKey] = meta
        persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        onThreadsChanged?()
    }

    /// Acknowledges (clears) the base branch reset banner for a thread.
    func clearBaseBranchReset(for threadId: UUID) {
        baseBranchResets.removeValue(forKey: threadId)
        guard let thread = store.threads.first(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }
        let basePath = project.resolvedWorktreesBasePath()
        var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
        if var meta = cache.worktrees[thread.worktreeKey] {
            meta.baseBranchResetFrom = nil
            cache.worktrees[thread.worktreeKey] = meta
            persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        }
    }

    /// Returns ancestor remote branches for a thread, ordered closest-first.
    /// Stops at the project's default branch so ancestors beyond it are excluded.
    func listAncestorBranches(for threadId: UUID) async -> [String] {
        guard let thread = store.threads.first(where: { $0.id == threadId }),
              FileManager.default.fileExists(atPath: thread.worktreePath) else { return [] }
        let settings = persistence.loadSettings()
        let defaultBranch = settings.projects.first(where: { $0.id == thread.projectId })?.defaultBranch ?? "main"
        return await git.listAncestorBranches(
            worktreePath: thread.worktreePath,
            currentBranch: thread.currentBranch,
            defaultBranch: defaultBranch
        )
    }

    // MARK: - Worktree Helpers

    /// Returns the set of active (non-archived, non-main) worktree keys for a project.
    /// Can be captured before a detached task to avoid a main-actor hop for pruning.
    func worktreeActiveNames(for projectId: UUID) -> Set<String> {
        Set(
            store.threads
                .filter { $0.projectId == projectId && !$0.isArchived && !$0.isMain }
                .map { $0.worktreeKey }
        )
    }

    func pruneWorktreeCache(for project: Project) {
        let activeNames = worktreeActiveNames(for: project.id)
        persistence.pruneWorktreeCache(
            worktreesBasePath: project.resolvedWorktreesBasePath(),
            activeNames: activeNames
        )
    }

    // MARK: - Private Helpers

    /// Config-only base branch resolution (no cache read). Used as fallback when detection fails.
    private func resolveBaseBranchFromConfig(for thread: MagentThread, settings: AppSettings) -> String {
        if let project = settings.projects.first(where: { $0.id == thread.projectId }),
           let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
            return defaultBranch
        }
        if let base = thread.baseBranch, !base.isEmpty {
            return base
        }
        return "main"
    }
}
