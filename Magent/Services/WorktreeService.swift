import AppKit
import CryptoKit
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

    /// Resolves the effective base branch for a thread.
    /// Wired to `gitStateService.resolveBaseBranch(for:)` by ThreadManager.
    var resolveBaseBranchForThread: ((MagentThread) -> String)?

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

// MARK: - Local File Sync

extension WorktreeService {

    // MARK: - Supporting Types

    nonisolated enum LocalSyncConflictMode {
        case overwrite
        case skip
        case prompt
    }

    nonisolated enum LocalSyncConflictChoice {
        case resolve
        case overwrite
        case overwriteAll
        case skip
        case skipAll
        case agenticMerge
        case cancel
    }

    nonisolated enum LocalSyncItemKind {
        case file
        case directory
    }

    nonisolated enum LocalSyncConflictKind {
        case fileDifferent
        case fileBlocksDirectory
        case directoryBlocksFile
    }

    nonisolated struct LocalSyncConflict: Sendable {
        let relativePath: String
        let sourcePath: String
        let destinationPath: String
        let kind: LocalSyncConflictKind
    }

    nonisolated struct LocalSyncBaselineManifest: Codable, Sendable {
        let fileHashes: [String: String]
    }

    nonisolated enum LocalSyncDirectoryMaterialization {
        case onDemand
        case always
    }

    nonisolated enum LocalSyncConflictDirection {
        case intoWorktree
        case intoRepo
    }

    // MARK: - Base Branch Sync Target Resolution

    /// Resolves the sync target for a thread based on its base branch.
    /// If an active sibling thread in the same project is checked out on the base branch,
    /// returns that worktree path and its display name. Otherwise falls back to project.repoPath.
    func resolveBaseBranchSyncTarget(for thread: MagentThread, project: Project) -> (path: String, label: String) {
        let baseBranch = resolveBaseBranchForThread?(thread) ?? thread.baseBranch ?? ""
        if let sibling = store.threads.first(where: {
            !$0.isArchived
            && $0.id != thread.id
            && $0.projectId == thread.projectId
            && $0.currentBranch == baseBranch
        }) {
            let label = (sibling.worktreePath as NSString).lastPathComponent
            return (sibling.worktreePath, label)
        }
        return (project.repoPath, "Project")
    }

    /// Overload that takes an explicit base branch string and excludes a thread by ID.
    /// Useful during thread creation when the thread is not yet fully formed.
    func resolveBaseBranchSyncTarget(baseBranch: String?, excludingThreadId: UUID, projectId: UUID, project: Project) -> (path: String, label: String) {
        guard let baseBranch, !baseBranch.isEmpty else {
            return (project.repoPath, "Project")
        }
        if let sibling = store.threads.first(where: {
            !$0.isArchived
            && $0.id != excludingThreadId
            && $0.projectId == projectId
            && $0.currentBranch == baseBranch
        }) {
            let label = (sibling.worktreePath as NSString).lastPathComponent
            return (sibling.worktreePath, label)
        }
        return (project.repoPath, "Project")
    }

    // MARK: - Local Sync In (Repo -> Worktree)

    @concurrent func syncConfiguredLocalPathsIntoWorktree(
        project: Project,
        worktreePath: String,
        syncEntries: [LocalFileSyncEntry],
        promptForConflicts: Bool = false,
        sourceRootOverride: String? = nil
    ) async throws -> [String] {
        let normalizedEntries = Project.normalizeLocalFileSyncEntries(syncEntries)
        guard !normalizedEntries.isEmpty else { return [] }

        let sourceRoot = sourceRootOverride ?? project.repoPath
        var missingPaths: [String] = []
        let conflictMode: LocalSyncConflictMode = promptForConflicts ? .prompt : .overwrite
        var overwriteAll = !promptForConflicts
        var ignoreAll = false
        for entry in normalizedEntries {
            let relativePath = entry.path
            do {
                switch entry.mode {
                case .copy:
                    let sourcePath = (sourceRoot as NSString).appendingPathComponent(relativePath)
                    guard localSyncSourceItemKind(atPath: sourcePath) != nil else {
                        missingPaths.append(relativePath)
                        continue
                    }

                    let destinationPath = (worktreePath as NSString).appendingPathComponent(relativePath)
                    try await mergeLocalSyncItem(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        relativePath: relativePath,
                        destinationRootPath: worktreePath,
                        repoPath: project.repoPath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
                        ignoreAll: &ignoreAll,
                        conflictDirection: .intoWorktree,
                        directoryMaterialization: .always
                    )

                case .symlink:
                    let sharedSourcePath = (project.repoPath as NSString).appendingPathComponent(relativePath)
                    guard localSyncSourceItemKind(atPath: sharedSourcePath) != nil else {
                        missingPaths.append(relativePath)
                        continue
                    }

                    try await createLocalSyncSymlink(
                        sourcePath: sharedSourcePath,
                        destinationPath: (worktreePath as NSString).appendingPathComponent(relativePath),
                        relativePath: relativePath,
                        destinationRootPath: worktreePath,
                        repoPath: project.repoPath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
                        ignoreAll: &ignoreAll,
                        conflictDirection: .intoWorktree
                    )
                }
            } catch ThreadManagerError.agenticMergeSignal {
                let sourceLabel = sourceRootOverride.map { ($0 as NSString).lastPathComponent } ?? "Project"
                let destLabel = (worktreePath as NSString).lastPathComponent
                throw ThreadManagerError.agenticMergeReady(LocalSyncAgenticMergeContext(
                    operation: .syncSourceToDestination,
                    sourceRoot: sourceRoot,
                    destinationRoot: worktreePath,
                    syncPaths: normalizedEntries.map(\.path),
                    sourceLabel: sourceLabel,
                    destinationLabel: destLabel
                ))
            } catch let error as ThreadManagerError {
                throw error
            } catch {
                let verb = entry.mode == .copy ? "copy" : "link"
                throw ThreadManagerError.localFileSyncFailed(
                    "Failed to \(verb) \"\(relativePath)\" into the new worktree: \(error.localizedDescription)"
                )
            }
        }

        let baselineHashes: [String: String]
        do {
            baselineHashes = try buildLocalSyncFileHashes(
                rootPath: worktreePath,
                syncPaths: normalizedEntries.filter { $0.mode == .copy }.map(\.path)
            )
        } catch {
            throw ThreadManagerError.localFileSyncFailed(
                "Failed to record local sync baseline: \(error.localizedDescription)"
            )
        }
        try await saveLocalSyncBaselineManifest(worktreePath: worktreePath, fileHashes: baselineHashes)
        return missingPaths
    }

    // MARK: - Local Sync Back (Worktree -> Repo)

    @concurrent func syncConfiguredLocalPathsFromWorktree(
        project: Project,
        worktreePath: String,
        syncEntries: [LocalFileSyncEntry],
        promptForConflicts: Bool,
        destinationRootOverride: String? = nil
    ) async throws {
        let copySyncPaths = Project.normalizeLocalFileSyncEntries(syncEntries)
            .filter { $0.mode == .copy }
            .map(\.path)
        guard !copySyncPaths.isEmpty else { return }

        let destinationRoot = destinationRootOverride ?? project.repoPath
        let baselineHashes = await loadLocalSyncBaselineFileHashes(worktreePath: worktreePath)
        let conflictMode: LocalSyncConflictMode = promptForConflicts ? .prompt : .skip
        var overwriteAll = false
        var ignoreAll = false
        for relativePath in copySyncPaths {
            let sourcePath = (worktreePath as NSString).appendingPathComponent(relativePath)
            guard localSyncSourceItemKind(atPath: sourcePath) != nil else { continue }

            let destinationPath = (destinationRoot as NSString).appendingPathComponent(relativePath)
            do {
                try await mergeLocalSyncItem(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    relativePath: relativePath,
                    destinationRootPath: destinationRoot,
                    repoPath: project.repoPath,
                    conflictMode: conflictMode,
                    overwriteAll: &overwriteAll,
                    ignoreAll: &ignoreAll,
                    conflictDirection: .intoRepo,
                    baselineFileHashes: baselineHashes,
                    directoryMaterialization: .onDemand
                )
            } catch ThreadManagerError.agenticMergeSignal {
                let sourceLabel = (worktreePath as NSString).lastPathComponent
                let destLabel = destinationRootOverride.map { ($0 as NSString).lastPathComponent } ?? "Project"
                throw ThreadManagerError.agenticMergeReady(LocalSyncAgenticMergeContext(
                    operation: .syncSourceToDestination,
                    sourceRoot: worktreePath,
                    destinationRoot: destinationRoot,
                    syncPaths: copySyncPaths,
                    sourceLabel: sourceLabel,
                    destinationLabel: destLabel
                ))
            } catch let error as ThreadManagerError {
                throw error
            } catch {
                throw ThreadManagerError.localFileSyncFailed(
                    "Failed to sync \"\(relativePath)\" back to the main repo: \(error.localizedDescription)"
                )
            }
        }
    }

    nonisolated func effectiveLocalSyncEntries(for thread: MagentThread, project: Project) -> [LocalFileSyncEntry] {
        let currentEntries = project.normalizedLocalFileSyncEntries
        if let snapshot = thread.localFileSyncEntriesSnapshot {
            let snapshotEntries = Project.normalizeLocalFileSyncEntries(snapshot)
            let currentPaths = Set(currentEntries.map(\.path))
            // Keep historical snapshot semantics for additions, but never sync paths
            // that are no longer configured in the project.
            return snapshotEntries.filter { currentPaths.contains($0.path) }
        }
        return currentEntries
    }

    @concurrent private func createLocalSyncSymlink(
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        destinationRootPath: String,
        repoPath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        ignoreAll: inout Bool,
        conflictDirection: LocalSyncConflictDirection
    ) async throws {
        guard let sourceKind = localSyncSourceItemKind(atPath: sourcePath) else { return }

        let resolvedSourcePath = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
        let parentRelativePath = (relativePath as NSString).deletingLastPathComponent
        if parentRelativePath != "." && !parentRelativePath.isEmpty {
            let parentReady = try await ensureLocalSyncDirectoryTree(
                destinationRootPath: destinationRootPath,
                relativeDirectoryPath: parentRelativePath,
                conflictMode: conflictMode,
                overwriteAll: &overwriteAll,
                ignoreAll: &ignoreAll,
                conflictDirection: conflictDirection,
                repoPath: repoPath
            )
            guard parentReady else { return }
        }

        let fm = FileManager.default
        if let existingTarget = localSyncResolvedSymlinkTarget(atPath: destinationPath),
           existingTarget == resolvedSourcePath {
            return
        }

        let existingKind = localSyncDestinationItemKind(atPath: destinationPath)
        if existingKind != nil || localSyncIsSymlink(atPath: destinationPath) {
            let conflictKind: LocalSyncConflictKind = {
                switch (sourceKind, existingKind) {
                case (.directory, .some(.file)):
                    return .fileBlocksDirectory
                case (.file, .some(.directory)):
                    return .directoryBlocksFile
                default:
                    return .fileDifferent
                }
            }()
            let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                LocalSyncConflict(
                    relativePath: relativePath,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    kind: conflictKind
                ),
                conflictMode: conflictMode,
                overwriteAll: &overwriteAll,
                ignoreAll: &ignoreAll,
                conflictDirection: conflictDirection,
                repoPath: repoPath
            )
            guard shouldOverwrite else { return }
            try fm.removeItem(atPath: destinationPath)
        }

        try fm.createSymbolicLink(atPath: destinationPath, withDestinationPath: resolvedSourcePath)
    }

    // MARK: - Merge Copy

    @concurrent private func mergeLocalSyncItem(
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        destinationRootPath: String,
        repoPath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        ignoreAll: inout Bool,
        conflictDirection: LocalSyncConflictDirection,
        baselineFileHashes: [String: String]? = nil,
        directoryMaterialization: LocalSyncDirectoryMaterialization
    ) async throws {
        do {
            guard let sourceKind = localSyncSourceItemKind(atPath: sourcePath) else { return }
            let fm = FileManager.default

            switch sourceKind {
            case .directory:
                if directoryMaterialization == .always {
                    let ready = try await ensureLocalSyncDirectoryExists(
                        atPath: destinationPath,
                        relativePath: relativePath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
                        ignoreAll: &ignoreAll,
                        conflictDirection: conflictDirection,
                        repoPath: repoPath
                    )
                    guard ready else { return }
                }

                // Recurse first and only materialize destination directories if a child
                // file actually needs to be copied. This avoids dirtying repo root by
                // creating empty directories when no file-level sync is needed.
                let children = (try fm.contentsOfDirectory(atPath: sourcePath)).sorted()
                for child in children {
                    let childSourcePath = (sourcePath as NSString).appendingPathComponent(child)
                    let childDestinationPath = (destinationPath as NSString).appendingPathComponent(child)
                    let childRelativePath = (relativePath as NSString).appendingPathComponent(child)

                    try await mergeLocalSyncItem(
                        sourcePath: childSourcePath,
                        destinationPath: childDestinationPath,
                        relativePath: childRelativePath,
                        destinationRootPath: destinationRootPath,
                        repoPath: repoPath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
                        ignoreAll: &ignoreAll,
                        conflictDirection: conflictDirection,
                        baselineFileHashes: baselineFileHashes,
                        directoryMaterialization: directoryMaterialization
                    )
                }

            case .file:
                if try shouldSkipArchiveCopyForUnchangedFile(
                    sourcePath: sourcePath,
                    relativePath: relativePath,
                    baselineFileHashes: baselineFileHashes
                ) {
                    return
                }

                let parentRelativePath = (relativePath as NSString).deletingLastPathComponent
                if parentRelativePath != "." && !parentRelativePath.isEmpty {
                    let parentReady = try await ensureLocalSyncDirectoryTree(
                        destinationRootPath: destinationRootPath,
                        relativeDirectoryPath: parentRelativePath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
                        ignoreAll: &ignoreAll,
                        conflictDirection: conflictDirection,
                        repoPath: repoPath
                    )
                    guard parentReady else { return }
                }

                if let destinationKind = localSyncDestinationItemKind(atPath: destinationPath) {
                    switch destinationKind {
                    case .directory:
                        let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                            LocalSyncConflict(
                                relativePath: relativePath,
                                sourcePath: sourcePath,
                                destinationPath: destinationPath,
                                kind: .directoryBlocksFile
                            ),
                            conflictMode: conflictMode,
                            overwriteAll: &overwriteAll,
                            ignoreAll: &ignoreAll,
                            conflictDirection: conflictDirection,
                            repoPath: repoPath
                        )
                        guard shouldOverwrite else { return }
                        try fm.removeItem(atPath: destinationPath)

                    case .file:
                        let filesMatch = try localSyncFilesMatch(
                            sourcePath: sourcePath,
                            destinationPath: destinationPath
                        )
                        guard !filesMatch else { return }

                        let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                            LocalSyncConflict(
                                relativePath: relativePath,
                                sourcePath: sourcePath,
                                destinationPath: destinationPath,
                                kind: .fileDifferent
                            ),
                            conflictMode: conflictMode,
                            overwriteAll: &overwriteAll,
                            ignoreAll: &ignoreAll,
                            conflictDirection: conflictDirection,
                            repoPath: repoPath
                        )
                        guard shouldOverwrite else { return }
                        try fm.removeItem(atPath: destinationPath)
                    }
                }

                try fm.copyItem(atPath: sourcePath, toPath: destinationPath)
            }
        } catch let error as ThreadManagerError {
            throw error
        } catch {
            throw ThreadManagerError.localFileSyncFailed(
                "Local sync failed at \"\(relativePath)\": \(error.localizedDescription)"
            )
        }
    }

    @concurrent private func ensureLocalSyncDirectoryTree(
        destinationRootPath: String,
        relativeDirectoryPath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        ignoreAll: inout Bool,
        conflictDirection: LocalSyncConflictDirection,
        repoPath: String
    ) async throws -> Bool {
        let components = relativeDirectoryPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return true }

        var currentRelativePath = ""
        for component in components {
            currentRelativePath = currentRelativePath.isEmpty
                ? component
                : (currentRelativePath as NSString).appendingPathComponent(component)

            let currentDestinationPath = (destinationRootPath as NSString).appendingPathComponent(currentRelativePath)
            let ready = try await ensureLocalSyncDirectoryExists(
                atPath: currentDestinationPath,
                relativePath: currentRelativePath,
                conflictMode: conflictMode,
                overwriteAll: &overwriteAll,
                ignoreAll: &ignoreAll,
                conflictDirection: conflictDirection,
                repoPath: repoPath
            )
            guard ready else { return false }
        }

        return true
    }

    @concurrent private func ensureLocalSyncDirectoryExists(
        atPath destinationPath: String,
        relativePath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        ignoreAll: inout Bool,
        conflictDirection: LocalSyncConflictDirection,
        repoPath: String
    ) async throws -> Bool {
        let fm = FileManager.default
        if let existingKind = localSyncDestinationItemKind(atPath: destinationPath) {
            switch existingKind {
            case .directory:
                return true
            case .file:
                let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                    LocalSyncConflict(
                        relativePath: relativePath,
                        sourcePath: destinationPath,
                        destinationPath: destinationPath,
                        kind: .fileBlocksDirectory
                    ),
                    conflictMode: conflictMode,
                    overwriteAll: &overwriteAll,
                    ignoreAll: &ignoreAll,
                    conflictDirection: conflictDirection,
                    repoPath: repoPath
                )
                guard shouldOverwrite else { return false }
                try fm.removeItem(atPath: destinationPath)
            }
        }

        try fm.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
        return true
    }

    nonisolated private func localSyncSourceItemKind(atPath path: String) -> LocalSyncItemKind? {
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .directory : .file
    }

    nonisolated private func localSyncDestinationItemKind(atPath path: String) -> LocalSyncItemKind? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return .file
        }
        return type == .typeDirectory ? .directory : .file
    }

    nonisolated private func localSyncIsSymlink(atPath path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    nonisolated private func localSyncResolvedSymlinkTarget(atPath path: String) -> String? {
        let fm = FileManager.default
        guard let rawTarget = try? fm.destinationOfSymbolicLink(atPath: path) else { return nil }

        let absoluteTarget: String
        if rawTarget.hasPrefix("/") {
            absoluteTarget = rawTarget
        } else {
            let parentPath = (path as NSString).deletingLastPathComponent
            absoluteTarget = URL(fileURLWithPath: rawTarget, relativeTo: URL(fileURLWithPath: parentPath))
                .standardizedFileURL
                .path
        }

        return URL(fileURLWithPath: absoluteTarget).resolvingSymlinksInPath().path
    }

    nonisolated private func localSyncFilesMatch(sourcePath: String, destinationPath: String) throws -> Bool {
        let fm = FileManager.default
        guard let sourceAttrs = try? fm.attributesOfItem(atPath: sourcePath),
              let destinationAttrs = try? fm.attributesOfItem(atPath: destinationPath) else {
            return false
        }
        let sourceSize = (sourceAttrs[.size] as? NSNumber)?.int64Value
        let destinationSize = (destinationAttrs[.size] as? NSNumber)?.int64Value
        if sourceSize != destinationSize {
            return false
        }
        let sourceHash = try localSyncFileHash(atPath: sourcePath)
        let destinationHash = try localSyncFileHash(atPath: destinationPath)
        return sourceHash == destinationHash
    }

    // MARK: - Baseline Manifest

    nonisolated private func shouldSkipArchiveCopyForUnchangedFile(
        sourcePath: String,
        relativePath: String,
        baselineFileHashes: [String: String]?
    ) throws -> Bool {
        guard let baselineFileHashes,
              let baselineHash = baselineFileHashes[relativePath] else {
            return false
        }
        let currentHash = try localSyncFileHash(atPath: sourcePath)
        return currentHash == baselineHash
    }

    nonisolated private func localSyncFileHash(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func buildLocalSyncFileHashes(rootPath: String, syncPaths: [String]) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for relativePath in syncPaths {
            let absolutePath = (rootPath as NSString).appendingPathComponent(relativePath)
            try collectLocalSyncFileHashes(
                absolutePath: absolutePath,
                relativePath: relativePath,
                into: &hashes
            )
        }
        return hashes
    }

    nonisolated private func collectLocalSyncFileHashes(
        absolutePath: String,
        relativePath: String,
        into hashes: inout [String: String]
    ) throws {
        guard let kind = localSyncSourceItemKind(atPath: absolutePath) else { return }
        let fm = FileManager.default
        switch kind {
        case .directory:
            let children = try fm.contentsOfDirectory(atPath: absolutePath)
            for child in children {
                let childAbsolutePath = (absolutePath as NSString).appendingPathComponent(child)
                let childRelativePath = (relativePath as NSString).appendingPathComponent(child)
                try collectLocalSyncFileHashes(
                    absolutePath: childAbsolutePath,
                    relativePath: childRelativePath,
                    into: &hashes
                )
            }
        case .file:
            hashes[relativePath] = try localSyncFileHash(atPath: absolutePath)
        }
    }

    @concurrent private func saveLocalSyncBaselineManifest(worktreePath: String, fileHashes: [String: String]) async throws {
        guard let manifestPath = await localSyncBaselineManifestPath(worktreePath: worktreePath) else {
            throw ThreadManagerError.localFileSyncFailed("Could not resolve local sync manifest path.")
        }
        let fm = FileManager.default
        let parentPath = (manifestPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
        let manifest = LocalSyncBaselineManifest(fileHashes: fileHashes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    }

    @concurrent private func loadLocalSyncBaselineFileHashes(worktreePath: String) async -> [String: String]? {
        guard let manifestPath = await localSyncBaselineManifestPath(worktreePath: worktreePath) else {
            return nil
        }
        let url = URL(fileURLWithPath: manifestPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let manifest = try? JSONDecoder().decode(LocalSyncBaselineManifest.self, from: data) else {
            return nil
        }
        return manifest.fileHashes
    }

    @concurrent private func localSyncBaselineManifestPath(worktreePath: String) async -> String? {
        let preferred = await ShellExecutor.execute(
            "git rev-parse --path-format=absolute --git-path magent-local-sync-baseline.json",
            workingDirectory: worktreePath
        )
        var path = preferred.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferred.exitCode != 0 || path.isEmpty {
            let fallback = await ShellExecutor.execute(
                "git rev-parse --git-path magent-local-sync-baseline.json",
                workingDirectory: worktreePath
            )
            path = fallback.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fallback.exitCode == 0, !path.isEmpty else { return nil }
        }
        if path.hasPrefix("/") {
            return path
        }
        return (worktreePath as NSString).appendingPathComponent(path)
    }

    // MARK: - Merge Tool

    /// Resolves a file conflict by creating a temporary git repo with a staged merge
    /// conflict and invoking `git mergetool`. This correctly uses the user's configured
    /// merge tool (from `git config merge.tool`) regardless of tool type — GUI tools
    /// like opendiff/mvimdiff, terminal tools like vimdiff, or custom commands.
    @concurrent private func openMergeToolForConflict(
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        repoPath: String
    ) async -> Bool {
        guard localSyncIsTextFile(atPath: sourcePath),
              localSyncIsTextFile(atPath: destinationPath) else {
            return false
        }

        let fm = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("magent-merge-\(UUID().uuidString)")
        do {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(atPath: tempDir) }

        let fileName = "conflict-file"
        let filePath = (tempDir as NSString).appendingPathComponent(fileName)

        // Read the user's configured merge tool from the project repo
        let toolResult = await ShellExecutor.execute(
            "git config --get merge.tool",
            workingDirectory: repoPath
        )
        let toolName = toolResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return false }

        // Validate tool name to prevent injection into git config key paths
        let validToolName = toolName.range(of: #"^[a-zA-Z0-9_\-]+$"#, options: .regularExpression) != nil
        guard validToolName else { return false }

        // Also propagate any custom mergetool command
        let customCmdResult = await ShellExecutor.execute(
            "git config --get mergetool.\(toolName).cmd",
            workingDirectory: repoPath
        )
        let customCmd = customCmdResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build a temporary git repo with a real merge conflict so git mergetool
        // handles all tool-specific invocation logic.
        // Base = empty file, branch "ours" = destination content, branch "theirs" = source content.
        let setupCommands = [
            "git init -b magent-base",
            "git config user.email 'merge@magent.local'",
            "git config user.name 'Magent'",
            "git config merge.tool \(toolName)",
        ]
        let setupResult = await ShellExecutor.execute(
            setupCommands.joined(separator: " && "),
            workingDirectory: tempDir
        )
        guard setupResult.exitCode == 0 else { return false }

        // Set custom mergetool command if configured
        if !customCmd.isEmpty {
            let cmdResult = await ShellExecutor.execute(
                "git config mergetool.\(toolName).cmd \(shellEscaped(customCmd))",
                workingDirectory: tempDir
            )
            guard cmdResult.exitCode == 0 else { return false }
        }

        // Create base commit with a placeholder file (single newline so both sides diff against it)
        do {
            try "\n".write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch { return false }

        let baseCommit = await ShellExecutor.execute(
            "git add \(shellEscaped(fileName)) && git commit -m 'base'",
            workingDirectory: tempDir
        )
        guard baseCommit.exitCode == 0 else { return false }

        // Create "theirs" branch with source content
        do {
            let sourceData = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            try sourceData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch { return false }

        let theirsCommit = await ShellExecutor.execute(
            "git checkout -b theirs && git add \(shellEscaped(fileName)) && git commit -m 'theirs'",
            workingDirectory: tempDir
        )
        guard theirsCommit.exitCode == 0 else { return false }

        // Go back to base, create "ours" branch with destination content
        do {
            let destData = try Data(contentsOf: URL(fileURLWithPath: destinationPath))
            try destData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch { return false }

        let oursCommit = await ShellExecutor.execute(
            "git checkout magent-base && git checkout -b ours && git add \(shellEscaped(fileName)) && git commit -m 'ours'",
            workingDirectory: tempDir
        )
        guard oursCommit.exitCode == 0 else { return false }

        // Merge to create the conflict — we expect exit code 1 (conflict)
        _ = await ShellExecutor.execute(
            "git merge theirs --no-commit || true",
            workingDirectory: tempDir
        )

        // Verify the file is actually conflicted before launching the tool
        let statusResult = await ShellExecutor.execute(
            "git status --porcelain \(shellEscaped(fileName))",
            workingDirectory: tempDir
        )
        let porcelain = statusResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard porcelain.hasPrefix("UU") || porcelain.hasPrefix("AA") else { return false }

        // Run git mergetool — this launches the user's configured tool and waits for it
        let mergetoolResult = await ShellExecutor.execute(
            "git mergetool --no-prompt \(shellEscaped(fileName))",
            workingDirectory: tempDir
        )
        guard mergetoolResult.exitCode == 0 else { return false }

        // Read the resolved file and apply to destination
        guard fm.fileExists(atPath: filePath) else { return false }
        do {
            let resolvedData = try Data(contentsOf: URL(fileURLWithPath: filePath))
            try resolvedData.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    nonisolated private func shellEscaped(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Conflict Resolution

    @concurrent private func shouldOverwriteLocalSyncConflict(
        _ conflict: LocalSyncConflict,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        ignoreAll: inout Bool,
        conflictDirection: LocalSyncConflictDirection,
        repoPath: String
    ) async throws -> Bool {
        switch conflictMode {
        case .overwrite:
            return true
        case .skip:
            return false
        case .prompt:
            if overwriteAll { return true }
            if ignoreAll { return false }
            while true {
                let choice = await presentLocalSyncConflictAlert(
                    conflict,
                    direction: conflictDirection,
                    repoPath: repoPath
                )
                switch choice {
                case .resolve:
                    let resolved = await openMergeToolForConflict(
                        sourcePath: conflict.sourcePath,
                        destinationPath: conflict.destinationPath,
                        relativePath: conflict.relativePath,
                        repoPath: repoPath
                    )
                    if resolved { return false }
                    // Merge tool failed or user quit — re-present the alert
                    continue
                case .overwrite:
                    return true
                case .overwriteAll:
                    overwriteAll = true
                    return true
                case .skip:
                    return false
                case .skipAll:
                    ignoreAll = true
                    return false
                case .agenticMerge:
                    throw ThreadManagerError.agenticMergeSignal
                case .cancel:
                    throw ThreadManagerError.archiveCancelled
                }
            }
        }
    }

    @MainActor
    private func presentLocalSyncConflictAlert(
        _ conflict: LocalSyncConflict,
        direction: LocalSyncConflictDirection,
        repoPath: String
    ) async -> LocalSyncConflictChoice {
        let isTextConflict = conflict.kind == .fileDifferent
            && localSyncIsTextFile(atPath: conflict.sourcePath)
            && localSyncIsTextFile(atPath: conflict.destinationPath)
        // Binary/structural conflicts get override/ignore; text conflicts use merge tool only
        let isBinaryOrStructural = !isTextConflict
        let canResolve: Bool
        if isTextConflict {
            canResolve = await hasMergeTool(repoPath: repoPath)
        } else {
            canResolve = false
        }

        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning

            let destinationPath = conflict.destinationPath
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")

            switch direction {
            case .intoRepo:
                alert.messageText = String(localized: .ThreadStrings.threadArchiveConflictTitle(conflict.relativePath))
                switch conflict.kind {
                case .fileDifferent:
                    alert.informativeText = String(localized: .ThreadStrings.threadArchiveConflictFileDifferent(destinationPath))
                case .fileBlocksDirectory:
                    alert.informativeText = String(localized: .ThreadStrings.threadArchiveConflictFileBlocksDirectory(destinationPath))
                case .directoryBlocksFile:
                    alert.informativeText = String(localized: .ThreadStrings.threadArchiveConflictDirectoryBlocksFile(destinationPath))
                }
            case .intoWorktree:
                alert.messageText = "Resync Local Paths Conflict"
                switch conflict.kind {
                case .fileDifferent:
                    alert.informativeText =
                        "The worktree already has a different file at \"\(destinationPath)\". Override it with the copy from the main repo?"
                case .fileBlocksDirectory:
                    alert.informativeText =
                        "The worktree has a file at \"\(destinationPath)\", but local sync needs a directory there. Override it with the directory from the main repo?"
                case .directoryBlocksFile:
                    alert.informativeText =
                        "The worktree has a directory at \"\(destinationPath)\", but local sync needs a file there. Override it with the file from the main repo?"
                }
            }

            // Build buttons based on conflict type.
            // Text file conflicts: [Resolve in Merge Tool], Resolve with Agent, Cancel
            // Binary/structural conflicts: Override/Ignore (Option for All), Resolve with Agent, Cancel

            var overrideButton: NSButton?
            var ignoreButton: NSButton?

            if canResolve {
                alert.addButton(withTitle: "Resolve in Merge Tool")
            }

            if isBinaryOrStructural {
                let optionHint = "\n\nHold Option for \"Override All\" or \"Ignore All\"."
                alert.informativeText += optionHint

                overrideButton = alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveConflictOverride))
                ignoreButton = alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveConflictIgnore))
            }

            alert.addButton(withTitle: "Resolve with Agent")

            let cancelTitle: String = switch direction {
            case .intoRepo:
                String(localized: .ThreadStrings.threadArchiveConflictCancelArchive)
            case .intoWorktree:
                String(localized: .CommonStrings.commonCancel)
            }
            alert.addButton(withTitle: cancelTitle)

            var optionHeld = NSEvent.modifierFlags.contains(.option)
            if isBinaryOrStructural {
                func updateButtonTitles() {
                    overrideButton?.title = optionHeld
                        ? String(localized: .ThreadStrings.threadArchiveConflictOverrideAll)
                        : String(localized: .ThreadStrings.threadArchiveConflictOverride)
                    ignoreButton?.title = optionHeld
                        ? "Ignore All"
                        : String(localized: .ThreadStrings.threadArchiveConflictIgnore)
                }
                updateButtonTitles()

                let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    optionHeld = event.modifierFlags.contains(.option)
                    updateButtonTitles()
                    return event
                }

                let response = alert.runModal()
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }

                let useAllChoice = optionHeld || (NSApp.currentEvent?.modifierFlags.contains(.option) == true)

                // Button index mapping for binary/structural:
                // [0: Resolve?], Override, Ignore, Resolve with Agent, Cancel
                let buttonIndex: Int
                switch response {
                case .alertFirstButtonReturn: buttonIndex = 0
                case .alertSecondButtonReturn: buttonIndex = 1
                case .alertThirdButtonReturn: buttonIndex = 2
                case NSApplication.ModalResponse(rawValue: 1003): buttonIndex = 3
                case NSApplication.ModalResponse(rawValue: 1004): buttonIndex = 4
                default: return .cancel
                }

                var idx = buttonIndex
                if canResolve {
                    if idx == 0 { return .resolve }
                    idx -= 1
                }
                // idx 0 = Override, 1 = Ignore, 2 = Resolve with Agent, 3 = Cancel
                switch idx {
                case 0: return useAllChoice ? .overwriteAll : .overwrite
                case 1: return useAllChoice ? .skipAll : .skip
                case 2: return .agenticMerge
                default: return .cancel
                }
            } else {
                // Text conflict — no Option key monitoring needed
                let response = alert.runModal()

                // Button index mapping for text:
                // [0: Resolve?], Resolve with Agent, Cancel
                let buttonIndex: Int
                switch response {
                case .alertFirstButtonReturn: buttonIndex = 0
                case .alertSecondButtonReturn: buttonIndex = 1
                case .alertThirdButtonReturn: buttonIndex = 2
                default: return .cancel
                }

                var idx = buttonIndex
                if canResolve {
                    if idx == 0 { return .resolve }
                    idx -= 1
                }
                // idx 0 = Resolve with Agent, 1 = Cancel
                switch idx {
                case 0: return .agenticMerge
                default: return .cancel
                }
            }
        }
    }

    /// Checks whether the user has a merge tool configured via `git config merge.tool`.
    @concurrent private func hasMergeTool(repoPath: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "git config --get merge.tool",
            workingDirectory: repoPath
        )
        let tool = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.exitCode == 0 && !tool.isEmpty
    }

    /// Returns `true` if the file at the given path appears to be a text file (not binary).
    nonisolated private func localSyncIsTextFile(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }
        // Check first 8 KB for null bytes — a common binary indicator.
        let sample = handle.readData(ofLength: 8192)
        return !sample.contains(0)
    }
}
