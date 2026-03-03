import Foundation

enum ContextExporter {

    // MARK: - ANSI Stripping

    /// Strips ANSI escape sequences (CSI, OSC, SGR, cursor movement, C1 controls, SI/SO).
    static func stripANSI(_ text: String) -> String {
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
    static func wrapLongLines(_ text: String, maxChars: Int = 500) -> String {
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
    static func formatAsMarkdown(
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

    /// Writes markdown to `.magent-context.md` in the given directory. Returns absolute path on success.
    static func writeContextFile(markdown: String, in directory: String) -> String? {
        let path = (directory as NSString).appendingPathComponent(".magent-context.md")
        do {
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            scheduleCleanup(path: path, delay: 60)
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

    /// Removes any leftover `.magent-context.md` files from all known worktree directories.
    static func cleanupAllContextFiles(worktreePaths: [String]) {
        for dir in worktreePaths {
            let path = (dir as NSString).appendingPathComponent(".magent-context.md")
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Transfer Prompt

    /// Builds the initial prompt for the receiving agent.
    static func transferPrompt(contextFilePath: String) -> String {
        return "Read \(contextFilePath) for context from the previous session. Continue where it left off. If work was interrupted or unfinished, resume and complete it first. Report progress and results directly. Ask what to do next only if no clear unfinished task remains."
    }
}
