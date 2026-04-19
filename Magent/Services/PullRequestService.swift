import Foundation
import MagentCore

/// Owns PR detection, cache management, and sync logic.
/// Extracted from `ThreadManager+PullRequests`.
///
/// Mutates `store.threads` directly and returns changed thread IDs for the caller to fan out.
final class PullRequestService {

    struct PullRequestActionTarget {
        let url: URL
        let provider: GitHostingProvider
        let isCreation: Bool
    }

    let store: ThreadStore
    let persistence: PersistenceService
    let git: GitService

    /// Called when thread data changes and the delegate/UI should be notified.
    var onThreadsChanged: (() -> Void)?

    /// Resolves the base branch for a thread.
    /// Injected by ThreadManager so we don't pull in helpers that live there.
    var resolveBaseBranch: ((MagentThread) -> String)?

    /// Formats a sync failure summary string. Injected from ThreadManager.
    var formatFailureSummary: ((_ title: String, _ details: [String], _ totalCount: Int?) -> String)?

    // MARK: - State (moved from ThreadManager)

    var isPRSyncRunning = false
    var prCache: [String: PullRequestCacheEntry] = [:]
    var prCacheLoaded = false

    // MARK: - Init

    init(store: ThreadStore, persistence: PersistenceService, git: GitService) {
        self.store = store
        self.persistence = persistence
        self.git = git
    }

    // MARK: - Remote Cache

    /// `_cachedRemoteByProjectId` is shared with GitState (Phase 3 will handle it).
    /// For now, the caller passes a reference to the shared remote cache via this closure.
    var cachedRemoteResolver: ((UUID, String) async -> GitRemote?)?

    // MARK: - Lookup Helpers

    private func updatePullRequestLookup(_ result: PullRequestLookupResult, forThreadId threadId: UUID) async {
        let info: PullRequestInfo?
        let status: PullRequestLookupStatus

        switch result {
        case .found(let foundInfo):
            info = foundInfo
            status = .found
        case .notFound:
            info = nil
            status = .notFound
        case .unavailable:
            info = nil
            status = .unavailable
        }

        guard let index = store.threads.firstIndex(where: { $0.id == threadId }),
              store.threads[index].pullRequestInfo != info || store.threads[index].pullRequestLookupStatus != status else {
            return
        }

        store.threads[index].pullRequestInfo = info
        store.threads[index].pullRequestLookupStatus = status
        savePRInfoToCache(info: info, thread: store.threads[index])
        await MainActor.run {
            onThreadsChanged?()
            NotificationCenter.default.post(name: .magentPullRequestInfoChanged, object: nil)
        }
    }

    private func normalizedPullRequestTargetBranch(for thread: MagentThread, project: Project) -> String {
        let sourceBranch = thread.actualBranch ?? thread.branchName

        let baseCandidate = resolveBaseBranch?(thread) ?? ""
        let normalizedBase = baseCandidate.hasPrefix("origin/")
            ? String(baseCandidate.dropFirst("origin/".count))
            : baseCandidate
        if !normalizedBase.isEmpty, normalizedBase != sourceBranch {
            return normalizedBase
        }

        if let configuredDefault = project.defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredDefault.isEmpty,
           configuredDefault != sourceBranch {
            return configuredDefault
        }

        return "main"
    }

    func resolvePullRequestActionTarget(for thread: MagentThread) async -> PullRequestActionTarget? {
        if let info = thread.pullRequestInfo {
            return PullRequestActionTarget(
                url: info.url,
                provider: info.provider,
                isCreation: false
            )
        }

        let settings = persistence.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
              let remote = await cachedRemoteResolver?(project.id, project.repoPath) else {
            return nil
        }

        guard !thread.isMain, thread.pullRequestLookupStatus == .notFound else {
            return nil
        }

        let sourceBranch = thread.actualBranch ?? thread.branchName
        let targetBranch = normalizedPullRequestTargetBranch(for: thread, project: project)
        let title = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = remote.createPullRequestURL(sourceBranch: sourceBranch, targetBranch: targetBranch, title: title) else {
            return nil
        }
        return PullRequestActionTarget(
            url: url,
            provider: remote.provider,
            isCreation: true
        )
    }

    /// Returns a summary of any PR sync failures encountered during the pass.
    @discardableResult
    func runPRSyncTick() async -> ThreadManager.StatusSyncResult {
        guard !isPRSyncRunning else { return .success }
        isPRSyncRunning = true
        defer { isPRSyncRunning = false }

        let settings = persistence.loadSettings()
        // Prime the shared remote cache for all projects.
        for project in settings.projects {
            _ = await cachedRemoteResolver?(project.id, project.repoPath)
        }

        let snapshot = store.threads.filter { !$0.isArchived && !$0.isMain }
        var changed = false
        var hadErrors = false
        var errorCount = 0
        var failureDetails: [String] = []
        for thread in snapshot {
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
                continue
            }

            guard let remote = await cachedRemoteResolver?(project.id, project.repoPath) else {
                guard let i = store.threads.firstIndex(where: { $0.id == thread.id }) else {
                    continue
                }
                if store.threads[i].pullRequestInfo != nil || store.threads[i].pullRequestLookupStatus != .unavailable {
                    store.threads[i].pullRequestInfo = nil
                    store.threads[i].pullRequestLookupStatus = .unavailable
                    changed = true
                }
                continue
            }

            let branch = thread.actualBranch ?? thread.branchName
            let info: PullRequestInfo?
            let status: PullRequestLookupStatus
            do {
                let lookupResult = try await git.lookupPullRequest(remote: remote, branch: branch)
                switch lookupResult {
                case .found(let foundInfo):
                    info = foundInfo
                    status = .found
                case .notFound:
                    info = nil
                    status = .notFound
                case .unavailable:
                    info = nil
                    status = .unavailable
                }
            } catch {
                hadErrors = true
                errorCount += 1
                if failureDetails.count < 3 {
                    let trimmedMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    let message = trimmedMessage.isEmpty ? "Unknown error." : trimmedMessage
                    failureDetails.append("\(project.name) / \(branch): \(message)")
                }
                info = nil
                status = .unavailable
            }
            guard let i = store.threads.firstIndex(where: { $0.id == thread.id }) else { continue }
            if store.threads[i].pullRequestInfo != info || store.threads[i].pullRequestLookupStatus != status {
                store.threads[i].pullRequestInfo = info
                store.threads[i].pullRequestLookupStatus = status
                savePRInfoToCache(info: info, thread: store.threads[i])
                changed = true
            }

            // Yield between threads so the background pass doesn't starve other work.
            await Task.yield()
        }

        if changed {
            await MainActor.run {
                onThreadsChanged?()
                NotificationCenter.default.post(name: .magentPullRequestInfoChanged, object: nil)
            }
        }

        prunePRCache()
        guard hadErrors else { return .success }
        let summary = formatFailureSummary?("PR sync failed", failureDetails, errorCount)
            ?? "PR sync failed (\(errorCount) error\(errorCount == 1 ? "" : "s"))."
        return .failure(summary)
    }

    /// Refreshes PR status for a single thread (called on thread selection).
    func refreshPRForSelectedThread(_ thread: MagentThread) {
        guard !thread.isMain else { return }
        Task {
            // Skip if a bulk sync is already running — it will cover this thread.
            guard !isPRSyncRunning else { return }

            let settings = persistence.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }),
                  let remote = await cachedRemoteResolver?(project.id, project.repoPath) else {
                await updatePullRequestLookup(.unavailable, forThreadId: thread.id)
                return
            }

            let branch = thread.actualBranch ?? thread.branchName
            do {
                let lookupResult = try await git.lookupPullRequest(remote: remote, branch: branch)
                await updatePullRequestLookup(lookupResult, forThreadId: thread.id)
            } catch {
                await updatePullRequestLookup(.unavailable, forThreadId: thread.id)
            }
        }
    }

    // MARK: - PR Cache

    func loadPRCacheIfNeeded() {
        guard !prCacheLoaded else { return }
        prCache = persistence.loadPRCache()
        prCacheLoaded = true
    }

    /// Populates `pullRequestInfo` on all active threads from the file cache.
    /// Called at startup before the first live PR sync tick, so PR indicators appear immediately.
    func populatePRInfoFromCache() {
        loadPRCacheIfNeeded()
        guard !prCache.isEmpty else { return }

        var changed = false
        for i in store.threads.indices where !store.threads[i].isArchived && store.threads[i].pullRequestInfo == nil {
            let branch = store.threads[i].actualBranch ?? store.threads[i].branchName
            if let cached = prCache[branch] {
                store.threads[i].pullRequestInfo = cached.toPullRequestInfo()
                store.threads[i].pullRequestLookupStatus = .found
                changed = true
            }
        }
        if changed {
            Task { @MainActor in
                onThreadsChanged?()
                NotificationCenter.default.post(name: .magentPullRequestInfoChanged, object: nil)
            }
        }
    }

    private func savePRInfoToCache(info: PullRequestInfo?, thread: MagentThread) {
        loadPRCacheIfNeeded()
        let branch = thread.actualBranch ?? thread.branchName
        if let info {
            prCache[branch] = PullRequestCacheEntry(from: info)
        } else {
            prCache.removeValue(forKey: branch)
        }
        persistence.savePRCache(prCache)
    }

    private func prunePRCache() {
        loadPRCacheIfNeeded()
        let activeBranches = Set(
            store.threads
                .filter { !$0.isArchived }
                .map { $0.actualBranch ?? $0.branchName }
        )
        let before = prCache.count
        prCache = prCache.filter { activeBranches.contains($0.key) }
        if prCache.count != before {
            persistence.savePRCache(prCache)
        }
    }
}
