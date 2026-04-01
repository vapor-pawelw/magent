import Foundation

public enum LocalFileSyncMode: String, Codable, Sendable, CaseIterable {
    case copy
    case symlink

    public var displayName: String {
        switch self {
        case .copy:
            return "Copy"
        case .symlink:
            return "Shared Link"
        }
    }
}

public struct LocalFileSyncEntry: Codable, Hashable, Sendable {
    public var path: String
    public var mode: LocalFileSyncMode

    public init(path: String, mode: LocalFileSyncMode = .copy) {
        self.path = path
        self.mode = mode
    }
}

public nonisolated struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var repoPath: String
    public var worktreesBasePath: String
    public var defaultBranch: String?
    public var agentType: AgentType?
    public var terminalInjectionCommand: String?
    public var preAgentInjectionCommand: String?
    public var agentContextInjection: String?
    public var autoRenameSlugPrompt: String?
    public var isPinned: Bool
    public var isHidden: Bool
    public var useThreadSectionsOverride: Bool?
    public var defaultSectionId: UUID?
    public var threadSections: [ThreadSection]?
    public var jiraProjectKey: String?
    public var jiraBoardId: Int?
    public var jiraBoardName: String?
    public var jiraSyncEnabled: Bool
    public var jiraSiteURL: String?
    public var jiraExcludedTicketKeys: Set<String>
    public var jiraAssigneeAccountId: String?
    public var jiraAcknowledgedStatuses: Set<String>?
    public var localFileSyncEntries: [LocalFileSyncEntry]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case repoPath
        case worktreesBasePath
        case defaultBranch
        case agentType
        case terminalInjectionCommand
        case preAgentInjectionCommand
        case agentContextInjection
        case autoRenameSlugPrompt
        case isPinned
        case isHidden
        case useThreadSectionsOverride
        case defaultSectionId
        case threadSections
        case jiraProjectKey
        case jiraBoardId
        case jiraBoardName
        case jiraSyncEnabled
        case jiraSiteURL
        case jiraExcludedTicketKeys
        case jiraAssigneeAccountId
        case jiraAcknowledgedStatuses
        case localFileSyncEntries
        case localFileSyncPaths
    }

    public init(
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
        jiraAcknowledgedStatuses: Set<String>? = nil,
        localFileSyncEntries: [LocalFileSyncEntry] = []
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
        self.localFileSyncEntries = localFileSyncEntries
    }

    public init(from decoder: Decoder) throws {
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
        if let decodedEntries = try container.decodeIfPresent([LocalFileSyncEntry].self, forKey: .localFileSyncEntries) {
            localFileSyncEntries = decodedEntries
        } else {
            let legacyPaths = try container.decodeIfPresent([String].self, forKey: .localFileSyncPaths) ?? []
            localFileSyncEntries = legacyPaths.map { LocalFileSyncEntry(path: $0, mode: .copy) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(repoPath, forKey: .repoPath)
        try container.encode(worktreesBasePath, forKey: .worktreesBasePath)
        try container.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try container.encodeIfPresent(agentType, forKey: .agentType)
        try container.encodeIfPresent(terminalInjectionCommand, forKey: .terminalInjectionCommand)
        try container.encodeIfPresent(preAgentInjectionCommand, forKey: .preAgentInjectionCommand)
        try container.encodeIfPresent(agentContextInjection, forKey: .agentContextInjection)
        try container.encodeIfPresent(autoRenameSlugPrompt, forKey: .autoRenameSlugPrompt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encodeIfPresent(useThreadSectionsOverride, forKey: .useThreadSectionsOverride)
        try container.encodeIfPresent(defaultSectionId, forKey: .defaultSectionId)
        try container.encodeIfPresent(threadSections, forKey: .threadSections)
        try container.encodeIfPresent(jiraProjectKey, forKey: .jiraProjectKey)
        try container.encodeIfPresent(jiraBoardId, forKey: .jiraBoardId)
        try container.encodeIfPresent(jiraBoardName, forKey: .jiraBoardName)
        try container.encode(jiraSyncEnabled, forKey: .jiraSyncEnabled)
        try container.encodeIfPresent(jiraSiteURL, forKey: .jiraSiteURL)
        try container.encode(jiraExcludedTicketKeys, forKey: .jiraExcludedTicketKeys)
        try container.encodeIfPresent(jiraAssigneeAccountId, forKey: .jiraAssigneeAccountId)
        try container.encodeIfPresent(jiraAcknowledgedStatuses, forKey: .jiraAcknowledgedStatuses)
        try container.encode(normalizedLocalFileSyncEntries, forKey: .localFileSyncEntries)
        try container.encode(normalizedLocalFileSyncPaths, forKey: .localFileSyncPaths)
    }

    /// Resolves template variables in `worktreesBasePath` (e.g. `$MAGENT_PROJECT_NAME`).
    public func resolvedWorktreesBasePath() -> String {
        worktreesBasePath.replacingOccurrences(of: "$MAGENT_PROJECT_NAME", with: name)
    }

    /// Whether the repo path still points to an existing directory.
    public var isValid: Bool {
        FileManager.default.fileExists(atPath: repoPath)
    }

    /// Suggests a default worktrees base path using the `$MAGENT_PROJECT_NAME` template variable.
    public static func suggestedWorktreesPath(for repoPath: String) -> String {
        let url = URL(fileURLWithPath: repoPath)
        let parent = url.deletingLastPathComponent().path
        return "\(parent)/.worktrees-$MAGENT_PROJECT_NAME"
    }

    public static func normalizeLocalFileSyncEntries(_ entries: [LocalFileSyncEntry]) -> [LocalFileSyncEntry] {
        var seen = Set<String>()
        var normalized: [LocalFileSyncEntry] = []
        for rawEntry in entries {
            guard let entry = normalizeLocalFileSyncEntry(rawEntry),
                  seen.insert(entry.path).inserted else { continue }
            normalized.append(entry)
        }
        return normalized
    }

    public static func normalizeLocalFileSyncEntry(_ entry: LocalFileSyncEntry) -> LocalFileSyncEntry? {
        guard let path = normalizeLocalFileSyncPath(entry.path) else { return nil }
        return LocalFileSyncEntry(path: path, mode: entry.mode)
    }

    public static func normalizeLocalFileSyncPaths(_ paths: [String]) -> [String] {
        normalizeLocalFileSyncEntries(paths.map { LocalFileSyncEntry(path: $0, mode: .copy) }).map(\.path)
    }

    public static func normalizeLocalFileSyncPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed.replacingOccurrences(of: "\\", with: "/")
        while candidate.hasPrefix("./") {
            candidate.removeFirst(2)
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !candidate.isEmpty, !candidate.hasPrefix("~") else { return nil }

        let segments = candidate.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        for segment in segments where segment == "." || segment == ".." {
            return nil
        }

        return segments.joined(separator: "/")
    }

    public var normalizedLocalFileSyncPaths: [String] {
        normalizedLocalFileSyncEntries.map(\.path)
    }

    public var normalizedLocalFileSyncEntries: [LocalFileSyncEntry] {
        Self.normalizeLocalFileSyncEntries(localFileSyncEntries)
    }

    public var hasCopyLocalFileSyncEntries: Bool {
        normalizedLocalFileSyncEntries.contains { $0.mode == .copy }
    }
}
