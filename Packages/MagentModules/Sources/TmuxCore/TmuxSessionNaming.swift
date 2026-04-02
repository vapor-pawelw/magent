import Foundation
import ShellInfra
import MagentModels

/// Centralizes tmux session naming conventions used by Magent.
public enum TmuxSessionNaming {

    public static func sanitizeForTmux(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .lowercased()
    }

    public static func repoSlug(from projectName: String) -> String {
        var slug = sanitizeForTmux(projectName)
        if slug.count > 16 {
            slug = String(slug.prefix(16))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug
    }

    public static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        var parts = ["ma", repoSlug]
        if let threadName {
            parts.append(threadName)
        }
        if let tabSlug {
            parts.append(tabSlug)
        }
        return parts.joined(separator: "-")
    }

    public static func defaultTabDisplayName(for agentType: AgentType?) -> String {
        switch agentType {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .custom: return "Custom"
        case .none: return "Terminal"
        }
    }

    public static func defaultTabDisplayName(
        for agentType: AgentType?,
        modelLabel: String? = nil,
        reasoningLevel: String? = nil
    ) -> String {
        var details: [String] = []
        if let modelLabel = displayModelLabel(modelLabel, for: agentType) {
            details.append(modelLabel)
        }
        if let reasoningLabel = displayReasoningLevelLabel(reasoningLevel) {
            details.append(reasoningLabel)
        }

        guard !details.isEmpty else { return defaultTabDisplayName(for: agentType) }
        return "\(defaultTabDisplayName(for: agentType)) (\(details.joined(separator: ", ")))"
    }

    private static func displayModelLabel(_ modelLabel: String?, for agentType: AgentType?) -> String? {
        let trimmed = modelLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }

        switch agentType {
        case .codex:
            let stripped = trimmed
                .replacingOccurrences(of: #"(?i)\bgpt\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)\b\d+(\.\d+)*\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        case .claude:
            return trimmed.caseInsensitiveCompare("Opus") == .orderedSame ? nil : trimmed
        case .custom:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func displayReasoningLevelLabel(_ reasoningLevel: String?) -> String? {
        let trimmed = reasoningLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "low":
            return "L"
        case "medium":
            return "M"
        case "high":
            return "H"
        case "xhigh":
            return "xH"
        case "max":
            return "Max"
        default:
            return trimmed
        }
    }

    public static func reviewTabDisplayName(for agentType: AgentType?, showAgentName: Bool) -> String {
        guard showAgentName else { return "Review" }
        return "Review (\(defaultTabDisplayName(for: agentType)))"
    }

    public static func isMagentSession(_ name: String) -> Bool {
        name.hasPrefix("ma-") || name.hasPrefix("magent-")
    }

    /// Renames session names produced by Magent without touching unrelated substrings.
    public static func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
        let oldPrefix = buildSessionName(repoSlug: repoSlug, threadName: oldName)
        let newPrefix = buildSessionName(repoSlug: repoSlug, threadName: newName)

        if sessionName == oldPrefix {
            return newPrefix
        }
        if sessionName.hasPrefix(oldPrefix + "-") {
            return newPrefix + String(sessionName.dropFirst(oldPrefix.count))
        }
        return sessionName
    }
}
