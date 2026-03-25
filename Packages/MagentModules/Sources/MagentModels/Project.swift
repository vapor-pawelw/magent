import Foundation

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
    public var localFileSyncPaths: [String]
    public var archiveCleanupGlobs: [String]

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
        localFileSyncPaths: [String] = [],
        archiveCleanupGlobs: [String] = []
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
        self.localFileSyncPaths = localFileSyncPaths
        self.archiveCleanupGlobs = archiveCleanupGlobs
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
        localFileSyncPaths = try container.decodeIfPresent([String].self, forKey: .localFileSyncPaths) ?? []
        archiveCleanupGlobs = try container.decodeIfPresent([String].self, forKey: .archiveCleanupGlobs) ?? []
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

    public static func normalizeLocalFileSyncPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for rawPath in paths {
            guard let value = normalizeLocalFileSyncPath(rawPath), seen.insert(value).inserted else { continue }
            normalized.append(value)
        }
        return normalized
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
        Self.normalizeLocalFileSyncPaths(localFileSyncPaths)
    }

    public static func normalizeArchiveCleanupGlobs(_ globs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for rawGlob in globs {
            var trimmed = rawGlob.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Reject absolute paths and home-dir expansion
            guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { continue }
            // Strip leading ./ prefixes
            while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
            // Reject patterns containing .. path traversal
            let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !segments.contains(".."), !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    public var normalizedArchiveCleanupGlobs: [String] {
        Self.normalizeArchiveCleanupGlobs(archiveCleanupGlobs)
    }
}
