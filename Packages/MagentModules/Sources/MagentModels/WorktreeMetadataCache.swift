import Foundation

public struct WorktreeMetadata: Codable {
    public var forkPointCommit: String?
    public var createdAt: Date?
    /// Detected remote base branch (e.g. "origin/develop"), cached per branch name.
    public var detectedBaseBranch: String?
    /// The branch name for which `detectedBaseBranch` was detected. Stale when current branch differs.
    public var detectedFor: String?

    public init(forkPointCommit: String? = nil, createdAt: Date? = nil, detectedBaseBranch: String? = nil, detectedFor: String? = nil) {
        self.forkPointCommit = forkPointCommit
        self.createdAt = createdAt
        self.detectedBaseBranch = detectedBaseBranch
        self.detectedFor = detectedFor
    }
}

public struct WorktreeMetadataCache: Codable {
    public var worktrees: [String: WorktreeMetadata]
    public var nameCounter: Int

    public init(worktrees: [String: WorktreeMetadata] = [:], nameCounter: Int = 0) {
        self.worktrees = worktrees
        self.nameCounter = nameCounter
    }
}
