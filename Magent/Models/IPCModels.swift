import Foundation

// MARK: - Request

nonisolated struct IPCRequest: Codable, Sendable {
    let command: String
    var project: String?
    var agentType: String?
    var prompt: String?
    var threadId: String?
    var threadName: String?
    var tabIndex: Int?
    var sessionName: String?
    var newName: String?
    var description: String?
    var id: String?
    var sectionName: String?
    var sectionColor: String?
    var position: Int?
}

// MARK: - Response

nonisolated struct IPCResponse: Encodable, Sendable {
    let ok: Bool
    var id: String?
    var error: String?
    var thread: IPCThreadInfo?
    var threads: [IPCThreadInfo]?
    var projects: [IPCProjectInfo]?
    var tabs: [IPCTabInfo]?
    var tab: IPCTabInfo?
    var sections: [IPCSectionInfo]?
    var section: IPCSectionInfo?

    static func success(id: String? = nil) -> IPCResponse {
        IPCResponse(ok: true, id: id)
    }

    static func failure(_ error: String, id: String? = nil) -> IPCResponse {
        IPCResponse(ok: false, id: id, error: error)
    }
}

// MARK: - DTOs

nonisolated struct IPCThreadInfo: Encodable, Sendable {
    let id: String
    let name: String
    let projectName: String
    let worktreePath: String
    let tmuxSession: String
    let agentType: String?
    let isMain: Bool
    var sectionName: String?
    var sectionId: String?
    var tabs: [IPCTabInfo]?

    init(thread: MagentThread, projectName: String) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.agentType = thread.selectedAgentType?.rawValue
        self.isMain = thread.isMain
    }

    init(thread: MagentThread, projectName: String, sectionName: String?, tabs: [IPCTabInfo]) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.agentType = thread.selectedAgentType?.rawValue
        self.isMain = thread.isMain
        self.sectionName = sectionName
        self.sectionId = thread.sectionId?.uuidString
        self.tabs = tabs
    }
}

nonisolated struct IPCProjectInfo: Encodable, Sendable {
    let name: String
    let repoPath: String

    init(project: Project) {
        self.name = project.name
        self.repoPath = project.repoPath
    }
}

nonisolated struct IPCTabInfo: Encodable, Sendable {
    let index: Int
    let sessionName: String
    let isAgent: Bool
    let agentType: String?

    init(index: Int, sessionName: String, isAgent: Bool, agentType: String?) {
        self.index = index
        self.sessionName = sessionName
        self.isAgent = isAgent
        self.agentType = agentType
    }
}

nonisolated struct IPCSectionInfo: Encodable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let sortOrder: Int
    let isDefault: Bool
    let isVisible: Bool
    let isProjectOverride: Bool
    var threads: [IPCThreadInfo]?

    init(section: ThreadSection, isProjectOverride: Bool, threads: [IPCThreadInfo]? = nil) {
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
