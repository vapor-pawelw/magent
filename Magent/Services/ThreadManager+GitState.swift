import Foundation
import MagentCore

enum BackgroundWorktreeCachePruner {
    nonisolated static func prune(worktreesBasePath: String, activeNames: Set<String>) {
        let url = URL(fileURLWithPath: worktreesBasePath).appendingPathComponent(".magent-cache.json")
        guard let data = try? Data(contentsOf: url) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var cache = try? decoder.decode(WorktreeMetadataCache.self, from: data) else { return }

        let before = cache.worktrees.count
        cache.worktrees = cache.worktrees.filter { activeNames.contains($0.key) }
        guard cache.worktrees.count != before else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(cache) else { return }
        try? encoded.write(to: url, options: .atomic)
    }
}

// MARK: - Forwarding layer — logic lives in GitStateService

extension ThreadManager {

    func resolveBaseBranch(for thread: MagentThread) -> String {
        gitStateService.resolveBaseBranch(for: thread)
    }

    func refreshDirtyStates() async {
        await gitStateService.refreshDirtyStates()
    }

    @discardableResult
    func refreshDirtyState(for threadId: UUID) async -> Bool {
        await gitStateService.refreshDirtyState(for: threadId)
    }

    func refreshDeliveredStates() async {
        await gitStateService.refreshDeliveredStates()
    }

    @discardableResult
    func refreshDeliveredState(for threadId: UUID) async -> Bool {
        await gitStateService.refreshDeliveredState(for: threadId)
    }

    func worktreeActiveNames(for projectId: UUID) -> Set<String> {
        gitStateService.worktreeActiveNames(for: projectId)
    }

    func pruneWorktreeCache(for project: Project) {
        gitStateService.pruneWorktreeCache(for: project)
    }

    func refreshBranchStates() async {
        await gitStateService.refreshBranchStates()
    }

    func resolveExpectedBranch(for thread: MagentThread) -> String? {
        gitStateService.resolveExpectedBranch(for: thread)
    }

    func acceptActualBranch(threadId: UUID) {
        gitStateService.acceptActualBranch(threadId: threadId)
    }

    func switchToExpectedBranch(threadId: UUID) async throws {
        try await gitStateService.switchToExpectedBranch(threadId: threadId)
    }

    func refreshDiffStats(for threadId: UUID) async -> [FileDiffEntry] {
        await gitStateService.refreshDiffStats(for: threadId)
    }

    func setBaseBranch(_ baseBranch: String, for threadId: UUID) {
        gitStateService.setBaseBranch(baseBranch, for: threadId)
    }

    func clearBaseBranchReset(for threadId: UUID) {
        gitStateService.clearBaseBranchReset(for: threadId)
    }

    func listAncestorBranches(for threadId: UUID) async -> [String] {
        await gitStateService.listAncestorBranches(for: threadId)
    }
}
