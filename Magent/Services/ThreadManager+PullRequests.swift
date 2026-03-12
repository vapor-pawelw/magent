import Foundation
import MagentCore

extension ThreadManager {

    private func cachedPullRequestRemote(for projectId: UUID, repoPath: String) async -> GitRemote? {
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

    private func updatePullRequestInfo(_ info: PullRequestInfo?, forThreadId threadId: UUID) async {
        guard let index = threads.firstIndex(where: { $0.id == threadId }),
              threads[index].pullRequestInfo != info else {
            return
        }

        threads[index].pullRequestInfo = info
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
            NotificationCenter.default.post(name: .magentPullRequestInfoChanged, object: nil)
        }
    }

    func resolvePullRequestURL(for thread: MagentThread) async -> URL? {
        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let remote = await cachedPullRequestRemote(for: project.id, repoPath: project.repoPath) else {
            return nil
        }

        let branch = thread.actualBranch ?? thread.branchName
        let defaultBranch: String?
        if let projectDefaultBranch = project.defaultBranch {
            defaultBranch = projectDefaultBranch
        } else {
            defaultBranch = await git.detectDefaultBranch(repoPath: project.repoPath)
        }

        if !thread.isMain, branch != defaultBranch,
           let info = await git.fetchPullRequest(remote: remote, branch: branch) {
            await updatePullRequestInfo(info, forThreadId: thread.id)
            return info.url
        }

        return remote.pullRequestURL(for: branch, defaultBranch: defaultBranch)
            ?? remote.openPullRequestsURL
            ?? remote.repoWebURL
    }

    func runPRSyncTick() async {
        let settings = persistence.loadSettings()
        for project in settings.projects where _cachedRemoteByProjectId[project.id] == nil {
            _ = await cachedPullRequestRemote(for: project.id, repoPath: project.repoPath)
        }

        let snapshot = threads.filter { !$0.isArchived && !$0.isMain }
        var changed = false
        for thread in snapshot {
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
                continue
            }

            guard let remote = await cachedPullRequestRemote(for: project.id, repoPath: project.repoPath) else {
                if let i = threads.firstIndex(where: { $0.id == thread.id }),
                   threads[i].pullRequestInfo != nil {
                    threads[i].pullRequestInfo = nil
                    changed = true
                }
                continue
            }

            let branch = thread.actualBranch ?? thread.branchName
            let info = await git.fetchPullRequest(remote: remote, branch: branch)
            guard let i = threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if threads[i].pullRequestInfo != info {
                threads[i].pullRequestInfo = info
                changed = true
            }
        }

        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                NotificationCenter.default.post(name: .magentPullRequestInfoChanged, object: nil)
            }
        }
    }
}
