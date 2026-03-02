import Foundation

struct WorktreeMetadata: Codable {
    var forkPointCommit: String?
    var createdAt: Date?
}

struct WorktreeMetadataCache: Codable {
    var worktrees: [String: WorktreeMetadata]
    var nameCounter: Int

    init(worktrees: [String: WorktreeMetadata] = [:], nameCounter: Int = 0) {
        self.worktrees = worktrees
        self.nameCounter = nameCounter
    }
}
