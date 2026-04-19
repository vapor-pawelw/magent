import Foundation
import MagentCore

extension ThreadManager {
    private static let archivedPathRediscoverySuppressionWindow: TimeInterval = 15 * 60
    private static let archivedHistoryLimitPerProject = 100

    // MARK: - Worktree Sync — forwarding to WorktreeService

    func syncThreadsWithWorktrees(for project: Project) async {
        await worktreeService.syncThreadsWithWorktrees(for: project)
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
            threads[i].protectedTmuxSessions = Set(threads[i].protectedTmuxSessions.map { renameMap[$0] ?? $0 })
            _ = remapTransientSessionState(threadIndex: i, sessionRenameMap: renameMap)
            threads[i].unreadCompletionSessions = Set(
                threads[i].unreadCompletionSessions.map { renameMap[$0] ?? $0 }
            )
            _ = remapSessionAgentTypes(threadIndex: i, sessionRenameMap: renameMap)
            threads[i].forwardedTmuxSessions = Set(
                threads[i].forwardedTmuxSessions.map { renameMap[$0] ?? $0 }
            )
            threads[i].sessionConversationIDs = Dictionary(
                uniqueKeysWithValues: threads[i].sessionConversationIDs.map { key, value in
                    (renameMap[key] ?? key, value)
                }
            )
            threads[i].sessionCreatedAts = Dictionary(
                uniqueKeysWithValues: threads[i].sessionCreatedAts.map { key, value in
                    (renameMap[key] ?? key, value)
                }
            )
            threads[i].freshAgentSessions = Set(
                threads[i].freshAgentSessions.map { renameMap[$0] ?? $0 }
            )
            _ = remapSubmittedPromptHistory(threadIndex: i, sessionRenameMap: renameMap)
            var newCustomTabNames: [String: String] = [:]
            for (key, value) in threads[i].customTabNames {
                newCustomTabNames[renameMap[key] ?? key] = value
            }
            threads[i].customTabNames = newCustomTabNames
            if let selected = threads[i].lastSelectedTabIdentifier {
                threads[i].lastSelectedTabIdentifier = renameMap[selected] ?? selected
            }
            changed = true
        }

        if changed {
            try? persistence.saveActiveThreads(threads)
        }
    }

    // MARK: - Bell Pipes — forwarding to WorktreeService

    func ensureBellPipes() async {
        await worktreeService.ensureBellPipes()
    }
}
