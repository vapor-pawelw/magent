import Foundation

nonisolated struct Project: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var repoPath: String
    var worktreesBasePath: String
    var defaultBranch: String?
    var agentType: AgentType?
    var terminalInjectionCommand: String?
    var agentContextInjection: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        worktreesBasePath: String,
        defaultBranch: String? = nil,
        agentType: AgentType? = nil,
        terminalInjectionCommand: String? = nil,
        agentContextInjection: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.worktreesBasePath = worktreesBasePath
        self.defaultBranch = defaultBranch
        self.agentType = agentType
        self.terminalInjectionCommand = terminalInjectionCommand
        self.agentContextInjection = agentContextInjection
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        worktreesBasePath = try container.decode(String.self, forKey: .worktreesBasePath)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType)
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand)
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    /// Resolves template variables in `worktreesBasePath` (e.g. `$MAGENT_PROJECT_NAME`).
    func resolvedWorktreesBasePath() -> String {
        worktreesBasePath.replacingOccurrences(of: "$MAGENT_PROJECT_NAME", with: name)
    }

    /// Whether the repo path still points to an existing directory.
    var isValid: Bool {
        FileManager.default.fileExists(atPath: repoPath)
    }

    /// Suggests a default worktrees base path using the `$MAGENT_PROJECT_NAME` template variable.
    static func suggestedWorktreesPath(for repoPath: String) -> String {
        let url = URL(fileURLWithPath: repoPath)
        let parent = url.deletingLastPathComponent().path
        return "\(parent)/.worktrees-$MAGENT_PROJECT_NAME"
    }
}
