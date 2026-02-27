import Foundation

// MARK: - Request

nonisolated struct IPCRequest: Codable, Sendable {
    let command: String
    var project: String?
    var agentType: String?
    var prompt: String?
    var threadId: String?
    var threadName: String?
    var id: String?
}

// MARK: - Response

nonisolated struct IPCResponse: Encodable, Sendable {
    let ok: Bool
    var id: String?
    var error: String?
    var thread: IPCThreadInfo?
    var threads: [IPCThreadInfo]?
    var projects: [IPCProjectInfo]?

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

    init(thread: MagentThread, projectName: String) {
        self.id = thread.id.uuidString
        self.name = thread.name
        self.projectName = projectName
        self.worktreePath = thread.worktreePath
        self.tmuxSession = thread.tmuxSessionNames.first ?? ""
        self.agentType = thread.selectedAgentType?.rawValue
        self.isMain = thread.isMain
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
