import Foundation
import MagentModels

// MARK: - Request

public nonisolated struct IPCRequest: Codable, Sendable {
    public let command: String
    public var project: String?
    public var agentType: String?
    public var modelId: String?
    public var reasoningLevel: String?
    public var prompt: String?
    public var title: String?
    /// URL for commands that open a web destination in a tab (for example, `create-web-tab`).
    public var url: String?
    public var threadId: String?
    public var threadName: String?
    public var tabIndex: Int?
    public var sessionName: String?
    public var newName: String?
    public var icon: String?
    public var description: String?
    /// Thread priority on a 1–5 scale (1 lowest, 5 highest). `0` clears the priority.
    public var priority: Int?
    public var baseThreadName: String?
    public var baseBranch: String?
    public var id: String?
    public var sectionName: String?
    public var sectionColor: String?
    public var position: Int?
    public var limit: Int?
    public var force: Bool?
    public var skipLocalSync: Bool?
    public var select: Bool?
    public var noSubmit: Bool?
    public var fresh: Bool?
    public var remove: Bool?
    public var threads: [IPCBatchThreadSpec]?
    /// Thread ID to inherit base branch and section from. Injected automatically by
    /// the CLI from `$MAGENT_THREAD_ID` unless `--from-thread none` is passed.
    public var fromThreadId: String?
    /// Thread name to inherit from (alternative to `fromThreadId`). Special values:
    /// `"main"` → project's main worktree thread; `"none"` → suppress auto-detection.
    public var fromThreadName: String?
}

/// Spec for a single thread inside a `batch-create` request.
public nonisolated struct IPCBatchThreadSpec: Codable, Sendable {
    public var agentType: String?
    public var modelId: String?
    public var reasoningLevel: String?
    public var prompt: String?
    /// Path to a file whose contents should be used as the initial prompt.
    /// Useful for long prompts that are fragile to inline in JSON strings.
    /// If both `prompt` and `promptFile` are provided, `promptFile` wins.
    public var promptFile: String?
    public var newName: String?
    public var description: String?
    public var sectionName: String?
    public var baseThreadName: String?
    public var baseBranch: String?
    public var noSubmit: Bool?
    /// Per-spec override: thread name to inherit base branch and section from.
    /// `"main"` → project's main thread; `"none"` → suppress auto-detection.
    public var fromThreadName: String?
    /// Per-spec thread priority on the 1–5 scale. `0` clears the priority.
    public var priority: Int?

    // The public JSON API uses "name" for the exact thread name; internally it's `newName`
    // to avoid shadowing the commonly used `name` property on response types.
    private enum CodingKeys: String, CodingKey {
        case agentType, modelId, reasoningLevel, prompt, promptFile
        case newName = "name"
        case description, sectionName, baseThreadName, baseBranch, noSubmit, fromThreadName, priority
    }
}

// MARK: - Response

public nonisolated struct IPCResponse: Encodable, Sendable {
    public let ok: Bool
    public var id: String?
    public var error: String?
    public var warning: String?
    public var thread: IPCThreadInfo?
    public var threads: [IPCThreadInfo]?
    public var projects: [IPCProjectInfo]?
    public var tabs: [IPCTabInfo]?
    public var tab: IPCTabInfo?
    public var sections: [IPCSectionInfo]?
    public var section: IPCSectionInfo?
    public var activeAgents: [String]?

    public init(
        ok: Bool,
        id: String? = nil,
        error: String? = nil,
        warning: String? = nil,
        thread: IPCThreadInfo? = nil,
        threads: [IPCThreadInfo]? = nil,
        projects: [IPCProjectInfo]? = nil,
        tabs: [IPCTabInfo]? = nil,
        tab: IPCTabInfo? = nil,
        sections: [IPCSectionInfo]? = nil,
        section: IPCSectionInfo? = nil,
        activeAgents: [String]? = nil
    ) {
        self.ok = ok
        self.id = id
        self.error = error
        self.warning = warning
        self.thread = thread
        self.threads = threads
        self.projects = projects
        self.tabs = tabs
        self.tab = tab
        self.sections = sections
        self.section = section
        self.activeAgents = activeAgents
    }

    public static func success(id: String? = nil, warning: String? = nil) -> IPCResponse {
        IPCResponse(ok: true, id: id, warning: warning)
    }

    public static func failure(_ error: String, id: String? = nil) -> IPCResponse {
        IPCResponse(ok: false, id: id, error: error)
    }
}

// MARK: - DTOs

public nonisolated struct IPCThreadStatus: Encodable, Sendable {
    public let isBusy: Bool
    public let isWaitingForInput: Bool
    public let hasUnreadCompletion: Bool
    public let isDirty: Bool
    public let isFullyDelivered: Bool
    public let showArchiveSuggestion: Bool
    public let isPinned: Bool
    public let isFavorite: Bool
    public let isSidebarHidden: Bool
    public let isArchived: Bool
    public let isBlockedByRateLimit: Bool
    public let hasBranchMismatch: Bool
    public let jiraTicketKey: String?
    public let jiraUnassigned: Bool
    public let branchName: String
    public let baseBranch: String?
    public let rateLimitDescription: String?

    public init(
        isBusy: Bool,
        isWaitingForInput: Bool,
        hasUnreadCompletion: Bool,
        isDirty: Bool,
        isFullyDelivered: Bool,
        showArchiveSuggestion: Bool,
        isPinned: Bool,
        isFavorite: Bool,
        isSidebarHidden: Bool,
        isArchived: Bool,
        isBlockedByRateLimit: Bool,
        hasBranchMismatch: Bool,
        jiraTicketKey: String?,
        jiraUnassigned: Bool,
        branchName: String,
        baseBranch: String?,
        rateLimitDescription: String?
    ) {
        self.isBusy = isBusy
        self.isWaitingForInput = isWaitingForInput
        self.hasUnreadCompletion = hasUnreadCompletion
        self.isDirty = isDirty
        self.isFullyDelivered = isFullyDelivered
        self.showArchiveSuggestion = showArchiveSuggestion
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.isSidebarHidden = isSidebarHidden
        self.isArchived = isArchived
        self.isBlockedByRateLimit = isBlockedByRateLimit
        self.hasBranchMismatch = hasBranchMismatch
        self.jiraTicketKey = jiraTicketKey
        self.jiraUnassigned = jiraUnassigned
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.rateLimitDescription = rateLimitDescription
    }
}

public nonisolated struct IPCThreadInfo: Encodable, Sendable {
    public let id: String
    public let name: String
    public let projectName: String
    public let worktreePath: String
    public let tmuxSession: String
    public let isMain: Bool
    public let taskDescription: String?
    public var sectionName: String?
    public var sectionId: String?
    public var tabs: [IPCTabInfo]?
    public var status: IPCThreadStatus?
    public var agentType: String?
    public var baseBranch: String?
    public var prLabel: String?
    public var prStatusText: String?
    public var jiraTicketKey: String?
    public var branchName: String?
    public var archivedAt: String?
    public var createdAt: String?
    /// Last path component of `worktreePath` — the on-disk worktree directory name.
    public var worktreeName: String?
    public var isFavorite: Bool?
    public var isPinned: Bool?
    public var isSidebarHidden: Bool?
    public var priority: Int?
    public var signEmoji: String?
    public var threadIcon: String?

    public init(thread: MagentThread, projectName: String, baseBranch: String? = nil) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.isMain = thread.isMain
        self.taskDescription = thread.taskDescription
        self.baseBranch = baseBranch
    }

    public init(thread: MagentThread, projectName: String, sectionName: String?, tabs: [IPCTabInfo], status: IPCThreadStatus? = nil) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.isMain = thread.isMain
        self.taskDescription = thread.taskDescription
        self.sectionName = sectionName
        self.sectionId = thread.sectionId?.uuidString
        self.tabs = tabs
        self.status = status
    }
}

public nonisolated struct IPCProjectInfo: Encodable, Sendable {
    public let name: String
    public let repoPath: String

    public init(project: Project) {
        self.name = project.name
        self.repoPath = project.repoPath
    }
}

public nonisolated struct IPCTabInfo: Encodable, Sendable {
    public let index: Int
    public let sessionName: String
    public var displayName: String?
    public let isAgent: Bool
    public var agentType: String?
    public var isBusy: Bool?
    public var isWaitingForInput: Bool?
    public var hasUnreadCompletion: Bool?
    public var isBlockedByRateLimit: Bool?

    public init(index: Int, sessionName: String, isAgent: Bool) {
        self.index = index
        self.sessionName = sessionName
        self.displayName = nil
        self.isAgent = isAgent
    }
}

public nonisolated struct IPCSectionInfo: Encodable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String
    public let sortOrder: Int
    public let isDefault: Bool
    public let isVisible: Bool
    public let isKeepAlive: Bool
    public let isProjectOverride: Bool
    public var threads: [IPCThreadInfo]?

    public init(section: ThreadSection, isProjectOverride: Bool, threads: [IPCThreadInfo]? = nil) {
        self.id = section.id.uuidString
        self.name = section.name
        self.colorHex = section.colorHex
        self.sortOrder = section.sortOrder
        self.isDefault = section.isDefault
        self.isVisible = section.isVisible
        self.isKeepAlive = section.isKeepAlive
        self.isProjectOverride = isProjectOverride
        self.threads = threads
    }
}
