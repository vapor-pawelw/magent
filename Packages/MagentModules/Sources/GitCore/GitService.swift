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
        let quotedRepo = ShellExecutor.shellQuote(repo)
        let quotedBranch = ShellExecutor.shellQuote(branch)

        let fields = "number,url,isDraft,state,reviewDecision,baseRefName"

        // Prefer open PRs; fall back to all states (merged/closed) if none found.
        for state in ["open", "all"] {
            let cmd = "gh pr list --repo \(quotedRepo) --head \(quotedBranch) --json \(fields) --state \(state) --sort created --limit 1"
            let result = await ShellExecutor.execute(cmd)
            guard result.exitCode == 0 else { continue }

            let data = Data(result.stdout.utf8)
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = array.first,
                  let number = first["number"] as? Int,
                  let urlString = first["url"] as? String,
                  let url = URL(string: urlString) else { continue }

            let prState = first["state"] as? String ?? "OPEN"
            let isDraft = first["isDraft"] as? Bool ?? false
            let reviewDecision = (first["reviewDecision"] as? String).flatMap { ReviewDecision(rawValue: $0) }
            let baseRefName = first["baseRefName"] as? String
            return PullRequestInfo(
                number: number,
                url: url,
                provider: remote.provider,
                isMerged: prState == "MERGED",
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                isClosed: prState == "CLOSED",
                baseBranch: baseRefName
            )
        }
        return nil
    }

    private func fetchGitLabMR(remote: GitRemote, branch: String) async -> PullRequestInfo? {
        if _glabAvailable == nil {
            let check = await ShellExecutor.execute("which glab")
            _glabAvailable = check.exitCode == 0
        }
        guard _glabAvailable == true else { return nil }

        let repo = "\(remote.host)/\(remote.repoPath)"
        let quotedRepo = ShellExecutor.shellQuote(repo)
        let quotedBranch = ShellExecutor.shellQuote(branch)

        // Prefer open MRs; fall back to all states if none found.
        for mrState in ["opened", "all"] {
            let flag = mrState == "all" ? "--all" : "--state \(mrState)"
            let cmd = "glab mr list --repo \(quotedRepo) --source-branch \(quotedBranch) \(flag) --sort created_at --output json --per-page 1"
            let result = await ShellExecutor.execute(cmd)
            guard result.exitCode == 0 else { continue }

            let data = Data(result.stdout.utf8)
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = array.first,
                  let number = first["iid"] as? Int else { continue }

            let url = remote.directPullRequestURL(number: number)
                ?? URL(string: "https://\(remote.host)/\(remote.repoPath)/-/merge_requests/\(number)")!

            let state = first["state"] as? String ?? "opened"
            let isDraft = first["draft"] as? Bool ?? false

            // GitLab exposes approved_by as an array of approvers
            let approvedBy = first["approved_by"] as? [[String: Any]]
            let reviewDecision: ReviewDecision? = if let approvedBy, !approvedBy.isEmpty { .approved } else { nil }
            let targetBranch = first["target_branch"] as? String

            return PullRequestInfo(
                number: number,
                url: url,
                provider: remote.provider,
                isMerged: state == "merged",
                isDraft: isDraft,
                reviewDecision: reviewDecision,
                isClosed: state == "closed",
                baseBranch: targetBranch
            )
        }
        return nil
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

    /// Returns the current HEAD commit hash, or `nil` on failure.
    public func currentCommit(worktreePath: String) async -> String? {
        let result = await ShellExecutor.execute("git rev-parse HEAD", workingDirectory: worktreePath)
        let hash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !hash.isEmpty else { return nil }
        return hash
    }

    /// Detects the remote base branch for the current HEAD by walking commit history and
    /// returning the closest remote ancestor branch (e.g. "origin/develop").
    /// Excludes the current branch's own remote tracking ref.
    /// Returns `nil` if no remote ancestor is found.
    public func detectBaseBranch(worktreePath: String, currentBranch: String) async -> String? {
        // Walk decorated commit history — git finds the nearest ancestor commit that has a
        // remote ref. Much faster than per-commit shell loops since git does the walk itself.
        let result = await ShellExecutor.execute(
            "git log --decorate=full --simplify-by-decoration --format='%D' HEAD",
            workingDirectory: worktreePath
        )
        guard result.exitCode == 0 else { return nil }
        let lines = result.stdout.components(separatedBy: "\n")
        let excluded = "refs/remotes/origin/\(currentBranch)"
        for line in lines {
            let refs = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for ref in refs {
                guard ref.hasPrefix("refs/remotes/origin/"),
                      ref != "refs/remotes/origin/HEAD",
                      ref != excluded else { continue }
                return String(ref.dropFirst("refs/remotes/".count)) // e.g. "origin/develop"
            }
        }

        // Fallback: when origin/main (or origin/master) diverged, the decorated walk
        // won't find it. Check common default branches via merge-base.
        for candidate in ["main", "master"] where candidate != currentBranch {
            let mb = await mergeBase(worktreePath: worktreePath, baseBranch: candidate)
            if mb != nil { return "origin/\(candidate)" }
        }
        return nil
    }

    /// Returns remote ancestor branches between the default branch and HEAD,
    /// ordered by proximity to HEAD (closest first). Only includes branches
    /// whose tips are within the merge-base..HEAD range, plus the default branch itself.
    public func listAncestorBranches(worktreePath: String, currentBranch: String, defaultBranch: String? = nil) async -> [String] {
        let base = defaultBranch ?? "main"
        guard let mergeBaseHash = await mergeBase(worktreePath: worktreePath, baseBranch: base) else {
            return ["origin/\(base)"]
        }

        // Only walk commits between merge-base and HEAD
        let result = await ShellExecutor.execute(
            "git log --decorate=full --simplify-by-decoration --format='%D' \(shellQuote(mergeBaseHash))..HEAD",
            workingDirectory: worktreePath
        )

        let excluded = "refs/remotes/origin/\(currentBranch)"
        var seen = Set<String>()
        var branches: [String] = []

        if result.exitCode == 0 {
            let lines = result.stdout.components(separatedBy: "\n")
            for line in lines {
                let refs = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for ref in refs {
                    guard ref.hasPrefix("refs/remotes/origin/"),
                          ref != "refs/remotes/origin/HEAD",
                          ref != excluded else { continue }
                    let name = String(ref.dropFirst("refs/remotes/".count))
                    if seen.insert(name).inserted {
                        branches.append(name)
                    }
                }
            }
        }

        // Always include the default branch as the last option
        let defaultRef = "origin/\(base)"
        if !seen.contains(defaultRef) {
            branches.append(defaultRef)
        }
        return branches
    }

    /// Returns local branch names sorted by most-recent committer date (descending).
    public func listBranchesByDate(repoPath: String) async -> [String] {
        let result = await ShellExecutor.execute(
            "git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads/",
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Returns all remote branch names (with `origin/` prefix stripped) sorted by most-recent committer date.
    public func listRemoteBranchesByDate(repoPath: String) async -> [String] {
        let result = await ShellExecutor.execute(
            "git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/remotes/origin/",
            workingDirectory: repoPath
        )
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "origin/HEAD" }
    }

    /// Returns `true` when all commits on HEAD are present in `baseBranch` (via merge,
    /// fast-forward, or cherry-pick). Callers must guard against fresh/empty branches using
    /// `MagentThread.hasEverDoneWork` before calling this — an empty `baseBranch..HEAD` log
    /// on a never-touched branch would also return `true`.
    public func isFullyDelivered(worktreePath: String, baseBranch: String) async -> Bool {
        // Check if the branch has commits not reachable from baseBranch.
        let logResult = await ShellExecutor.execute(
            "git log \(shellQuote(baseBranch))..HEAD --oneline",
            workingDirectory: worktreePath
        )
        guard logResult.exitCode == 0 else { return false }
        let hasUnmergedCommits = !logResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasUnmergedCommits {
            // Branch has commits not yet in baseBranch — check if they were cherry-picked.
            let cherry = await ShellExecutor.execute(
                "git cherry \(shellQuote(baseBranch)) HEAD",
                workingDirectory: worktreePath
            )
            guard cherry.exitCode == 0 else { return false }
            let cherryOutput = cherry.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if cherryOutput.isEmpty { return false }
            return !cherryOutput.components(separatedBy: "\n").contains(where: { $0.hasPrefix("+") })
        }

        // baseBranch..HEAD is empty — base has everything HEAD has (FF, merge, or fresh).
        // The caller's hasEverDoneWork guard distinguishes "merged" from "never touched".
        return true
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

    private func parseCommitLog(_ output: String, separator: String) -> [BranchCommit] {
        output
            .components(separatedBy: "\n")
            .compactMap { line -> BranchCommit? in
                let parts = line.components(separatedBy: separator)
                guard parts.count == 4 else { return nil }
                return BranchCommit(
                    shortHash: parts[0],
                    subject: parts[1],
                    authorName: parts[2],
                    date: parts[3]
                )
            }
    }

    /// Returns commits on HEAD that are not reachable from `baseBranch`, ordered newest-first.
    public func commitLog(
        worktreePath: String,
        baseBranch: String,
        limit: Int? = nil,
        skip: Int = 0
    ) async -> [BranchCommit] {
        let sep = "\u{1F}"  // unit separator unlikely to appear in commit messages
        let fmt = "%h\(sep)%s\(sep)%an\(sep)%ad"
        var command = "git log \(shellQuote(baseBranch))..HEAD --format=\(shellQuote(fmt)) --date=short"
        if skip > 0 {
            command += " --skip=\(skip)"
        }
        if let limit {
            command += " -n \(max(0, limit))"
        }
        let result = await ShellExecutor.execute(
            command,
            workingDirectory: worktreePath
        )
        guard result.exitCode == 0 else { return [] }
        return parseCommitLog(result.stdout, separator: sep)
    }

    /// Returns the most recent commits on `HEAD`, ordered newest-first.
    public func recentCommitLog(
        worktreePath: String,
        limit: Int,
        skip: Int = 0
    ) async -> [BranchCommit] {
        let sep = "\u{1F}"
        let fmt = "%h\(sep)%s\(sep)%an\(sep)%ad"
        var command = "git log HEAD --format=\(shellQuote(fmt)) --date=short -n \(max(0, limit))"
        if skip > 0 {
            command += " --skip=\(skip)"
        }
        let result = await ShellExecutor.execute(
            command,
            workingDirectory: worktreePath
        )
        guard result.exitCode == 0 else { return [] }
        return parseCommitLog(result.stdout, separator: sep)
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

    private func parseStatusMap(_ output: String) -> [String: FileWorkingStatus] {
        // Get working tree status for coloring
        var statusMap: [String: FileWorkingStatus] = [:]
        for line in output.components(separatedBy: "\n") where line.count >= 3 {
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
        return statusMap
    }

    private func parseDiffEntries(
        numstatOutput: String,
        statusMap: [String: FileWorkingStatus]
    ) -> [FileDiffEntry] {
        var entries: [FileDiffEntry] = []
        var seenPaths = Set<String>()
        for line in numstatOutput.components(separatedBy: "\n") where !line.isEmpty {
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

        // Add untracked files not already in numstat
        for (path, status) in statusMap where status == .untracked && !seenPaths.contains(path) {
            entries.append(FileDiffEntry(
                relativePath: path,
                additions: 0,
                deletions: 0,
                workingStatus: .untracked
            ))
        }

        entries.sort {
            if $0.workingStatus.sortOrder != $1.workingStatus.sortOrder {
                return $0.workingStatus.sortOrder < $1.workingStatus.sortOrder
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return entries
    }

    /// Returns per-file diff stats comparing the worktree to its base branch.
    public func diffStats(worktreePath: String, baseBranch: String) async -> [FileDiffEntry] {
        guard let mergeBase = await mergeBase(worktreePath: worktreePath, baseBranch: baseBranch) else { return [] }

        // Get numstat for all changes from merge-base to working tree (includes uncommitted)
        let numstatResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --numstat \(shellQuote(mergeBase))",
            workingDirectory: worktreePath
        )

        let statusResult = await ShellExecutor.execute(
            "git -c core.quotePath=false status --porcelain",
            workingDirectory: worktreePath
        )

        guard numstatResult.exitCode == 0 || statusResult.exitCode == 0 else { return [] }
        let statusMap = statusResult.exitCode == 0 ? parseStatusMap(statusResult.stdout) : [:]
        let numstatOutput = numstatResult.exitCode == 0 ? numstatResult.stdout : ""
        return parseDiffEntries(numstatOutput: numstatOutput, statusMap: statusMap)
    }

    /// Returns per-file diff stats for working tree changes only, relative to `HEAD`.
    public func workingTreeDiffStats(worktreePath: String) async -> [FileDiffEntry] {
        let numstatResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --numstat HEAD",
            workingDirectory: worktreePath
        )

        let statusResult = await ShellExecutor.execute(
            "git -c core.quotePath=false status --porcelain",
            workingDirectory: worktreePath
        )

        guard numstatResult.exitCode == 0 || statusResult.exitCode == 0 else { return [] }
        let statusMap = statusResult.exitCode == 0 ? parseStatusMap(statusResult.stdout) : [:]
        let numstatOutput = numstatResult.exitCode == 0 ? numstatResult.stdout : ""
        return parseDiffEntries(numstatOutput: numstatOutput, statusMap: statusMap)
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

    /// Returns the full unified diff output for working tree changes only, relative to `HEAD`.
    public func workingTreeDiffContent(worktreePath: String) async -> String? {
        let diffResult = await ShellExecutor.execute(
            "git -c core.quotePath=false diff --no-color HEAD",
            workingDirectory: worktreePath
        )
        guard diffResult.exitCode == 0 else { return nil }

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

    /// Returns per-file diff stats for a single commit (files changed in that commit).
    public func commitDiffStats(worktreePath: String, commitHash: String) async -> [FileDiffEntry] {
        let numstatResult = await ShellExecutor.execute(
            "git -c core.quotePath=false show --numstat --format= \(shellQuote(commitHash))",
            workingDirectory: worktreePath
        )
        guard numstatResult.exitCode == 0 else { return [] }
        // All files in a commit are "committed" status
        return parseDiffEntries(numstatOutput: numstatResult.stdout, statusMap: [:])
    }

    /// Stages a file (or directory) in the working tree.
    public func stageFile(worktreePath: String, relativePath: String) async {
        _ = await ShellExecutor.execute(
            "git add \(shellQuote(relativePath))",
            workingDirectory: worktreePath
        )
    }

    /// Unstages a file (or directory) from the index, keeping working tree changes.
    public func unstageFile(worktreePath: String, relativePath: String) async {
        _ = await ShellExecutor.execute(
            "git restore --staged \(shellQuote(relativePath))",
            workingDirectory: worktreePath
        )
    }

    /// Returns the full unified diff output for a single commit.
    public func commitDiffContent(worktreePath: String, commitHash: String) async -> String? {
        let diffResult = await ShellExecutor.execute(
            "git -c core.quotePath=false show --no-color \(shellQuote(commitHash))",
            workingDirectory: worktreePath
        )
        guard diffResult.exitCode == 0 else { return nil }
        let output = diffResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : diffResult.stdout
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
