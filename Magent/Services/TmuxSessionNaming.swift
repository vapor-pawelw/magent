import Foundation

/// Centralizes tmux session naming conventions used by Magent.
enum TmuxSessionNaming {

    static func sanitizeForTmux(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .lowercased()
    }

    static func repoSlug(from projectName: String) -> String {
        var slug = sanitizeForTmux(projectName)
        if slug.count > 16 {
            slug = String(slug.prefix(16))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return slug
    }

    static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        var parts = ["ma", repoSlug]
        if let threadName {
            parts.append(threadName)
        }
        if let tabSlug {
            parts.append(tabSlug)
        }
        return parts.joined(separator: "-")
    }

    static func defaultTabDisplayName(for agentType: AgentType?) -> String {
        switch agentType {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .custom: return "Custom"
        case .none: return "Terminal"
        }
    }

    static func isMagentSession(_ name: String) -> Bool {
        name.hasPrefix("ma-") || name.hasPrefix("magent-")
    }

    /// Renames session names produced by Magent without touching unrelated substrings.
    static func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
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
