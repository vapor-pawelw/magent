import Foundation

public struct PullRequestCacheEntry: Codable, Sendable {
    public let number: Int
    public let url: URL
    public let provider: String
    public let isMerged: Bool
    public let cachedAt: Date

    public init(from info: PullRequestInfo, cachedAt: Date = Date()) {
        self.number = info.number
        self.url = info.url
        self.provider = info.provider.cacheKey
        self.isMerged = info.isMerged
        self.cachedAt = cachedAt
    }

    public func toPullRequestInfo() -> PullRequestInfo {
        PullRequestInfo(
            number: number,
            url: url,
            provider: GitHostingProvider.from(cacheKey: provider),
            isMerged: isMerged
        )
    }
}

extension GitHostingProvider {
    public var cacheKey: String {
        switch self {
        case .github: "github"
        case .gitlab: "gitlab"
        case .bitbucket: "bitbucket"
        case .unknown: "unknown"
        }
    }

    public static func from(cacheKey: String) -> GitHostingProvider {
        switch cacheKey {
        case "github": .github
        case "gitlab": .gitlab
        case "bitbucket": .bitbucket
        default: .unknown
        }
    }
}
