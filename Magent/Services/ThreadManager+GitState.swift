import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Base Branch

    /// Returns the resolved base branch for a thread.
    /// Priority: detected remote branch (cached per current branch) → stored baseBranch → project default → "main".
    func resolveBaseBranch(for thread: MagentThread) -> String {
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            let cache = persistence.loadWorktreeCache(worktreesBasePath: project.resolvedWorktreesBasePath())
            if let meta = cache.worktrees[thread.worktreeKey],
               let detected = meta.detectedBaseBranch,
               let detectedFor = meta.detectedFor,
               detectedFor == thread.currentBranch {
                return detected
            }
            if let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
                return defaultBranch
            }
        }
        if let base = thread.baseBranch, !base.isEmpty {
            return base
        }
        return "main"
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
            // Set when base branch was newly detected from git (cache needs update).
            let detectedBaseBranch: String?
            let resolvedBaseBranch: String
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
            let cachedBaseBranch: String?     // valid only when detectedFor matches currentBranch
            let fallbackBaseBranch: String    // from project config
            let forkPoint: String?            // for migration check
        }

        var inputs: [ThreadInput] = []
        for thread in snapshot {
            guard FileManager.default.fileExists(atPath: thread.worktreePath) else { continue }
            guard let projectEntry = cacheByProjectId[thread.projectId] else { continue }
            let meta = projectEntry.cache.worktrees[thread.worktreeKey]
            let cachedBase: String? = {
                guard let detected = meta?.detectedBaseBranch,
                      let detectedFor = meta?.detectedFor,
                      detectedFor == thread.currentBranch else { return nil }
                return detected
            }()
            inputs.append(ThreadInput(
                thread: thread,
                cachedBaseBranch: cachedBase,
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
                group.addTask {
                    // Phase 1: resolve base branch.
                    let resolvedBase: String
                    let detectedBase: String?
                    if let cached = input.cachedBaseBranch {
                        resolvedBase = cached
                        detectedBase = nil
                    } else if let detected = await self.git.detectBaseBranch(
                        worktreePath: thread.worktreePath,
                        currentBranch: thread.currentBranch
                    ) {
                        resolvedBase = detected
                        detectedBase = detected
                    } else {
                        resolvedBase = input.fallbackBaseBranch
                        detectedBase = nil
                    }

                    // Phase 2: hasEverDoneWork check (only if not already set in snapshot).
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

                    // Phase 3: isFullyDelivered check.
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
                        detectedBaseBranch: detectedBase,
                        resolvedBaseBranch: resolvedBase,
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
            // Update cache if base branch was newly detected.
            if let detected = result.detectedBaseBranch,
               var projectEntry = cacheByProjectId[result.projectId] {
                var meta = projectEntry.cache.worktrees[result.worktreeKey] ?? WorktreeMetadata()
                meta.detectedBaseBranch = detected
                meta.detectedFor = result.currentBranch
                projectEntry.cache.worktrees[result.worktreeKey] = meta
                projectEntry.dirty = true
                cacheByProjectId[result.projectId] = projectEntry
            }

            guard let i = threads.firstIndex(where: { $0.id == result.threadId }) else { continue }

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
    func pruneWorktreeCache(for project: Project) {
        let activeNames = Set(
            threads
                .filter { $0.projectId == project.id && !$0.isArchived && !$0.isMain }
                .map { $0.worktreeKey }
        )
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

            if !threads[i].isMain,
               let actual = result.actual, !actual.isEmpty,
               threads[i].branchName != actual {
                threads[i].branchName = actual
                persistedChanged = true
            }

            let resolvedExpected = threads[i].isMain ? expected : threads[i].branchName
            let mismatch: Bool
            if threads[i].isMain, let resolvedExpected, let actual = result.actual {
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
