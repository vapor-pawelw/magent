import AppKit
import CryptoKit
import Foundation
import MagentCore

nonisolated enum BackgroundLocalSyncWorker {
    private enum ItemKind {
        case file
        case directory
    }

    private struct BaselineManifest: Codable {
        let fileHashes: [String: String]
    }

    static func syncConfiguredLocalPathsFromWorktree(
        projectRepoPath: String,
        worktreePath: String,
        syncPaths: [String]
    ) async throws {
        guard !syncPaths.isEmpty else { return }

        let baselineHashes = await loadBaselineFileHashes(worktreePath: worktreePath)
        for relativePath in syncPaths {
            let sourcePath = (worktreePath as NSString).appendingPathComponent(relativePath)
            guard itemKind(atPath: sourcePath) != nil else { continue }

            let destinationPath = (projectRepoPath as NSString).appendingPathComponent(relativePath)
            do {
                try await mergeItem(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    relativePath: relativePath,
                    destinationRootPath: projectRepoPath,
                    baselineFileHashes: baselineHashes
                )
            } catch let error as ThreadManagerError {
                throw error
            } catch {
                throw ThreadManagerError.localFileSyncFailed(
                    "Failed to sync \"\(relativePath)\" back to the main repo: \(error.localizedDescription)"
                )
            }
        }
    }

    private static func mergeItem(
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        destinationRootPath: String,
        baselineFileHashes: [String: String]?
    ) async throws {
        do {
            guard let sourceKind = itemKind(atPath: sourcePath) else { return }
            let fm = FileManager.default

            switch sourceKind {
            case .directory:
                let children = (try fm.contentsOfDirectory(atPath: sourcePath)).sorted()
                for child in children {
                    try await mergeItem(
                        sourcePath: (sourcePath as NSString).appendingPathComponent(child),
                        destinationPath: (destinationPath as NSString).appendingPathComponent(child),
                        relativePath: (relativePath as NSString).appendingPathComponent(child),
                        destinationRootPath: destinationRootPath,
                        baselineFileHashes: baselineFileHashes
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
                    let parentReady = ensureDirectoryTree(
                        destinationRootPath: destinationRootPath,
                        relativeDirectoryPath: parentRelativePath
                    )
                    guard parentReady else { return }
                }

                if let destinationKind = itemKind(atPath: destinationPath) {
                    switch destinationKind {
                    case .directory:
                        return
                    case .file:
                        if try filesMatch(sourcePath: sourcePath, destinationPath: destinationPath) {
                            return
                        }
                        return
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

    private static func ensureDirectoryTree(
        destinationRootPath: String,
        relativeDirectoryPath: String
    ) -> Bool {
        let components = relativeDirectoryPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return true }

        var currentRelativePath = ""
        for component in components {
            currentRelativePath = currentRelativePath.isEmpty
                ? component
                : (currentRelativePath as NSString).appendingPathComponent(component)

            let currentDestinationPath = (destinationRootPath as NSString).appendingPathComponent(currentRelativePath)
            guard ensureDirectoryExists(atPath: currentDestinationPath) else { return false }
        }
        return true
    }

    private static func ensureDirectoryExists(atPath destinationPath: String) -> Bool {
        let fm = FileManager.default
        if let existingKind = itemKind(atPath: destinationPath) {
            switch existingKind {
            case .directory:
                return true
            case .file:
                return false
            }
        }

        do {
            try fm.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private static func itemKind(atPath path: String) -> ItemKind? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return .file
        }
        return type == .typeDirectory ? .directory : .file
    }

    private static func filesMatch(sourcePath: String, destinationPath: String) throws -> Bool {
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
        let sourceHash = try fileHash(atPath: sourcePath)
        let destinationHash = try fileHash(atPath: destinationPath)
        return sourceHash == destinationHash
    }

    private static func shouldSkipArchiveCopyForUnchangedFile(
        sourcePath: String,
        relativePath: String,
        baselineFileHashes: [String: String]?
    ) throws -> Bool {
        guard let baselineFileHashes,
              let baselineHash = baselineFileHashes[relativePath] else {
            return false
        }
        let currentHash = try fileHash(atPath: sourcePath)
        return currentHash == baselineHash
    }

    private static func fileHash(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadBaselineFileHashes(worktreePath: String) async -> [String: String]? {
        guard let manifestPath = await baselineManifestPath(worktreePath: worktreePath) else {
            return nil
        }
        let url = URL(fileURLWithPath: manifestPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let manifest = try? JSONDecoder().decode(BaselineManifest.self, from: data) else {
            return nil
        }
        return manifest.fileHashes
    }

    private static func baselineManifestPath(worktreePath: String) async -> String? {
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
}

extension ThreadManager {

    private nonisolated enum LocalSyncConflictMode {
        case overwrite
        case skip
        case prompt
    }

    private nonisolated enum LocalSyncConflictChoice {
        case resolve
        case overwrite
        case overwriteAll
        case skip
        case skipAll
        case agenticMerge
        case cancel
    }

    private nonisolated enum LocalSyncItemKind {
        case file
        case directory
    }

    private nonisolated enum LocalSyncConflictKind {
        case fileDifferent
        case fileBlocksDirectory
        case directoryBlocksFile
    }

    private nonisolated struct LocalSyncConflict: Sendable {
        let relativePath: String
        let sourcePath: String
        let destinationPath: String
        let kind: LocalSyncConflictKind
    }

    private nonisolated struct LocalSyncBaselineManifest: Codable, Sendable {
        let fileHashes: [String: String]
    }

    private nonisolated enum LocalSyncDirectoryMaterialization {
        case onDemand
        case always
    }

    private nonisolated enum LocalSyncConflictDirection {
        case intoWorktree
        case intoRepo
    }

    // MARK: - Base Branch Sync Target Resolution

    /// Resolves the sync target for a thread based on its base branch.
    /// If an active sibling thread in the same project is checked out on the base branch,
    /// returns that worktree path and its display name. Otherwise falls back to project.repoPath.
    func resolveBaseBranchSyncTarget(for thread: MagentThread, project: Project) -> (path: String, label: String) {
        let baseBranch = resolveBaseBranch(for: thread)
        if let sibling = threads.first(where: {
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
        if let sibling = threads.first(where: {
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
        syncPaths: [String],
        promptForConflicts: Bool = false,
        sourceRootOverride: String? = nil
    ) async throws -> [String] {
        guard !syncPaths.isEmpty else { return [] }

        let sourceRoot = sourceRootOverride ?? project.repoPath
        var missingPaths: [String] = []
        let conflictMode: LocalSyncConflictMode = promptForConflicts ? .prompt : .overwrite
        var overwriteAll = !promptForConflicts
        var ignoreAll = false
        for relativePath in syncPaths {
            let sourcePath = (sourceRoot as NSString).appendingPathComponent(relativePath)
            guard localSyncItemKind(atPath: sourcePath) != nil else {
                missingPaths.append(relativePath)
                continue
            }

            let destinationPath = (worktreePath as NSString).appendingPathComponent(relativePath)
            do {
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
            } catch ThreadManagerError.agenticMergeSignal {
                let sourceLabel = sourceRootOverride.map { ($0 as NSString).lastPathComponent } ?? "Project"
                let destLabel = (worktreePath as NSString).lastPathComponent
                throw ThreadManagerError.agenticMergeReady(LocalSyncAgenticMergeContext(
                    sourceRoot: sourceRoot,
                    destinationRoot: worktreePath,
                    syncPaths: syncPaths,
                    sourceLabel: sourceLabel,
                    destinationLabel: destLabel
                ))
            } catch let error as ThreadManagerError {
                throw error
            } catch {
                throw ThreadManagerError.localFileSyncFailed(
                    "Failed to copy \"\(relativePath)\" into the new worktree: \(error.localizedDescription)"
                )
            }
        }

        let baselineHashes: [String: String]
        do {
            baselineHashes = try buildLocalSyncFileHashes(rootPath: worktreePath, syncPaths: syncPaths)
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
        syncPaths: [String],
        promptForConflicts: Bool,
        destinationRootOverride: String? = nil
    ) async throws {
        guard !syncPaths.isEmpty else { return }

        let destinationRoot = destinationRootOverride ?? project.repoPath
        let baselineHashes = await loadLocalSyncBaselineFileHashes(worktreePath: worktreePath)
        let conflictMode: LocalSyncConflictMode = promptForConflicts ? .prompt : .skip
        var overwriteAll = false
        var ignoreAll = false
        for relativePath in syncPaths {
            let sourcePath = (worktreePath as NSString).appendingPathComponent(relativePath)
            guard localSyncItemKind(atPath: sourcePath) != nil else { continue }

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
                    sourceRoot: worktreePath,
                    destinationRoot: destinationRoot,
                    syncPaths: syncPaths,
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

    nonisolated func effectiveLocalSyncPaths(for thread: MagentThread, project: Project) -> [String] {
        let currentPaths = project.normalizedLocalFileSyncPaths
        if let snapshot = thread.localFileSyncPathsSnapshot {
            let snapshotPaths = Project.normalizeLocalFileSyncPaths(snapshot)
            let currentSet = Set(currentPaths)
            // Keep historical snapshot semantics for additions, but never sync paths
            // that are no longer configured in the project.
            return snapshotPaths.filter { currentSet.contains($0) }
        }
        return currentPaths
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
            guard let sourceKind = localSyncItemKind(atPath: sourcePath) else { return }
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

                if let destinationKind = localSyncItemKind(atPath: destinationPath) {
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
        if let existingKind = localSyncItemKind(atPath: destinationPath) {
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

    nonisolated private func localSyncItemKind(atPath path: String) -> LocalSyncItemKind? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return .file
        }
        return type == .typeDirectory ? .directory : .file
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
        guard let kind = localSyncItemKind(atPath: absolutePath) else { return }
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
        await ShellExecutor.execute(
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
            // Text file conflicts: [Resolve in Merge Tool], Agentic Merge, Cancel
            // Binary/structural conflicts: Override/Ignore (Option for All), Agentic Merge, Cancel

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

            alert.addButton(withTitle: "Agentic Merge")

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
                // [0: Resolve?], Override, Ignore, Agentic Merge, Cancel
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
                // idx 0 = Override, 1 = Ignore, 2 = Agentic Merge, 3 = Cancel
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
                // [0: Resolve?], Agentic Merge, Cancel
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
                // idx 0 = Agentic Merge, 1 = Cancel
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
