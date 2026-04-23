import Foundation

public nonisolated struct ClosedTerminalTabSnapshot: Sendable, Equatable {
    public var displayName: String
    public var isAgentTab: Bool
    public var agentType: AgentType?
    public var resumeSessionID: String?
    public var startFresh: Bool
    public var isForwardedContinuation: Bool
    public var isPinned: Bool

    public init(
        displayName: String,
        isAgentTab: Bool,
        agentType: AgentType?,
        resumeSessionID: String?,
        startFresh: Bool,
        isForwardedContinuation: Bool,
        isPinned: Bool
    ) {
        self.displayName = displayName
        self.isAgentTab = isAgentTab
        self.agentType = agentType
        self.resumeSessionID = resumeSessionID
        self.startFresh = startFresh
        self.isForwardedContinuation = isForwardedContinuation
        self.isPinned = isPinned
    }
}

public nonisolated enum ClosedTabSnapshot: Sendable, Equatable {
    case terminal(ClosedTerminalTabSnapshot)
    case web(PersistedWebTab)
    case draft(PersistedDraftTab)
}

public nonisolated struct ClosedTabHistoryBuffer: Sendable, Equatable {
    public static let defaultLimit = 10

    public let limit: Int
    public private(set) var entries: [ClosedTabSnapshot]

    public init(limit: Int = ClosedTabHistoryBuffer.defaultLimit, entries: [ClosedTabSnapshot] = []) {
        self.limit = max(1, limit)
        if entries.count > self.limit {
            self.entries = Array(entries.suffix(self.limit))
        } else {
            self.entries = entries
        }
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public mutating func push(_ entry: ClosedTabSnapshot) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    public mutating func popLast() -> ClosedTabSnapshot? {
        entries.popLast()
    }
}
