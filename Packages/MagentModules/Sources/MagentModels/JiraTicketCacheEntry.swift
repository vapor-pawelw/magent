import Foundation

public struct JiraTicketCacheEntry: Codable, Sendable, Equatable {
    public let key: String
    public let summary: String
    public let status: String
    /// The Jira status category key: "new", "indeterminate", or "done".
    public let statusCategoryKey: String?
    public let verifiedAt: Date

    public init(key: String, summary: String, status: String, statusCategoryKey: String? = nil, verifiedAt: Date = Date()) {
        self.key = key
        self.summary = summary
        self.status = status
        self.statusCategoryKey = statusCategoryKey
        self.verifiedAt = verifiedAt
    }

    /// Compares only display-relevant fields; `verifiedAt` is a cache bookkeeping timestamp.
    public static func == (lhs: JiraTicketCacheEntry, rhs: JiraTicketCacheEntry) -> Bool {
        lhs.key == rhs.key
            && lhs.summary == rhs.summary
            && lhs.status == rhs.status
            && lhs.statusCategoryKey == rhs.statusCategoryKey
    }
}
