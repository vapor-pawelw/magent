import Foundation

nonisolated enum ThreadIcon: String, CaseIterable, Codable, Sendable {
    case feature
    case fix
    case improvement
    case refactor
    case test
    case other

    var symbolName: String {
        switch self {
        case .feature:
            return "star.fill"
        case .fix:
            return "ladybug.fill"
        case .improvement:
            return "arrow.up.circle.fill"
        case .refactor:
            return "arrow.triangle.branch"
        case .test:
            return "checkmark.seal.fill"
        case .other:
            return "square.grid.2x2.fill"
        }
    }

    var menuTitle: String {
        switch self {
        case .feature:
            return "Feature"
        case .fix:
            return "Fix"
        case .improvement:
            return "Improvement"
        case .refactor:
            return "Refactor"
        case .test:
            return "Test"
        case .other:
            return "Other"
        }
    }

    var accessibilityDescription: String {
        "\(menuTitle) thread"
    }
}

nonisolated struct AgentRateLimitInfo: Hashable, Sendable {
    var resetAt: Date
    var resetDescription: String?
    var detectedAt: Date
    /// True for markers set from the interactive rate-limit prompt (e.g. "Stop and
    /// wait for limit to reset"). These are managed by syncBusySessionsFromProcessState
    /// and should not be cleared by checkForRateLimitedSessions.
    var isPromptBased: Bool = false
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
    var sessionConversationIDs: [String: String]
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
    var taskDescription: String?
    var threadIcon: ThreadIcon
    var isThreadIconManuallySet: Bool
    /// Persisted per-session history of TOC-confirmed prompts (newest at end).
    var submittedPromptsBySession: [String: [String]]
    /// Snapshot of project local sync paths taken when the thread was created.
    /// `nil` means the thread predates path snapshotting and should fall back to
    /// current project settings during archive.
    var localFileSyncPathsSnapshot: [String]?

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
    /// Prompt-based markers (no concrete reset time) are excluded from the computation.
    var rateLimitLiftAt: Date? {
        guard isBlockedByRateLimit else { return nil }
        return agentTmuxSessions.compactMap { session -> Date? in
            guard let info = rateLimitedSessions[session], !info.isPromptBased else { return nil }
            return info.resetAt
        }.max()
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
        case tmuxSessionNames, agentTmuxSessions, sessionAgentTypes, sessionConversationIDs, pinnedTmuxSessions
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
        case taskDescription
        case threadIcon
        case isThreadIconManuallySet
        case submittedPromptsBySession
        case localFileSyncPathsSnapshot
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
        sessionConversationIDs: [String: String] = [:],
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
        jiraTicketKey: String? = nil,
        taskDescription: String? = nil,
        threadIcon: ThreadIcon = .other,
        isThreadIconManuallySet: Bool = false,
        submittedPromptsBySession: [String: [String]] = [:],
        localFileSyncPathsSnapshot: [String]? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.tmuxSessionNames = tmuxSessionNames
        self.agentTmuxSessions = agentTmuxSessions
        self.sessionAgentTypes = sessionAgentTypes
        self.sessionConversationIDs = sessionConversationIDs
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
        self.taskDescription = taskDescription
        self.threadIcon = threadIcon
        self.isThreadIconManuallySet = isThreadIconManuallySet
        self.submittedPromptsBySession = submittedPromptsBySession
        self.localFileSyncPathsSnapshot = localFileSyncPathsSnapshot
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
        sessionConversationIDs = try container.decodeIfPresent([String: String].self, forKey: .sessionConversationIDs) ?? [:]
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
        taskDescription = try container.decodeIfPresent(String.self, forKey: .taskDescription)
        threadIcon = try container.decodeIfPresent(ThreadIcon.self, forKey: .threadIcon) ?? .other
        isThreadIconManuallySet = try container.decodeIfPresent(Bool.self, forKey: .isThreadIconManuallySet)
            ?? (threadIcon != .other)
        submittedPromptsBySession = try container.decodeIfPresent([String: [String]].self, forKey: .submittedPromptsBySession) ?? [:]
        localFileSyncPathsSnapshot = try container.decodeIfPresent([String].self, forKey: .localFileSyncPathsSnapshot)

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
        if !sessionConversationIDs.isEmpty {
            try container.encode(sessionConversationIDs, forKey: .sessionConversationIDs)
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
        try container.encodeIfPresent(taskDescription, forKey: .taskDescription)
        try container.encode(threadIcon, forKey: .threadIcon)
        try container.encode(isThreadIconManuallySet, forKey: .isThreadIconManuallySet)
        if !submittedPromptsBySession.isEmpty {
            try container.encode(submittedPromptsBySession, forKey: .submittedPromptsBySession)
        }
        try container.encodeIfPresent(localFileSyncPathsSnapshot, forKey: .localFileSyncPathsSnapshot)
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
