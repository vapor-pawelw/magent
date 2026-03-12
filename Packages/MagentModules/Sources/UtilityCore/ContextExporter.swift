import Foundation
import ShellInfra
import MagentModels

public enum ContextExporter {
    private static let legacyContextFileName = ".magent-context.md"
    private static let transferDirectoryName = ".magent-context"
    private static let transferFilePrefix = "transfer-"
    public static let transferFileTTL: TimeInterval = 60 * 60

    // MARK: - ANSI Stripping

    /// Strips ANSI escape sequences (CSI, OSC, SGR, cursor movement, C1 controls, SI/SO).
    public static func stripANSI(_ text: String) -> String {
        let patterns = [
            "\\x1B\\[[0-9;]*[A-Za-z]",                     // CSI sequences
            "\\x1B\\][^\\x07\\x1B]*(\\x07|\\x1B\\\\)",     // OSC sequences
            "\\x1B[()][0-9A-Za-z]",                         // Charset selection
            "[\\x80-\\x9F]",                                // C1 control codes
            "\\x0E|\\x0F",                                  // SI/SO shift codes
            "\\x1B[=>]",                                    // Keypad mode
        ]
        let combined = patterns.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: combined) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Line Wrapping

    /// Wraps lines exceeding maxChars at word boundaries; shorter lines pass through.
    public static func wrapLongLines(_ text: String, maxChars: Int = 500) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            guard s.count > maxChars else { return s }
            return wrapSingleLine(s, maxChars: maxChars)
        }.joined(separator: "\n")
    }

    private static func wrapSingleLine(_ line: String, maxChars: Int) -> String {
        var result: [String] = []
        var remaining = line[...]
        while remaining.count > maxChars {
            let chunk = remaining.prefix(maxChars)
            if let lastSpace = chunk.lastIndex(of: " ") {
                result.append(String(remaining[remaining.startIndex..<lastSpace]))
                remaining = remaining[remaining.index(after: lastSpace)...]
            } else {
                // No space found — hard break
                let breakIndex = remaining.index(remaining.startIndex, offsetBy: maxChars)
                result.append(String(remaining[remaining.startIndex..<breakIndex]))
                remaining = remaining[breakIndex...]
            }
        }
        if !remaining.isEmpty {
            result.append(String(remaining))
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Markdown Formatting

    /// Formats cleaned content into markdown with metadata header.
    public static func formatAsMarkdown(
        rawContent: String,
        sourceAgent: AgentType?,
        threadName: String,
        projectName: String
    ) -> String {
        let cleaned = wrapLongLines(stripANSI(rawContent))
        let agentName = sourceAgent?.displayName ?? "Terminal"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = dateFormatter.string(from: Date())

        return """
        # Agent Context Transfer

        - **Source**: \(agentName)
        - **Thread**: \(threadName)
        - **Project**: \(projectName)
        - **Captured**: \(timestamp)

        ---

        \(cleaned)
        """
    }

    // MARK: - File Writing

    /// Writes markdown to a unique transient markdown file under the project's worktrees base path.
    public static func writeContextFile(markdown: String, inWorktreesBasePath basePath: String) -> String? {
        let fileManager = FileManager.default
        let transferDirectory = contextTransferDirectoryPath(in: basePath)
        let path = (transferDirectory as NSString).appendingPathComponent(uniqueTransferFileName())
        do {
            cleanupExpiredContextFiles(worktreesBasePaths: [basePath])
            try fileManager.createDirectory(
                atPath: transferDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            scheduleCleanup(path: path, delay: transferFileTTL)
            return path
        } catch {
            return nil
        }
    }

    /// Deletes a context file after a delay. The agent should have read it by then.
    private static func scheduleCleanup(path: String, delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Removes expired transfer files from all known worktrees-base directories and legacy files from worktrees.
    public static func cleanupExpiredContextFiles(
        worktreePaths: [String] = [],
        worktreesBasePaths: [String],
        maxAge: TimeInterval = transferFileTTL
    ) {
        cleanupLegacyContextFiles(worktreePaths: worktreePaths)
        let now = Date()
        let fileManager = FileManager.default
        for basePath in Set(worktreesBasePaths) {
            let directoryPath = contextTransferDirectoryPath(in: basePath)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: directoryPath, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for entry in entries where shouldDeleteTransferFile(at: entry, now: now, maxAge: maxAge) {
                try? fileManager.removeItem(at: entry)
            }

            removeTransferDirectoryIfEmpty(directoryPath: directoryPath)
        }
    }

    /// Removes any leftover transfer files from all known worktrees-base directories and legacy files from worktrees.
    public static func cleanupAllContextFiles(worktreePaths: [String], worktreesBasePaths: [String]) {
        cleanupLegacyContextFiles(worktreePaths: worktreePaths)
        for basePath in Set(worktreesBasePaths) {
            let directoryPath = contextTransferDirectoryPath(in: basePath)
            try? FileManager.default.removeItem(atPath: directoryPath)
        }
    }

    private static func cleanupLegacyContextFiles(worktreePaths: [String]) {
        for dir in worktreePaths {
            let path = (dir as NSString).appendingPathComponent(legacyContextFileName)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func contextTransferDirectoryPath(in basePath: String) -> String {
        (basePath as NSString).appendingPathComponent(transferDirectoryName)
    }

    private static func uniqueTransferFileName() -> String {
        "\(transferFilePrefix)\(UUID().uuidString.lowercased()).md"
    }

    private static func shouldDeleteTransferFile(at fileURL: URL, now: Date, maxAge: TimeInterval) -> Bool {
        guard fileURL.lastPathComponent.hasPrefix(transferFilePrefix) else { return false }
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modifiedAt = values?.contentModificationDate else { return true }
        return now.timeIntervalSince(modifiedAt) >= maxAge
    }

    private static func removeTransferDirectoryIfEmpty(directoryPath: String) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryPath),
              contents.isEmpty else {
            return
        }
        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    // MARK: - Transfer Prompt

    /// Builds the initial prompt for the receiving agent.
    public static func transferPrompt(contextFilePath: String) -> String {
        return "Read \(contextFilePath) for context from the previous session. Continue where it left off. If work was interrupted or unfinished, resume and complete it first. Report progress and results directly. Ask what to do next only if no clear unfinished task remains."
    }
}
