import Foundation
import MagentCore

// MARK: - Forwarding layer — logic lives in PullRequestService

extension ThreadManager {

    // MARK: - Remote cache helper (stays here until Phase 3 extracts GitState)

    /// Checks `_cachedRemoteByProjectId` first; fetches via GitService on cache miss.
    /// The result is stored back into the shared cache so all callers share one fetch per project.
    func cachedPullRequestRemote(for projectId: UUID, repoPath: String) async -> GitRemote? {
        if let cached = _cachedRemoteByProjectId[projectId] {
            return cached
        }
        let remotes = await git.getRemotes(repoPath: repoPath)
        let chosen = remotes.first(where: { $0.name == "origin" && $0.provider != .unknown })
            ?? remotes.first(where: { $0.provider != .unknown })
        if let chosen {
            _cachedRemoteByProjectId[projectId] = chosen
        }
        return chosen
    }

    @discardableResult
    func runPRSyncTick() async -> StatusSyncResult {
        await pullRequestService.runPRSyncTick()
    }

    func refreshPRForSelectedThread(_ thread: MagentThread) {
        pullRequestService.refreshPRForSelectedThread(thread)
    }

    func loadPRCacheIfNeeded() {
        pullRequestService.loadPRCacheIfNeeded()
    }

    func populatePRInfoFromCache() {
        pullRequestService.populatePRInfoFromCache()
    }

    func resolvePullRequestActionTarget(for thread: MagentThread) async -> PullRequestService.PullRequestActionTarget? {
        await pullRequestService.resolvePullRequestActionTarget(for: thread)
    }
}
