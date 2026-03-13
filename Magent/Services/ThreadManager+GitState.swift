import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Base Branch

    /// Returns the resolved base branch for a thread.
    /// Priority: detected remote branch (cached per current branch) → stored baseBranch → project default → "main".
    func resolveBaseBranch(for thread: MagentThread) -> String {
        let currentBranch = thread.actualBranch ?? thread.branchName
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
            let cache = persistence.loadWorktreeCache(worktreesBasePath: project.resolvedWorktreesBasePath())
            let worktreeKey = (thread.worktreePath as NSString).lastPathComponent
            if let meta = cache.worktrees[worktreeKey],
               let detected = meta.detectedBaseBranch,
               let detectedFor = meta.detectedFor,
               detectedFor == currentBranch {
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
        var changed = false
        var persistedChanged = false
        for thread in snapshot {
            let dirty = await git.isDirty(worktreePath: thread.worktreePath)
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
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
            try? persistence.saveActiveThreads(threads)
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
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
        var changed = false
        var persistedThreadsChanged = false

        for thread in snapshot {
            guard FileManager.default.fileExists(atPath: thread.worktreePath) else { continue }
            guard var projectEntry = cacheByProjectId[thread.projectId] else { continue }
            let worktreeKey = (thread.worktreePath as NSString).lastPathComponent
            let currentBranch = thread.actualBranch ?? thread.branchName

            // Resolve base branch: use cache if valid, otherwise detect from git.
            let baseBranch: String
            if let meta = projectEntry.cache.worktrees[worktreeKey],
               let detected = meta.detectedBaseBranch,
               let detectedFor = meta.detectedFor,
               detectedFor == currentBranch {
                baseBranch = detected
            } else if let detected = await git.detectBaseBranch(
                worktreePath: thread.worktreePath,
                currentBranch: currentBranch
            ) {
                var meta = projectEntry.cache.worktrees[worktreeKey] ?? WorktreeMetadata()
                meta.detectedBaseBranch = detected
                meta.detectedFor = currentBranch
                projectEntry.cache.worktrees[worktreeKey] = meta
                projectEntry.dirty = true
                cacheByProjectId[thread.projectId] = projectEntry
                baseBranch = detected
            } else {
                // Fall back to stored config when no remote refs exist.
                baseBranch = resolveBaseBranchFromConfig(for: thread, settings: settings)
            }

            // Re-lookup after awaits — thread may have been archived.
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }

            // Set hasEverDoneWork the first time commits ahead of base are detected.
            if !threads[i].hasEverDoneWork {
                let logResult = await ShellExecutor.execute(
                    "git log \(baseBranch)..HEAD --oneline",
                    workingDirectory: thread.worktreePath
                )
                let hasCommitsAhead = logResult.exitCode == 0
                    && !logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if hasCommitsAhead || threads[i].isDirty {
                    threads[i].hasEverDoneWork = true
                    persistedThreadsChanged = true
                    changed = true
                } else {
                    // Migration for existing threads: if HEAD has moved past the stored fork
                    // point, work was done and delivered before this field existed.
                    let forkPoint = projectEntry.cache.worktrees[worktreeKey]?.forkPointCommit
                    if let forkPoint, !forkPoint.isEmpty,
                       let head = await git.currentCommit(worktreePath: thread.worktreePath),
                       head != forkPoint {
                        threads[i].hasEverDoneWork = true
                        persistedThreadsChanged = true
                        changed = true
                    }
                }
            }

            // Guard: skip delivery check for threads with no work done yet.
            guard let j = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            guard threads[j].hasEverDoneWork else {
                if threads[j].isFullyDelivered {
                    threads[j].isFullyDelivered = false
                    changed = true
                }
                continue
            }

            let delivered = await git.isFullyDelivered(
                worktreePath: thread.worktreePath,
                baseBranch: baseBranch
            )
            guard let k = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if threads[k].isFullyDelivered != delivered {
                threads[k].isFullyDelivered = delivered
                changed = true
            }
        }

        // Save mutated caches.
        for (projectId, entry) in cacheByProjectId where entry.dirty {
            persistence.saveWorktreeCache(entry.cache, worktreesBasePath: entry.basePath)
            _ = projectId
        }
        if persistedThreadsChanged {
            try? persistence.saveActiveThreads(threads)
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
                .map { ($0.worktreePath as NSString).lastPathComponent }
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
        var changed = false
        var persistedChanged = false
        for thread in snapshot {
            let worktreePath = thread.worktreePath
            guard FileManager.default.fileExists(atPath: worktreePath) else { continue }

            let actual = await git.getCurrentBranch(workingDirectory: worktreePath)

            let expected: String?
            if thread.isMain {
                if let project = settings.projects.first(where: { $0.id == thread.projectId }),
                   let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
                    expected = defaultBranch
                } else if let detected = await git.detectDefaultBranch(repoPath: worktreePath) {
                    expected = detected
                } else {
                    expected = nil
                }
            } else {
                expected = thread.branchName
            }

            // Re-lookup after await — the thread may have been removed
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if !threads[i].isMain,
               let actual,
               !actual.isEmpty,
               threads[i].branchName != actual {
                threads[i].branchName = actual
                persistedChanged = true
            }

            let resolvedExpected = threads[i].isMain ? expected : threads[i].branchName
            let mismatch: Bool
            if threads[i].isMain, let resolvedExpected, let actual {
                mismatch = actual != resolvedExpected
            } else {
                mismatch = false
            }

            if threads[i].actualBranch != actual
                || threads[i].expectedBranch != resolvedExpected
                || threads[i].hasBranchMismatch != mismatch {
                threads[i].actualBranch = actual
                threads[i].expectedBranch = resolvedExpected
                threads[i].hasBranchMismatch = mismatch
                changed = true
            }
        }
        if persistedChanged {
            try? persistence.saveActiveThreads(threads)
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
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
