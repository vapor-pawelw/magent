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
    var agentHasRun: Bool
    var isPinned: Bool
    var lastAgentCompletionAt: Date?
    var unreadCompletionSessions: Set<String>
    var didAutoRenameFromFirstPrompt: Bool
    var customTabNames: [String: String]
    var baseBranch: String?
    var displayOrder: Int

    // Transient (not persisted) — tracks which agent sessions are currently working
    var busySessions: Set<String> = []
    // Transient (not persisted) — tracks which agent sessions are waiting for user input
    var waitingForInputSessions: Set<String> = []
    // Transient (not persisted) — tracks whether worktree has uncommitted/untracked changes
    var isDirty: Bool = false
    // Transient (not persisted) — tracks whether all commits are in the base branch
    var isFullyDelivered: Bool = false

    var hasUnreadAgentCompletion: Bool {
        !unreadCompletionSessions.isEmpty
    }

    var hasAgentBusy: Bool {
        !busySessions.isEmpty
    }

    var hasWaitingForInput: Bool {
        !waitingForInputSessions.isEmpty
    }

    var showArchiveSuggestion: Bool {
        isFullyDelivered && !isDirty && !hasAgentBusy && !hasWaitingForInput
    }

    func displayName(for sessionName: String, at index: Int) -> String {
        if let custom = customTabNames[sessionName], !custom.isEmpty {
            return custom
        }
        return Self.defaultDisplayName(at: index)
    }

    static func defaultDisplayName(at index: Int) -> String {
        index == 0 ? "Main" : "Tab \(index)"
    }

    enum CodingKeys: String, CodingKey {
        case id, projectId, name, worktreePath, branchName
        case tmuxSessionNames, agentTmuxSessions, pinnedTmuxSessions
        case createdAt, isArchived, sectionId, isMain
        case selectedAgentType, lastSelectedTmuxSessionName
        case agentHasRun, isPinned, lastAgentCompletionAt
        case unreadCompletionSessions
        case hasUnreadAgentCompletion // migration only
        case didAutoRenameFromFirstPrompt
        case customTabNames
        case baseBranch
        case displayOrder
    }

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
        lastSelectedTmuxSessionName: String? = nil,
        agentHasRun: Bool = false,
        isPinned: Bool = false,
        lastAgentCompletionAt: Date? = nil,
        unreadCompletionSessions: Set<String> = [],
        didAutoRenameFromFirstPrompt: Bool = false,
        customTabNames: [String: String] = [:],
        baseBranch: String? = nil,
        displayOrder: Int = 0
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
        self.agentHasRun = agentHasRun
        self.isPinned = isPinned
        self.lastAgentCompletionAt = lastAgentCompletionAt
        self.unreadCompletionSessions = unreadCompletionSessions
        self.didAutoRenameFromFirstPrompt = didAutoRenameFromFirstPrompt
        self.customTabNames = customTabNames
        self.baseBranch = baseBranch
        self.displayOrder = displayOrder
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
        agentHasRun = try container.decodeIfPresent(Bool.self, forKey: .agentHasRun) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        lastAgentCompletionAt = try container.decodeIfPresent(Date.self, forKey: .lastAgentCompletionAt)
        didAutoRenameFromFirstPrompt = try container.decodeIfPresent(Bool.self, forKey: .didAutoRenameFromFirstPrompt) ?? false
        customTabNames = try container.decodeIfPresent([String: String].self, forKey: .customTabNames) ?? [:]
        baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        displayOrder = try container.decodeIfPresent(Int.self, forKey: .displayOrder) ?? 0

        // Decode new set, or migrate from old boolean
        if let sessions = try container.decodeIfPresent(Set<String>.self, forKey: .unreadCompletionSessions) {
            unreadCompletionSessions = sessions
        } else {
            let oldBool = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadAgentCompletion) ?? false
            unreadCompletionSessions = oldBool ? Set(agentTmuxSessions) : []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(name, forKey: .name)
        try container.encode(worktreePath, forKey: .worktreePath)
        try container.encode(branchName, forKey: .branchName)
        try container.encode(tmuxSessionNames, forKey: .tmuxSessionNames)
        try container.encode(agentTmuxSessions, forKey: .agentTmuxSessions)
        try container.encode(pinnedTmuxSessions, forKey: .pinnedTmuxSessions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(sectionId, forKey: .sectionId)
        try container.encode(isMain, forKey: .isMain)
        try container.encodeIfPresent(selectedAgentType, forKey: .selectedAgentType)
        try container.encodeIfPresent(lastSelectedTmuxSessionName, forKey: .lastSelectedTmuxSessionName)
        try container.encode(agentHasRun, forKey: .agentHasRun)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(lastAgentCompletionAt, forKey: .lastAgentCompletionAt)
        try container.encode(unreadCompletionSessions, forKey: .unreadCompletionSessions)
        try container.encode(didAutoRenameFromFirstPrompt, forKey: .didAutoRenameFromFirstPrompt)
        if !customTabNames.isEmpty {
            try container.encode(customTabNames, forKey: .customTabNames)
        }
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try container.encode(displayOrder, forKey: .displayOrder)
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
