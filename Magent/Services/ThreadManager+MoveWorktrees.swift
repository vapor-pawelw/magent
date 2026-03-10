import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Move Worktrees Base Path

    func moveWorktreesBasePath(for project: Project, from oldBase: String, to newBase: String) async throws {
        let fm = FileManager.default

        // Collect active (non-archived, non-main) threads for this project
        let affectedIndices = threads.indices.filter { i in
            threads[i].projectId == project.id && !threads[i].isArchived && !threads[i].isMain
        }

        // Build list of worktree directory names to move
        let worktreeNames: [(index: Int, dirName: String)] = affectedIndices.compactMap { i in
            let dirName = URL(fileURLWithPath: threads[i].worktreePath).lastPathComponent
            // Only include if the worktree actually lives under oldBase
            let expectedPath = (oldBase as NSString).appendingPathComponent(dirName)
            guard threads[i].worktreePath == expectedPath else { return nil }
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

            threads[index].worktreePath = newPath

            // Update MAGENT_WORKTREE_PATH on live tmux sessions
            for sessionName in threads[index].tmuxSessionNames {
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
        try persistence.saveActiveThreads(threads)

        // Try to remove old base directory if empty
        if let remaining = try? fm.contentsOfDirectory(atPath: oldBase), remaining.isEmpty {
            try? fm.removeItem(atPath: oldBase)
        }
    }
}
