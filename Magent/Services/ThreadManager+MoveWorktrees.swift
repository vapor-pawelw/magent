import Foundation
import MagentCore

// MARK: - Forwarding layer — logic lives in WorktreeService

extension ThreadManager {

    func moveWorktreesBasePath(for project: Project, from oldBase: String, to newBase: String) async throws {
        try await worktreeService.moveWorktreesBasePath(for: project, from: oldBase, to: newBase)
    }
}
