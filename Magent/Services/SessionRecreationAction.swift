import Foundation

// MARK: - SessionRecreationAction

enum SessionRecreationAction {
    case recreateMissingAgentSession
    case recreateMismatchedAgentSession
    case recreateMissingTerminalSession
    case recreateMismatchedTerminalSession

    var loadingOverlayDetail: String {
        switch self {
        case .recreateMissingAgentSession:
            return "Recovering a missing tmux session and restoring the saved agent conversation."
        case .recreateMismatchedAgentSession:
            return "Replacing a stale tmux session that points at the wrong worktree, then restoring the saved conversation."
        case .recreateMissingTerminalSession:
            return "Recovering a missing tmux session for this tab."
        case .recreateMismatchedTerminalSession:
            return "Replacing a stale tmux session that points at the wrong worktree."
        }
    }
}
