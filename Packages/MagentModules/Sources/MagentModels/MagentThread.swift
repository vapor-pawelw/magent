import Foundation

public nonisolated enum ThreadIcon: String, CaseIterable, Codable, Sendable {
    case feature
    case fix
    case improvement
    case refactor
    case test
    case other

    public var symbolName: String {
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

    public var menuTitle: String {
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

    public var accessibilityDescription: String {
        "\(menuTitle) thread"
    }
}

public nonisolated struct AgentRateLimitInfo: Hashable, Sendable {
    public var resetAt: Date
    public var resetDescription: String?
    public var detectedAt: Date
    /// True for markers set from the interactive rate-limit prompt (e.g. "Stop and
    /// wait for limit to reset"). These are managed by syncBusySessionsFromProcessState
    /// and should not be cleared by checkForRateLimitedSessions.
    public var isPromptBased: Bool = false

    public init(
        resetAt: Date,
        resetDescription: String? = nil,
        detectedAt: Date,
        isPromptBased: Bool = false
    ) {
        self.resetAt = resetAt
        self.resetDescription = resetDescription
        self.detectedAt = detectedAt
        self.isPromptBased = isPromptBased
    }
}

public nonisolated struct PullRequestInfo: Sendable, Equatable {
    public let number: Int
    public let url: URL
    public let provider: GitHostingProvider

    public init(number: Int, url: URL, provider: GitHostingProvider) {
        self.number = number
        self.url = url
        self.provider = provider
    }

    public var displayLabel: String {
        provider == .gitlab ? "MR !\(number)" : "PR #\(number)"
    }
    public var shortLabel: String {
        provider == .gitlab ? "!\(number)" : "#\(number)"
    }
}

public nonisolated enum ThreadSidebarListState: Int, CaseIterable, Sendable {
    case pinned = 0
    case visible = 1
    case hidden = 2
}

public nonisolated struct MagentThread: Codable, Identifiable, Sendable {
    public let id: UUID
    public let projectId: UUID
    public var name: String
    public var worktreePath: String
    public var branchName: String
    public var tmuxSessionNames: [String]
    public var agentTmuxSessions: [String]
    public var sessionConversationIDs: [String: String]
    public var sessionAgentTypes: [String: AgentType]
    public var pinnedTmuxSessions: [String]
    public let createdAt: Date
    public var isArchived: Bool
    public var archivedAt: Date?
    public var sectionId: UUID?
    public var isMain: Bool
    public var lastSelectedTmuxSessionName: String?
    public var agentHasRun: Bool
    public var isPinned: Bool
    public var isSidebarHidden: Bool
    public var lastAgentCompletionAt: Date?
    public var unreadCompletionSessions: Set<String>
    public var didAutoRenameFromFirstPrompt: Bool
    public var customTabNames: [String: String]
    public var baseBranch: String?
    public var displayOrder: Int
    public var jiraTicketKey: String?
    public var taskDescription: String?
    public var threadIcon: ThreadIcon
    public var isThreadIconManuallySet: Bool
    /// Persisted per-session history of TOC-confirmed prompts (newest at end).
    public var submittedPromptsBySession: [String: [String]]
    /// Snapshot of project local sync paths taken when the thread was created.
    /// `nil` means the thread predates path snapshotting and should fall back to
    /// current project settings during archive.
    public var localFileSyncPathsSnapshot: [String]?
    /// Persisted flag — set the first time this thread's worktree becomes dirty or has commits
    /// ahead of its base branch on any branch. Used to guard archive suggestions so a brand-new,
    /// untouched worktree is never suggested for archiving.
    public var hasEverDoneWork: Bool

    // MARK: - Computed

    /// The last path component of `worktreePath`, used as the key in per-project worktree caches.
    public var worktreeKey: String {
        (worktreePath as NSString).lastPathComponent
    }

    /// The currently checked-out branch name; prefers the live-detected value over the persisted one.
    public var currentBranch: String {
        actualBranch ?? branchName
    }

    // Transient (not persisted) — tracks which agent sessions are currently working
    public var busySessions: Set<String> = []
    // Transient (not persisted) — tracks which agent sessions are waiting for user input
    public var waitingForInputSessions: Set<String> = []
    // Transient (not persisted) — tracks whether worktree has uncommitted/untracked changes
    public var isDirty: Bool = false
    // Transient (not persisted) — tracks whether all commits are in the base branch
    public var isFullyDelivered: Bool = false
    // Transient (not persisted) — tracks whether Jira ticket is no longer assigned to user
    public var jiraUnassigned: Bool = false
    // Transient (not persisted) — current HEAD branch from git
    public var actualBranch: String? = nil
    // Transient (not persisted) — expected branch (detected or from branchName)
    public var expectedBranch: String? = nil
    // Transient (not persisted) — whether actual branch != expected branch
    public var hasBranchMismatch: Bool = false
    // Transient (not persisted) — tracks agent rate limit status per session.
    public var rateLimitedSessions: [String: AgentRateLimitInfo] = [:]
    // Transient (not persisted) — detected open PR/MR for this branch.
    public var pullRequestInfo: PullRequestInfo? = nil

    /// Resolves the effective section ID for this thread given a set of known section IDs.
    /// If the thread's sectionId is recognized, returns it; otherwise returns the fallback.
    public func resolvedSectionId(knownSectionIds: Set<UUID>, fallback: UUID?) -> UUID? {
        if let sid = sectionId, knownSectionIds.contains(sid) {
            return sid
        }
        return fallback
    }

    public var hasUnreadAgentCompletion: Bool {
        !unreadCompletionSessions.isEmpty
    }

    public var sidebarListState: ThreadSidebarListState {
        if isPinned {
            return .pinned
        }
        if isSidebarHidden {
            return .hidden
        }
        return .visible
    }

    public var hasAgentBusy: Bool {
        !busySessions.isEmpty
    }

    public var hasWaitingForInput: Bool {
        !waitingForInputSessions.isEmpty
    }

    public var showArchiveSuggestion: Bool {
        hasEverDoneWork && isFullyDelivered && !isDirty && !hasAgentBusy && !hasWaitingForInput
    }

    /// True only when every tab in the thread currently reports an active rate-limit message.
    /// This intentionally hides the blocked icon if any tab is terminal or has unknown state.
    public var isBlockedByRateLimit: Bool {
        guard !agentTmuxSessions.isEmpty else { return false }
        return agentTmuxSessions.allSatisfy { rateLimitedSessions[$0] != nil }
    }

    /// When all tabs are rate-limited, the thread is effectively unblocked at the latest reset time.
    /// Prompt-based markers (no concrete reset time) are excluded from the computation.
    public var rateLimitLiftAt: Date? {
        guard isBlockedByRateLimit else { return nil }
        return agentTmuxSessions.compactMap { session -> Date? in
            guard let info = rateLimitedSessions[session], !info.isPromptBased else { return nil }
            return info.resetAt
        }.max()
    }

    public var rateLimitLiftDescription: String? {
        guard let latest = rateLimitLiftAt else { return nil }
        return "Resets \(latest.formatted(date: .abbreviated, time: .shortened))"
    }

    /// True when the thread is technically rate-limited but the concrete reset time has already passed,
    /// meaning the user can resume the agent without waiting.
    public var isRateLimitExpiredAndResumable: Bool {
        guard isBlockedByRateLimit else { return false }
        guard let liftAt = rateLimitLiftAt else { return false }
        return liftAt <= Date()
    }

    public func displayName(for sessionName: String, at index: Int) -> String {
        if let custom = customTabNames[sessionName], !custom.isEmpty {
            return custom
        }
        return Self.defaultDisplayName(at: index)
    }

    public static func defaultDisplayName(at index: Int) -> String {
        "Tab \(index)"
    }

    public enum CodingKeys: String, CodingKey {
        case id, projectId, name, worktreePath, branchName
        case tmuxSessionNames, agentTmuxSessions, sessionConversationIDs, sessionAgentTypes, pinnedTmuxSessions
        case createdAt, isArchived, archivedAt, sectionId, isMain
        case lastSelectedTmuxSessionName
        case agentHasRun, isPinned, isSidebarHidden, lastAgentCompletionAt
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
        case hasEverDoneWork
    }

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        worktreePath: String,
        branchName: String,
        tmuxSessionNames: [String] = [],
        agentTmuxSessions: [String] = [],
        sessionConversationIDs: [String: String] = [:],
        sessionAgentTypes: [String: AgentType] = [:],
        pinnedTmuxSessions: [String] = [],
        createdAt: Date = Date(),
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        sectionId: UUID? = nil,
        isMain: Bool = false,
        lastSelectedTmuxSessionName: String? = nil,
        agentHasRun: Bool = false,
        isPinned: Bool = false,
        isSidebarHidden: Bool = false,
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
        localFileSyncPathsSnapshot: [String]? = nil,
        hasEverDoneWork: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.tmuxSessionNames = tmuxSessionNames
        self.agentTmuxSessions = agentTmuxSessions
        self.sessionConversationIDs = sessionConversationIDs
        self.sessionAgentTypes = sessionAgentTypes
        self.pinnedTmuxSessions = pinnedTmuxSessions
        self.createdAt = createdAt
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.sectionId = sectionId
        self.isMain = isMain
        self.lastSelectedTmuxSessionName = lastSelectedTmuxSessionName
        self.agentHasRun = agentHasRun
        self.isPinned = isPinned
        self.isSidebarHidden = isSidebarHidden
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
        self.hasEverDoneWork = hasEverDoneWork
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        name = try container.decode(String.self, forKey: .name)
        worktreePath = try container.decode(String.self, forKey: .worktreePath)
        branchName = try container.decode(String.self, forKey: .branchName)
        tmuxSessionNames = try container.decode([String].self, forKey: .tmuxSessionNames)
        agentTmuxSessions = try container.decodeIfPresent([String].self, forKey: .agentTmuxSessions) ?? []
        sessionConversationIDs = try container.decodeIfPresent([String: String].self, forKey: .sessionConversationIDs) ?? [:]
        sessionAgentTypes = try container.decodeIfPresent([String: AgentType].self, forKey: .sessionAgentTypes) ?? [:]
        pinnedTmuxSessions = try container.decodeIfPresent([String].self, forKey: .pinnedTmuxSessions) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isArchived = try container.decode(Bool.self, forKey: .isArchived)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        sectionId = try container.decodeIfPresent(UUID.self, forKey: .sectionId)
        isMain = try container.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        lastSelectedTmuxSessionName = try container.decodeIfPresent(String.self, forKey: .lastSelectedTmuxSessionName)
        agentHasRun = try container.decodeIfPresent(Bool.self, forKey: .agentHasRun) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isSidebarHidden = try container.decodeIfPresent(Bool.self, forKey: .isSidebarHidden) ?? false
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
        hasEverDoneWork = try container.decodeIfPresent(Bool.self, forKey: .hasEverDoneWork) ?? false

        // Decode new set, or migrate from old boolean
        if let sessions = try container.decodeIfPresent(Set<String>.self, forKey: .unreadCompletionSessions) {
            unreadCompletionSessions = sessions
        } else {
            let oldBool = try container.decodeIfPresent(Bool.self, forKey: .hasUnreadAgentCompletion) ?? false
            unreadCompletionSessions = oldBool ? Set(agentTmuxSessions) : []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(name, forKey: .name)
        try container.encode(worktreePath, forKey: .worktreePath)
        try container.encode(branchName, forKey: .branchName)
        try container.encode(tmuxSessionNames, forKey: .tmuxSessionNames)
        try container.encode(agentTmuxSessions, forKey: .agentTmuxSessions)
        if !sessionConversationIDs.isEmpty {
            try container.encode(sessionConversationIDs, forKey: .sessionConversationIDs)
        }
        if !sessionAgentTypes.isEmpty {
            try container.encode(sessionAgentTypes, forKey: .sessionAgentTypes)
        }
        try container.encode(pinnedTmuxSessions, forKey: .pinnedTmuxSessions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encodeIfPresent(sectionId, forKey: .sectionId)
        try container.encode(isMain, forKey: .isMain)
        try container.encodeIfPresent(lastSelectedTmuxSessionName, forKey: .lastSelectedTmuxSessionName)
        try container.encode(agentHasRun, forKey: .agentHasRun)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isSidebarHidden, forKey: .isSidebarHidden)
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
        if hasEverDoneWork {
            try container.encode(hasEverDoneWork, forKey: .hasEverDoneWork)
        }
    }
}

extension MagentThread: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: MagentThread, rhs: MagentThread) -> Bool {
        lhs.id == rhs.id
    }
}
