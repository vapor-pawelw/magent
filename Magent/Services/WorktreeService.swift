import Foundation
import MagentCore

/// Standalone service owning worktree-level operations: disk sync, move, and bell pipes.
/// Extracted from `ThreadManager+WorktreeSync` and `ThreadManager+MoveWorktrees`.
///
/// The caller (ThreadManager) is responsible for delegate calls and
/// notification posts after mutations.
final class WorktreeService {

    // MARK: - Dependencies

    let store: ThreadStore
    let persistence: PersistenceService
    let git: GitService
    let tmux: TmuxService

    // MARK: - Constants

    private static let archivedPathRediscoverySuppressionWindow: TimeInterval = 15 * 60
    private static let archivedHistoryLimitPerProject = 100

    // MARK: - Callbacks

    /// Called after `syncThreadsWithWorktrees` changes the thread list.
    /// Caller (ThreadManager) posts notifications and calls delegate.
    var onThreadsChanged: (() -> Void)?

    // MARK: - Init

    init(store: ThreadStore, persistence: PersistenceService, tmux: TmuxService, git: GitService) {
        self.store = store
        self.persistence = persistence
        self.tmux = tmux
        self.git = git
    }

    // MARK: - Worktree Sync

    func syncThreadsWithWorktrees(for project: Project) async {
        let basePath = project.resolvedWorktreesBasePath()
        let fm = FileManager.default

        // Discover directories in the worktrees base path
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else { return }

        // Build a map of symlink target → latest symlink name.
        // Rename creates symlinks from the new name pointing to the original worktree directory,
        // so the latest symlink name represents the most recent thread name.
        var latestSymlinkName: [String: (name: String, date: Date)] = [:]
        for entry in contents {
            let entryPath = (basePath as NSString).appendingPathComponent(entry)
            guard let attrs = try? fm.attributesOfItem(atPath: entryPath),
                  attrs[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: entryPath) else { continue }
            let resolved = dest.hasPrefix("/") ? dest : (basePath as NSString).appendingPathComponent(dest)
            let created = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date ?? .distantPast
            if let existing = latestSymlinkName[resolved], existing.date > created { continue }
            latestSymlinkName[resolved] = (name: entry, date: created)
        }

        var changed = false
        let existingPaths = Set(store.threads.filter { $0.projectId == project.id }.map(\.worktreePath))

        // Load persisted threads once — used for archived-path exclusion and later merge/save.
        var allPersistedThreads = persistence.loadThreads()

        // Collect paths of recently archived threads so we don't immediately
        // re-discover them while archive cleanup is still in flight.
        // If a directory still exists long after archive, let sync re-discover it.
        let now = Date()
        let archivedPaths = Set(
            allPersistedThreads
                .filter { thread in
                    guard thread.projectId == project.id, thread.isArchived else { return false }
                    guard let archivedAt = thread.archivedAt else { return false }
                    return now.timeIntervalSince(archivedAt) <= Self.archivedPathRediscoverySuppressionWindow
                }
                .map(\.worktreePath)
        )

        for dirName in contents {
            let fullPath = (basePath as NSString).appendingPathComponent(dirName)

            // Skip symlinks — these are rename aliases, not real worktrees
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                continue
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check if this is a git worktree (has a .git file, not directory)
            let gitPath = (fullPath as NSString).appendingPathComponent(".git")
            var gitIsDir: ObjCBool = false
            let gitExists = fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir)
            guard gitExists && !gitIsDir.boolValue else { continue }

            // Skip if we already have a thread for this path, or it was archived
            guard !existingPaths.contains(fullPath),
                  !archivedPaths.contains(fullPath) else { continue }

            // If a symlink points here, the worktree was renamed — use the symlink name
            // as the sidebar thread label, but seed branchName from the actual checkout.
            let threadName = latestSymlinkName[fullPath]?.name ?? dirName
            let currentBranch = await git.getCurrentBranch(workingDirectory: fullPath)
            let branchName = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? currentBranch!
                : threadName

            let settings = persistence.loadSettings()
            let thread = MagentThread(
                projectId: project.id,
                name: threadName,
                worktreePath: fullPath,
                branchName: branchName,
                sectionId: settings.defaultSection?.id
            )
            store.threads.append(thread)
            changed = true
        }

        // Archive threads whose worktree directories no longer exist on disk
        // (skip main threads — those point at the repo itself)
        for i in store.threads.indices {
            guard store.threads[i].projectId == project.id,
                  !store.threads[i].isMain,
                  !store.threads[i].isArchived else { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: store.threads[i].worktreePath, isDirectory: &isDir) && isDir.boolValue
            if !exists {
                store.threads[i].isArchived = true
                if store.threads[i].archivedAt == nil {
                    store.threads[i].archivedAt = Date()
                }
                changed = true
            }
        }

        // Keep archived history bounded per project so persistence doesn't grow
        // unbounded. Preserve the most recently archived entries.
        let archivedForProject = allPersistedThreads
            .filter { $0.projectId == project.id && $0.isArchived && !$0.isMain }
            .sorted { lhs, rhs in
                let lhsDate = lhs.archivedAt ?? .distantPast
                let rhsDate = rhs.archivedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.createdAt > rhs.createdAt
            }
        if archivedForProject.count > Self.archivedHistoryLimitPerProject {
            let archivedIdsToRemove = Set(
                archivedForProject
                    .dropFirst(Self.archivedHistoryLimitPerProject)
                    .map(\.id)
            )
            allPersistedThreads.removeAll { archivedIdsToRemove.contains($0.id) }
            changed = true
        }

        if changed {
            // Remove archived from active list
            store.threads = store.threads.filter { !$0.isArchived }

            // Merge: update archived flags, add new threads
            for thread in store.threads where !allPersistedThreads.contains(where: { $0.id == thread.id }) {
                allPersistedThreads.append(thread)
            }
            // Update archived flags
            for i in allPersistedThreads.indices {
                if !store.threads.contains(where: { $0.id == allPersistedThreads[i].id })
                    && allPersistedThreads[i].projectId == project.id
                    && !allPersistedThreads[i].isMain {
                    allPersistedThreads[i].isArchived = true
                    if allPersistedThreads[i].archivedAt == nil {
                        allPersistedThreads[i].archivedAt = Date()
                    }
                }
            }
            try? persistence.saveThreads(allPersistedThreads)

            NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
            onThreadsChanged?()
        }
    }

    // MARK: - Bell Pipes

    /// Manages legacy tmux bell-pipe lifecycle for all live agent sessions.
    /// When the legacy path is enabled, ensures each session has a pipe.
    /// When disabled, proactively detaches any stale pipes from upgraded sessions.
    func ensureBellPipes() async {
        let pipedSessions = await tmux.sessionsWithActivePipe()
        for thread in store.threads where !thread.isArchived {
            for sessionName in thread.agentTmuxSessions {
                guard await tmux.hasSession(name: sessionName) else { continue }
                if TmuxService.legacyAgentBellPipeEnabled {
                    guard !pipedSessions.contains(sessionName) else { continue }
                    await tmux.setupBellPipe(for: sessionName)
                } else if pipedSessions.contains(sessionName) {
                    await tmux.clearBellPipe(for: sessionName)
                }
            }
        }
    }

    // MARK: - Move Worktrees Base Path

    func moveWorktreesBasePath(for project: Project, from oldBase: String, to newBase: String) async throws {
        let fm = FileManager.default

        // Collect active (non-archived, non-main) threads for this project
        let affectedIndices = store.threads.indices.filter { i in
            store.threads[i].projectId == project.id && !store.threads[i].isArchived && !store.threads[i].isMain
        }

        // Build list of worktree directory names to move
        let worktreeNames: [(index: Int, dirName: String)] = affectedIndices.compactMap { i in
            let dirName = URL(fileURLWithPath: store.threads[i].worktreePath).lastPathComponent
            // Only include if the worktree actually lives under oldBase
            let expectedPath = (oldBase as NSString).appendingPathComponent(dirName)
            guard store.threads[i].worktreePath == expectedPath else { return nil }
            return (i, dirName)
        }

        // Check for conflicts in destination
        var conflicts: [String] = []
        for (_, dirName) in worktreeNames {
            let destPath = (newBase as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: destPath, isDirectory: &isDir) {
                // Allow if it's a symlink (rename compatibility symlink)
                let url = URL(fileURLWithPath: destPath)
                if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   values.isSymbolicLink == true {
                    continue
                }
                conflicts.append(dirName)
            }
        }
        if !conflicts.isEmpty {
            throw ThreadManagerError.worktreePathConflict(conflicts)
        }

        // Create destination directory if needed
        try fm.createDirectory(atPath: newBase, withIntermediateDirectories: true)

        // Move each worktree using `git worktree move`
        for (index, dirName) in worktreeNames {
            let oldPath = (oldBase as NSString).appendingPathComponent(dirName)
            let newPath = (newBase as NSString).appendingPathComponent(dirName)

            guard fm.fileExists(atPath: oldPath) else { continue }

            do {
                try await git.moveWorktree(repoPath: project.repoPath, oldPath: oldPath, newPath: newPath)
            } catch {
                // If git worktree move fails (e.g. already moved manually), try a filesystem move
                do {
                    try fm.moveItem(atPath: oldPath, toPath: newPath)
                } catch {
                    // Skip this worktree — it may have been moved manually already
                    continue
                }
            }

            store.threads[index].worktreePath = newPath

            // Update MAGENT_WORKTREE_PATH on live tmux sessions
            for sessionName in store.threads[index].tmuxSessionNames {
                try? await tmux.setEnvironment(sessionName: sessionName, key: "MAGENT_WORKTREE_PATH", value: newPath)
            }
        }

        // Move rename symlinks: entries in old base that are symlinks pointing into old base
        if let entries = try? fm.contentsOfDirectory(atPath: oldBase) {
            for entry in entries {
                let fullPath = (oldBase as NSString).appendingPathComponent(entry)
                let url = URL(fileURLWithPath: fullPath)
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink == true else { continue }

                // Read the symlink target
                guard let target = try? fm.destinationOfSymbolicLink(atPath: fullPath) else { continue }

                // Check if target points to something now under newBase
                let movedNames = Set(worktreeNames.map(\.dirName))
                let targetBaseName = URL(fileURLWithPath: target).lastPathComponent
                guard movedNames.contains(targetBaseName) else { continue }

                // Create updated symlink in newBase pointing to new location
                let newSymlinkPath = (newBase as NSString).appendingPathComponent(entry)
                let newTarget = (newBase as NSString).appendingPathComponent(targetBaseName)
                try? fm.removeItem(atPath: newSymlinkPath)
                try? fm.createSymbolicLink(atPath: newSymlinkPath, withDestinationPath: newTarget)
                try? fm.removeItem(atPath: fullPath)
            }
        }

        // Move .magent-cache.json: merge old cache into destination
        let oldCache = persistence.loadWorktreeCache(worktreesBasePath: oldBase)
        if !oldCache.worktrees.isEmpty {
            var newCache = persistence.loadWorktreeCache(worktreesBasePath: newBase)
            for (key, value) in oldCache.worktrees {
                // Old cache entries take precedence (they're the ones being moved)
                newCache.worktrees[key] = value
            }
            persistence.saveWorktreeCache(newCache, worktreesBasePath: newBase)
            // Remove old cache file
            let oldCacheURL = URL(fileURLWithPath: oldBase).appendingPathComponent(".magent-cache.json")
            try? fm.removeItem(at: oldCacheURL)
        }

        // Save updated thread records
        try persistence.saveActiveThreads(store.threads)

        // Try to remove old base directory if empty
        if let remaining = try? fm.contentsOfDirectory(atPath: oldBase), remaining.isEmpty {
            try? fm.removeItem(atPath: oldBase)
        }
    }
}
