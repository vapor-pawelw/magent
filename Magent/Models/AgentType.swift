import Foundation

nonisolated enum AgentType: String, Codable, CaseIterable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .custom: return "Custom"
        }
    }

    /// Whether this agent type supports the /resume command for restoring conversations.
    var supportsResume: Bool {
        self == .claude
    }
}
