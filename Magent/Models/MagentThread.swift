import Foundation

nonisolated struct MagentThread: Codable, Identifiable, Sendable {
    let id: UUID
    let projectId: UUID
    var name: String
    var worktreePath: String
    var branchName: String
    var tmuxSessionNames: [String]
    var agentTmuxSessions: [String]
    var pinnedTmuxSessions: [String]
    let createdAt: Date
    var isArchived: Bool
    var sectionId: UUID?
    var isMain: Bool
    var selectedAgentType: AgentType?
    var lastSelectedTmuxSessionName: String?

    init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        worktreePath: String,
        branchName: String,
        tmuxSessionNames: [String] = [],
        agentTmuxSessions: [String] = [],
        pinnedTmuxSessions: [String] = [],
        createdAt: Date = Date(),
        isArchived: Bool = false,
        sectionId: UUID? = nil,
        isMain: Bool = false,
        selectedAgentType: AgentType? = nil,
        lastSelectedTmuxSessionName: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.tmuxSessionNames = tmuxSessionNames
        self.agentTmuxSessions = agentTmuxSessions
        self.pinnedTmuxSessions = pinnedTmuxSessions
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.sectionId = sectionId
        self.isMain = isMain
        self.selectedAgentType = selectedAgentType
        self.lastSelectedTmuxSessionName = lastSelectedTmuxSessionName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        name = try container.decode(String.self, forKey: .name)
        worktreePath = try container.decode(String.self, forKey: .worktreePath)
        branchName = try container.decode(String.self, forKey: .branchName)
        tmuxSessionNames = try container.decode([String].self, forKey: .tmuxSessionNames)
        agentTmuxSessions = try container.decodeIfPresent([String].self, forKey: .agentTmuxSessions) ?? []
        pinnedTmuxSessions = try container.decodeIfPresent([String].self, forKey: .pinnedTmuxSessions) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        sectionId = try container.decodeIfPresent(UUID.self, forKey: .sectionId)
        isMain = try container.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        selectedAgentType = try container.decodeIfPresent(AgentType.self, forKey: .selectedAgentType)
        lastSelectedTmuxSessionName = try container.decodeIfPresent(String.self, forKey: .lastSelectedTmuxSessionName)
    }
}

extension MagentThread: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MagentThread, rhs: MagentThread) -> Bool {
        lhs.id == rhs.id
    }
}
