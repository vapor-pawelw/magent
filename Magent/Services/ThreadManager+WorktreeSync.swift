import Foundation
import MagentCore

extension ThreadManager {

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
        let existingPaths = Set(threads.filter { $0.projectId == project.id }.map(\.worktreePath))

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

            // Skip if we already have a thread for this path
            guard !existingPaths.contains(fullPath) else { continue }

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
            threads.append(thread)
            changed = true
        }

        // Archive threads whose worktree directories no longer exist on disk
        // (skip main threads — those point at the repo itself)
        for i in threads.indices {
            guard threads[i].projectId == project.id,
                  !threads[i].isMain,
                  !threads[i].isArchived else { continue }

            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: threads[i].worktreePath, isDirectory: &isDir) && isDir.boolValue
            if !exists {
                threads[i].isArchived = true
                if threads[i].archivedAt == nil {
                    threads[i].archivedAt = Date()
                }
                changed = true
            }
        }

        if changed {
            // Remove archived from active list
            threads = threads.filter { !$0.isArchived }

            // Save all (including newly archived) to persistence
            var allThreads = persistence.loadThreads()
            // Merge: update archived flags, add new threads
            for thread in threads where !allThreads.contains(where: { $0.id == thread.id }) {
                allThreads.append(thread)
            }
            // Update archived flags
            for i in allThreads.indices {
                if !threads.contains(where: { $0.id == allThreads[i].id }) && allThreads[i].projectId == project.id && !allThreads[i].isMain {
                    allThreads[i].isArchived = true
                    if allThreads[i].archivedAt == nil {
                        allThreads[i].archivedAt = Date()
                    }
                }
            }
            try? persistence.saveThreads(allThreads)

            await MainActor.run {
                NotificationCenter.default.post(name: .magentArchivedThreadsDidChange, object: nil)
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    // MARK: - Session Name Migration

    /// One-time migration: renames tmux sessions from the old `magent-` format to the new `ma-` format.
    func migrateSessionNamesToNewFormat() async {
        let needsMigration = threads.contains { thread in
            thread.tmuxSessionNames.contains { $0.hasPrefix("magent-") }
        }
        guard needsMigration else { return }

        let settings = persistence.loadSettings()
        var changed = false

        for i in threads.indices {
            let thread = threads[i]
            guard thread.tmuxSessionNames.contains(where: { $0.hasPrefix("magent-") }) else { continue }
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { continue }

            let slug = Self.repoSlug(from: project.name)
            var renameMap: [String: String] = [:]
            var usedNames = Set<String>()

            for (tabIndex, sessionName) in thread.tmuxSessionNames.enumerated() {
                guard sessionName.hasPrefix("magent-") else {
                    usedNames.insert(sessionName)
                    continue
                }

                let customName = thread.customTabNames[sessionName]
                let displayName = (customName?.isEmpty == false)
                    ? customName!
                    : MagentThread.defaultDisplayName(at: tabIndex)
                let tabSlug = Self.sanitizeForTmux(displayName)

                let threadNamePart = thread.isMain ? nil : thread.name
                let baseName = Self.buildSessionName(repoSlug: slug, threadName: threadNamePart, tabSlug: tabSlug)

                var candidate = baseName
                if usedNames.contains(candidate) {
                    var suffix = 2
                    while usedNames.contains("\(baseName)-\(suffix)") {
                        suffix += 1
                    }
                    candidate = "\(baseName)-\(suffix)"
                }
                usedNames.insert(candidate)

                if candidate != sessionName {
                    renameMap[sessionName] = candidate
                }
            }

            guard !renameMap.isEmpty else { continue }

            // Rename live tmux sessions
            let oldNames = thread.tmuxSessionNames
            let newNames = oldNames.map { renameMap[$0] ?? $0 }
            try? await renameTmuxSessions(from: oldNames, to: newNames)

            // Update all references
            threads[i].tmuxSessionNames = newNames
            threads[i].agentTmuxSessions = threads[i].agentTmuxSessions.map { renameMap[$0] ?? $0 }
            threads[i].pinnedTmuxSessions = threads[i].pinnedTmuxSessions.map { renameMap[$0] ?? $0 }
            _ = remapTransientSessionState(threadIndex: i, sessionRenameMap: renameMap)
            threads[i].unreadCompletionSessions = Set(
                threads[i].unreadCompletionSessions.map { renameMap[$0] ?? $0 }
            )
            threads[i].sessionAgentTypes = Dictionary(
                uniqueKeysWithValues: threads[i].sessionAgentTypes.map { key, value in
                    (renameMap[key] ?? key, value)
                }
            )
            threads[i].sessionConversationIDs = Dictionary(
                uniqueKeysWithValues: threads[i].sessionConversationIDs.map { key, value in
                    (renameMap[key] ?? key, value)
                }
            )
            _ = remapSubmittedPromptHistory(threadIndex: i, sessionRenameMap: renameMap)
            var newCustomTabNames: [String: String] = [:]
            for (key, value) in threads[i].customTabNames {
                newCustomTabNames[renameMap[key] ?? key] = value
            }
            threads[i].customTabNames = newCustomTabNames
            if let selected = threads[i].lastSelectedTmuxSessionName {
                threads[i].lastSelectedTmuxSessionName = renameMap[selected] ?? selected
            }
            changed = true
        }

        if changed {
            try? persistence.saveActiveThreads(threads)
        }
    }

    // MARK: - Bell Pipes

    /// Ensures every live agent tmux session has a pipe-pane bell watcher set up.
    /// Called at startup and periodically from the session monitor.
    func ensureBellPipes() async {
        let pipedSessions = await tmux.sessionsWithActivePipe()
        for thread in threads where !thread.isArchived {
            for sessionName in thread.agentTmuxSessions {
                guard !pipedSessions.contains(sessionName) else { continue }
                // Only set up if the session is actually alive
                guard await tmux.hasSession(name: sessionName) else { continue }
                await tmux.setupBellPipe(for: sessionName)
            }
        }
    }
}
