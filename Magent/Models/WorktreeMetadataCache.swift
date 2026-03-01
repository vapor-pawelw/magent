import Foundation

struct WorktreeMetadata: Codable {
    var forkPointCommit: String?
    var createdAt: Date?
}

struct WorktreeMetadataCache: Codable {
    var worktrees: [String: WorktreeMetadata]

    init(worktrees: [String: WorktreeMetadata] = [:]) {
        self.worktrees = worktrees
    }
}
