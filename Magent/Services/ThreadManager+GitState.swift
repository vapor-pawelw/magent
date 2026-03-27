import Foundation
import MagentCore

enum BackgroundWorktreeCachePruner {
    nonisolated static func prune(worktreesBasePath: String, activeNames: Set<String>) {
        let url = URL(fileURLWithPath: worktreesBasePath).appendingPathComponent(".magent-cache.json")
        guard let data = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var cache = try? decoder.decode(WorktreeMetadataCache.self, from: data) else { return }

        let before = cache.worktrees.count
        cache.worktrees = cache.worktrees.filter { activeNames.contains($0.key) }
        guard cache.worktrees.count != before else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(cache) else { return }
        try? encoded.write(to: url, options: .atomic)
    }
}

extension ThreadManager {

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
    private static func stripRemotePrefix(_ branch: String) -> String {
        if branch.hasPrefix("origin/") {
            return String(branch.dropFirst("origin/".count))
        }
        return branch
    }

    // MARK: - Dirty State

    func refreshDirtyStates() async {
        let snapshot = threads.filter { !$0.isArchived }
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
            guard let i = threads.firstIndex(where: { $0.id == id }) else { continue }
            if threads[i].isDirty != dirty {
                threads[i].isDirty = dirty
                changed = true
            }
            // Set hasEverDoneWork the first time the worktree becomes dirty.
            if dirty && !threads[i].isMain && !threads[i].hasEverDoneWork {
                threads[i].hasEverDoneWork = true
                persistedChanged = true
                changed = true
            }
        }
        if persistedChanged {
            persistence.debouncedSaveActiveThreads(threads)
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    /// Refreshes the dirty state for a single thread. Returns true if the value changed.
    @discardableResult
    func refreshDirtyState(for threadId: UUID) async -> Bool {
        guard let idx = threads.firstIndex(where: { $0.id == threadId }),
              !threads[idx].isArchived else { return false }
        let thread = threads[idx]
        let dirty = await git.isDirty(worktreePath: thread.worktreePath)
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        var changed = false
        if threads[i].isDirty != dirty {
            threads[i].isDirty = dirty
            changed = true
        }
        if dirty && !threads[i].isMain && !threads[i].hasEverDoneWork {
            threads[i].hasEverDoneWork = true
            persistence.debouncedSaveActiveThreads(threads)
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

        let snapshot = threads.filter { !$0.isArchived && !$0.isMain }

        // Per-thread result from the parallel git work phase.
        struct ThreadDeliveryResult {
            let threadId: UUID
            let projectId: UUID
            let worktreeKey: String
            let currentBranch: String
            let resolvedBaseBranch: String
            // Non-nil when the originally resolved base branch was missing and we fell back.
            let baseBranchFallback: BaseBranchReset?
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
        }

        var inputs: [ThreadInput] = []
        for thread in snapshot {
            guard FileManager.default.fileExists(atPath: thread.worktreePath) else { continue }
            guard cacheByProjectId[thread.projectId] != nil else { continue }
            let meta = cacheByProjectId[thread.projectId]?.cache.worktrees[thread.worktreeKey]

            // Restore persisted base branch reset info for banner display.
            if let resetFrom = meta?.baseBranchResetFrom, !resetFrom.isEmpty,
               let override = meta?.detectedBaseBranch {
                baseBranchResets[thread.id] = BaseBranchReset(oldBase: resetFrom, newBase: override)
            }

            let resolved = resolveBaseBranch(for: thread)
            inputs.append(ThreadInput(
                thread: thread,
                resolvedBaseBranch: resolved,
                fallbackBaseBranch: resolveBaseBranchFromConfig(for: thread, settings: settings),
                forkPoint: meta?.forkPointCommit
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
                group.addTask {
                    // Phase 0: validate base branch exists; fall back to project default if missing.
                    var resolvedBase = initialBase
                    var baseBranchFallback: BaseBranchReset?
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
                        baseBranchFallback = BaseBranchReset(oldBase: initialBase, newBase: fallbackBase)
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
            guard let i = threads.firstIndex(where: { $0.id == result.threadId }) else { continue }

            // When base branch was missing, update the cache to the fallback value
            // and record the reset so we can show a banner for the selected thread.
            if let fallback = result.baseBranchFallback {
                if var projectEntry = cacheByProjectId[result.projectId] {
                    var meta = projectEntry.cache.worktrees[result.worktreeKey] ?? WorktreeMetadata()
                    meta.detectedBaseBranch = fallback.newBase
                    meta.baseBranchResetFrom = fallback.oldBase
                    projectEntry.cache.worktrees[result.worktreeKey] = meta
                    projectEntry.dirty = true
                    cacheByProjectId[result.projectId] = projectEntry
                }
                baseBranchResets[threads[i].id] = BaseBranchReset(
                    oldBase: fallback.oldBase,
                    newBase: fallback.newBase
                )
            }

            if result.newlyHasEverDoneWork && !threads[i].hasEverDoneWork {
                threads[i].hasEverDoneWork = true
                persistedThreadsChanged = true
                changed = true
            }

            let hasWorkDone = threads[i].hasEverDoneWork
            if !hasWorkDone {
                if threads[i].isFullyDelivered {
                    threads[i].isFullyDelivered = false
                    changed = true
                }
                continue
            }

            if result.knownHasCommitsAhead {
                if threads[i].isFullyDelivered {
                    threads[i].isFullyDelivered = false
                    changed = true
                }
                continue
            }

            if let delivered = result.isFullyDelivered,
               threads[i].isFullyDelivered != delivered {
                threads[i].isFullyDelivered = delivered
                changed = true
            }
        }

        // Save mutated caches.
        for (_, entry) in cacheByProjectId where entry.dirty {
            persistence.saveWorktreeCache(entry.cache, worktreesBasePath: entry.basePath)
        }
        if persistedThreadsChanged {
            persistence.debouncedSaveActiveThreads(threads)
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
        guard let idx = threads.firstIndex(where: { $0.id == threadId }),
              !threads[idx].isArchived, !threads[idx].isMain else { return false }
        let thread = threads[idx]
        guard thread.hasEverDoneWork else {
            if threads[idx].isFullyDelivered {
                threads[idx].isFullyDelivered = false
                return true
            }
            return false
        }
        let baseBranch = resolveBaseBranch(for: thread)
        let delivered = await git.isFullyDelivered(
            worktreePath: thread.worktreePath,
            baseBranch: baseBranch
        )
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        guard threads[i].isFullyDelivered != delivered else { return false }
        threads[i].isFullyDelivered = delivered
        return true
    }

    /// Removes stale entries from the worktree metadata cache for a project.
    /// Returns the set of active (non-archived, non-main) worktree keys for a project.
    /// Can be captured before a detached task to avoid a main-actor hop for pruning.
    func worktreeActiveNames(for projectId: UUID) -> Set<String> {
        Set(
            threads
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

    // MARK: - Branch State

    func refreshBranchStates() async {
        let settings = persistence.loadSettings()
        let snapshot = threads.filter { !$0.isArchived }

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
        var persistedChanged = false
        var branchChangedThreadIds: Set<UUID> = []
        for result in results {
            guard let i = threads.firstIndex(where: { $0.id == result.id }) else { continue }

            let expected: String?
            if threads[i].isMain {
                if let project = settings.projects.first(where: { $0.id == threads[i].projectId }),
                   let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
                    expected = defaultBranch
                } else {
                    expected = result.detectedDefault
                }
            } else {
                expected = threads[i].branchName
            }

            let resolvedExpected = threads[i].isMain ? expected : threads[i].branchName
            let mismatch: Bool
            if let resolvedExpected, let actual = result.actual,
               !resolvedExpected.isEmpty, !actual.isEmpty {
                mismatch = actual != resolvedExpected
            } else {
                mismatch = false
            }

            if threads[i].actualBranch != result.actual
                || threads[i].expectedBranch != resolvedExpected
                || threads[i].hasBranchMismatch != mismatch {
                let branchActuallyChanged = threads[i].actualBranch != result.actual
                threads[i].actualBranch = result.actual
                threads[i].expectedBranch = resolvedExpected
                threads[i].hasBranchMismatch = mismatch
                changed = true
                if branchActuallyChanged {
                    branchChangedThreadIds.insert(result.id)
                }
            }
        }
        if persistedChanged {
            persistence.debouncedSaveActiveThreads(threads)
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
        if !branchChangedThreadIds.isEmpty {
            await MainActor.run {
                NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            }
            await verifyDetectedJiraTickets(forThreadIds: branchChangedThreadIds)
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
        guard let index = threads.firstIndex(where: { $0.id == threadId }),
              let actual = threads[index].actualBranch, !actual.isEmpty else { return }

        if threads[index].isMain {
            var settings = persistence.loadSettings()
            if let projIdx = settings.projects.firstIndex(where: { $0.id == threads[index].projectId }) {
                settings.projects[projIdx].defaultBranch = actual
                try? persistence.saveSettings(settings)
            }
        } else {
            threads[index].branchName = actual
            try? persistence.saveActiveThreads(threads)
        }

        threads[index].expectedBranch = actual
        threads[index].hasBranchMismatch = false
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    func switchToExpectedBranch(threadId: UUID) async throws {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            throw ThreadManagerError.threadNotFound
        }
        let thread = threads[index]
        guard let expected = resolveExpectedBranch(for: thread) else {
            throw ThreadManagerError.noExpectedBranch
        }
        try await git.checkoutBranch(workingDirectory: thread.worktreePath, branchName: expected)

        // Refresh branch state immediately
        let actual = await git.getCurrentBranch(workingDirectory: thread.worktreePath)
        threads[index].actualBranch = actual
        threads[index].hasBranchMismatch = actual != nil && actual != expected
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }
    }

    func refreshDiffStats(for threadId: UUID) async -> [FileDiffEntry] {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        let baseBranch = resolveBaseBranch(for: thread)
        return await git.diffStats(worktreePath: thread.worktreePath, baseBranch: baseBranch)
    }

    // MARK: - Manual Base Branch Override

    /// Sets the base branch for a thread, updating the worktree metadata cache.
    func setBaseBranch(_ baseBranch: String, for threadId: UUID) {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }
        let basePath = project.resolvedWorktreesBasePath()
        var cache = persistence.loadWorktreeCache(worktreesBasePath: basePath)
        var meta = cache.worktrees[thread.worktreeKey] ?? WorktreeMetadata()
        meta.detectedBaseBranch = Self.stripRemotePrefix(baseBranch)
        cache.worktrees[thread.worktreeKey] = meta
        persistence.saveWorktreeCache(cache, worktreesBasePath: basePath)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Acknowledges (clears) the base branch reset banner for a thread.
    func clearBaseBranchReset(for threadId: UUID) {
        baseBranchResets.removeValue(forKey: threadId)
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
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
        guard let thread = threads.first(where: { $0.id == threadId }),
              FileManager.default.fileExists(atPath: thread.worktreePath) else { return [] }
        let settings = persistence.loadSettings()
        let defaultBranch = settings.projects.first(where: { $0.id == thread.projectId })?.defaultBranch ?? "main"
        return await git.listAncestorBranches(
            worktreePath: thread.worktreePath,
            currentBranch: thread.currentBranch,
            defaultBranch: defaultBranch
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
