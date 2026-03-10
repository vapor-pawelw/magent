import Foundation
import MagentModels

// MARK: - Request

public nonisolated struct IPCRequest: Codable, Sendable {
    public let command: String
    public var project: String?
    public var agentType: String?
    public var prompt: String?
    public var threadId: String?
    public var threadName: String?
    public var tabIndex: Int?
    public var sessionName: String?
    public var newName: String?
    public var icon: String?
    public var description: String?
    public var baseThreadName: String?
    public var baseBranch: String?
    public var id: String?
    public var sectionName: String?
    public var sectionColor: String?
    public var position: Int?
    public var force: Bool?
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
    public let agentType: String?
    public let isMain: Bool
    public let taskDescription: String?
    public var sectionName: String?
    public var sectionId: String?
    public var tabs: [IPCTabInfo]?
    public var status: IPCThreadStatus?

    public init(thread: MagentThread, projectName: String) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.agentType = thread.effectiveAgentType?.rawValue
        self.isMain = thread.isMain
        self.taskDescription = thread.taskDescription
    }

    public init(thread: MagentThread, projectName: String, sectionName: String?, tabs: [IPCTabInfo], status: IPCThreadStatus? = nil) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.agentType = thread.effectiveAgentType?.rawValue
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
    public let isAgent: Bool
    public let agentType: String?

    public init(index: Int, sessionName: String, isAgent: Bool, agentType: String?) {
        self.index = index
        self.sessionName = sessionName
        self.isAgent = isAgent
        self.agentType = agentType
    }
}

public nonisolated struct IPCSectionInfo: Encodable, Sendable {
    public let id: String
    public let name: String
    public let colorHex: String
    public let sortOrder: Int
    public let isDefault: Bool
    public let isVisible: Bool
    public let isProjectOverride: Bool
    public var threads: [IPCThreadInfo]?

    public init(section: ThreadSection, isProjectOverride: Bool, threads: [IPCThreadInfo]? = nil) {
        self.id = section.id.uuidString
        self.name = section.name
        self.colorHex = section.colorHex
        self.sortOrder = section.sortOrder
        self.isDefault = section.isDefault
        self.isVisible = section.isVisible
        self.isProjectOverride = isProjectOverride
        self.threads = threads
    }
}
