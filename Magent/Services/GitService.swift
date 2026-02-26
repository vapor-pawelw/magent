import Foundation

nonisolated struct WorktreeInfo: Sendable {
    let path: String
    let branch: String
    let isBareStem: Bool
}

final class GitService {

    static let shared = GitService()

    // MARK: - Worktree Operations

    func createWorktree(repoPath: String, branchName: String, worktreePath: String, baseBranch: String? = nil) async throws -> URL {
        let worktreeURL = URL(fileURLWithPath: worktreePath)

        // Create parent directory if needed
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Disable hooks during worktree creation — repos may have post-checkout
        // hooks (e.g. tuist generate, codegen) that fail in the new worktree context
        var cmd = "git -c core.hooksPath=/dev/null worktree add -b \(shellQuote(branchName)) \(shellQuote(worktreePath))"
        if let baseBranch {
            cmd += " \(shellQuote(baseBranch))"
        }
        let result = await ShellExecutor.execute(
            cmd,
            workingDirectory: repoPath
        )

        // Verify the worktree directory exists.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            throw GitError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await validateWorktreeCheckout(
            repoPath: repoPath,
            worktreePath: worktreePath,
            commandResult: result
        )

        return worktreeURL
    }

    func pruneWorktrees(repoPath: String) async {
        _ = await ShellExecutor.execute("git worktree prune", workingDirectory: repoPath)
    }

    func addWorktreeForExistingBranch(repoPath: String, branchName: String, worktreePath: String) async throws -> URL {
        let worktreeURL = URL(fileURLWithPath: worktreePath)

        // Create parent directory if needed
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let cmd = "git -c core.hooksPath=/dev/null worktree add \(shellQuote(worktreePath)) \(shellQuote(branchName))"
        let result = await ShellExecutor.execute(cmd, workingDirectory: repoPath)

        // Verify the worktree directory exists.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            throw GitError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try await validateWorktreeCheckout(
            repoPath: repoPath,
            worktreePath: worktreePath,
            commandResult: result
        )

        return worktreeURL
    }

    func removeWorktree(repoPath: String, worktreePath: String) async throws {
        _ = try await ShellExecutor.run(
            "git worktree remove --force \(shellQuote(worktreePath))",
            workingDirectory: repoPath
        )
        _ = try await ShellExecutor.run(
            "git worktree prune",
            workingDirectory: repoPath
        )
    }

    func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
        let output = try await ShellExecutor.run(
            "git worktree list --porcelain",
            workingDirectory: repoPath
        )

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isBare = false

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(path: path, branch: currentBranch ?? "", isBareStem: isBare))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
                isBare = false
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                currentBranch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" {
                isBare = true
            }
        }

        if let path = currentPath {
            worktrees.append(WorktreeInfo(path: path, branch: currentBranch ?? "", isBareStem: isBare))
        }

        return worktrees
    }

    func moveWorktree(repoPath: String, oldPath: String, newPath: String) async throws {
        _ = try await ShellExecutor.run(
            "git worktree move \(shellQuote(oldPath)) \(shellQuote(newPath))",
            workingDirectory: repoPath
        )
    }

    func renameBranch(repoPath: String, oldName: String, newName: String) async throws {
        _ = try await ShellExecutor.run(
            "git branch -m \(shellQuote(oldName)) \(shellQuote(newName))",
            workingDirectory: repoPath
        )
    }

    func deleteBranch(repoPath: String, branchName: String) async throws {
        _ = try await ShellExecutor.run(
            "git branch -D \(shellQuote(branchName))",
            workingDirectory: repoPath
        )
    }

    func branchExists(repoPath: String, branchName: String) async -> Bool {
        do {
            _ = try await ShellExecutor.run(
                "git rev-parse --verify \(shellQuote(branchName))",
                workingDirectory: repoPath
            )
            return true
        } catch {
            return false
        }
    }

    /// Detects the default branch via origin/HEAD, falling back to main/master existence check.
    func detectDefaultBranch(repoPath: String) async -> String? {
        // Try origin/HEAD (set during clone)
        let result = await ShellExecutor.execute(
            "git symbolic-ref refs/remotes/origin/HEAD",
            workingDirectory: repoPath
        )
        let ref = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0, !ref.isEmpty {
            return ref.replacingOccurrences(of: "refs/remotes/origin/", with: "")
        }

        // Fallback: check common branch names
        for candidate in ["main", "master", "develop"] {
            if await branchExists(repoPath: repoPath, branchName: candidate) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Remote Operations

    func getRemotes(repoPath: String) async -> [GitRemote] {
        let result = await ShellExecutor.execute(
            "git remote -v",
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else { return [] }

        var seen = Set<String>()
        var remotes: [GitRemote] = []
        for line in result.stdout.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            // Take the URL part (before " (fetch)" or " (push)")
            let urlPart = parts[1].split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            guard !urlPart.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            if let info = GitRemote.parse(name: name, rawURL: urlPart) {
                remotes.append(info)
            }
        }
        return remotes
    }

    func getCurrentBranch(workingDirectory: String) async -> String? {
        let result = await ShellExecutor.execute(
            "git rev-parse --abbrev-ref HEAD",
            workingDirectory: workingDirectory
        )
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !branch.isEmpty, branch != "HEAD" else { return nil }
        return branch
    }

    func isGitRepository(at path: String) async -> Bool {
        do {
            _ = try await ShellExecutor.run("git rev-parse --git-dir", workingDirectory: path)
            return true
        } catch {
            return false
        }
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Ensures worktree creation completed with a checked-out commit when the source repo has commits.
    private func validateWorktreeCheckout(
        repoPath: String,
        worktreePath: String,
        commandResult: ShellExecutor.Result
    ) async throws {
        let sourceHead = await ShellExecutor.execute(
            "git rev-parse --verify HEAD",
            workingDirectory: repoPath
        )

        // Source repo has no commits (unborn) — empty worktree is expected.
        guard sourceHead.exitCode == 0 else { return }

        let worktreeHead = await ShellExecutor.execute(
            "git rev-parse --verify HEAD",
            workingDirectory: worktreePath
        )

        if commandResult.exitCode == 0 && worktreeHead.exitCode == 0 {
            return
        }

        let message = commandResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            throw GitError.commandFailed(message)
        }
        let headError = worktreeHead.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitError.commandFailed(headError.isEmpty ? "Worktree checkout failed" : headError)
    }
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

// MARK: - Git Remote

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

    func pullRequestURL(for branch: String, defaultBranch: String?) -> URL? {
        // If on the default branch, just open the repo page
        if let defaultBranch, branch == defaultBranch {
            return repoWebURL
        }

        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch

        switch provider {
        case .github:
            return URL(string: "https://\(host)/\(repoPath)/pulls?q=is%3Apr+head%3A\(encodedBranch)")
        case .gitlab:
            return URL(string: "https://\(host)/\(repoPath)/-/merge_requests?source_branch=\(encodedBranch)")
        case .bitbucket:
            return URL(string: "https://\(host)/\(repoPath)/pull-requests?source=\(encodedBranch)")
        case .unknown:
            return repoWebURL
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
