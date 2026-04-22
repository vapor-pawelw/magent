import Foundation
import MagentModels

/// Lightweight snapshot used to detect tab-structure changes coming from outside
/// the active `ThreadDetailViewController` instance (for example CLI tab creation).
///
/// This intentionally ignores transient state (busy, waiting, unread markers) and
/// tracks only tab identity/order/pinning across terminal, web, and draft tabs.
public struct ThreadTabStructureFingerprint: Equatable, Sendable {
    public struct WebTab: Equatable, Sendable {
        public let identifier: String
        public let isPinned: Bool

        public init(identifier: String, isPinned: Bool) {
            self.identifier = identifier
            self.isPinned = isPinned
        }
    }

    public let terminalSessionNames: [String]
    public let pinnedTerminalSessions: [String]
    public let webTabs: [WebTab]
    public let draftTabIdentifiers: [String]

    public init(thread: MagentThread) {
        self.terminalSessionNames = thread.tmuxSessionNames
        self.pinnedTerminalSessions = thread.pinnedTmuxSessions.sorted()
        self.webTabs = thread.persistedWebTabs.map { persisted in
            WebTab(identifier: persisted.identifier, isPinned: persisted.isPinned)
        }
        self.draftTabIdentifiers = thread.persistedDraftTabs.map(\.identifier)
    }
}
