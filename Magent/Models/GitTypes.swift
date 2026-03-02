import Foundation

nonisolated struct WorktreeInfo: Sendable {
    let path: String
    let branch: String
    let isBareStem: Bool
}

enum GitError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "Git error: \(message)"
        }
    }
}

nonisolated enum GitHostingProvider: Sendable {
    case github
    case gitlab
    case bitbucket
    case unknown
}

nonisolated struct GitRemote: Sendable {
    let name: String
    let host: String
    let repoPath: String  // e.g. "owner/repo"
    let provider: GitHostingProvider

    var repoWebURL: URL? {
        URL(string: "https://\(host)/\(repoPath)")
    }

    /// URL to the open pull/merge requests listing page.
    var openPullRequestsURL: URL? {
        switch provider {
        case .github:
            return URL(string: "https://\(host)/\(repoPath)/pulls?q=is%3Aopen+is%3Apr")
        case .gitlab:
            return URL(string: "https://\(host)/\(repoPath)/-/merge_requests?state=opened")
        case .bitbucket:
            return URL(string: "https://\(host)/\(repoPath)/pull-requests?state=OPEN")
        case .unknown:
            return repoWebURL
        }
    }

    func pullRequestURL(for branch: String, defaultBranch: String?) -> URL? {
        // If on the default branch, show the open PRs listing
        if let defaultBranch, branch == defaultBranch {
            return openPullRequestsURL
        }

        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch

        switch provider {
        case .github:
            return URL(string: "https://\(host)/\(repoPath)/pulls?q=is%3Aopen+is%3Apr+head%3A\(encodedBranch)")
        case .gitlab:
            return URL(string: "https://\(host)/\(repoPath)/-/merge_requests?state=opened&source_branch=\(encodedBranch)")
        case .bitbucket:
            return URL(string: "https://\(host)/\(repoPath)/pull-requests?state=OPEN&source=\(encodedBranch)")
        case .unknown:
            return openPullRequestsURL
        }
    }

    static func parse(name: String, rawURL: String) -> GitRemote? {
        let (host, repoPath) = parseRemoteURL(rawURL)
        guard let host, let repoPath else { return nil }
        let provider = detectProvider(host: host)
        return GitRemote(name: name, host: host, repoPath: repoPath, provider: provider)
    }

    private static func detectProvider(host: String) -> GitHostingProvider {
        let lower = host.lowercased()
        if lower.contains("github") { return .github }
        if lower.contains("gitlab") { return .gitlab }
        if lower.contains("bitbucket") { return .bitbucket }
        return .unknown
    }

    /// Parses git remote URLs in various formats:
    /// - `git@host:owner/repo.git`
    /// - `https://host/owner/repo.git`
    /// - `ssh://git@host/owner/repo.git`
    /// - `ssh://git@host:port/owner/repo.git`
    private static func parseRemoteURL(_ url: String) -> (host: String?, repoPath: String?) {
        var url = url

        // SSH shorthand: git@host:owner/repo.git
        if let atIndex = url.firstIndex(of: "@"),
           let colonIndex = url.firstIndex(of: ":"),
           colonIndex > atIndex,
           !url.hasPrefix("ssh://"),
           !url.hasPrefix("http") {
            let host = String(url[url.index(after: atIndex)..<colonIndex])
            var path = String(url[url.index(after: colonIndex)...])
            path = stripGitSuffix(path)
            return (host, path)
        }

        // URL-based: https://, ssh://, git://
        // Strip scheme
        if let schemeEnd = url.range(of: "://") {
            url = String(url[schemeEnd.upperBound...])
        }

        // Strip user@ prefix
        if let atIndex = url.firstIndex(of: "@") {
            url = String(url[url.index(after: atIndex)...])
        }

        // Split host (possibly with port) from path
        guard let slashIndex = url.firstIndex(of: "/") else { return (nil, nil) }
        var host = String(url[url.startIndex..<slashIndex])
        // Strip port from host
        if let colonIndex = host.firstIndex(of: ":") {
            host = String(host[host.startIndex..<colonIndex])
        }
        var path = String(url[url.index(after: slashIndex)...])
        path = stripGitSuffix(path)

        guard !host.isEmpty, !path.isEmpty else { return (nil, nil) }
        return (host, path)
    }

    private static func stripGitSuffix(_ path: String) -> String {
        if path.hasSuffix(".git") {
            return String(path.dropLast(4))
        }
        return path
    }
}

// MARK: - Diff Types

nonisolated enum FileWorkingStatus: Sendable {
    case committed   // only in committed diff, working tree clean
    case staged      // staged changes
    case unstaged    // unstaged modifications
    case untracked   // untracked file
}

nonisolated struct FileDiffEntry: Sendable {
    let relativePath: String
    let additions: Int
    let deletions: Int
    let workingStatus: FileWorkingStatus
}
