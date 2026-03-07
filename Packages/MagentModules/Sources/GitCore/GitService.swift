import Foundation
import ShellInfra
import MagentModels

public final class GitService: Sendable {

    public static let shared = GitService()

    // Normalize git diff/status path formats (especially rename syntax) to the
    // actual "new/current" path used by file operations and diff sections.
    private func normalizedStatusPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let range = trimmed.range(of: " -> ") {
            return String(trimmed[range.upperBound...])
        }
        return trimmed
    }

    private func normalizedNumstatPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Handles rename shapes like:
        // - "old/path => new/path"
        // - "src/{old.swift => new.swift}"
        // - "{old => new}/file.swift"
        if let openBrace = trimmed.firstIndex(of: "{"),
           let closeBrace = trimmed.lastIndex(of: "}"),
           openBrace < closeBrace {
            let insideStart = trimmed.index(after: openBrace)
            let inside = String(trimmed[insideStart..<closeBrace])
            if let arrow = inside.range(of: " => ") {
                let prefix = String(trimmed[..<openBrace])
                let suffixStart = trimmed.index(after: closeBrace)
                let suffix = String(trimmed[suffixStart...])
                let newSegment = String(inside[arrow.upperBound...])
                return prefix + newSegment + suffix
            }
        }

        if let range = trimmed.range(of: " => ") {
            return String(trimmed[range.upperBound...])
        }
        return trimmed
    }

    // MARK: - Worktree Operations

    public func createWorktree(repoPath: String, branchName: String, worktreePath: String, baseBranch: String? = nil) async throws -> URL {
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

    public func pruneWorktrees(repoPath: String) async {
        _ = await ShellExecutor.execute("git worktree prune", workingDirectory: repoPath)
    }

    public func addWorktreeForExistingBranch(repoPath: String, branchName: String, worktreePath: String) async throws -> URL {
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

    public func removeWorktree(repoPath: String, worktreePath: String) async throws {
        _ = try await ShellExecutor.run(
            "git worktree remove --force \(shellQuote(worktreePath))",
            workingDirectory: repoPath
        )
        _ = try await ShellExecutor.run(
            "git worktree prune",
            workingDirectory: repoPath
        )
    }

    public func listWorktrees(repoPath: String) async throws -> [WorktreeInfo] {
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

    public func moveWorktree(repoPath: String, oldPath: String, newPath: String) async throws {
        _ = try await ShellExecutor.run(
            "git worktree move \(shellQuote(oldPath)) \(shellQuote(newPath))",
            workingDirectory: repoPath
        )
    }

    public func renameBranch(repoPath: String, oldName: String, newName: String) async throws {
        _ = try await ShellExecutor.run(
            "git branch -m \(shellQuote(oldName)) \(shellQuote(newName))",
            workingDirectory: repoPath
        )
    }

    public func deleteBranch(repoPath: String, branchName: String) async throws {
        _ = try await ShellExecutor.run(
            "git branch -D \(shellQuote(branchName))",
            workingDirectory: repoPath
        )
    }

    public func branchExists(repoPath: String, branchName: String) async -> Bool {
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
    public func detectDefaultBranch(repoPath: String) async -> String? {
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

    public func getRemotes(repoPath: String) async -> [GitRemote] {
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

    // MARK: - Pull Request Detection

    private var _ghAvailable: Bool?
    private var _glabAvailable: Bool?

    public func fetchPullRequest(remote: GitRemote, branch: String) async -> PullRequestInfo? {
        switch remote.provider {
        case .github:   return await fetchGitHubPR(remote: remote, branch: branch)
        case .gitlab:   return await fetchGitLabMR(remote: remote, branch: branch)
        case .bitbucket, .unknown: return nil
        }
    }

    private func fetchGitHubPR(remote: GitRemote, branch: String) async -> PullRequestInfo? {
        if _ghAvailable == nil {
            let check = await ShellExecutor.execute("which gh")
            _ghAvailable = check.exitCode == 0
        }
        guard _ghAvailable == true else { return nil }

        let repo = "\(remote.host)/\(remote.repoPath)"
        let cmd = "gh pr list --repo \(ShellExecutor.shellQuote(repo)) --head \(ShellExecutor.shellQuote(branch)) --json number,url --state open --limit 1"
        let result = await ShellExecutor.execute(cmd)
        guard result.exitCode == 0 else { return nil }

        let data = Data(result.stdout.utf8)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let number = first["number"] as? Int,
              let urlString = first["url"] as? String,
              let url = URL(string: urlString) else { return nil }

        return PullRequestInfo(number: number, url: url, provider: remote.provider)
    }

    private func fetchGitLabMR(remote: GitRemote, branch: String) async -> PullRequestInfo? {
        if _glabAvailable == nil {
            let check = await ShellExecutor.execute("which glab")
            _glabAvailable = check.exitCode == 0
        }
        guard _glabAvailable == true else { return nil }

        let repo = "\(remote.host)/\(remote.repoPath)"
        let cmd = "glab mr list --repo \(ShellExecutor.shellQuote(repo)) --source-branch \(ShellExecutor.shellQuote(branch)) --output json --per-page 1"
        let result = await ShellExecutor.execute(cmd)
        guard result.exitCode == 0 else { return nil }

        let data = Data(result.stdout.utf8)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first,
              let number = first["iid"] as? Int else { return nil }

        let url = remote.directPullRequestURL(number: number)
            ?? URL(string: "https://\(remote.host)/\(remote.repoPath)/-/merge_requests/\(number)")!
        return PullRequestInfo(number: number, url: url, provider: remote.provider)
    }

    public func getCurrentBranch(workingDirectory: String) async -> String? {
        let result = await ShellExecutor.execute(
            "git rev-parse --abbrev-ref HEAD",
            workingDirectory: workingDirectory
        )
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !branch.isEmpty, branch != "HEAD" else { return nil }
        return branch
    }

    /// Returns `true` when the worktree has no uncommitted changes (untracked files are ignored).
    public func isClean(worktreePath: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "git status --porcelain -uno",
            workingDirectory: worktreePath
        )
        return result.exitCode == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns `true` when the branch has no commits beyond `baseBranch`.
    public func isMergedInto(worktreePath: String, baseBranch: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "git log \(shellQuote(baseBranch))..HEAD --oneline",
            workingDirectory: worktreePath
        )
        return result.exitCode == 0
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns `true` when the branch has commits beyond `baseBranch` and all of them
    /// have been merged or cherry-picked into `baseBranch`.
    ///
    /// When `forkPointCommit` is provided, it's used to distinguish "branch was merged"
    /// from "brand new branch with no commits" in the case where HEAD is an ancestor of baseBranch.
    public func isFullyDelivered(worktreePath: String, baseBranch: String, forkPointCommit: String? = nil) async -> Bool {
        let headTip = await ShellExecutor.execute("git rev-parse HEAD", workingDirectory: worktreePath)
        let head = headTip.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return false }

        // If we know the fork point, use it to short-circuit: no work done → not delivered.
        if let forkPoint = forkPointCommit, !forkPoint.isEmpty, head == forkPoint {
            return false
        }

        // Check if the branch has commits not reachable from baseBranch.
        let logResult = await ShellExecutor.execute(
            "git log \(shellQuote(baseBranch))..HEAD --oneline",
            workingDirectory: worktreePath
        )
        guard logResult.exitCode == 0 else { return false }
        let hasUnmergedCommits = !logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasUnmergedCommits {
            // Branch has commits not yet in baseBranch — check if they were cherry-picked
            let cherry = await ShellExecutor.execute(
                "git cherry \(shellQuote(baseBranch)) HEAD",
                workingDirectory: worktreePath
            )
            guard cherry.exitCode == 0 else { return false }
            let cherryOutput = cherry.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if cherryOutput.isEmpty { return false }
            return !cherryOutput.components(separatedBy: "\n").contains(where: { $0.hasPrefix("+") })
        }

        // baseBranch..HEAD is empty — branch was either merged or has no work.
        // If we have a fork point and got here, HEAD != forkPoint → branch was merged.
        if forkPointCommit != nil {
            return true
        }

        // No fork point (old thread) — two checks:

        // 1. FF-merged: HEAD is at baseBranch tip (or baseBranch has no commits beyond HEAD).
        //    This detects fast-forward merges where no merge commit exists.
        let aheadResult = await ShellExecutor.execute(
            "git log HEAD..\(shellQuote(baseBranch)) --oneline",
            workingDirectory: worktreePath
        )
        if aheadResult.exitCode == 0,
           aheadResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        // 2. Merge-commit: HEAD is a non-first parent of a merge commit on baseBranch.
        //    Only check 2nd+ parents (the merged branch tips), not the first parent
        //    (the main-line commit), to avoid false-positives when the branch was
        //    created from a commit that happens to be the main-side parent of a merge.
        let mergeCheck = await ShellExecutor.execute(
            "git log --merges --ancestry-path HEAD..\(shellQuote(baseBranch)) --format=%P",
            workingDirectory: worktreePath
        )
        guard mergeCheck.exitCode == 0 else { return false }
        let parentLines = mergeCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        for line in parentLines {
            let parents = line.components(separatedBy: " ")
            // Skip first parent (main-line); check 2nd+ parents (merged branches)
            if parents.dropFirst().contains(head) {
                return true
            }
        }
        return false
    }

    // MARK: - Merge Base, Commit Log & File Data

    /// Returns the merge-base commit hash between `baseBranch` and HEAD.
    public func mergeBase(worktreePath: String, baseBranch: String) async -> String? {
        let result = await ShellExecutor.execute(
            "git merge-base \(shellQuote(baseBranch)) HEAD",
            workingDirectory: worktreePath
        )
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !hash.isEmpty else { return nil }
        return hash
    }

    /// Returns commits on HEAD that are not reachable from `baseBranch`, ordered newest-first.
    func commitLog(worktreePath: String, baseBranch: String) async -> [BranchCommit] {
        let sep = "\u{1F}"  // unit separator unlikely to appear in commit messages
        let fmt = "%h\(sep)%s\(sep)%an\(sep)%ad"
        let result = await ShellExecutor.execute(
            "git log \(shellQuote(baseBranch))..HEAD --format=\(shellQuote(fmt)) --date=short",
            workingDirectory: worktreePath
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .compactMap { line -> BranchCommit? in
                let parts = line.components(separatedBy: sep)
                guard parts.count == 4 else { return nil }
                return BranchCommit(
                    shortHash: parts[0],
                    subject: parts[1],
                    authorName: parts[2],
                    date: parts[3]
                )
            }
    }

    /// Returns the raw file contents at a given git ref (commit, branch, tag).
    public func fileData(atRef ref: String, relativePath: String, worktreePath: String) async -> Data? {
        let result = await ShellExecutor.executeData(
            "git show \(shellQuote(ref)):\(shellQuote(relativePath))",
            workingDirectory: worktreePath
        )
        guard result.exitCode == 0, !result.stdoutData.isEmpty else { return nil }
        return result.stdoutData
    }

    // MARK: - Diff & Status

    /// Returns `true` when the worktree has any uncommitted changes or untracked files.
    public func isDirty(worktreePath: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "git status --porcelain",
            workingDirectory: worktreePath
        )
        return result.exitCode == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns per-file diff stats comparing the worktree to its base branch.
    public func diffStats(worktreePath: String, baseBranch: String) async -> [FileDiffEntry] {
        guard let mergeBase = await mergeBase(worktreePath: worktreePath, baseBranch: baseBranch) else { return [] }

        // Get numstat for all changes from merge-base to working tree (includes uncommitted)
        let numstatResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --numstat \(shellQuote(mergeBase))",
            workingDirectory: worktreePath
        )

        // Get working tree status for coloring
        let statusResult = await ShellExecutor.execute(
            "git -c core.quotePath=false status --porcelain",
            workingDirectory: worktreePath
        )

        // Parse status into a map: relativePath → FileWorkingStatus
        var statusMap: [String: FileWorkingStatus] = [:]
        if statusResult.exitCode == 0 {
            for line in statusResult.stdout.components(separatedBy: "\n") where line.count >= 3 {
                let indexChar = line[line.startIndex]
                let workChar = line[line.index(after: line.startIndex)]
                let path = normalizedStatusPath(String(line.dropFirst(3)))
                guard !path.isEmpty else { continue }

                if indexChar == "?" {
                    statusMap[path] = .untracked
                } else if workChar != " " && workChar != "?" {
                    statusMap[path] = .unstaged
                } else if indexChar != " " && indexChar != "?" {
                    statusMap[path] = .staged
                }
            }
        }

        // Parse numstat
        var entries: [FileDiffEntry] = []
        var seenPaths = Set<String>()
        if numstatResult.exitCode == 0 {
            for line in numstatResult.stdout.components(separatedBy: "\n") where !line.isEmpty {
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count >= 3 else { continue }
                let additions = Int(parts[0]) ?? 0
                let deletions = Int(parts[1]) ?? 0
                let filePath = normalizedNumstatPath(String(parts[2]))
                guard !filePath.isEmpty else { continue }

                seenPaths.insert(filePath)
                let status = statusMap[filePath] ?? .committed
                entries.append(FileDiffEntry(
                    relativePath: filePath,
                    additions: additions,
                    deletions: deletions,
                    workingStatus: status
                ))
            }
        }

        // Add untracked files not already in numstat
        for (path, status) in statusMap where status == .untracked && !seenPaths.contains(path) {
            entries.append(FileDiffEntry(
                relativePath: path,
                additions: 0,
                deletions: 0,
                workingStatus: .untracked
            ))
        }

        return entries
    }

    /// Returns the full unified diff output comparing the worktree to its base branch.
    public func diffContent(worktreePath: String, baseBranch: String) async -> String? {
        guard let mergeBase = await mergeBase(worktreePath: worktreePath, baseBranch: baseBranch) else { return nil }

        let diffResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --no-color \(shellQuote(mergeBase))",
            workingDirectory: worktreePath
        )
        guard diffResult.exitCode == 0 else { return nil }

        // Also get content of untracked files as pseudo-diffs
        let statusResult = await ShellExecutor.execute(
            "git -c core.quotePath=false status --porcelain",
            workingDirectory: worktreePath
        )
        var untrackedDiff = ""
        if statusResult.exitCode == 0 {
            for line in statusResult.stdout.components(separatedBy: "\n") where line.hasPrefix("?? ") {
                let path = String(line.dropFirst(3))
                guard !path.isEmpty, !path.hasSuffix("/") else { continue }
                let catResult = await ShellExecutor.execute(
                    "cat \(shellQuote(path))",
                    workingDirectory: worktreePath
                )
                if catResult.exitCode == 0 {
                    let lines = catResult.stdout.components(separatedBy: "\n")
                    untrackedDiff += "\ndiff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n"
                    for l in lines {
                        untrackedDiff += "+\(l)\n"
                    }
                }
            }
        }

        let combined = diffResult.stdout + untrackedDiff
        return combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : combined
    }

    /// Returns the unified diff for a single file comparing the worktree to its base branch.
    public func diffContentForFile(worktreePath: String, baseBranch: String, relativePath: String) async -> String? {
        guard let mergeBase = await mergeBase(worktreePath: worktreePath, baseBranch: baseBranch) else { return nil }

        let diffResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --no-color \(shellQuote(mergeBase)) -- \(shellQuote(relativePath))",
            workingDirectory: worktreePath
        )
        let output = diffResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if diffResult.exitCode == 0 && !output.isEmpty {
            return diffResult.stdout
        }

        // Check if it's an untracked file
        let statusResult = await ShellExecutor.execute(
            "git -c core.quotePath=false status --porcelain -- \(shellQuote(relativePath))",
            workingDirectory: worktreePath
        )
        if statusResult.exitCode == 0 && statusResult.stdout.hasPrefix("?? ") {
            let catResult = await ShellExecutor.execute(
                "cat \(shellQuote(relativePath))",
                workingDirectory: worktreePath
            )
            if catResult.exitCode == 0 {
                let lines = catResult.stdout.components(separatedBy: "\n")
                var result = "diff --git a/\(relativePath) b/\(relativePath)\nnew file mode 100644\n--- /dev/null\n+++ b/\(relativePath)\n@@ -0,0 +1,\(lines.count) @@\n"
                for l in lines {
                    result += "+\(l)\n"
                }
                return result
            }
        }

        return nil
    }

    public func checkoutBranch(workingDirectory: String, branchName: String) async throws {
        _ = try await ShellExecutor.run(
            "git checkout \(shellQuote(branchName))",
            workingDirectory: workingDirectory
        )
    }

    public func isGitRepository(at path: String) async -> Bool {
        do {
            _ = try await ShellExecutor.run("git rev-parse --git-dir", workingDirectory: path)
            return true
        } catch {
            return false
        }
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
