import Foundation

struct Project: Codable, Identifiable, Hashable {
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

    /// Suggests a default worktrees base path: `<parent>/<name>-worktrees/`
    static func suggestedWorktreesPath(for repoPath: String) -> String {
        let url = URL(fileURLWithPath: repoPath)
        let parent = url.deletingLastPathComponent().path
        let name = url.lastPathComponent
        return "\(parent)/\(name)-worktrees"
    }
}
