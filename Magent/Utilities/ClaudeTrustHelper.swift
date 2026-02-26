import Foundation

/// Pre-trusts directories in ~/.claude.json so claude doesn't show the "Do you trust this folder?" dialog.
enum ClaudeTrustHelper {

    private static let claudeJsonURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude.json")
    }()

    /// Marks the given directory as trusted in ~/.claude.json
    static func trustDirectory(_ path: String) {
        var root = loadClaudeJson()

        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[path] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[path] = entry
        root["projects"] = projects

        saveClaudeJson(root)
    }

    private static func loadClaudeJson() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeJsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func saveClaudeJson(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: claudeJsonURL, options: .atomic)
    }
}

/// Pre-trusts directories in ~/.codex/config.toml so codex doesn't show trust prompts.
enum CodexTrustHelper {

    private static let configURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/config.toml")
    }()

    static func trustDirectory(_ path: String) {
        let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
        let header = "[projects.\"\(escapedPath)\"]"
        let trustLine = "trust_level = \"trusted\""

        var lines = loadLines()
        if let headerIndex = lines.firstIndex(of: header) {
            var idx = headerIndex + 1
            var inserted = false
            while idx < lines.count, !lines[idx].hasPrefix("[") {
                if lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("trust_level") {
                    lines[idx] = trustLine
                    inserted = true
                    break
                }
                idx += 1
            }
            if !inserted {
                lines.insert(trustLine, at: idx)
            }
            saveLines(lines)
            return
        }

        if !lines.isEmpty, !lines.last!.isEmpty {
            lines.append("")
        }
        lines.append(header)
        lines.append(trustLine)
        saveLines(lines)
    }

    private static func loadLines() -> [String] {
        guard let data = try? Data(contentsOf: configURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.components(separatedBy: .newlines)
    }

    private static func saveLines(_ lines: [String]) {
        let directory = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let text = lines.joined(separator: "\n")
        guard let data = text.data(using: .utf8) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}
