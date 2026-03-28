import AppKit
import CryptoKit
import Foundation
import MagentCore

enum BackgroundLocalSyncWorker {
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

    /// Attempts to resolve a file conflict by launching opendiff (FileMerge).
    /// Other merge tools are not supported because they require git's backend-specific
    /// launch logic which we can't replicate outside a real git merge context.
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

        // Create temp copies for LOCAL / BASE / REMOTE / MERGED
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("magent-merge-\(UUID().uuidString)")
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(atPath: tempDir) }

        let localFile = (tempDir as NSString).appendingPathComponent("LOCAL")
        let baseFile = (tempDir as NSString).appendingPathComponent("BASE")
        let remoteFile = (tempDir as NSString).appendingPathComponent("REMOTE")
        let mergedFile = (tempDir as NSString).appendingPathComponent("MERGED")

        do {
            try fm.copyItem(atPath: destinationPath, toPath: localFile)
            try Data().write(to: URL(fileURLWithPath: baseFile))
            try fm.copyItem(atPath: sourcePath, toPath: remoteFile)
            try fm.copyItem(atPath: destinationPath, toPath: mergedFile)
        } catch {
            return false
        }

        let mergeCommand = "opendiff \(shellEscaped(localFile)) \(shellEscaped(remoteFile)) -ancestor \(shellEscaped(baseFile)) -merge \(shellEscaped(mergedFile))"

        let toolRunResult = await ShellExecutor.execute(mergeCommand)
        guard toolRunResult.exitCode == 0 else { return false }

        // Tool exited successfully — apply the MERGED result to the destination.
        // We trust exit 0 as resolution even if the user chose to keep the local
        // version unchanged (a valid "keep mine" resolution).
        guard fm.fileExists(atPath: mergedFile) else { return false }
        do {
            let mergedData = try Data(contentsOf: URL(fileURLWithPath: mergedFile))
            try mergedData.write(to: URL(fileURLWithPath: destinationPath), options: .atomic)
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
    ) -> LocalSyncConflictChoice {
        let isTextConflict = conflict.kind == .fileDifferent
            && localSyncIsTextFile(atPath: conflict.sourcePath)
            && localSyncIsTextFile(atPath: conflict.destinationPath)
        let canShowDiff = isTextConflict
        let canResolve = isTextConflict && hasMergeTool(repoPath: repoPath)

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

            let optionHint = "\n\nHold Option for \"Override All\" or \"Ignore All\"."
            alert.informativeText += optionHint

            // Button order: [Resolve (primary)], Override, Ignore, [Show Diff], Cancel
            // "Resolve" is the primary action when a merge tool is available.
            if canResolve {
                alert.addButton(withTitle: "Resolve in Merge Tool")
            }
            let overrideButton = alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveConflictOverride))
            let ignoreButton = alert.addButton(withTitle: String(localized: .ThreadStrings.threadArchiveConflictIgnore))
            if canShowDiff {
                alert.addButton(withTitle: "Show Diff")
            }
            let cancelTitle: String = switch direction {
            case .intoRepo:
                String(localized: .ThreadStrings.threadArchiveConflictCancelArchive)
            case .intoWorktree:
                String(localized: .CommonStrings.commonCancel)
            }
            alert.addButton(withTitle: cancelTitle)

            var optionHeld = NSEvent.modifierFlags.contains(.option)
            func updateButtonTitles() {
                overrideButton.title = optionHeld
                    ? String(localized: .ThreadStrings.threadArchiveConflictOverrideAll)
                    : String(localized: .ThreadStrings.threadArchiveConflictOverride)
                ignoreButton.title = optionHeld
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

            // Map response to button index, accounting for optional Resolve button
            let buttonIndex: Int
            switch response {
            case .alertFirstButtonReturn: buttonIndex = 0
            case .alertSecondButtonReturn: buttonIndex = 1
            case .alertThirdButtonReturn: buttonIndex = 2
            case NSApplication.ModalResponse(rawValue: 1003): buttonIndex = 3
            case NSApplication.ModalResponse(rawValue: 1004): buttonIndex = 4
            default: return .cancel
            }

            // Decode which logical button was pressed
            var idx = buttonIndex
            if canResolve {
                if idx == 0 { return .resolve }
                idx -= 1
            }
            // idx 0 = Override, 1 = Ignore, 2 = Show Diff (if present), last = Cancel
            switch idx {
            case 0:
                return useAllChoice ? .overwriteAll : .overwrite
            case 1:
                return useAllChoice ? .skipAll : .skip
            case 2 where canShowDiff:
                presentLocalSyncDiffPanel(conflict, direction: direction)
                continue // re-present the conflict alert after closing diff
            default:
                return .cancel
            }
        }
    }

    /// Checks whether opendiff (FileMerge) is available as a merge tool.
    /// Other merge tools are not supported — they require git's backend-specific launch logic.
    nonisolated private func hasMergeTool(repoPath: String) -> Bool {
        // Check if opendiff is available on the system (ships with Xcode command line tools)
        return FileManager.default.fileExists(atPath: "/usr/bin/opendiff")
    }

    // MARK: - Diff

    @MainActor
    private func presentLocalSyncDiffPanel(_ conflict: LocalSyncConflict, direction: LocalSyncConflictDirection) {
        let sourceContent = (try? String(contentsOfFile: conflict.sourcePath, encoding: .utf8)) ?? "(unreadable)"
        let destContent = (try? String(contentsOfFile: conflict.destinationPath, encoding: .utf8)) ?? "(unreadable)"

        // source = where the file is being copied FROM, destination = where it would land.
        // For intoWorktree: source is project, destination is worktree.
        // For intoRepo: source is worktree, destination is project repo.
        let sourceLabel: String
        let destLabel: String
        let shortSource = conflict.sourcePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let shortDest = conflict.destinationPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        switch direction {
        case .intoWorktree:
            destLabel = "Worktree: \(shortDest)"
            sourceLabel = "Project: \(shortSource)"
        case .intoRepo:
            destLabel = "Project: \(shortDest)"
            sourceLabel = "Worktree: \(shortSource)"
        }

        let diff = localSyncUnifiedDiff(
            oldText: destContent,
            newText: sourceContent,
            oldLabel: destLabel,
            newLabel: sourceLabel
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Diff: \(conflict.relativePath)"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        let scrollView = NSScrollView(frame: panel.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        applyLocalSyncDiffColoring(to: textView, diff: diff)

        scrollView.documentView = textView
        panel.contentView = scrollView
        panel.center()

        // Stop modal run loop when the panel is closed.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            NSApp.stopModal()
        }
        NSApp.runModal(for: panel)
    }

    private func applyLocalSyncDiffColoring(to textView: NSTextView, diff: String) {
        let storage = NSMutableAttributedString()
        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let baseColor = NSColor.labelColor

        let addedFg = NSColor(calibratedRed: 0.35, green: 0.75, blue: 0.35, alpha: 1.0)
        let addedBg = NSColor.systemGreen.withAlphaComponent(0.08)
        let removedFg = NSColor(calibratedRed: 0.9, green: 0.35, blue: 0.35, alpha: 1.0)
        let removedBg = NSColor.systemRed.withAlphaComponent(0.08)
        let headerColor = NSColor.secondaryLabelColor

        for line in diff.components(separatedBy: "\n") {
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: baseColor]
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                attrs[.foregroundColor] = headerColor
            } else if line.hasPrefix("+") {
                attrs[.foregroundColor] = addedFg
                attrs[.backgroundColor] = addedBg
            } else if line.hasPrefix("-") {
                attrs[.foregroundColor] = removedFg
                attrs[.backgroundColor] = removedBg
            }
            storage.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }

        textView.textStorage?.setAttributedString(storage)
    }

    /// Produces a basic unified diff between two strings.
    private func localSyncUnifiedDiff(oldText: String, newText: String, oldLabel: String, newLabel: String) -> String {
        // Use the system `diff` command for a proper unified diff.
        let tempDir = NSTemporaryDirectory()
        let oldFile = (tempDir as NSString).appendingPathComponent("magent-diff-old-\(UUID().uuidString)")
        let newFile = (tempDir as NSString).appendingPathComponent("magent-diff-new-\(UUID().uuidString)")

        defer {
            try? FileManager.default.removeItem(atPath: oldFile)
            try? FileManager.default.removeItem(atPath: newFile)
        }

        do {
            try oldText.write(toFile: oldFile, atomically: true, encoding: .utf8)
            try newText.write(toFile: newFile, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            process.arguments = ["-u", "--label", oldLabel, "--label", newLabel, oldFile, newFile]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                return output
            }
        } catch {
            // Fall through to simple diff
        }

        // Fallback: simple line-by-line comparison
        let oldFallbackLines = oldText.components(separatedBy: "\n")
        let newFallbackLines = newText.components(separatedBy: "\n")
        var result = "--- \(oldLabel)\n+++ \(newLabel)\n"
        result += "@@ -1,\(oldFallbackLines.count) +1,\(newFallbackLines.count) @@\n"
        for line in oldFallbackLines { result += "-\(line)\n" }
        for line in newFallbackLines { result += "+\(line)\n" }
        return result
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
