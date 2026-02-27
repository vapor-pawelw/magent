import Foundation

nonisolated struct AppSettings: Codable, Sendable {
    var projects: [Project]
    var activeAgents: [AgentType]
    var defaultAgentType: AgentType?
    var customAgentCommand: String
    var playSoundForAgentCompletion: Bool
    var agentCompletionSoundName: String
    var autoRenameWorktrees: Bool
    var isConfigured: Bool
    var threadSections: [ThreadSection]
    var terminalInjectionCommand: String
    var agentContextInjection: String

    init(
        projects: [Project] = [],
        activeAgents: [AgentType] = [.claude],
        defaultAgentType: AgentType? = nil,
        customAgentCommand: String = "claude",
        playSoundForAgentCompletion: Bool = true,
        agentCompletionSoundName: String = "Ping",
        autoRenameWorktrees: Bool = true,
        isConfigured: Bool = false,
        threadSections: [ThreadSection] = ThreadSection.defaults(),
        terminalInjectionCommand: String = "",
        agentContextInjection: String = ""
    ) {
        self.projects = projects
        self.activeAgents = activeAgents
        self.defaultAgentType = defaultAgentType
        self.customAgentCommand = customAgentCommand
        self.playSoundForAgentCompletion = playSoundForAgentCompletion
        self.agentCompletionSoundName = agentCompletionSoundName
        self.autoRenameWorktrees = autoRenameWorktrees
        self.isConfigured = isConfigured
        self.threadSections = threadSections
        self.terminalInjectionCommand = terminalInjectionCommand
        self.agentContextInjection = agentContextInjection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        let legacyAgentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType) ?? .claude
        let legacyAgentCommand = try container.decodeIfPresent(String.self, forKey: .agentCommand) ?? "claude"
        activeAgents = try container.decodeIfPresent([AgentType].self, forKey: .activeAgents) ?? [legacyAgentType]
        defaultAgentType = try container.decodeIfPresent(AgentType.self, forKey: .defaultAgentType)
        customAgentCommand = try container.decodeIfPresent(String.self, forKey: .customAgentCommand) ?? legacyAgentCommand
        playSoundForAgentCompletion = try container.decodeIfPresent(Bool.self, forKey: .playSoundForAgentCompletion) ?? true
        agentCompletionSoundName = try container.decodeIfPresent(String.self, forKey: .agentCompletionSoundName) ?? "Ping"
        autoRenameWorktrees = try container.decodeIfPresent(Bool.self, forKey: .autoRenameWorktrees) ?? true
        isConfigured = try container.decode(Bool.self, forKey: .isConfigured)
        threadSections = try container.decodeIfPresent([ThreadSection].self, forKey: .threadSections) ?? ThreadSection.defaults()
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand) ?? ""
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(activeAgents, forKey: .activeAgents)
        try container.encodeIfPresent(defaultAgentType, forKey: .defaultAgentType)
        try container.encode(customAgentCommand, forKey: .customAgentCommand)
        try container.encode(playSoundForAgentCompletion, forKey: .playSoundForAgentCompletion)
        try container.encode(agentCompletionSoundName, forKey: .agentCompletionSoundName)
        try container.encode(autoRenameWorktrees, forKey: .autoRenameWorktrees)
        try container.encode(isConfigured, forKey: .isConfigured)
        try container.encode(threadSections, forKey: .threadSections)
        try container.encode(terminalInjectionCommand, forKey: .terminalInjectionCommand)
        try container.encode(agentContextInjection, forKey: .agentContextInjection)
    }

    var visibleSections: [ThreadSection] {
        threadSections.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    var defaultSection: ThreadSection? {
        visibleSections.first
    }

    var availableActiveAgents: [AgentType] {
        var seen = Set<AgentType>()
        return activeAgents.filter { seen.insert($0).inserted }
    }

    var effectiveGlobalDefaultAgentType: AgentType? {
        let agents = availableActiveAgents
        guard !agents.isEmpty else { return nil }
        if agents.count == 1 {
            return agents[0]
        }
        if let defaultAgentType, agents.contains(defaultAgentType) {
            return defaultAgentType
        }
        return agents[0]
    }

    func command(for agentType: AgentType) -> String {
        switch agentType {
        case .claude:
            return "claude --dangerously-skip-permissions"
        case .codex:
            return "codex --yolo"
        case .custom:
            let trimmed = customAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "custom-agent" : trimmed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case activeAgents
        case defaultAgentType
        case customAgentCommand
        case playSoundForAgentCompletion
        case agentCompletionSoundName
        case autoRenameWorktrees
        case isConfigured
        case threadSections
        case terminalInjectionCommand
        case agentContextInjection

        // Legacy keys kept for migration.
        case agentCommand
        case agentType
    }
}
