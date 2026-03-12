import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Base Branch & Dirty State

    func resolveBaseBranch(for thread: MagentThread) -> String {
        if let base = thread.baseBranch, !base.isEmpty {
            return base
        }
        let settings = persistence.loadSettings()
        if let project = settings.projects.first(where: { $0.id == thread.projectId }),
           let defaultBranch = project.defaultBranch, !defaultBranch.isEmpty {
            return defaultBranch
        }
        return "main"
    }

    func refreshDirtyStates() async {
        let snapshot = threads.filter { !$0.isArchived }
        var changed = false
        for thread in snapshot {
            let dirty = await git.isDirty(worktreePath: thread.worktreePath)
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if threads[i].isDirty != dirty {
                threads[i].isDirty = dirty
                changed = true
            }
        }
        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    func refreshDeliveredStates() async {
        // Load metadata caches per-project to pass fork points
        let settings = persistence.loadSettings()
        var cacheByProjectId: [UUID: WorktreeMetadataCache] = [:]
        for project in settings.projects {
            cacheByProjectId[project.id] = persistence.loadWorktreeCache(
                worktreesBasePath: project.resolvedWorktreesBasePath()
            )
        }

        let snapshot = threads.filter { !$0.isArchived && !$0.isMain }
        var changed = false
        for thread in snapshot {
            let baseBranch = resolveBaseBranch(for: thread)
            let worktreeKey = (thread.worktreePath as NSString).lastPathComponent
            let forkPoint = cacheByProjectId[thread.projectId]?.worktrees[worktreeKey]?.forkPointCommit
            let delivered = await git.isFullyDelivered(
                worktreePath: thread.worktreePath,
                baseBranch: baseBranch,
                forkPointCommit: forkPoint
            )
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if threads[i].isFullyDelivered != delivered {
                threads[i].isFullyDelivered = delivered
                changed = true
            }
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
        let baseBranch = resolveBaseBranch(for: thread)
        let settings = persistence.loadSettings()
        let forkPoint: String? = settings.projects
            .first(where: { $0.id == thread.projectId })
            .flatMap { persistence.loadWorktreeCache(worktreesBasePath: $0.resolvedWorktreesBasePath()).worktrees[(thread.worktreePath as NSString).lastPathComponent]?.forkPointCommit }
        let delivered = await git.isFullyDelivered(
            worktreePath: thread.worktreePath,
            baseBranch: baseBranch,
            forkPointCommit: forkPoint
        )
        // Re-lookup after await — the thread may have been archived/removed
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
}
