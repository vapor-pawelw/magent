import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Model Change Detection

    /// Scans agent sessions for Claude's "Set model to …" output and updates tab display
    /// names to reflect the current model/effort — skipping any tab the user has manually
    /// renamed.
    ///
    /// Called on the session monitor's 10-tick cadence (~50 s). Not time-critical; a brief
    /// lag between the user switching models and the tab name updating is acceptable.
    func syncTabNamesFromModelChanges() async {
        var changed = false
        var changedThreadIds: Set<UUID> = []

        for i in threads.indices {
            let thread = threads[i]
            for session in thread.agentTmuxSessions {
                guard thread.sessionAgentTypes[session] == .claude else { continue }

                // Guard 1: user has explicitly renamed this tab via the rename dialog —
                // never overwrite their choice.
                guard !thread.manuallyRenamedTabs.contains(session) else { continue }

                // Guard 2: only update if the current name looks auto-generated. This
                // protects tabs that were manually named *before* this feature shipped,
                // when manuallyRenamedTabs was still empty for all existing threads.
                let currentName = thread.customTabNames[session] ?? ""
                guard TmuxSessionNaming.looksLikeDefaultTabName(currentName, for: .claude) else { continue }

                guard let paneContent = await tmux.cachedCapturePane(sessionName: session, lastLines: 80) else { continue }

                guard let (modelLabel, effortLevel) = parseClaudeModelChange(from: paneContent) else { continue }

                let newName = TmuxSessionNaming.defaultTabDisplayName(
                    for: .claude,
                    modelLabel: modelLabel,
                    reasoningLevel: effortLevel
                )
                guard newName != currentName else { continue }

                threads[i].customTabNames[session] = newName
                changed = true
                changedThreadIds.insert(thread.id)
            }
        }

        guard changed else { return }

        try? persistence.saveActiveThreads(threads)
        let updatedThreads = threads
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: updatedThreads)
        }
    }

    // MARK: - Parsing

    /// Extracts the last "Set model to <Model>" or "Set model to <Model> with <effort> effort"
    /// line from `paneContent` and returns the parsed model label and optional effort level.
    ///
    /// Scopes to the latest terminal block (content after the last horizontal separator line),
    /// matching the pattern used by rate-limit detection to avoid stale scrollback matches.
    ///
    /// Returns nil if no model-change line is found.
    func parseClaudeModelChange(from paneContent: String) -> (modelLabel: String, effortLevel: String?)? {
        let allLines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)

        // Scope to the latest block — everything after the last separator (same heuristic as
        // rate-limit detection). Falls back to the full tail if there's no separator.
        let scopedLines: [String]
        if let separatorIdx = allLines.lastIndex(where: Self.isModelDetectionScopeSeparator) {
            scopedLines = Array(allLines[(allLines.index(after: separatorIdx)...)])
        } else {
            scopedLines = allLines
        }

        // Scan from the bottom — we want the *last* model-change line, which reflects the
        // current model even if the user ran /model multiple times in the same session.
        return scopedLines.reversed().lazy.compactMap { Self.parseModelChangeLine($0) }.first
    }

    /// Returns true if the line looks like a Claude/Codex block separator (a long horizontal
    /// rule of dashes or box-drawing chars), used to scope parsing to the latest pane block.
    private static func isModelDetectionScopeSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20 else { return false }
        return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
    }

    /// Parses a single line for the Claude model-change pattern:
    ///   `Set model to <ModelName>`
    ///   `Set model to <ModelName> with <effort> effort`
    ///
    /// The "⎿ " prefix that Claude Code prepends to tool-result lines is optional — we strip
    /// leading whitespace and any leading "⎿" before matching, so the regex stays simple.
    private static func parseModelChangeLine(_ line: String) -> (modelLabel: String, effortLevel: String?)? {
        // Strip leading whitespace and the "⎿" result indicator Claude Code uses.
        let stripped = line
            .trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "⎿" || $0 == " " })

        guard stripped.hasPrefix("Set model to ") else { return nil }

        let remainder = String(stripped.dropFirst("Set model to ".count)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        // Check for the optional "with <effort> effort" suffix.
        // Pattern: "<ModelName> with <effort> effort"
        if let withRange = remainder.range(of: #" with (\w+) effort$"#, options: .regularExpression) {
            let modelLabel = String(remainder[remainder.startIndex..<withRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            // Extract the effort word between "with " and " effort".
            let withClause = String(remainder[withRange]).trimmingCharacters(in: .whitespaces)
            // "with high effort" → "high"
            let effortWord = withClause
                .replacingOccurrences(of: "^with ", with: "", options: .regularExpression)
                .replacingOccurrences(of: " effort$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !modelLabel.isEmpty, !effortWord.isEmpty else { return nil }
            return (modelLabel, effortWord)
        }

        // No effort suffix — model name only.
        return (remainder, nil)
    }
}
