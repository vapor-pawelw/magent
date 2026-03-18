import Foundation

public struct PullRequestCacheEntry: Codable, Sendable {
    public let number: Int
    public let url: URL
    public let provider: String
    public let isMerged: Bool
    public let isDraft: Bool
    public let reviewDecision: ReviewDecision?
    public let isClosed: Bool
    public let cachedAt: Date

    private enum CodingKeys: String, CodingKey {
        case number, url, provider, isMerged, isDraft, reviewDecision, isClosed, cachedAt
    }

    public init(from info: PullRequestInfo, cachedAt: Date = Date()) {
        self.number = info.number
        self.url = info.url
        self.provider = info.provider.cacheKey
        self.isMerged = info.isMerged
        self.isDraft = info.isDraft
        self.reviewDecision = info.reviewDecision
        self.isClosed = info.isClosed
        self.cachedAt = cachedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        url = try container.decode(URL.self, forKey: .url)
        provider = try container.decode(String.self, forKey: .provider)
        isMerged = try container.decode(Bool.self, forKey: .isMerged)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        // Decode as string for backward compat, then map to enum (unknown values become nil).
        reviewDecision = try container.decodeIfPresent(String.self, forKey: .reviewDecision)
            .flatMap { ReviewDecision(rawValue: $0) }
        isClosed = try container.decodeIfPresent(Bool.self, forKey: .isClosed) ?? false
        cachedAt = try container.decode(Date.self, forKey: .cachedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(url, forKey: .url)
        try container.encode(provider, forKey: .provider)
        try container.encode(isMerged, forKey: .isMerged)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encodeIfPresent(reviewDecision?.rawValue, forKey: .reviewDecision)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encode(cachedAt, forKey: .cachedAt)
    }

    public func toPullRequestInfo() -> PullRequestInfo {
        PullRequestInfo(
            number: number,
            url: url,
            provider: GitHostingProvider.from(cacheKey: provider),
            isMerged: isMerged,
            isDraft: isDraft,
            reviewDecision: reviewDecision,
            isClosed: isClosed
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
