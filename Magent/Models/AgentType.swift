import Foundation

enum AgentType: String, Codable, CaseIterable {
    case claude = "claude"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .custom: return "Custom"
        }
    }

    /// Whether this agent type supports the /resume command for restoring conversations.
    var supportsResume: Bool {
        self == .claude
    }
}
