import Foundation

/// Lightweight semver parser used for launch-time version comparisons
/// (update checks, changelog/what's-new gating).
///
/// Parses `1`, `1.2`, `1.2.3`, optional leading `v`, and ignores any
/// pre-release / build suffix after the first `-` (`1.2.3-alpha` → `1.2.3`).
public struct SemanticVersion: Comparable, Sendable, Hashable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        let core = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? value
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard let majorPart = parts.indices.contains(0) ? Int(parts[0]) : nil else { return nil }
        let minorPart = parts.indices.contains(1) ? Int(parts[1]) : 0
        let patchPart = parts.indices.contains(2) ? Int(parts[2]) : 0
        guard let minorPart, let patchPart else { return nil }
        self.major = majorPart
        self.minor = minorPart
        self.patch = patchPart
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var displayString: String {
        "\(major).\(minor).\(patch)"
    }
}
