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

    init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        worktreesBasePath: String,
        defaultBranch: String? = nil,
        agentType: AgentType? = nil,
        terminalInjectionCommand: String? = nil,
        agentContextInjection: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.worktreesBasePath = worktreesBasePath
        self.defaultBranch = defaultBranch
        self.agentType = agentType
        self.terminalInjectionCommand = terminalInjectionCommand
        self.agentContextInjection = agentContextInjection
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
