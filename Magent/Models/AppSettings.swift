import Foundation

struct AppSettings: Codable {
    var projects: [Project]
    var agentCommand: String
    var agentType: AgentType
    var isConfigured: Bool
    var threadSections: [ThreadSection]
    var terminalInjectionCommand: String
    var agentContextInjection: String

    init(
        projects: [Project] = [],
        agentCommand: String = "claude",
        agentType: AgentType = .claude,
        isConfigured: Bool = false,
        threadSections: [ThreadSection] = ThreadSection.defaults(),
        terminalInjectionCommand: String = "",
        agentContextInjection: String = ""
    ) {
        self.projects = projects
        self.agentCommand = agentCommand
        self.agentType = agentType
        self.isConfigured = isConfigured
        self.threadSections = threadSections
        self.terminalInjectionCommand = terminalInjectionCommand
        self.agentContextInjection = agentContextInjection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        agentCommand = try container.decode(String.self, forKey: .agentCommand)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType) ?? .claude
        isConfigured = try container.decode(Bool.self, forKey: .isConfigured)
        threadSections = try container.decodeIfPresent([ThreadSection].self, forKey: .threadSections) ?? ThreadSection.defaults()
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand) ?? ""
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection) ?? ""
    }

    var visibleSections: [ThreadSection] {
        threadSections.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    var defaultSection: ThreadSection? {
        visibleSections.first
    }

    var isClaudeAgent: Bool {
        agentType == .claude
    }
}
