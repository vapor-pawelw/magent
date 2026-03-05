import Foundation

nonisolated struct AppSettings: Codable, Sendable {
    static let defaultSlugPrompt = "Generate a short kebab-case slug (2-4 words) for a git branch name. Extract the core concept or feature — ignore filler words like 'I want', 'how do I', 'can you', etc. Bug reports, observations about broken behavior, and feature requests are all actionable — generate a slug for them."
    static let defaultReviewPrompt = "Review the changes on this branch compared to {baseBranch}. Run `git diff $(git merge-base {baseBranch} HEAD)` to see all changes (committed and uncommitted) since this branch diverged. Also run `git log HEAD..{baseBranch} --oneline` to check if {baseBranch} has moved ahead, and flag any likely merge conflicts. Provide a thorough code review covering correctness, potential bugs, code style, and any suggestions for improvement."

    var projects: [Project]
    var activeAgents: [AgentType]
    var defaultAgentType: AgentType?
    var customAgentCommand: String
    var showSystemBanners: Bool
    var playSoundForAgentCompletion: Bool
    var agentCompletionSoundName: String
    var autoReorderThreadsOnAgentCompletion: Bool
    var autoRenameBranches: Bool
    var autoSetThreadDescription: Bool
    var autoSetThreadIconFromWorkType: Bool
    var autoRenameSlugPrompt: String
    var useThreadSections: Bool
    var isConfigured: Bool
    var threadSections: [ThreadSection]
    var defaultSectionId: UUID?
    var terminalInjectionCommand: String
    var agentContextInjection: String
    var agentSandboxEnabled: Bool
    var agentSkipPermissions: Bool
    var ipcPromptInjectionEnabled: Bool
    var reviewPrompt: String
    var jiraSiteURL: String
    var enableRateLimitDetection: Bool
    var playSoundOnRateLimitDetected: Bool
    var rateLimitDetectedSoundName: String
    var showSystemNotificationOnRateLimitLifted: Bool
    var notifyOnRateLimitLifted: Bool
    var rateLimitLiftedSoundName: String
    var autoCheckForUpdates: Bool

    init(
        projects: [Project] = [],
        activeAgents: [AgentType] = [.claude],
        defaultAgentType: AgentType? = nil,
        customAgentCommand: String = "claude",
        showSystemBanners: Bool = true,
        playSoundForAgentCompletion: Bool = true,
        agentCompletionSoundName: String = "Ping",
        autoReorderThreadsOnAgentCompletion: Bool = true,
        autoRenameBranches: Bool = true,
        autoSetThreadDescription: Bool = true,
        autoSetThreadIconFromWorkType: Bool = true,
        autoRenameSlugPrompt: String = AppSettings.defaultSlugPrompt,
        useThreadSections: Bool = true,
        isConfigured: Bool = false,
        threadSections: [ThreadSection] = ThreadSection.defaults(),
        defaultSectionId: UUID? = nil,
        terminalInjectionCommand: String = "",
        agentContextInjection: String = "",
        agentSandboxEnabled: Bool = false,
        agentSkipPermissions: Bool = true,
        ipcPromptInjectionEnabled: Bool = true,
        reviewPrompt: String = AppSettings.defaultReviewPrompt,
        jiraSiteURL: String = "",
        enableRateLimitDetection: Bool = true,
        playSoundOnRateLimitDetected: Bool = true,
        rateLimitDetectedSoundName: String = "Sosumi",
        showSystemNotificationOnRateLimitLifted: Bool = true,
        notifyOnRateLimitLifted: Bool = true,
        rateLimitLiftedSoundName: String = "Glass",
        autoCheckForUpdates: Bool = true
    ) {
        self.projects = projects
        self.activeAgents = activeAgents
        self.defaultAgentType = defaultAgentType
        self.customAgentCommand = customAgentCommand
        self.showSystemBanners = showSystemBanners
        self.playSoundForAgentCompletion = playSoundForAgentCompletion
        self.agentCompletionSoundName = agentCompletionSoundName
        self.autoReorderThreadsOnAgentCompletion = autoReorderThreadsOnAgentCompletion
        self.autoRenameBranches = autoRenameBranches
        self.autoSetThreadDescription = autoSetThreadDescription
        self.autoSetThreadIconFromWorkType = autoSetThreadIconFromWorkType
        self.autoRenameSlugPrompt = autoRenameSlugPrompt
        self.useThreadSections = useThreadSections
        self.isConfigured = isConfigured
        self.threadSections = threadSections
        self.defaultSectionId = defaultSectionId
        self.terminalInjectionCommand = terminalInjectionCommand
        self.agentContextInjection = agentContextInjection
        self.agentSandboxEnabled = agentSandboxEnabled
        self.agentSkipPermissions = agentSkipPermissions
        self.ipcPromptInjectionEnabled = ipcPromptInjectionEnabled
        self.reviewPrompt = reviewPrompt
        self.jiraSiteURL = jiraSiteURL
        self.enableRateLimitDetection = enableRateLimitDetection
        self.playSoundOnRateLimitDetected = playSoundOnRateLimitDetected
        self.rateLimitDetectedSoundName = rateLimitDetectedSoundName
        self.showSystemNotificationOnRateLimitLifted = showSystemNotificationOnRateLimitLifted
        self.notifyOnRateLimitLifted = notifyOnRateLimitLifted
        self.rateLimitLiftedSoundName = rateLimitLiftedSoundName
        self.autoCheckForUpdates = autoCheckForUpdates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        let legacyAgentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType) ?? .claude
        let legacyAgentCommand = try container.decodeIfPresent(String.self, forKey: .agentCommand) ?? "claude"
        activeAgents = try container.decodeIfPresent([AgentType].self, forKey: .activeAgents) ?? [legacyAgentType]
        defaultAgentType = try container.decodeIfPresent(AgentType.self, forKey: .defaultAgentType)
        customAgentCommand = try container.decodeIfPresent(String.self, forKey: .customAgentCommand) ?? legacyAgentCommand
        showSystemBanners = try container.decodeIfPresent(Bool.self, forKey: .showSystemBanners) ?? true
        playSoundForAgentCompletion = try container.decodeIfPresent(Bool.self, forKey: .playSoundForAgentCompletion) ?? true
        agentCompletionSoundName = try container.decodeIfPresent(String.self, forKey: .agentCompletionSoundName) ?? "Ping"
        autoReorderThreadsOnAgentCompletion = try container.decodeIfPresent(Bool.self, forKey: .autoReorderThreadsOnAgentCompletion) ?? true
        let legacyAutoRename = try container.decodeIfPresent(Bool.self, forKey: .autoRenameWorktrees)
        autoRenameBranches = try container.decodeIfPresent(Bool.self, forKey: .autoRenameBranches) ?? legacyAutoRename ?? true
        autoSetThreadDescription = try container.decodeIfPresent(Bool.self, forKey: .autoSetThreadDescription) ?? legacyAutoRename ?? true
        autoSetThreadIconFromWorkType = try container.decodeIfPresent(Bool.self, forKey: .autoSetThreadIconFromWorkType) ?? true
        autoRenameSlugPrompt = try container.decodeIfPresent(String.self, forKey: .autoRenameSlugPrompt) ?? Self.defaultSlugPrompt
        useThreadSections = try container.decodeIfPresent(Bool.self, forKey: .useThreadSections) ?? true
        isConfigured = try container.decode(Bool.self, forKey: .isConfigured)
        threadSections = try container.decodeIfPresent([ThreadSection].self, forKey: .threadSections) ?? ThreadSection.defaults()
        defaultSectionId = try container.decodeIfPresent(UUID.self, forKey: .defaultSectionId)
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand) ?? ""
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection) ?? ""
        agentSandboxEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentSandboxEnabled) ?? false
        agentSkipPermissions = try container.decodeIfPresent(Bool.self, forKey: .agentSkipPermissions) ?? true
        ipcPromptInjectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .ipcPromptInjectionEnabled) ?? true
        reviewPrompt = try container.decodeIfPresent(String.self, forKey: .reviewPrompt) ?? Self.defaultReviewPrompt
        jiraSiteURL = try container.decodeIfPresent(String.self, forKey: .jiraSiteURL) ?? ""
        enableRateLimitDetection = try container.decodeIfPresent(Bool.self, forKey: .enableRateLimitDetection) ?? true
        playSoundOnRateLimitDetected = try container.decodeIfPresent(Bool.self, forKey: .playSoundOnRateLimitDetected) ?? true
        rateLimitDetectedSoundName = try container.decodeIfPresent(String.self, forKey: .rateLimitDetectedSoundName) ?? "Sosumi"
        notifyOnRateLimitLifted = try container.decodeIfPresent(Bool.self, forKey: .notifyOnRateLimitLifted) ?? true
        showSystemNotificationOnRateLimitLifted = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotificationOnRateLimitLifted) ?? notifyOnRateLimitLifted
        rateLimitLiftedSoundName = try container.decodeIfPresent(String.self, forKey: .rateLimitLiftedSoundName) ?? "Glass"
        autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(activeAgents, forKey: .activeAgents)
        try container.encodeIfPresent(defaultAgentType, forKey: .defaultAgentType)
        try container.encode(customAgentCommand, forKey: .customAgentCommand)
        try container.encode(showSystemBanners, forKey: .showSystemBanners)
        try container.encode(playSoundForAgentCompletion, forKey: .playSoundForAgentCompletion)
        try container.encode(agentCompletionSoundName, forKey: .agentCompletionSoundName)
        try container.encode(autoReorderThreadsOnAgentCompletion, forKey: .autoReorderThreadsOnAgentCompletion)
        try container.encode(autoRenameBranches, forKey: .autoRenameBranches)
        try container.encode(autoSetThreadDescription, forKey: .autoSetThreadDescription)
        try container.encode(autoSetThreadIconFromWorkType, forKey: .autoSetThreadIconFromWorkType)
        // Keep writing the legacy key for backward compatibility with older builds.
        try container.encode(autoRenameBranches, forKey: .autoRenameWorktrees)
        try container.encode(autoRenameSlugPrompt, forKey: .autoRenameSlugPrompt)
        try container.encode(useThreadSections, forKey: .useThreadSections)
        try container.encode(isConfigured, forKey: .isConfigured)
        try container.encode(threadSections, forKey: .threadSections)
        try container.encodeIfPresent(defaultSectionId, forKey: .defaultSectionId)
        try container.encode(terminalInjectionCommand, forKey: .terminalInjectionCommand)
        try container.encode(agentContextInjection, forKey: .agentContextInjection)
        try container.encode(agentSandboxEnabled, forKey: .agentSandboxEnabled)
        try container.encode(agentSkipPermissions, forKey: .agentSkipPermissions)
        try container.encode(ipcPromptInjectionEnabled, forKey: .ipcPromptInjectionEnabled)
        try container.encode(reviewPrompt, forKey: .reviewPrompt)
        try container.encode(jiraSiteURL, forKey: .jiraSiteURL)
        try container.encode(enableRateLimitDetection, forKey: .enableRateLimitDetection)
        try container.encode(playSoundOnRateLimitDetected, forKey: .playSoundOnRateLimitDetected)
        try container.encode(rateLimitDetectedSoundName, forKey: .rateLimitDetectedSoundName)
        try container.encode(notifyOnRateLimitLifted, forKey: .notifyOnRateLimitLifted)
        try container.encode(showSystemNotificationOnRateLimitLifted, forKey: .showSystemNotificationOnRateLimitLifted)
        try container.encode(rateLimitLiftedSoundName, forKey: .rateLimitLiftedSoundName)
        try container.encode(autoCheckForUpdates, forKey: .autoCheckForUpdates)
    }

    var visibleSections: [ThreadSection] {
        threadSections.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    var defaultSection: ThreadSection? {
        let visible = visibleSections
        if let id = defaultSectionId, let match = visible.first(where: { $0.id == id }) {
            return match
        }
        return visible.first
    }

    func defaultSection(for projectId: UUID) -> ThreadSection? {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            return defaultSection
        }

        let sections = visibleSections(for: projectId)
        if let id = project.defaultSectionId,
           let match = sections.first(where: { $0.id == id }) {
            return match
        }

        if let inheritedId = defaultSection?.id,
           let inherited = sections.first(where: { $0.id == inheritedId }) {
            return inherited
        }

        return sections.first
    }

    /// Returns sections for a specific project — project override if set, otherwise global.
    func sections(for projectId: UUID) -> [ThreadSection] {
        if let project = projects.first(where: { $0.id == projectId }),
           let override = project.threadSections {
            return override
        }
        return threadSections
    }

    /// Returns visible sections for a specific project, sorted by sortOrder.
    func visibleSections(for projectId: UUID) -> [ThreadSection] {
        sections(for: projectId).filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    func shouldUseThreadSections(for projectId: UUID) -> Bool {
        if let project = projects.first(where: { $0.id == projectId }),
           let projectOverride = project.useThreadSectionsOverride {
            return projectOverride
        }
        return useThreadSections
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
            return agentSkipPermissions ? "claude --dangerously-skip-permissions" : "claude"
        case .codex:
            if agentSkipPermissions {
                return "codex --yolo"
            } else if agentSandboxEnabled {
                return "codex --full-auto"
            } else {
                return "codex"
            }
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
        case showSystemBanners
        case playSoundForAgentCompletion
        case agentCompletionSoundName
        case autoReorderThreadsOnAgentCompletion
        case autoRenameBranches
        case autoSetThreadDescription
        case autoSetThreadIconFromWorkType
        case autoRenameWorktrees
        case autoRenameSlugPrompt
        case useThreadSections
        case isConfigured
        case threadSections
        case defaultSectionId
        case terminalInjectionCommand
        case agentContextInjection
        case agentSandboxEnabled
        case agentSkipPermissions
        case ipcPromptInjectionEnabled
        case reviewPrompt
        case jiraSiteURL
        case enableRateLimitDetection
        case playSoundOnRateLimitDetected
        case rateLimitDetectedSoundName
        case showSystemNotificationOnRateLimitLifted
        case notifyOnRateLimitLifted
        case rateLimitLiftedSoundName
        case autoCheckForUpdates

        // Legacy keys kept for migration.
        case agentCommand
        case agentType
    }
}
