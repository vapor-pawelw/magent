import Foundation
import MagentCore

extension ThreadManager {

    // MARK: - Model Change Detection

    /// Scans agent sessions for Claude's "Set model to …" / Codex's "• Model changed to …"
    /// output and updates tab display names to reflect the current model/effort — skipping
    /// any tab the user has manually renamed.
    ///
    /// Called on the session monitor's 10-tick cadence (~50 s). Not time-critical; a brief
    /// lag between the user switching models and the tab name updating is acceptable.
    func syncTabNamesFromModelChanges() async {
        var changed = false
        var changedThreadIds: Set<UUID> = []

        for i in threads.indices {
            let thread = threads[i]
            for session in thread.agentTmuxSessions {
                let agentType = thread.sessionAgentTypes[session]
                guard agentType == .claude || agentType == .codex else { continue }

                // Skip tabs the user has explicitly renamed — either via the rename dialog
                // after this feature shipped, or populated by the startup migration for tabs
                // that carried a non-default name before this feature existed.
                guard !thread.manuallyRenamedTabs.contains(session) else { continue }

                let currentName = thread.customTabNames[session] ?? ""

                guard let paneContent = await tmux.cachedCapturePane(sessionName: session, lastLines: 300) else { continue }

                let modelLabel: String
                let effortLevel: String?
                switch agentType {
                case .claude:
                    guard let parsed = parseClaudeModelChange(from: paneContent) else { continue }
                    modelLabel = parsed.modelLabel
                    effortLevel = parsed.effortLevel
                case .codex:
                    guard let parsed = parseCodexModelChange(from: paneContent) else { continue }
                    // Prefer the human label from the manifest so the compact formatter can
                    // cleanly strip the "GPT" vendor prefix. If the id isn't in the manifest
                    // (stale cache, new release), fall back to a spacified raw id so
                    // displayModelLabel still recognises the "gpt" token to strip.
                    if let resolved = resolvedModelLabel(for: .codex, modelId: parsed.modelId) {
                        modelLabel = resolved
                    } else {
                        modelLabel = parsed.modelId.replacingOccurrences(of: "-", with: " ")
                    }
                    effortLevel = parsed.effortLevel
                default:
                    continue
                }

                let newName = TmuxSessionNaming.defaultTabDisplayName(
                    for: agentType,
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
    /// Scans the full capture window from the bottom up so the most recent `/model` run
    /// wins even when the user ran `/model` multiple times in the same session. Do NOT
    /// scope to the latest terminal block the way rate-limit detection does: Claude Code's
    /// input box is bordered by full-width `─` rules, so "lines after the last separator"
    /// only ever sees the input box itself and any `Set model to …` line in the conversation
    /// history above is silently dropped.
    ///
    /// Returns nil if no model-change line is found.
    func parseClaudeModelChange(from paneContent: String) -> (modelLabel: String, effortLevel: String?)? {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.reversed().lazy.compactMap { Self.parseModelChangeLine(String($0)) }.first
    }

    /// Extracts the last "• Model changed to <modelId> <effort>" line from `paneContent` and
    /// returns the parsed raw model id plus optional effort level.
    ///
    /// Codex writes this line after a `/model` switch (for example
    /// `• Model changed to gpt-5.3-codex medium`), so the id matches the entries in
    /// `agent-models.json` and can be looked up through `AgentModelsService`.
    ///
    /// Same whole-capture scan as `parseClaudeModelChange` — see that method for why we
    /// deliberately don't scope to the latest block.
    ///
    /// Returns nil if no model-change line is found.
    func parseCodexModelChange(from paneContent: String) -> (modelId: String, effortLevel: String?)? {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.reversed().lazy.compactMap { Self.parseCodexModelChangeLine(String($0)) }.first
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

    /// Parses a single line for the Codex model-change pattern:
    ///   `• Model changed to <modelId> <effort>`
    ///   `• Model changed to <modelId>`
    ///
    /// The leading "•" bullet is optional — we strip leading whitespace and any leading
    /// bullets/spaces before matching. The first whitespace-delimited token after the
    /// prefix is treated as the model id (Codex ids are hyphen-separated, never contain
    /// spaces), and the second token (if present) is the reasoning level.
    private static func parseCodexModelChangeLine(_ line: String) -> (modelId: String, effortLevel: String?)? {
        let stripped = line
            .trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "•" || $0 == " " })

        guard stripped.hasPrefix("Model changed to ") else { return nil }

        let remainder = String(stripped.dropFirst("Model changed to ".count)).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        let tokens = remainder.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let modelId = tokens.first, !modelId.isEmpty else { return nil }
        let effortLevel = tokens.count >= 2 ? tokens[1] : nil
        return (modelId, effortLevel)
    }
}
