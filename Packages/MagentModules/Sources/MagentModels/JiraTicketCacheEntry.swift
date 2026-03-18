import Foundation

public struct JiraTicketCacheEntry: Codable, Sendable {
    public let key: String
    public let summary: String
    public let status: String
    public let verifiedAt: Date

    public init(key: String, summary: String, status: String, verifiedAt: Date = Date()) {
        self.key = key
        self.summary = summary
        self.status = status
        self.verifiedAt = verifiedAt
    }
}
