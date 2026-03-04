import Foundation

nonisolated struct Project: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var repoPath: String
    var worktreesBasePath: String
    var defaultBranch: String?
    var agentType: AgentType?
    var terminalInjectionCommand: String?
    var preAgentInjectionCommand: String?
    var agentContextInjection: String?
    var autoRenameSlugPrompt: String?
    var isPinned: Bool
    var isHidden: Bool
    var useThreadSectionsOverride: Bool?
    var defaultSectionId: UUID?
    var threadSections: [ThreadSection]?
    var jiraProjectKey: String?
    var jiraBoardId: Int?
    var jiraBoardName: String?
    var jiraSyncEnabled: Bool
    var jiraSiteURL: String?
    var jiraExcludedTicketKeys: Set<String>
    var jiraAssigneeAccountId: String?
    var jiraAcknowledgedStatuses: Set<String>?

    init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        worktreesBasePath: String,
        defaultBranch: String? = nil,
        agentType: AgentType? = nil,
        terminalInjectionCommand: String? = nil,
        preAgentInjectionCommand: String? = nil,
        agentContextInjection: String? = nil,
        autoRenameSlugPrompt: String? = nil,
        isPinned: Bool = false,
        isHidden: Bool = false,
        useThreadSectionsOverride: Bool? = nil,
        defaultSectionId: UUID? = nil,
        threadSections: [ThreadSection]? = nil,
        jiraProjectKey: String? = nil,
        jiraBoardId: Int? = nil,
        jiraBoardName: String? = nil,
        jiraSyncEnabled: Bool = false,
        jiraSiteURL: String? = nil,
        jiraExcludedTicketKeys: Set<String> = [],
        jiraAssigneeAccountId: String? = nil,
        jiraAcknowledgedStatuses: Set<String>? = nil
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.worktreesBasePath = worktreesBasePath
        self.defaultBranch = defaultBranch
        self.agentType = agentType
        self.terminalInjectionCommand = terminalInjectionCommand
        self.preAgentInjectionCommand = preAgentInjectionCommand
        self.agentContextInjection = agentContextInjection
        self.autoRenameSlugPrompt = autoRenameSlugPrompt
        self.isPinned = isPinned
        self.isHidden = isHidden
        self.useThreadSectionsOverride = useThreadSectionsOverride
        self.defaultSectionId = defaultSectionId
        self.threadSections = threadSections
        self.jiraProjectKey = jiraProjectKey
        self.jiraBoardId = jiraBoardId
        self.jiraBoardName = jiraBoardName
        self.jiraSyncEnabled = jiraSyncEnabled
        self.jiraSiteURL = jiraSiteURL
        self.jiraExcludedTicketKeys = jiraExcludedTicketKeys
        self.jiraAssigneeAccountId = jiraAssigneeAccountId
        self.jiraAcknowledgedStatuses = jiraAcknowledgedStatuses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repoPath = try container.decode(String.self, forKey: .repoPath)
        worktreesBasePath = try container.decode(String.self, forKey: .worktreesBasePath)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType)
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand)
        preAgentInjectionCommand = try container.decodeIfPresent(String.self, forKey: .preAgentInjectionCommand)
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection)
        autoRenameSlugPrompt = try container.decodeIfPresent(String.self, forKey: .autoRenameSlugPrompt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        useThreadSectionsOverride = try container.decodeIfPresent(Bool.self, forKey: .useThreadSectionsOverride)
        defaultSectionId = try container.decodeIfPresent(UUID.self, forKey: .defaultSectionId)
        threadSections = try container.decodeIfPresent([ThreadSection].self, forKey: .threadSections)
        jiraProjectKey = try container.decodeIfPresent(String.self, forKey: .jiraProjectKey)
        jiraBoardId = try container.decodeIfPresent(Int.self, forKey: .jiraBoardId)
        jiraBoardName = try container.decodeIfPresent(String.self, forKey: .jiraBoardName)
        jiraSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .jiraSyncEnabled) ?? false
        jiraSiteURL = try container.decodeIfPresent(String.self, forKey: .jiraSiteURL)
        jiraExcludedTicketKeys = try container.decodeIfPresent(Set<String>.self, forKey: .jiraExcludedTicketKeys) ?? []
        jiraAssigneeAccountId = try container.decodeIfPresent(String.self, forKey: .jiraAssigneeAccountId)
        jiraAcknowledgedStatuses = try container.decodeIfPresent(Set<String>.self, forKey: .jiraAcknowledgedStatuses)
    }

    /// Resolves template variables in `worktreesBasePath` (e.g. `$MAGENT_PROJECT_NAME`).
    func resolvedWorktreesBasePath() -> String {
        worktreesBasePath.replacingOccurrences(of: "$MAGENT_PROJECT_NAME", with: name)
    }

    /// Whether the repo path still points to an existing directory.
    var isValid: Bool {
        FileManager.default.fileExists(atPath: repoPath)
    }

    /// Suggests a default worktrees base path using the `$MAGENT_PROJECT_NAME` template variable.
    static func suggestedWorktreesPath(for repoPath: String) -> String {
        let url = URL(fileURLWithPath: repoPath)
        let parent = url.deletingLastPathComponent().path
        return "\(parent)/.worktrees-$MAGENT_PROJECT_NAME"
    }
}
