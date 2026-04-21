import Foundation

enum ThreadManagerError: LocalizedError {
    case threadNotFound
    case invalidName
    case invalidPrompt
    case invalidDescription
    case duplicateName
    case invalidTabIndex
    case cannotDeleteMainThread
    case cannotRenameMainThread
    case nameGenerationFailed(diagnostic: String?)
    case worktreePathConflict([String])
    case noExpectedBranch
    case archiveCancelled
    /// Refused to archive because the worktree has uncommitted/untracked changes.
    case dirtyWorktree(worktreePath: String)
    case localFileSyncFailed(String)
    /// Signal case thrown by the inner conflict handler; carries no data.
    /// The sync entry points catch this and rethrow `.agenticMergeReady` with full context.
    case agenticMergeSignal
    case agenticMergeReady(LocalSyncAgenticMergeContext)

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "Thread not found"
        case .invalidName:
            return "Invalid name. Name must not be empty or contain slashes."
        case .invalidPrompt:
            return "Prompt must not be empty."
        case .invalidDescription:
            return "Invalid description. Use 1-8 words with at least one letter."
        case .duplicateName:
            return "A thread with that name already exists."
        case .invalidTabIndex:
            return "Invalid tab index."
        case .cannotDeleteMainThread:
            return "Main threads cannot be deleted."
        case .cannotRenameMainThread:
            return "Main threads cannot be renamed."
        case .nameGenerationFailed(let diagnostic):
            let base = "Could not generate a thread name."
            if let diagnostic, !diagnostic.isEmpty {
                return "\(base) \(diagnostic)"
            }
            return "\(base) Ensure Claude or Codex is configured and reachable, then try again."
        case .worktreePathConflict(let names):
            let list = names.joined(separator: ", ")
            return "Cannot move worktrees — the following directories already exist in the destination: \(list)"
        case .noExpectedBranch:
            return "No expected branch configured. Set the default branch in project settings."
        case .archiveCancelled:
            return "Archive cancelled."
        case .dirtyWorktree(let worktreePath):
            return "Worktree has uncommitted or untracked changes at \(worktreePath). Commit/stash/discard first. CLI --force does not bypass dirty-worktree safety."
        case .localFileSyncFailed(let message):
            return message
        case .agenticMergeSignal:
            return "Agentic merge requested."
        case .agenticMergeReady:
            return "Agentic merge requested."
        }
    }
}

/// Describes the intent for an agent-driven local sync operation.
enum LocalSyncAgenticOperation: Sendable {
    case syncSourceToDestination
    case reconcileBothWays
}

/// Context passed when the user chooses agent-driven local sync handling.
/// Carries all the information needed to construct an agent prompt for the sync operation.
struct LocalSyncAgenticMergeContext: Sendable {
    let operation: LocalSyncAgenticOperation
    let sourceRoot: String
    let destinationRoot: String
    let syncPaths: [String]
    /// Human-readable label for the source (e.g. "Project" or worktree name)
    let sourceLabel: String
    /// Human-readable label for the destination
    let destinationLabel: String
}
