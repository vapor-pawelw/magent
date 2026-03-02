import Foundation

nonisolated struct AgentRateLimitInfo: Hashable, Sendable {
    var resetAt: Date
    var resetDescription: String?
    var detectedAt: Date
}

nonisolated struct PullRequestInfo: Sendable, Equatable {
    let number: Int
    let url: URL
    let provider: GitHostingProvider

    var displayLabel: String {
        provider == .gitlab ? "MR !\(number)" : "PR #\(number)"
    }
    var shortLabel: String {
        provider == .gitlab ? "!\(number)" : "#\(number)"
    }
}

nonisolated struct MagentThread: Codable, Identifiable, Sendable {
    let id: UUID
    let projectId: UUID
    var name: String
    var worktreePath: String
    var branchName: String
    var tmuxSessionNames: [String]
    var agentTmuxSessions: [String]
    var sessionAgentTypes: [String: AgentType]
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
    var jiraTicketKey: String?

    // Transient (not persisted) — tracks which agent sessions are currently working
    var busySessions: Set<String> = []
    // Transient (not persisted) — tracks which agent sessions are waiting for user input
    var waitingForInputSessions: Set<String> = []
    // Transient (not persisted) — tracks whether worktree has uncommitted/untracked changes
    var isDirty: Bool = false
    // Transient (not persisted) — tracks whether all commits are in the base branch
    var isFullyDelivered: Bool = false
    // Transient (not persisted) — tracks whether Jira ticket is no longer assigned to user
    var jiraUnassigned: Bool = false
    // Transient (not persisted) — current HEAD branch from git
    var actualBranch: String? = nil
    // Transient (not persisted) — expected branch (detected or from branchName)
    var expectedBranch: String? = nil
    // Transient (not persisted) — whether actual branch != expected branch
    var hasBranchMismatch: Bool = false
    // Transient (not persisted) — tracks agent rate limit status per session.
    var rateLimitedSessions: [String: AgentRateLimitInfo] = [:]
    // Transient (not persisted) — detected open PR/MR for this branch.
    var pullRequestInfo: PullRequestInfo? = nil

    /// Resolves the effective section ID for this thread given a set of known section IDs.
    /// If the thread's sectionId is recognized, returns it; otherwise returns the fallback.
    func resolvedSectionId(knownSectionIds: Set<UUID>, fallback: UUID?) -> UUID? {
        if let sid = sectionId, knownSectionIds.contains(sid) {
            return sid
        }
        return fallback
    }

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

    /// True only when every tab in the thread currently reports an active rate-limit message.
    /// This intentionally hides the blocked icon if any tab is terminal or has unknown state.
    var isBlockedByRateLimit: Bool {
        guard !agentTmuxSessions.isEmpty else { return false }
        return agentTmuxSessions.allSatisfy { rateLimitedSessions[$0] != nil }
    }

    /// When all tabs are rate-limited, the thread is effectively unblocked at the latest reset time.
    var rateLimitLiftAt: Date? {
        guard isBlockedByRateLimit else { return nil }
        return agentTmuxSessions.compactMap { rateLimitedSessions[$0]?.resetAt }.max()
    }

    var rateLimitLiftDescription: String? {
        guard let latest = rateLimitLiftAt else { return nil }
        return "Resets \(latest.formatted(date: .abbreviated, time: .shortened))"
    }

    func displayName(for sessionName: String, at index: Int) -> String {
        if let custom = customTabNames[sessionName], !custom.isEmpty {
            return custom
        }
        return Self.defaultDisplayName(at: index)
    }

    static func defaultDisplayName(at index: Int) -> String {
        "Tab \(index)"
    }

    enum CodingKeys: String, CodingKey {
        case id, projectId, name, worktreePath, branchName
        case tmuxSessionNames, agentTmuxSessions, sessionAgentTypes, pinnedTmuxSessions
        case createdAt, isArchived, sectionId, isMain
        case selectedAgentType, lastSelectedTmuxSessionName
        case agentHasRun, isPinned, lastAgentCompletionAt
        case unreadCompletionSessions
        case hasUnreadAgentCompletion // migration only
        case didAutoRenameFromFirstPrompt
        case customTabNames
        case baseBranch
        case displayOrder
        case jiraTicketKey
    }

    init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        worktreePath: String,
        branchName: String,
        tmuxSessionNames: [String] = [],
        agentTmuxSessions: [String] = [],
        sessionAgentTypes: [String: AgentType] = [:],
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
        displayOrder: Int = 0,
        jiraTicketKey: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.tmuxSessionNames = tmuxSessionNames
        self.agentTmuxSessions = agentTmuxSessions
        self.sessionAgentTypes = sessionAgentTypes
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
        self.jiraTicketKey = jiraTicketKey
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
        sessionAgentTypes = try container.decodeIfPresent([String: AgentType].self, forKey: .sessionAgentTypes) ?? [:]
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
        jiraTicketKey = try container.decodeIfPresent(String.self, forKey: .jiraTicketKey)

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
        if !sessionAgentTypes.isEmpty {
            try container.encode(sessionAgentTypes, forKey: .sessionAgentTypes)
        }
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
        try container.encodeIfPresent(jiraTicketKey, forKey: .jiraTicketKey)
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
