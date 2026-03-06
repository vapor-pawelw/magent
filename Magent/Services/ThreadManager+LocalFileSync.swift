import AppKit
import CryptoKit
import Foundation

extension ThreadManager {

    private enum LocalSyncConflictMode {
        case overwrite
        case skip
        case prompt
    }

    private enum LocalSyncConflictChoice {
        case overwrite
        case overwriteAll
        case skip
        case cancel
    }

    private enum LocalSyncItemKind {
        case file
        case directory
    }

    private enum LocalSyncConflictKind {
        case fileDifferent
        case fileBlocksDirectory
        case directoryBlocksFile
    }

    private struct LocalSyncConflict {
        let relativePath: String
        let destinationPath: String
        let kind: LocalSyncConflictKind
    }

    private struct LocalSyncBaselineManifest: Codable {
        let fileHashes: [String: String]
    }

    // MARK: - Local Sync In (Repo -> Worktree)

    func syncConfiguredLocalPathsIntoWorktree(
        project: Project,
        worktreePath: String,
        syncPaths: [String]
    ) async throws {
        guard !syncPaths.isEmpty else { return }

        var overwriteAll = true
        for relativePath in syncPaths {
            let sourcePath = (project.repoPath as NSString).appendingPathComponent(relativePath)
            guard localSyncItemKind(atPath: sourcePath) != nil else { continue }

            let destinationPath = (worktreePath as NSString).appendingPathComponent(relativePath)
            do {
                try await mergeLocalSyncItem(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    relativePath: relativePath,
                    destinationRootPath: worktreePath,
                    conflictMode: .overwrite,
                    overwriteAll: &overwriteAll
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
    }

    // MARK: - Local Sync Back (Worktree -> Repo)

    func syncConfiguredLocalPathsFromWorktree(
        project: Project,
        worktreePath: String,
        syncPaths: [String],
        promptForConflicts: Bool
    ) async throws {
        guard !syncPaths.isEmpty else { return }

        let baselineHashes = await loadLocalSyncBaselineFileHashes(worktreePath: worktreePath)
        let conflictMode: LocalSyncConflictMode = promptForConflicts ? .prompt : .skip
        var overwriteAll = false
        for relativePath in syncPaths {
            let sourcePath = (worktreePath as NSString).appendingPathComponent(relativePath)
            guard localSyncItemKind(atPath: sourcePath) != nil else { continue }

            let destinationPath = (project.repoPath as NSString).appendingPathComponent(relativePath)
            do {
                try await mergeLocalSyncItem(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    relativePath: relativePath,
                    destinationRootPath: project.repoPath,
                    conflictMode: conflictMode,
                    overwriteAll: &overwriteAll,
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

    func effectiveLocalSyncPaths(for thread: MagentThread, project: Project) -> [String] {
        if let snapshot = thread.localFileSyncPathsSnapshot {
            return Project.normalizeLocalFileSyncPaths(snapshot)
        }
        return project.normalizedLocalFileSyncPaths
    }

    // MARK: - Merge Copy

    private func mergeLocalSyncItem(
        sourcePath: String,
        destinationPath: String,
        relativePath: String,
        destinationRootPath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool,
        baselineFileHashes: [String: String]? = nil
    ) async throws {
        do {
            guard let sourceKind = localSyncItemKind(atPath: sourcePath) else { return }
            let fm = FileManager.default

            switch sourceKind {
            case .directory:
                let ensured = try await ensureLocalSyncDirectoryExists(
                    atPath: destinationPath,
                    relativePath: relativePath,
                    conflictMode: conflictMode,
                    overwriteAll: &overwriteAll
                )
                guard ensured else { return }

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
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll,
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
                    let parentReady = try await ensureLocalSyncDirectoryTree(
                        destinationRootPath: destinationRootPath,
                        relativeDirectoryPath: parentRelativePath,
                        conflictMode: conflictMode,
                        overwriteAll: &overwriteAll
                    )
                    guard parentReady else { return }
                }

                if let destinationKind = localSyncItemKind(atPath: destinationPath) {
                    switch destinationKind {
                    case .directory:
                        let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                            LocalSyncConflict(
                                relativePath: relativePath,
                                destinationPath: destinationPath,
                                kind: .directoryBlocksFile
                            ),
                            conflictMode: conflictMode,
                            overwriteAll: &overwriteAll
                        )
                        guard shouldOverwrite else { return }
                        try fm.removeItem(atPath: destinationPath)

                    case .file:
                        let filesMatch = fm.contentsEqual(atPath: sourcePath, andPath: destinationPath)
                        guard !filesMatch else { return }

                        let shouldOverwrite = try await shouldOverwriteLocalSyncConflict(
                            LocalSyncConflict(
                                relativePath: relativePath,
                                destinationPath: destinationPath,
                                kind: .fileDifferent
                            ),
                            conflictMode: conflictMode,
                            overwriteAll: &overwriteAll
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

    private func ensureLocalSyncDirectoryTree(
        destinationRootPath: String,
        relativeDirectoryPath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool
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
                overwriteAll: &overwriteAll
            )
            guard ready else { return false }
        }

        return true
    }

    private func ensureLocalSyncDirectoryExists(
        atPath destinationPath: String,
        relativePath: String,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool
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
                        destinationPath: destinationPath,
                        kind: .fileBlocksDirectory
                    ),
                    conflictMode: conflictMode,
                    overwriteAll: &overwriteAll
                )
                guard shouldOverwrite else { return false }
                try fm.removeItem(atPath: destinationPath)
            }
        }

        try fm.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
        return true
    }

    private func localSyncItemKind(atPath path: String) -> LocalSyncItemKind? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else {
            return .file
        }
        return type == .typeDirectory ? .directory : .file
    }

    // MARK: - Baseline Manifest

    private func shouldSkipArchiveCopyForUnchangedFile(
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

    private func localSyncFileHash(atPath path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func buildLocalSyncFileHashes(rootPath: String, syncPaths: [String]) throws -> [String: String] {
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

    private func collectLocalSyncFileHashes(
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

    private func saveLocalSyncBaselineManifest(worktreePath: String, fileHashes: [String: String]) async throws {
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

    private func loadLocalSyncBaselineFileHashes(worktreePath: String) async -> [String: String]? {
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

    private func localSyncBaselineManifestPath(worktreePath: String) async -> String? {
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

    // MARK: - Conflict Resolution

    private func shouldOverwriteLocalSyncConflict(
        _ conflict: LocalSyncConflict,
        conflictMode: LocalSyncConflictMode,
        overwriteAll: inout Bool
    ) async throws -> Bool {
        switch conflictMode {
        case .overwrite:
            return true
        case .skip:
            return false
        case .prompt:
            if overwriteAll { return true }
            let choice = presentLocalSyncConflictAlert(conflict)
            switch choice {
            case .overwrite:
                return true
            case .overwriteAll:
                overwriteAll = true
                return true
            case .skip:
                return false
            case .cancel:
                throw ThreadManagerError.archiveCancelled
            }
        }
    }

    @MainActor
    private func presentLocalSyncConflictAlert(_ conflict: LocalSyncConflict) -> LocalSyncConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive Conflict: \(conflict.relativePath)"

        let destinationPath = conflict.destinationPath
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        switch conflict.kind {
        case .fileDifferent:
            alert.informativeText = "A different file already exists at:\n\(destinationPath)\n\nChoose how to proceed."
        case .fileBlocksDirectory:
            alert.informativeText = "A file exists where a directory is needed:\n\(destinationPath)\n\nChoose how to proceed."
        case .directoryBlocksFile:
            alert.informativeText = "A directory exists where a file is needed:\n\(destinationPath)\n\nChoose how to proceed."
        }

        alert.addButton(withTitle: "Override")
        alert.addButton(withTitle: "Override All")
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Cancel Archive")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .overwrite
        case .alertSecondButtonReturn:
            return .overwriteAll
        case .alertThirdButtonReturn:
            return .skip
        default:
            return .cancel
        }
    }
}
