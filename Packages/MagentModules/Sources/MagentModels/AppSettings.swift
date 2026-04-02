import Foundation

public enum AppAppearanceMode: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum TerminalMouseWheelBehavior: String, Codable, Sendable, CaseIterable {
    case magentDefaultScroll
    case inheritGhosttyGlobal
    case allowAppsToCapture

    public var displayName: String {
        switch self {
        case .magentDefaultScroll: "Scroll terminal history"
        case .inheritGhosttyGlobal: "Use Ghostty global setting"
        case .allowAppsToCapture: "Send wheel input to apps/prompts"
        }
    }
}

public enum ExternalLinkOpenPreference: String, Codable, Sendable, CaseIterable {
    case browser
    case inApp

    public var displayName: String {
        switch self {
        case .browser: "Default browser"
        case .inApp: "Magent web tab"
        }
    }
}

public nonisolated struct AgentLaunchPromptDraft: Codable, Sendable, Equatable {
    public var prompt: String
    public var description: String
    public var branchName: String

    public init(prompt: String = "", description: String = "", branchName: String = "") {
        self.prompt = prompt
        self.description = description
        self.branchName = branchName
    }
}
public nonisolated struct AppSettings: Codable, Sendable {
    public static let defaultSlugPrompt = "Generate a short kebab-case slug (2-4 words) for a git branch name. Extract the core concept or feature — ignore filler words like 'I want', 'how do I', 'can you', etc. Bug reports, observations about broken behavior, and feature requests are all actionable — generate a slug for them."
    public static let defaultReviewPrompt = "Review the changes on this branch compared to {baseBranch}. Run `git diff $(git merge-base {baseBranch} HEAD)` to see all changes (committed and uncommitted) since this branch diverged. Also run `git log HEAD..{baseBranch} --oneline` to check if {baseBranch} has moved ahead, and flag any likely merge conflicts. Provide a thorough code review covering correctness, potential bugs, code style, and any suggestions for improvement."

    public var projects: [Project]
    public var activeAgents: [AgentType]
    public var defaultAgentType: AgentType?
    public var customAgentCommand: String
    public var showSystemBanners: Bool
    public var playSoundForAgentCompletion: Bool
    public var agentCompletionSoundName: String
    public var autoReorderThreadsOnAgentCompletion: Bool
    public var showDockBadgeAndBounceForUnreadCompletions: Bool
    public var autoRenameBranches: Bool
    public var autoSetThreadDescription: Bool
    public var autoSetThreadIconFromWorkType: Bool
    public var narrowThreads: Bool
    public var showPRStatusBadges: Bool
    public var showJiraStatusBadges: Bool
    public var showBusyStateDuration: Bool
    public var autoRenameSlugPrompt: String
    public var useThreadSections: Bool
    public var isConfigured: Bool
    public var threadSections: [ThreadSection]
    public var defaultSectionId: UUID?
    public var terminalInjectionCommand: String
    public var agentContextInjection: String
    public var agentSandboxEnabled: Bool
    public var agentSkipPermissions: Bool
    public var ipcPromptInjectionEnabled: Bool
    public var reviewPrompt: String
    public var jiraIntegrationEnabled: Bool
    public var jiraSiteURL: String
    public var jiraTicketDetectionEnabled: Bool
    public var jiraTicketDetectionPrefixes: String
    public var enableRateLimitDetection: Bool
    public var playSoundOnRateLimitDetected: Bool
    public var rateLimitDetectedSoundName: String
    public var showSystemNotificationOnRateLimitLifted: Bool
    public var notifyOnRateLimitLifted: Bool
    public var rateLimitLiftedSoundName: String
    public var autoCheckForUpdates: Bool
    public var skippedUpdateVersion: String?
    public var syncLocalPathsOnArchive: Bool
    public var externalLinkOpenPreference: ExternalLinkOpenPreference
    public var appAppearanceMode: AppAppearanceMode
    public var terminalMouseWheelBehavior: TerminalMouseWheelBehavior
    public var showScrollToBottomIndicator: Bool
    public var showTerminalScrollOverlay: Bool
    public var showPromptTOCOverlay: Bool
    public var preserveAgentColorTheme: Bool
    public var rememberLastTypeSelection: Bool
    public var switchToNewlyCreatedThread: Bool
    public var switchToNewlyCreatedTab: Bool
    public var protectPinnedFromEviction: Bool
    public var maxIdleSessions: Int?
    public var keyBindings: KeyBindingSettings

    public init(
        projects: [Project] = [],
        activeAgents: [AgentType] = [.claude],
        defaultAgentType: AgentType? = nil,
        customAgentCommand: String = "claude",
        showSystemBanners: Bool = true,
        playSoundForAgentCompletion: Bool = true,
        agentCompletionSoundName: String = "Ping",
        autoReorderThreadsOnAgentCompletion: Bool = true,
        showDockBadgeAndBounceForUnreadCompletions: Bool = true,
        autoRenameBranches: Bool = true,
        autoSetThreadDescription: Bool = true,
        autoSetThreadIconFromWorkType: Bool = true,
        narrowThreads: Bool = false,
        showPRStatusBadges: Bool = true,
        showJiraStatusBadges: Bool = true,
        showBusyStateDuration: Bool = true,
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
        jiraIntegrationEnabled: Bool = true,
        jiraSiteURL: String = "",
        jiraTicketDetectionEnabled: Bool = true,
        jiraTicketDetectionPrefixes: String = "",
        enableRateLimitDetection: Bool = true,
        playSoundOnRateLimitDetected: Bool = true,
        rateLimitDetectedSoundName: String = "Sosumi",
        showSystemNotificationOnRateLimitLifted: Bool = true,
        notifyOnRateLimitLifted: Bool = true,
        rateLimitLiftedSoundName: String = "Glass",
        autoCheckForUpdates: Bool = true,
        skippedUpdateVersion: String? = nil,
        syncLocalPathsOnArchive: Bool = true,
        externalLinkOpenPreference: ExternalLinkOpenPreference = .browser,
        appAppearanceMode: AppAppearanceMode = .system,
        terminalMouseWheelBehavior: TerminalMouseWheelBehavior = .magentDefaultScroll,
        showScrollToBottomIndicator: Bool = true,
        showTerminalScrollOverlay: Bool = true,
        showPromptTOCOverlay: Bool = true,
        preserveAgentColorTheme: Bool = false,
        rememberLastTypeSelection: Bool = true,
        switchToNewlyCreatedThread: Bool = true,
        switchToNewlyCreatedTab: Bool = true,
        protectPinnedFromEviction: Bool = true,
        maxIdleSessions: Int? = 30,
        keyBindings: KeyBindingSettings = KeyBindingSettings()
    ) {
        self.projects = projects
        self.activeAgents = activeAgents
        self.defaultAgentType = defaultAgentType
        self.customAgentCommand = customAgentCommand
        self.showSystemBanners = showSystemBanners
        self.playSoundForAgentCompletion = playSoundForAgentCompletion
        self.agentCompletionSoundName = agentCompletionSoundName
        self.autoReorderThreadsOnAgentCompletion = autoReorderThreadsOnAgentCompletion
        self.showDockBadgeAndBounceForUnreadCompletions = showDockBadgeAndBounceForUnreadCompletions
        self.autoRenameBranches = autoRenameBranches
        self.autoSetThreadDescription = autoSetThreadDescription
        self.autoSetThreadIconFromWorkType = autoSetThreadIconFromWorkType
        self.narrowThreads = narrowThreads
        self.showPRStatusBadges = showPRStatusBadges
        self.showJiraStatusBadges = showJiraStatusBadges
        self.showBusyStateDuration = showBusyStateDuration
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
        self.jiraIntegrationEnabled = jiraIntegrationEnabled
        self.jiraSiteURL = jiraSiteURL
        self.jiraTicketDetectionEnabled = jiraTicketDetectionEnabled
        self.jiraTicketDetectionPrefixes = jiraTicketDetectionPrefixes
        self.enableRateLimitDetection = enableRateLimitDetection
        self.playSoundOnRateLimitDetected = playSoundOnRateLimitDetected
        self.rateLimitDetectedSoundName = rateLimitDetectedSoundName
        self.showSystemNotificationOnRateLimitLifted = showSystemNotificationOnRateLimitLifted
        self.notifyOnRateLimitLifted = notifyOnRateLimitLifted
        self.rateLimitLiftedSoundName = rateLimitLiftedSoundName
        self.autoCheckForUpdates = autoCheckForUpdates
        self.skippedUpdateVersion = skippedUpdateVersion
        self.syncLocalPathsOnArchive = syncLocalPathsOnArchive
        self.externalLinkOpenPreference = externalLinkOpenPreference
        self.appAppearanceMode = appAppearanceMode
        self.terminalMouseWheelBehavior = terminalMouseWheelBehavior
        self.showScrollToBottomIndicator = showScrollToBottomIndicator
        self.showTerminalScrollOverlay = showTerminalScrollOverlay
        self.showPromptTOCOverlay = showPromptTOCOverlay
        self.preserveAgentColorTheme = preserveAgentColorTheme
        self.rememberLastTypeSelection = rememberLastTypeSelection
        self.switchToNewlyCreatedThread = switchToNewlyCreatedThread
        self.switchToNewlyCreatedTab = switchToNewlyCreatedTab
        self.protectPinnedFromEviction = protectPinnedFromEviction
        self.maxIdleSessions = maxIdleSessions
        self.keyBindings = keyBindings
    }

    public init(from decoder: Decoder) throws {
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
        showDockBadgeAndBounceForUnreadCompletions = try container.decodeIfPresent(Bool.self, forKey: .showDockBadgeAndBounceForUnreadCompletions) ?? true
        let legacyAutoRename = try container.decodeIfPresent(Bool.self, forKey: .autoRenameWorktrees)
        autoRenameBranches = try container.decodeIfPresent(Bool.self, forKey: .autoRenameBranches) ?? legacyAutoRename ?? true
        autoSetThreadDescription = try container.decodeIfPresent(Bool.self, forKey: .autoSetThreadDescription) ?? legacyAutoRename ?? true
        autoSetThreadIconFromWorkType = try container.decodeIfPresent(Bool.self, forKey: .autoSetThreadIconFromWorkType) ?? true
        narrowThreads = try container.decodeIfPresent(Bool.self, forKey: .narrowThreads) ?? false
        showPRStatusBadges = try container.decodeIfPresent(Bool.self, forKey: .showPRStatusBadges) ?? true
        showJiraStatusBadges = try container.decodeIfPresent(Bool.self, forKey: .showJiraStatusBadges) ?? true
        showBusyStateDuration = try container.decodeIfPresent(Bool.self, forKey: .showBusyStateDuration) ?? true
        autoRenameSlugPrompt = try container.decodeIfPresent(String.self, forKey: .autoRenameSlugPrompt) ?? Self.defaultSlugPrompt
        useThreadSections = try container.decodeIfPresent(Bool.self, forKey: .useThreadSections) ?? true
        isConfigured = try container.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? !projects.isEmpty
        threadSections = try container.decodeIfPresent([ThreadSection].self, forKey: .threadSections) ?? ThreadSection.defaults()
        defaultSectionId = try container.decodeIfPresent(UUID.self, forKey: .defaultSectionId)
        terminalInjectionCommand = try container.decodeIfPresent(String.self, forKey: .terminalInjectionCommand) ?? ""
        agentContextInjection = try container.decodeIfPresent(String.self, forKey: .agentContextInjection) ?? ""
        agentSandboxEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentSandboxEnabled) ?? false
        agentSkipPermissions = try container.decodeIfPresent(Bool.self, forKey: .agentSkipPermissions) ?? true
        ipcPromptInjectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .ipcPromptInjectionEnabled) ?? true
        reviewPrompt = try container.decodeIfPresent(String.self, forKey: .reviewPrompt) ?? Self.defaultReviewPrompt
        jiraIntegrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .jiraIntegrationEnabled) ?? true
        jiraSiteURL = try container.decodeIfPresent(String.self, forKey: .jiraSiteURL) ?? ""
        jiraTicketDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .jiraTicketDetectionEnabled) ?? true
        jiraTicketDetectionPrefixes = try container.decodeIfPresent(String.self, forKey: .jiraTicketDetectionPrefixes) ?? ""
        enableRateLimitDetection = try container.decodeIfPresent(Bool.self, forKey: .enableRateLimitDetection) ?? true
        playSoundOnRateLimitDetected = try container.decodeIfPresent(Bool.self, forKey: .playSoundOnRateLimitDetected) ?? true
        rateLimitDetectedSoundName = try container.decodeIfPresent(String.self, forKey: .rateLimitDetectedSoundName) ?? "Sosumi"
        notifyOnRateLimitLifted = try container.decodeIfPresent(Bool.self, forKey: .notifyOnRateLimitLifted) ?? true
        showSystemNotificationOnRateLimitLifted = try container.decodeIfPresent(Bool.self, forKey: .showSystemNotificationOnRateLimitLifted) ?? notifyOnRateLimitLifted
        rateLimitLiftedSoundName = try container.decodeIfPresent(String.self, forKey: .rateLimitLiftedSoundName) ?? "Glass"
        autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? true
        skippedUpdateVersion = try container.decodeIfPresent(String.self, forKey: .skippedUpdateVersion)
        syncLocalPathsOnArchive = try container.decodeIfPresent(Bool.self, forKey: .syncLocalPathsOnArchive) ?? true
        externalLinkOpenPreference = try container.decodeIfPresent(ExternalLinkOpenPreference.self, forKey: .externalLinkOpenPreference) ?? .browser
        appAppearanceMode = try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appAppearanceMode) ?? .system
        terminalMouseWheelBehavior = try container.decodeIfPresent(TerminalMouseWheelBehavior.self, forKey: .terminalMouseWheelBehavior) ?? .magentDefaultScroll
        showScrollToBottomIndicator = try container.decodeIfPresent(Bool.self, forKey: .showScrollToBottomIndicator) ?? true
        showTerminalScrollOverlay = try container.decodeIfPresent(Bool.self, forKey: .showTerminalScrollOverlay) ?? true
        showPromptTOCOverlay = try container.decodeIfPresent(Bool.self, forKey: .showPromptTOCOverlay) ?? true
        preserveAgentColorTheme = try container.decodeIfPresent(Bool.self, forKey: .preserveAgentColorTheme) ?? false
        rememberLastTypeSelection = try container.decodeIfPresent(Bool.self, forKey: .rememberLastTypeSelection) ?? true
        switchToNewlyCreatedThread = try container.decodeIfPresent(Bool.self, forKey: .switchToNewlyCreatedThread) ?? true
        switchToNewlyCreatedTab = try container.decodeIfPresent(Bool.self, forKey: .switchToNewlyCreatedTab) ?? true
        protectPinnedFromEviction = try container.decodeIfPresent(Bool.self, forKey: .protectPinnedFromEviction) ?? true
        maxIdleSessions = try container.decodeIfPresent(Int.self, forKey: .maxIdleSessions)
        keyBindings = try container.decodeIfPresent(KeyBindingSettings.self, forKey: .keyBindings) ?? KeyBindingSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(activeAgents, forKey: .activeAgents)
        try container.encodeIfPresent(defaultAgentType, forKey: .defaultAgentType)
        try container.encode(customAgentCommand, forKey: .customAgentCommand)
        try container.encode(showSystemBanners, forKey: .showSystemBanners)
        try container.encode(playSoundForAgentCompletion, forKey: .playSoundForAgentCompletion)
        try container.encode(agentCompletionSoundName, forKey: .agentCompletionSoundName)
        try container.encode(autoReorderThreadsOnAgentCompletion, forKey: .autoReorderThreadsOnAgentCompletion)
        try container.encode(showDockBadgeAndBounceForUnreadCompletions, forKey: .showDockBadgeAndBounceForUnreadCompletions)
        try container.encode(autoRenameBranches, forKey: .autoRenameBranches)
        try container.encode(autoSetThreadDescription, forKey: .autoSetThreadDescription)
        try container.encode(autoSetThreadIconFromWorkType, forKey: .autoSetThreadIconFromWorkType)
        try container.encode(narrowThreads, forKey: .narrowThreads)
        try container.encode(showPRStatusBadges, forKey: .showPRStatusBadges)
        try container.encode(showJiraStatusBadges, forKey: .showJiraStatusBadges)
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
        try container.encode(jiraIntegrationEnabled, forKey: .jiraIntegrationEnabled)
        try container.encode(jiraSiteURL, forKey: .jiraSiteURL)
        try container.encode(jiraTicketDetectionEnabled, forKey: .jiraTicketDetectionEnabled)
        try container.encode(jiraTicketDetectionPrefixes, forKey: .jiraTicketDetectionPrefixes)
        try container.encode(enableRateLimitDetection, forKey: .enableRateLimitDetection)
        try container.encode(playSoundOnRateLimitDetected, forKey: .playSoundOnRateLimitDetected)
        try container.encode(rateLimitDetectedSoundName, forKey: .rateLimitDetectedSoundName)
        try container.encode(notifyOnRateLimitLifted, forKey: .notifyOnRateLimitLifted)
        try container.encode(showSystemNotificationOnRateLimitLifted, forKey: .showSystemNotificationOnRateLimitLifted)
        try container.encode(rateLimitLiftedSoundName, forKey: .rateLimitLiftedSoundName)
        try container.encode(autoCheckForUpdates, forKey: .autoCheckForUpdates)
        try container.encodeIfPresent(skippedUpdateVersion, forKey: .skippedUpdateVersion)
        try container.encode(syncLocalPathsOnArchive, forKey: .syncLocalPathsOnArchive)
        try container.encode(appAppearanceMode, forKey: .appAppearanceMode)
        try container.encode(terminalMouseWheelBehavior, forKey: .terminalMouseWheelBehavior)
        try container.encode(showScrollToBottomIndicator, forKey: .showScrollToBottomIndicator)
        try container.encode(showTerminalScrollOverlay, forKey: .showTerminalScrollOverlay)
        try container.encode(showPromptTOCOverlay, forKey: .showPromptTOCOverlay)
        try container.encode(preserveAgentColorTheme, forKey: .preserveAgentColorTheme)
        try container.encode(rememberLastTypeSelection, forKey: .rememberLastTypeSelection)
        try container.encode(switchToNewlyCreatedThread, forKey: .switchToNewlyCreatedThread)
        try container.encode(switchToNewlyCreatedTab, forKey: .switchToNewlyCreatedTab)
        try container.encode(protectPinnedFromEviction, forKey: .protectPinnedFromEviction)
        try container.encodeIfPresent(maxIdleSessions, forKey: .maxIdleSessions)
        try container.encode(keyBindings, forKey: .keyBindings)
    }

    public var visibleSections: [ThreadSection] {
        threadSections.filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    public var defaultSection: ThreadSection? {
        let visible = visibleSections
        if let id = defaultSectionId, let match = visible.first(where: { $0.id == id }) {
            return match
        }
        return visible.first
    }

    public func defaultSection(for projectId: UUID) -> ThreadSection? {
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
    public func sections(for projectId: UUID) -> [ThreadSection] {
        if let project = projects.first(where: { $0.id == projectId }),
           let override = project.threadSections {
            return override
        }
        return threadSections
    }

    /// Returns visible sections for a specific project, sorted by sortOrder.
    public func visibleSections(for projectId: UUID) -> [ThreadSection] {
        sections(for: projectId).filter(\.isVisible).sorted { $0.sortOrder < $1.sortOrder }
    }

    public func shouldUseThreadSections(for projectId: UUID) -> Bool {
        if let project = projects.first(where: { $0.id == projectId }),
           let projectOverride = project.useThreadSectionsOverride {
            return projectOverride
        }
        return useThreadSections
    }

    public var sidebarDescriptionLineLimit: Int {
        narrowThreads ? 1 : 2
    }

    public var availableActiveAgents: [AgentType] {
        var seen = Set<AgentType>()
        return activeAgents.filter { seen.insert($0).inserted }
    }

    public var effectiveGlobalDefaultAgentType: AgentType? {
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

    public func command(for agentType: AgentType) -> String {
        switch agentType {
        case .claude:
            // Use `command claude` to bypass any shell function wrappers (same as codex).
            return agentSkipPermissions ? "command claude --dangerously-skip-permissions" : "command claude"
        case .codex:
            // Use `command codex` to bypass any shell function wrappers (e.g. ones that
            // inject --dangerously-bypass-approvals-and-sandbox) which would conflict with
            // our explicit flags like --yolo (an alias for the same flag in newer codex).
            if agentSkipPermissions {
                return "command codex --yolo"
            } else if agentSandboxEnabled {
                return "command codex --full-auto"
            } else {
                return "command codex"
            }
        case .custom:
            let trimmed = customAgentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "custom-agent" : trimmed
        }
    }

    public var jiraTicketDetectionPrefixFilterSet: Set<String> {
        Set(Self.parseJiraTicketDetectionPrefixes(jiraTicketDetectionPrefixes))
    }

    public static func parseJiraTicketDetectionPrefixes(_ rawValue: String) -> [String] {
        rawValue
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { token in
                token
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    .uppercased()
            }
            .filter { !$0.isEmpty }
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
        case showDockBadgeAndBounceForUnreadCompletions
        case autoRenameBranches
        case autoSetThreadDescription
        case autoSetThreadIconFromWorkType
        case narrowThreads
        case showPRStatusBadges
        case showJiraStatusBadges
        case showBusyStateDuration
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
        case jiraIntegrationEnabled
        case jiraSiteURL
        case jiraTicketDetectionEnabled
        case jiraTicketDetectionPrefixes
        case enableRateLimitDetection
        case playSoundOnRateLimitDetected
        case rateLimitDetectedSoundName
        case showSystemNotificationOnRateLimitLifted
        case notifyOnRateLimitLifted
        case rateLimitLiftedSoundName
        case autoCheckForUpdates
        case skippedUpdateVersion
        case syncLocalPathsOnArchive
        case externalLinkOpenPreference
        case appAppearanceMode
        case terminalMouseWheelBehavior
        case showScrollToBottomIndicator
        case showTerminalScrollOverlay
        case showPromptTOCOverlay
        case preserveAgentColorTheme
        case rememberLastTypeSelection
        case switchToNewlyCreatedThread
        case switchToNewlyCreatedTab
        case protectPinnedFromEviction
        case maxIdleSessions
        case keyBindings

        // Legacy keys kept for migration.
        case agentCommand
        case agentType
    }
}
