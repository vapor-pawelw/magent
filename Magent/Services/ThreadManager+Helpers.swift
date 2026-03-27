import AppKit
import Foundation
import UserNotifications
import MagentCore

extension ThreadManager {
    private static let agentPromptCaptureLines = 120
    private static let agentPromptTimeoutLogLines = 8
    private static let recentPromptDetectionLines = 12

    // MARK: - Session Environment

    func sessionEnvironmentVariables(
        threadId: UUID,
        worktreePath: String? = nil,
        projectPath: String,
        worktreeName: String,
        projectName: String,
        agentType: AgentType? = nil
    ) -> [(String, String)] {
        var envVars: [(String, String)] = [
            ("MAGENT_PROJECT_PATH", projectPath),
            ("MAGENT_WORKTREE_NAME", worktreeName),
            ("MAGENT_PROJECT_NAME", projectName),
            ("MAGENT_THREAD_ID", threadId.uuidString),
            ("MAGENT_SOCKET", IPCSocketServer.socketPath),
        ]
        if let worktreePath {
            envVars.insert(("MAGENT_WORKTREE_PATH", worktreePath), at: 0)
        }
        if let agentType {
            envVars.append(("MAGENT_AGENT_TYPE", agentType.rawValue))
        }
        return envVars
    }

    func shellExportCommand(for environmentVariables: [(String, String)]) -> String {
        environmentVariables
            .map { key, value in
                "export \(key)=\(ShellExecutor.shellQuote(value))"
            }
            .joined(separator: " && ")
    }

    func applySessionEnvironmentVariables(
        sessionName: String,
        environmentVariables: [(String, String)]
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for (key, value) in environmentVariables {
                group.addTask { [tmux] in
                    try? await tmux.setEnvironment(sessionName: sessionName, key: key, value: value)
                }
            }
        }
    }

    // MARK: - Agent Readiness

    /// Waits until the pane can be captured, which is enough to start sending keys.
    /// This avoids paying a fixed startup delay on fast machines while still giving
    /// tmux a brief window to finish creating the pane on slower ones.
    private func waitForPaneCaptureReady(
        sessionName: String,
        timeout: TimeInterval = 1.0,
        interval: TimeInterval = 0.05
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await tmux.capturePane(sessionName: sessionName, lastLines: 1) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    /// Polls tmux pane content for the actual agent input prompt marker.
    /// Returns `true` only when the user prompt is visible, or `false` on timeout.
    /// For agents that show placeholder text on the prompt line (e.g. Codex),
    /// uses ANSI-aware capture to distinguish placeholder from user-typed text
    /// and only considers the prompt ready when it's empty or showing placeholder.
    func waitForAgentPrompt(
        sessionName: String,
        agentType: AgentType?,
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.3
    ) async -> Bool {
        let needsAnsi = agentType == .codex
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let content: String?
            if needsAnsi {
                content = await tmux.capturePaneWithEscapes(
                    sessionName: sessionName,
                    lastLines: Self.agentPromptCaptureLines
                )
            } else {
                content = await tmux.capturePane(
                    sessionName: sessionName,
                    lastLines: Self.agentPromptCaptureLines
                )
            }
            if let content, isAgentPromptReady(content, agentType: agentType) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        // Log final pane state on timeout for diagnostics
        let finalContent = await tmux.capturePane(
            sessionName: sessionName,
            lastLines: Self.agentPromptCaptureLines
        ) ?? "<nil>"
        let finalLines = finalContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .reversed()
            .suffix(Self.agentPromptTimeoutLogLines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        NSLog("[waitForAgentPrompt] TIMEOUT session=\(sessionName) agentType=\(agentType?.rawValue ?? "nil") finalLines=\(finalLines)")
        return false
    }

    /// Polls the tmux pane until the last ~20 characters of `prompt` are visible,
    /// confirming the TUI has finished processing the paste before Enter is sent.
    /// This replaces the old fixed sleep and avoids the race between paste-buffer
    /// delivery and the Enter key arriving while the TUI event loop is still consuming
    /// buffered input.
    /// Returns `true` when the fingerprint is found, `false` on timeout (graceful
    /// fallback — Enter is sent anyway).
    func waitForPromptToAppear(
        sessionName: String,
        prompt: String,
        timeout: TimeInterval = 3.0,
        interval: TimeInterval = 0.15
    ) async -> Bool {
        // Use the last 20 characters of the trimmed prompt as a fingerprint.
        // Resilient to line-wrapping and any cursor character the TUI appends.
        let fingerprint = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).suffix(20))
        guard !fingerprint.isEmpty else { return true }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let content = await tmux.capturePane(sessionName: sessionName, lastLines: 50),
               content.contains(fingerprint) {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    /// Checks whether captured pane content contains an interactive shell blocker
    /// (e.g. an oh-my-zsh update prompt, homebrew yes/no, "press any key" pause).
    /// Used to distinguish a timed-out agent-readiness wait from a blocked shell.
    func detectsInteractiveShellBlocker(_ content: String) -> Bool {
        let blockerPatterns = ["[Y/n]", "[y/N]", "[y/n]", "[N/y]", "[n/Y]",
                               "(Y/n)", "(y/N)", "(y/n)", "(N/y)",
                               "Press any key", "press any key"]
        return blockerPatterns.contains { content.contains($0) }
    }

    private func isAgentPromptReady(_ paneContent: String, agentType: AgentType?) -> Bool {
        switch agentType {
        case .claude:
            if paneContentShowsEscToInterrupt(paneContent) { return false }
            if paneShowsBarePromptMarker(paneContent, marker: "\u{276F}", agentType: agentType) {
                return true
            }
            return false
        case .codex:
            return paneShowsBarePromptMarker(paneContent, marker: "\u{203A}", agentType: agentType)
        case .custom, .none:
            let content = paneContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return content.filter({ !$0.isWhitespace }).count > 50
        }
    }

    func isAgentContentReady(_ content: String, agentType: AgentType?) -> Bool {
        isAgentPromptReady(content, agentType: agentType)
    }

    private func paneShowsBarePromptMarker(
        _ paneContent: String,
        marker: Character,
        agentType: AgentType?
    ) -> Bool {
        let recentLines = latestScopedPaneLines(from: paneContent, agentType: agentType)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(Self.recentPromptDetectionLines)
        guard !recentLines.isEmpty else { return false }
        let bareMarker = String(marker)
        return recentLines.contains { line in
            // Strip ANSI escapes for the structural check
            let plain = Self.stripAnsiEscapes(line)
            let filtered = plain.filter { !$0.isWhitespace }
            if filtered == bareMarker { return true }
            // Line starts with the marker (e.g. Codex "› placeholder text").
            // Only treat as ready if the text after the marker is placeholder
            // (rendered dim via SGR 2) or absent — not user-typed input.
            guard plain.hasPrefix(bareMarker) else { return false }
            return Self.isPromptLineEmpty(line, marker: bareMarker)
        }
    }

    /// Returns `true` when the text after the prompt marker is either absent or
    /// rendered as placeholder (SGR 2 / dim). When the line contains ANSI
    /// escapes, any non-whitespace text after the marker that is NOT preceded
    /// by a dim escape (`\e[2m`) is considered user-typed input.
    /// If the line has no ANSI escapes at all (plain capture), falls back to
    /// treating any text after the marker as placeholder (safe for injection).
    private static func isPromptLineEmpty(_ line: String, marker: String) -> Bool {
        let hasAnsi = line.contains("\u{1b}[")
        guard hasAnsi else {
            // Plain capture (no ANSI) — can't distinguish placeholder from input.
            // Treat as ready (backwards-compatible).
            return true
        }
        // Find the marker in the plain text and check what follows in the raw line.
        // After the marker + reset escape, placeholder text starts with \e[2m (dim).
        // User-typed text does NOT have the dim escape.
        guard let markerRange = line.range(of: marker) else { return true }
        let afterMarker = line[markerRange.upperBound...]
        // Strip leading ANSI escapes and whitespace to find the first content
        let stripped = Self.stripLeadingAnsiAndWhitespace(String(afterMarker))
        if stripped.isEmpty { return true }
        // Check if the text content is preceded by a dim (SGR 2) escape
        // in the original after-marker substring
        return afterMarker.contains("\u{1b}[2m")
    }

    static func stripAnsiEscapes(_ string: String) -> String {
        string.replacingOccurrences(
            of: #"\x1b\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func stripLeadingAnsiAndWhitespace(_ string: String) -> String {
        var s = string[...]
        while !s.isEmpty {
            if s.first?.isWhitespace == true {
                s = s.dropFirst()
            } else if s.hasPrefix("\u{1b}[") {
                // Skip the full escape sequence
                if let end = s.firstIndex(where: { $0.isLetter && $0 != "[" }) {
                    s = s[s.index(after: end)...]
                } else {
                    break
                }
            } else {
                break
            }
        }
        return String(s)
    }

    private func latestScopedPaneLines(from paneContent: String, agentType: AgentType?) -> [String] {
        let lines = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        guard agentType == .codex,
              let scopeSeparatorIndex = lines.lastIndex(where: isPaneScopeSeparator) else {
            return lines
        }
        let latestScopeStart = lines.index(after: scopeSeparatorIndex)
        guard latestScopeStart < lines.endIndex else { return lines }
        return Array(lines[latestScopeStart...])
    }

    private func isPaneScopeSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20 else { return false }
        return trimmed.allSatisfy { $0 == "─" }
    }

    private func showInjectionRetryBanner(
        message: String,
        sessionName: String,
        agentContext: String,
        initialPrompt: String?,
        shouldSubmitInitialPrompt: Bool,
        agentType: AgentType?
    ) async {
        clearMagentBusy(sessionName: sessionName)
        await MainActor.run {
            BannerManager.shared.show(
                message: message,
                style: .warning,
                duration: nil,
                isDismissible: true,
                actions: [BannerAction(title: "Retry") { [weak self] in
                    self?.injectAfterStart(
                        sessionName: sessionName,
                        terminalCommand: "",
                        agentContext: agentContext,
                        initialPrompt: initialPrompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                }]
            )
        }
    }

    private func postInitialPromptInjectionFailure(
        sessionName: String,
        prompt: String,
        shouldSubmitInitialPrompt: Bool,
        agentType: AgentType?
    ) async {
        clearMagentBusy(sessionName: sessionName)
        pendingPromptInjectionSessions.removeValue(forKey: sessionName)
        pendingPromptInjectionTasks.removeValue(forKey: sessionName)
        initialPromptInjectionCompletionsBySession.removeValue(forKey: sessionName)
        initialPromptInjectionFailuresBySession[sessionName] = InitialPromptInjectionFailureInfo(
            prompt: prompt,
            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
            agentType: agentType
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: .magentInitialPromptInjectionFailed,
                object: self,
                userInfo: [
                    "sessionName": sessionName,
                    "prompt": prompt,
                    "shouldSubmitInitialPrompt": shouldSubmitInitialPrompt,
                    "agentType": agentType?.rawValue as Any,
                ]
            )
        }
    }

    func initialPromptInjectionFailure(for sessionName: String) -> InitialPromptInjectionFailureInfo? {
        initialPromptInjectionFailuresBySession[sessionName]
    }

    func clearInitialPromptInjectionFailure(for sessionName: String) {
        initialPromptInjectionFailuresBySession.removeValue(forKey: sessionName)
    }

    func clearTrackedInitialPromptInjection(for sessionName: String) {
        initialPromptInjectionFailuresBySession.removeValue(forKey: sessionName)
        initialPromptInjectionCompletionsBySession.removeValue(forKey: sessionName)
        clearPendingPromptInjection(for: sessionName)
    }

    // MARK: - Pending Prompt Recovery (per-thread)

    func addPendingPromptRecovery(for threadId: UUID, info: PendingPromptRecoveryInfo) {
        pendingPromptRecoveriesByThread[threadId, default: []].append(info)
        NotificationCenter.default.post(
            name: .magentPendingPromptRecovery,
            object: self,
            userInfo: ["threadId": threadId]
        )
    }

    func pendingPromptRecoveries(for threadId: UUID) -> [PendingPromptRecoveryInfo] {
        pendingPromptRecoveriesByThread[threadId] ?? []
    }

    func removePendingPromptRecovery(for threadId: UUID, tempFileURL: URL) {
        guard var entries = pendingPromptRecoveriesByThread[threadId] else { return }
        entries.removeAll { $0.tempFileURL == tempFileURL }
        if entries.isEmpty {
            pendingPromptRecoveriesByThread.removeValue(forKey: threadId)
        } else {
            pendingPromptRecoveriesByThread[threadId] = entries
        }
        NotificationCenter.default.post(
            name: .magentPendingPromptRecovery,
            object: self,
            userInfo: ["threadId": threadId]
        )
    }

    func clearAllPendingPromptRecoveries(for threadId: UUID) {
        guard pendingPromptRecoveriesByThread.removeValue(forKey: threadId) != nil else { return }
        NotificationCenter.default.post(
            name: .magentPendingPromptRecovery,
            object: self,
            userInfo: ["threadId": threadId]
        )
    }

    /// Removes all pending prompt recoveries for a thread and deletes their temp files.
    func cleanupPendingPromptRecoveries(for threadId: UUID) {
        guard let entries = pendingPromptRecoveriesByThread.removeValue(forKey: threadId) else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.tempFileURL)
        }
    }

    func clearTrackedInitialPromptInjection(forSessions sessionNames: some Sequence<String>) {
        for sessionName in sessionNames {
            clearTrackedInitialPromptInjection(for: sessionName)
        }
    }

    func pendingPromptInjection(for sessionName: String) -> InitialPromptInjectionFailureInfo? {
        pendingPromptInjectionSessions[sessionName]
    }

    func didCompleteInitialPromptInjection(for sessionName: String) -> Bool {
        initialPromptInjectionCompletionsBySession[sessionName] != nil
    }

    func hasTrackedInitialPromptInjection(for sessionName: String) -> Bool {
        pendingPromptInjectionSessions[sessionName] != nil
            || pendingPromptInjectionTasks[sessionName] != nil
            || initialPromptInjectionFailuresBySession[sessionName] != nil
            || initialPromptInjectionCompletionsBySession[sessionName] != nil
    }

    /// Waits for a prompt-bearing injection to finish sending keys before callers perform
    /// session-sensitive work such as tmux renames.
    func waitForInitialPromptInjectionSettlement(
        sessionName: String,
        timeout: TimeInterval = 35
    ) async -> Bool {
        if didCompleteInitialPromptInjection(for: sessionName) {
            return true
        }
        if initialPromptInjectionFailure(for: sessionName) != nil {
            return false
        }

        let wasTrackedAtStart = hasTrackedInitialPromptInjection(for: sessionName)
        guard wasTrackedAtStart else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Callers may wait on this before renaming tmux sessions. If that caller is
            // cancelled, do not keep polling the old session name until timeout.
            guard !Task.isCancelled else { return false }
            if didCompleteInitialPromptInjection(for: sessionName) {
                return true
            }
            if initialPromptInjectionFailure(for: sessionName) != nil {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return didCompleteInitialPromptInjection(for: sessionName)
    }

    func clearPendingPromptInjection(for sessionName: String) {
        pendingPromptInjectionSessions.removeValue(forKey: sessionName)
        pendingPromptInjectionTasks[sessionName]?.cancel()
        pendingPromptInjectionTasks.removeValue(forKey: sessionName)
    }

    /// Cancels the in-flight polling task and immediately injects the pending prompt.
    func injectPendingPromptNow(sessionName: String, prompt: String, shouldSubmitInitialPrompt: Bool, agentType: AgentType?) {
        clearPendingPromptInjection(for: sessionName)
        NSLog("[injectPendingPromptNow] session=\(sessionName) submit=\(shouldSubmitInitialPrompt)")
        Task {
            if shouldSubmitInitialPrompt {
                do {
                    try await tmux.sendText(sessionName: sessionName, text: prompt)
                } catch {
                    NSLog("[injectPendingPromptNow] sendText failed: \(error)")
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
                let appeared = await waitForPromptToAppear(sessionName: sessionName, prompt: prompt)
                if !appeared {
                    NSLog("[injectPendingPromptNow] prompt fingerprint not found — sending Enter anyway")
                }
                try? await tmux.sendEnter(sessionName: sessionName)
            } else {
                do {
                    try await tmux.sendText(sessionName: sessionName, text: prompt)
                } catch {
                    NSLog("[injectPendingPromptNow] sendText failed: \(error)")
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
            }
            self.postAgentKeysInjectedNotification(sessionName: sessionName, includedInitialPrompt: true)
        }
    }

    // MARK: - Injection

    func effectiveInjection(for projectId: UUID) -> (terminalCommand: String, agentContext: String) {
        let settings = persistence.loadSettings()
        let project = settings.projects.first(where: { $0.id == projectId })
        let termCmd = (project?.terminalInjectionCommand?.isEmpty == false)
            ? project!.terminalInjectionCommand! : settings.terminalInjectionCommand
        let agentCtx = (project?.agentContextInjection?.isEmpty == false)
            ? project!.agentContextInjection! : settings.agentContextInjection
        return (termCmd, agentCtx)
    }

    func preAgentInjectionCommand(for projectId: UUID, settings: AppSettings) -> String {
        guard let project = settings.projects.first(where: { $0.id == projectId }),
              let command = project.preAgentInjectionCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return "" }
        return command
    }

    @MainActor
    func registerPendingPromptCleanup(fileURL: URL?, sessionName: String) {
        guard let fileURL else { return }
        PendingInitialPromptStore.clearAfterInjection(fileURL: fileURL, sessionName: sessionName)
    }

    /// Removes a session from `magentBusySessions` on the owning thread and
    /// notifies the sidebar so the spinner can update.
    func clearMagentBusy(sessionName: String) {
        guard let idx = threads.firstIndex(where: {
            $0.magentBusySessions.contains(sessionName)
        }) else { return }
        threads[idx].magentBusySessions.remove(sessionName)
        Task { @MainActor in
            self.delegate?.threadManager(self, didUpdateThreads: self.threads)
        }
    }

    private func postAgentKeysInjectedNotification(sessionName: String, includedInitialPrompt: Bool) {
        clearMagentBusy(sessionName: sessionName)
        if includedInitialPrompt {
            initialPromptInjectionCompletionsBySession[sessionName] = Date()
        }
        NotificationCenter.default.post(
            name: .magentAgentKeysInjected,
            object: nil,
            userInfo: [
                "sessionName": sessionName,
                "includedInitialPrompt": includedInitialPrompt,
            ]
        )
    }

    func injectAfterStart(sessionName: String, terminalCommand: String, agentContext: String, initialPrompt: String? = nil, shouldSubmitInitialPrompt: Bool = true, agentType: AgentType? = nil) {
        let prompt = initialPrompt.flatMap { $0.isEmpty ? nil : $0 }
        let hasPrompt = shouldSubmitInitialPrompt && prompt != nil

        // Mark session as magent-busy for the duration of injection/readiness detection.
        // This ensures the sidebar shows a spinner even before the agent starts.
        if let idx = threads.firstIndex(where: {
            $0.tmuxSessionNames.contains(sessionName)
        }), !threads[idx].magentBusySessions.contains(sessionName) {
            threads[idx].magentBusySessions.insert(sessionName)
            Task { @MainActor in
                self.delegate?.threadManager(self, didUpdateThreads: self.threads)
            }
        }

        guard !terminalCommand.isEmpty || !agentContext.isEmpty || prompt != nil else {
            clearMagentBusy(sessionName: sessionName)
            return
        }
        NSLog("[injectAfterStart] session=\(sessionName) hasPrompt=\(hasPrompt) injectOnly=\(prompt != nil && !shouldSubmitInitialPrompt) hasTermCmd=\(!terminalCommand.isEmpty) agentType=\(agentType?.rawValue ?? "nil")")

        // Track pending prompt injection so the UI can show a "waiting" banner
        if let prompt {
            initialPromptInjectionFailuresBySession.removeValue(forKey: sessionName)
            initialPromptInjectionCompletionsBySession.removeValue(forKey: sessionName)
            pendingPromptInjectionSessions[sessionName] = InitialPromptInjectionFailureInfo(
                prompt: prompt,
                shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                agentType: agentType
            )
            NotificationCenter.default.post(
                name: .magentPendingPromptInjection,
                object: self,
                userInfo: ["sessionName": sessionName]
            )
        }

        // Cancel any prior in-flight injection for this session — but only when
        // the new call also carries a prompt. A prompt-less call (agent context only,
        // e.g. from recreateSessionIfNeeded) must not nuke an in-flight prompt task.
        if prompt != nil {
            pendingPromptInjectionTasks[sessionName]?.cancel()
        }

        let task = Task {
            _ = await waitForPaneCaptureReady(sessionName: sessionName)
            var didSendTerminalCommand = false
            if !terminalCommand.isEmpty {
                // Do not signal magentAgentKeysInjected yet when more startup work
                // is still pending for this session (agent context or initial prompt).
                try? await tmux.sendKeys(sessionName: sessionName, keys: terminalCommand)
                didSendTerminalCommand = true
            }
            if let prompt, !shouldSubmitInitialPrompt {
                // Inject-only mode: paste the prompt text but don't press Enter.
                // Wait for agent readiness so the text lands in the right input area.
                NotificationCenter.default.post(name: .magentAgentInjectionStarted, object: nil, userInfo: ["sessionName": sessionName])
                let promptReady = await waitForAgentPrompt(
                    sessionName: sessionName,
                    agentType: agentType,
                    timeout: 30
                )
                guard !Task.isCancelled else {
                    self.clearMagentBusy(sessionName: sessionName)
                    return
                }
                if !promptReady {
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
                do {
                    try await tmux.sendText(sessionName: sessionName, text: prompt)
                } catch {
                    NSLog("[injectAfterStart] sendText failed for inject-only session \(sessionName): \(error)")
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
                pendingPromptInjectionSessions.removeValue(forKey: sessionName)
                pendingPromptInjectionTasks.removeValue(forKey: sessionName)
                postAgentKeysInjectedNotification(sessionName: sessionName, includedInitialPrompt: true)
            } else if let prompt, shouldSubmitInitialPrompt {
                // When an initial prompt is provided, skip the agent context injection
                // and send only the prompt. The agent context would race with the prompt —
                // submitting as a first prompt that blocks the real one.
                // Wait for the agent TUI to be ready before sending the prompt.
                NotificationCenter.default.post(name: .magentAgentInjectionStarted, object: nil, userInfo: ["sessionName": sessionName])
                let promptReady = await waitForAgentPrompt(
                    sessionName: sessionName,
                    agentType: agentType,
                    timeout: 30
                )
                guard !Task.isCancelled else {
                    self.clearMagentBusy(sessionName: sessionName)
                    return
                }
                if !promptReady {
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
                // Send text and Enter separately — the Enter key gets lost if sent in the
                // same send-keys call while the TUI is still processing buffered input.
                // Poll until the pasted text is visible in the pane instead of using a
                // fixed sleep, so Enter only arrives after the TUI event loop has fully
                // consumed the paste. Falls back gracefully on timeout.
                do {
                    try await tmux.sendText(sessionName: sessionName, text: prompt)
                } catch {
                    NSLog("[injectAfterStart] sendText failed for session \(sessionName): \(error)")
                    await postInitialPromptInjectionFailure(
                        sessionName: sessionName,
                        prompt: prompt,
                        shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                        agentType: agentType
                    )
                    return
                }
                let appeared = await waitForPromptToAppear(sessionName: sessionName, prompt: prompt)
                if !appeared {
                    NSLog("[injectAfterStart] prompt fingerprint not found in pane for session \(sessionName) — sending Enter anyway")
                }
                try? await tmux.sendEnter(sessionName: sessionName)
                pendingPromptInjectionSessions.removeValue(forKey: sessionName)
                pendingPromptInjectionTasks.removeValue(forKey: sessionName)
                postAgentKeysInjectedNotification(sessionName: sessionName, includedInitialPrompt: true)
            } else if !agentContext.isEmpty {
                // No initial prompt — send agent context as usual
                if !terminalCommand.isEmpty {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                let promptReady = await waitForAgentPrompt(sessionName: sessionName, agentType: agentType)
                if !promptReady {
                    let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 30) ?? ""
                    if detectsInteractiveShellBlocker(paneContent) {
                        await showInjectionRetryBanner(
                            message: "Agent context not injected — shell is waiting for user input. Answer the prompt in the terminal, then retry.",
                            sessionName: sessionName,
                            agentContext: agentContext,
                            initialPrompt: nil,
                            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                            agentType: agentType
                        )
                    } else {
                        await showInjectionRetryBanner(
                            message: "Agent context not injected — the agent input prompt did not appear yet. Retry after the agent finishes starting.",
                            sessionName: sessionName,
                            agentContext: agentContext,
                            initialPrompt: nil,
                            shouldSubmitInitialPrompt: shouldSubmitInitialPrompt,
                            agentType: agentType
                        )
                    }
                    return
                }
                try? await tmux.sendKeys(sessionName: sessionName, keys: agentContext)
                postAgentKeysInjectedNotification(sessionName: sessionName, includedInitialPrompt: false)
            } else if didSendTerminalCommand {
                postAgentKeysInjectedNotification(sessionName: sessionName, includedInitialPrompt: false)
            }
        }
        if prompt != nil {
            pendingPromptInjectionTasks[sessionName] = task
        }
    }

    // MARK: - Agent Type

    func effectiveAgentType(for projectId: UUID) -> AgentType? {
        let settings = persistence.loadSettings()
        return resolveAgentType(for: projectId, requestedAgentType: nil, settings: settings)
    }

    func detectedRunningAgentType(
        paneCommand: String,
        childProcesses: [(pid: pid_t, args: String)]
    ) -> AgentType? {
        if let directMatch = detectedAgentType(from: paneCommand) {
            return directMatch
        }

        for child in childProcesses {
            if let childMatch = detectedAgentType(from: child.args) {
                return childMatch
            }
        }

        return nil
    }

    func detectedAgentType(from commandLine: String) -> AgentType? {
        let commandLower = commandLine.lowercased()
        if commandLower.contains("claude") { return .claude }
        if commandLower.contains("codex") { return .codex }
        return nil
    }

    /// Returns the agent type currently running in the given tmux session, or nil if
    /// no known agent process is detected (e.g. the pane is at a plain shell prompt).
    func detectedAgentTypeInSession(_ sessionName: String) async -> AgentType? {
        guard let paneState = await tmux.activePaneStates(forSessions: [sessionName])[sessionName] else {
            return nil
        }
        if let directMatch = detectedAgentType(from: paneState.command) {
            return directMatch
        }
        let children = paneState.pid > 0
            ? await tmux.childProcesses(forParents: [paneState.pid])[paneState.pid] ?? []
            : []
        return detectedRunningAgentType(paneCommand: paneState.command, childProcesses: children)
    }

    func agentType(for thread: MagentThread, sessionName: String) -> AgentType? {
        guard thread.agentTmuxSessions.contains(sessionName) else { return nil }
        if let stored = thread.sessionAgentTypes[sessionName] {
            return stored
        }
        if let inferred = inferredStoredAgentType(for: thread, sessionName: sessionName) {
            return inferred
        }
        return effectiveAgentType(for: thread.projectId)
    }

    func loadingOverlayAgentType(for thread: MagentThread, sessionName: String) async -> AgentType? {
        guard thread.agentTmuxSessions.contains(sessionName) else { return nil }

        let persistedAgentType = agentType(for: thread, sessionName: sessionName)
        guard await tmux.hasSession(name: sessionName) else {
            return persistedAgentType
        }

        let paneStates = await tmux.activePaneStates(forSessions: [sessionName])
        guard let paneState = paneStates[sessionName] else {
            return persistedAgentType
        }

        if let directMatch = detectedAgentType(from: paneState.command) {
            return directMatch
        }

        let childProcessesByPid = paneState.pid > 0
            ? await tmux.childProcesses(forParents: [paneState.pid])
            : [:]
        let children = childProcessesByPid[paneState.pid] ?? []

        if let runningAgent = detectedRunningAgentType(
            paneCommand: paneState.command,
            childProcesses: children
        ) {
            return runningAgent
        }

        let shellCommands: Set<String> = ["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh"]
        if shellCommands.contains(paneState.command.lowercased()) {
            return nil
        }

        return persistedAgentType
    }

    func migrateSessionAgentTypes(threadIndex index: Int) async -> Bool {
        guard threads.indices.contains(index) else { return false }

        let validAgentSessions = Set(threads[index].agentTmuxSessions)
        let filtered = threads[index].sessionAgentTypes.filter { validAgentSessions.contains($0.key) }
        var updated = filtered
        var changed = filtered.count != threads[index].sessionAgentTypes.count

        for sessionName in threads[index].agentTmuxSessions {
            guard updated[sessionName] == nil else { continue }
            if let live = await liveSessionAgentType(sessionName: sessionName)
                ?? inferredStoredAgentType(for: threads[index], sessionName: sessionName)
                ?? effectiveAgentType(for: threads[index].projectId) {
                updated[sessionName] = live
                changed = true
            }
        }

        guard changed else { return false }
        threads[index].sessionAgentTypes = updated
        return true
    }

    @discardableResult
    func remapSessionAgentTypes(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        guard threads.indices.contains(index) else { return false }
        guard !sessionRenameMap.isEmpty else { return false }

        let remapped = Dictionary(
            uniqueKeysWithValues: threads[index].sessionAgentTypes.map { key, value in
                (sessionRenameMap[key] ?? key, value)
            }
        )
        guard remapped != threads[index].sessionAgentTypes else { return false }
        threads[index].sessionAgentTypes = remapped
        return true
    }

    @discardableResult
    func pruneSessionAgentTypesToKnownSessions(threadIndex index: Int) -> Bool {
        guard threads.indices.contains(index) else { return false }

        let validAgentSessions = Set(threads[index].agentTmuxSessions)
        let filtered = threads[index].sessionAgentTypes.filter { validAgentSessions.contains($0.key) }
        guard filtered != threads[index].sessionAgentTypes else { return false }
        threads[index].sessionAgentTypes = filtered
        return true
    }

    private func inferredStoredAgentType(for thread: MagentThread, sessionName: String) -> AgentType? {
        if let customName = thread.customTabNames[sessionName] {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "claude" || trimmed == "claude code" {
                return .claude
            }
            if trimmed == "codex" {
                return .codex
            }
            if trimmed == "custom" {
                return .custom
            }
        }

        let components = sessionName
            .split(separator: "-")
            .map { $0.lowercased() }
        if components.contains("claude") {
            return .claude
        }
        if components.contains("codex") {
            return .codex
        }
        if components.contains("custom") {
            return .custom
        }

        return nil
    }

    private func liveSessionAgentType(sessionName: String) async -> AgentType? {
        guard let rawValue = await tmux.environmentValue(sessionName: sessionName, key: "MAGENT_AGENT_TYPE")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawValue.isEmpty else {
            return nil
        }
        return AgentType(rawValue: rawValue)
    }

    // MARK: - Agent Conversation IDs

    func conversationID(for threadId: UUID, sessionName: String) -> String? {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return nil }
        return thread.sessionConversationIDs[sessionName]
    }

    func scheduleAgentConversationIDRefresh(
        threadId: UUID,
        sessionName: String,
        delaySeconds: TimeInterval = 1.2
    ) {
        Task { [weak self] in
            guard delaySeconds > 0 else {
                await self?.refreshAgentConversationID(threadId: threadId, sessionName: sessionName)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self?.refreshAgentConversationID(threadId: threadId, sessionName: sessionName)
        }
    }

    func refreshAgentConversationID(threadId: UUID, sessionName: String) async {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[threadIndex].agentTmuxSessions.contains(sessionName) else { return }

        let agentType = agentType(for: threads[threadIndex], sessionName: sessionName)
        let worktreePath = threads[threadIndex].worktreePath

        let conversationID: String?
        switch agentType {
        case .claude:
            conversationID = latestClaudeConversationID(worktreePath: worktreePath)
        case .codex:
            conversationID = await latestCodexConversationID(worktreePath: worktreePath)
        case .custom, .none:
            conversationID = nil
        }

        guard let conversationID, !conversationID.isEmpty else { return }
        guard threads[threadIndex].sessionConversationIDs[sessionName] != conversationID else { return }

        threads[threadIndex].sessionConversationIDs[sessionName] = conversationID
        try? persistence.saveActiveThreads(threads)
    }

    private func latestClaudeConversationID(worktreePath: String) -> String? {
        struct ClaudeSessionIndex: Decodable {
            struct Entry: Decodable {
                let sessionId: String
                let projectPath: String?
                let modified: String?
                let fileMtime: Double?
            }
            let entries: [Entry]
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encodedPath = worktreePath.replacingOccurrences(of: "/", with: "-")
        let candidatePaths = [
            "\(home)/.claude/projects/\(encodedPath)/sessions-index.json",
            "\(home)/.agents/projects/\(encodedPath)/sessions-index.json",
        ]

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        func readIndex(path: String) -> String? {
            guard let data = FileManager.default.contents(atPath: path),
                  let index = try? JSONDecoder().decode(ClaudeSessionIndex.self, from: data) else {
                return nil
            }

            let scoped = index.entries.filter { entry in
                guard let projectPath = entry.projectPath, !projectPath.isEmpty else { return true }
                return projectPath == worktreePath
            }
            let entries = scoped.isEmpty ? index.entries : scoped
            guard !entries.isEmpty else { return nil }

            let sorted = entries.sorted { lhs, rhs in
                func score(_ e: ClaudeSessionIndex.Entry) -> Double {
                    if let modified = e.modified {
                        if let date = isoWithFractional.date(from: modified) ?? isoPlain.date(from: modified) {
                            return date.timeIntervalSince1970
                        }
                    }
                    if let mtime = e.fileMtime {
                        return mtime / 1000.0
                    }
                    return 0
                }
                return score(lhs) > score(rhs)
            }
            guard let best = sorted.first, isUUID(best.sessionId) else { return nil }
            return best.sessionId
        }

        for path in candidatePaths {
            if let id = readIndex(path: path) {
                return id
            }
        }
        return nil
    }

    private func latestCodexConversationID(worktreePath: String) async -> String? {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let dbPath = newestCodexStateDatabase(in: codexDir)
        guard let dbPath else { return nil }

        let sqlWorktree = sqlQuoted(worktreePath)
        let query = "SELECT id FROM threads WHERE cwd = \(sqlWorktree) ORDER BY updated_at DESC LIMIT 1;"
        let command = "sqlite3 \(ShellExecutor.shellQuote(dbPath)) \(ShellExecutor.shellQuote(query))"
        let result = await ShellExecutor.execute(command)
        guard result.exitCode == 0 else { return nil }

        let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUUID(id) else { return nil }
        return id
    }

    private func newestCodexStateDatabase(in directoryPath: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            atPath: directoryPath
        ) else {
            return nil
        }

        let candidates = entries.filter { name in
            name.hasPrefix("state_") && name.hasSuffix(".sqlite")
        }
        guard !candidates.isEmpty else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for name in candidates {
            let path = "\(directoryPath)/\(name)"
            let attrs = try? fm.attributesOfItem(atPath: path)
            let modified = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if modified > bestDate {
                bestDate = modified
                bestPath = path
            }
        }
        return bestPath
    }

    private func sqlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: - Submitted Prompt History

    private static let maxSubmittedPromptsPerSession = 250

    func replaceSubmittedPromptHistory(threadId: UUID, sessionName: String, prompts: [String]) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].agentTmuxSessions.contains(sessionName) else { return }

        var history = prompts
            .map(normalizedSubmittedPrompt(_:))
            .filter { !$0.isEmpty }
        if history.count > Self.maxSubmittedPromptsPerSession {
            history = Array(history.suffix(Self.maxSubmittedPromptsPerSession))
        }

        let existing = threads[index].submittedPromptsBySession[sessionName] ?? []
        guard history != existing else { return }

        if history.isEmpty {
            threads[index].submittedPromptsBySession.removeValue(forKey: sessionName)
        } else {
            threads[index].submittedPromptsBySession[sessionName] = history
        }
        try? persistence.saveActiveThreads(threads)
    }

    private func normalizedSubmittedPrompt(_ prompt: String) -> String {
        prompt
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func remapSubmittedPromptHistory(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        guard threads.indices.contains(index) else { return false }
        guard !sessionRenameMap.isEmpty else { return false }

        var changed = false
        var updated: [String: [String]] = [:]
        for (sessionName, prompts) in threads[index].submittedPromptsBySession {
            let newName = sessionRenameMap[sessionName] ?? sessionName
            let existing = updated[newName] ?? []
            updated[newName] = existing + prompts
            if newName != sessionName {
                changed = true
            }
        }

        if changed || updated.count != threads[index].submittedPromptsBySession.count {
            threads[index].submittedPromptsBySession = updated
            return true
        }
        return false
    }

    @discardableResult
    func pruneSubmittedPromptHistoryToKnownSessions(threadIndex index: Int) -> Bool {
        guard threads.indices.contains(index) else { return false }

        let validSessions = Set(threads[index].tmuxSessionNames)
        let filtered = threads[index].submittedPromptsBySession.filter { key, prompts in
            validSessions.contains(key) && !prompts.isEmpty
        }
        if filtered != threads[index].submittedPromptsBySession {
            threads[index].submittedPromptsBySession = filtered
            return true
        }
        return false
    }

    // MARK: - Session-State Rekey/Prune

    /// Rekeys transient, session-scoped state after tmux session renames.
    /// Keeps only sessions that are still agent tabs for this thread.
    @discardableResult
    func remapTransientSessionState(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        guard threads.indices.contains(index) else { return false }
        guard !sessionRenameMap.isEmpty else { return false }

        var changed = false
        let validAgentSessions = Set(threads[index].agentTmuxSessions)

        let remappedBusy = Set(
            threads[index].busySessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedBusy != threads[index].busySessions {
            threads[index].busySessions = remappedBusy
            changed = true
        }

        let remappedWaiting = Set(
            threads[index].waitingForInputSessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAgentSessions.contains($0) }
        )
        if remappedWaiting != threads[index].waitingForInputSessions {
            threads[index].waitingForInputSessions = remappedWaiting
            changed = true
        }

        // Re-key magentBusySessions — filter against all tmux sessions (not just agent ones)
        // since magent busy applies to any session during injection/setup.
        let validAllSessions = Set(threads[index].tmuxSessionNames)
        let remappedMagentBusy = Set(
            threads[index].magentBusySessions
                .map { sessionRenameMap[$0] ?? $0 }
                .filter { validAllSessions.contains($0) || $0 == MagentThread.threadSetupSentinel }
        )
        if remappedMagentBusy != threads[index].magentBusySessions {
            threads[index].magentBusySessions = remappedMagentBusy
            changed = true
        }

        // Keep notification dedup state aligned with waiting sessions after rename.
        let renamedTargets = Set(sessionRenameMap.values)
        for (oldName, newName) in sessionRenameMap where notifiedWaitingSessions.remove(oldName) != nil {
            if remappedWaiting.contains(newName) {
                notifiedWaitingSessions.insert(newName)
            }
        }
        for target in renamedTargets where !remappedWaiting.contains(target) {
            notifiedWaitingSessions.remove(target)
        }

        return changed
    }

    @discardableResult
    func remapInitialPromptInjectionState(sessionRenameMap: [String: String]) -> Bool {
        guard !sessionRenameMap.isEmpty else { return false }

        var changed = false

        func remapDictionary<Value>(_ dictionary: inout [String: Value]) {
            let originalKeys = Set(dictionary.keys)
            var remapped: [String: Value] = [:]
            // Build this manually instead of `Dictionary(uniqueKeysWithValues:)` so a
            // future caller cannot crash here if two old session names ever collapse to
            // the same new name during rename reconciliation.
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                remapped[sessionRenameMap[key] ?? key] = value
            }
            dictionary = remapped
            if Set(dictionary.keys) != originalKeys {
                changed = true
            }
        }

        remapDictionary(&initialPromptInjectionFailuresBySession)
        remapDictionary(&pendingPromptInjectionSessions)
        remapDictionary(&initialPromptInjectionCompletionsBySession)

        let originalTaskKeys = Set(pendingPromptInjectionTasks.keys)
        var remappedTasks: [String: Task<Void, Never>] = [:]
        for key in pendingPromptInjectionTasks.keys.sorted() {
            guard let task = pendingPromptInjectionTasks[key] else { continue }
            remappedTasks[sessionRenameMap[key] ?? key] = task
        }
        pendingPromptInjectionTasks = remappedTasks
        if Set(pendingPromptInjectionTasks.keys) != originalTaskKeys {
            changed = true
        }

        return changed
    }

    /// Removes stale transient session state that references non-agent sessions.
    /// Returns true when any thread-visible state changed.
    @discardableResult
    func pruneTransientSessionStateToKnownAgentSessions(threadIndex index: Int) -> Bool {
        guard threads.indices.contains(index) else { return false }

        var changed = false
        let validAgentSessions = Set(threads[index].agentTmuxSessions)

        let prunedBusy = threads[index].busySessions.intersection(validAgentSessions)
        if prunedBusy != threads[index].busySessions {
            threads[index].busySessions = prunedBusy
            changed = true
        }

        let oldWaiting = threads[index].waitingForInputSessions
        let prunedWaiting = oldWaiting.intersection(validAgentSessions)
        if prunedWaiting != oldWaiting {
            let removed = oldWaiting.subtracting(prunedWaiting)
            for session in removed {
                notifiedWaitingSessions.remove(session)
            }
            threads[index].waitingForInputSessions = prunedWaiting
            changed = true
        }

        // Prune magentBusySessions against all known tmux sessions + the setup sentinel.
        let validMagentTargets = Set(threads[index].tmuxSessionNames)
            .union([MagentThread.threadSetupSentinel])
        let prunedMagentBusy = threads[index].magentBusySessions.intersection(validMagentTargets)
        if prunedMagentBusy != threads[index].magentBusySessions {
            threads[index].magentBusySessions = prunedMagentBusy
            changed = true
        }

        return changed
    }

    // MARK: - Session Naming (delegates to TmuxSessionNaming)

    /// Renames session names produced by Magent without touching unrelated substrings.
    func renamedSessionName(_ sessionName: String, fromThreadName oldName: String, toThreadName newName: String, repoSlug: String) -> String {
        TmuxSessionNaming.renamedSessionName(sessionName, fromThreadName: oldName, toThreadName: newName, repoSlug: repoSlug)
    }

    static func sanitizeForTmux(_ name: String) -> String {
        TmuxSessionNaming.sanitizeForTmux(name)
    }

    static func repoSlug(from projectName: String) -> String {
        TmuxSessionNaming.repoSlug(from: projectName)
    }

    static func buildSessionName(repoSlug: String, threadName: String?, tabSlug: String? = nil) -> String {
        TmuxSessionNaming.buildSessionName(repoSlug: repoSlug, threadName: threadName, tabSlug: tabSlug)
    }

    static func isMagentSession(_ name: String) -> Bool {
        TmuxSessionNaming.isMagentSession(name)
    }

    // MARK: - Symlinks (delegates to SymlinkManager)

    func cleanupAllBrokenSymlinks() {
        SymlinkManager.cleanupAll(settings: persistence.loadSettings())
    }

    func createCompatibilitySymlink(from oldPath: String, to newPath: String) {
        SymlinkManager.createCompatibilitySymlink(from: oldPath, to: newPath)
    }

    // MARK: - Claude Settings

    /// Path to the Magent-specific Claude Code settings file.
    static let claudeHooksSettingsPath = "/tmp/magent-claude-hooks.json"

    /// Writes (or refreshes) the Claude Code settings JSON that Magent injects via `--settings`.
    /// Includes:
    /// - Stop hook for completion detection
    /// - Session-only theme hints derived from Magent appearance settings
    func installClaudeHooksSettings() {
        let appearanceMode = persistence.loadSettings().appAppearanceMode
        installClaudeHooksSettings(for: appearanceMode)
    }

    private func installClaudeHooksSettings(for appearanceMode: AppAppearanceMode, preserveAgentColorTheme: Bool = false) {
        let themeSuffix = preserveAgentColorTheme ? "-notheme" : ""
        let marker = "magent-settings-v2-\(appearanceMode.rawValue)\(themeSuffix)"
        let path = Self.claudeHooksSettingsPath
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing.contains(marker) {
            return
        }
        let eventsPath = "/tmp/magent-agent-completion-events.log"
        // The Stop hook runs `tmux display-message` to get the session name and
        // appends it to the event log. Guarded by MAGENT_WORKTREE_NAME so it
        // only fires inside Magent-managed sessions.
        var settings: [String: Any] = [
            "_comment": marker,
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            [
                                "type": "command",
                                "command": "[ -n \"$MAGENT_WORKTREE_NAME\" ] && tmux display-message -p '#{session_name}' >> \(eventsPath) || true",
                                "timeout": 5,
                            ],
                        ],
                    ],
                ],
            ],
        ]

        // Keep this scoped to Magent-managed sessions via --settings.
        // Skip theme hints when the user wants to preserve the agent's own default theme.
        if !preserveAgentColorTheme {
            switch appearanceMode {
            case .light:
                settings["theme"] = "light"
                settings["terminalTheme"] = "light"
            case .dark:
                settings["theme"] = "dark"
                settings["terminalTheme"] = "dark"
            case .system:
                settings["terminalTheme"] = "system"
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Codex Config

    /// Legacy no-op. Codex launch behavior is now configured per Magent session
    /// via command-line overrides, without writing to user-wide `~/.codex/config.toml`.
    func ensureCodexBellNotification() {
        // Intentionally left blank.
    }

    // MARK: - Codex IPC Instructions

    func installCodexIPCInstructions() {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
        let filePath = codexDir.appendingPathComponent("AGENTS.md").path

        if let existing = try? String(contentsOfFile: filePath, encoding: .utf8) {
            // Already up to date
            if existing.contains(IPCAgentDocs.codexIPCVersion) { return }

            // Replace outdated Magent section if present
            if let startRange = existing.range(of: IPCAgentDocs.codexIPCMarkerStart),
               let endRange = existing.range(of: IPCAgentDocs.codexIPCMarkerEnd),
               startRange.lowerBound <= endRange.lowerBound {
                var updated = existing
                updated.replaceSubrange(
                    startRange.lowerBound..<endRange.upperBound,
                    with: IPCAgentDocs.codexAgentsMdBlock
                )
                try? updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            } else {
                // Append to existing user content
                var updated = existing
                if !updated.hasSuffix("\n") { updated += "\n" }
                updated += "\n" + IPCAgentDocs.codexAgentsMdBlock + "\n"
                try? updated.write(toFile: filePath, atomically: true, encoding: .utf8)
            }
        } else {
            // No file — create with just the IPC section
            try? FileManager.default.createDirectory(
                atPath: codexDir.path,
                withIntermediateDirectories: true
            )
            try? IPCAgentDocs.codexAgentsMdBlock.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Agent Start Command

    private static let managedZdotdirPath = "/tmp/magent-zdotdir"
    private static let managedZdotdirMarker = "# magent-zdotdir-v1"
    private static let managedZdotdirFiles = [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"]
    private static let managedZdotdirLock = NSLock()
    private static let userShell: String = {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()
    private static let startupShell: String = {
        let shell = userShell
        let shellName = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        return shellName.contains("zsh") ? shell : "/bin/zsh"
    }()

    private static func managedZdotfileContents(fileName: String) -> String {
        switch fileName {
        case ".zshrc":
            return """
            \(managedZdotdirMarker)
            export ZDOTDIR="$HOME"
            if [ -f "$HOME/.zshrc" ]; then
              source "$HOME/.zshrc"
            fi
            if [ -n "${MAGENT_START_CWD:-}" ] && [ -d "${MAGENT_START_CWD}" ]; then
              cd -- "${MAGENT_START_CWD}" || true
            fi
            unset MAGENT_START_CWD
            """
        case ".zshenv", ".zprofile", ".zlogin", ".zlogout":
            return """
            \(managedZdotdirMarker)
            if [ -f "$HOME/\(fileName)" ]; then
              source "$HOME/\(fileName)"
            fi
            """
        default:
            return "\(managedZdotdirMarker)\n"
        }
    }

    @discardableResult
    func ensureManagedZdotdir() -> String {
        Self.managedZdotdirLock.lock()
        defer { Self.managedZdotdirLock.unlock() }

        let path = Self.managedZdotdirPath
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            try? fileManager.removeItem(atPath: path)
        }
        try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)

        for fileName in Self.managedZdotdirFiles {
            let filePath = "\(path)/\(fileName)"
            let desired = Self.managedZdotfileContents(fileName: fileName)
            if let existing = try? String(contentsOfFile: filePath, encoding: .utf8),
               existing == desired {
                continue
            }
            try? desired.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        return path
    }

    func cleanupManagedZdotdir() {
        Self.managedZdotdirLock.lock()
        defer { Self.managedZdotdirLock.unlock() }
        try? FileManager.default.removeItem(atPath: Self.managedZdotdirPath)
    }

    func terminalStartCommand(
        envExports: String,
        workingDirectory: String
    ) -> String {
        let shell = ShellExecutor.shellQuote(Self.startupShell)
        let zdotdir = ShellExecutor.shellQuote(ensureManagedZdotdir())
        let startCwd = ShellExecutor.shellQuote(workingDirectory)
        // Unset CLAUDECODE so agent CLIs can be launched manually from a terminal tab
        // without triggering the "nested session" error inherited from Magent's parent process.
        return "unset CLAUDECODE && \(envExports) && exec env MAGENT_START_CWD=\(startCwd) ZDOTDIR=\(zdotdir) \(shell) -l"
    }

    func agentStartCommand(
        settings: AppSettings,
        projectId: UUID? = nil,
        agentType: AgentType?,
        envExports: String,
        workingDirectory: String,
        resumeSessionID: String? = nil
    ) -> String {
        let shell = ShellExecutor.shellQuote(Self.startupShell)
        let zdotdir = ShellExecutor.shellQuote(ensureManagedZdotdir())
        let startCwd = ShellExecutor.shellQuote(workingDirectory)
        let preAgentCommand = projectId.map { preAgentInjectionCommand(for: $0, settings: settings) } ?? ""

        guard let agentType else {
            return terminalStartCommand(envExports: envExports, workingDirectory: workingDirectory)
        }

        var parts = [String]()
        if agentType == .claude {
            installClaudeHooksSettings(for: settings.appAppearanceMode, preserveAgentColorTheme: settings.preserveAgentColorTheme)
            parts.append("unset CLAUDECODE")
        }
        if !preAgentCommand.isEmpty {
            // Pre-agent startup commands are best-effort and should not block agent launch.
            parts.append("{ \(preAgentCommand) ; } || true")
        }
        let command = agentCommand(
            settings: settings,
            agentType: agentType,
            resumeSessionID: resumeSessionID
        )
        // Use an interactive login shell so zsh loads both login files and `.zshrc`
        // before resolving the agent binary. Many PATH/custom command setups live in `.zshrc`.
        parts.append(command)
        let innerCmd = parts.joined(separator: " && ") + "; exec \(shell) -l"
        return "\(envExports) && exec env MAGENT_START_CWD=\(startCwd) ZDOTDIR=\(zdotdir) \(shell) -il -c \(ShellExecutor.shellQuote(innerCmd))"
    }

    private func agentCommand(
        settings: AppSettings,
        agentType: AgentType,
        resumeSessionID: String?
    ) -> String {
        let fresh = freshAgentCommand(settings: settings, agentType: agentType)
        guard let resumeSessionID = normalizedResumeID(resumeSessionID),
              let resume = resumableAgentCommand(
                settings: settings,
                agentType: agentType,
                sessionID: resumeSessionID
              ) else {
            return fresh
        }
        // Always attempt deterministic resume first; fall back to a fresh session.
        return "{ \(resume) || \(fresh) ; }"
    }

    private func freshAgentCommand(settings: AppSettings, agentType: AgentType) -> String {
        var command = settings.command(for: agentType)
        if agentType == .claude {
            command += " --settings \(Self.claudeHooksSettingsPath)"
            if settings.ipcPromptInjectionEnabled {
                command += " --append-system-prompt \(ShellExecutor.shellQuote(IPCAgentDocs.claudeSystemPrompt))"
            }
            command = claudeSessionConfiguredCommand(command, appearanceMode: settings.appAppearanceMode, preserveAgentColorTheme: settings.preserveAgentColorTheme)
        } else if agentType == .codex {
            command = codexSessionConfiguredCommand(command, appearanceMode: settings.appAppearanceMode, preserveAgentColorTheme: settings.preserveAgentColorTheme)
        }
        return command
    }

    private func resumableAgentCommand(
        settings: AppSettings,
        agentType: AgentType,
        sessionID: String
    ) -> String? {
        let quotedID = ShellExecutor.shellQuote(sessionID)
        switch agentType {
        case .claude:
            // Use `command claude` to bypass any shell function wrappers.
            var command = settings.agentSkipPermissions
                ? "command claude --dangerously-skip-permissions"
                : "command claude"
            command += " --resume \(quotedID)"
            command += " --settings \(Self.claudeHooksSettingsPath)"
            if settings.ipcPromptInjectionEnabled {
                command += " --append-system-prompt \(ShellExecutor.shellQuote(IPCAgentDocs.claudeSystemPrompt))"
            }
            return claudeSessionConfiguredCommand(command, appearanceMode: settings.appAppearanceMode, preserveAgentColorTheme: settings.preserveAgentColorTheme)
        case .codex:
            // Use `command codex` to bypass shell function wrappers (same reason as in AppSettings.command(for:)).
            var command = "command codex resume \(quotedID)"
            if settings.agentSkipPermissions {
                command += " --yolo"
            } else if settings.agentSandboxEnabled {
                command += " --full-auto"
            }
            return codexSessionConfiguredCommand(command, appearanceMode: settings.appAppearanceMode, preserveAgentColorTheme: settings.preserveAgentColorTheme)
        case .custom:
            return nil
        }
    }

    private func codexSessionLaunchFlags(for appearanceMode: AppAppearanceMode, preserveAgentColorTheme: Bool = false) -> String {
        var flags = [
            "-c \(ShellExecutor.shellQuote("tui.notification_method=\"bel\""))",
        ]
        // Keep Codex rendering aligned with the terminal palette in explicit light mode.
        if !preserveAgentColorTheme && appearanceMode == .light {
            flags.append("-c \(ShellExecutor.shellQuote("tui.theme=\"ansi\""))")
        }
        return flags.joined(separator: " ")
    }

    private func codexSessionConfiguredCommand(_ command: String, appearanceMode: AppAppearanceMode, preserveAgentColorTheme: Bool = false) -> String {
        let prefix = "command codex"
        guard command.hasPrefix(prefix) else { return command }

        let launchFlags = codexSessionLaunchFlags(for: appearanceMode, preserveAgentColorTheme: preserveAgentColorTheme)
        guard !launchFlags.isEmpty else { return command }

        let suffix = String(command.dropFirst(prefix.count))
        return "\(prefix) \(launchFlags)\(suffix)"
    }

    private func claudeSessionConfiguredCommand(_ command: String, appearanceMode: AppAppearanceMode, preserveAgentColorTheme: Bool = false) -> String {
        guard command.hasPrefix("command claude") else { return command }
        // Claude's current terminal renderer can keep dark-styled truecolor blocks even when
        // theme hints are set. In explicit light mode, force a basic ANSI profile for this
        // process only (instead of disabling color completely).
        if !preserveAgentColorTheme && appearanceMode == .light {
            return "TERM=screen COLORTERM= \(command)"
        }
        return command
    }

    private func normalizedResumeID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              isUUID(value) else {
            return nil
        }
        return value
    }

    // MARK: - Name Availability

    func isNameAvailable(_ name: String, project: Project) async throws -> Bool {
        let nameInUse = threads.contains(where: { $0.name == name })
        let dirExists = FileManager.default.fileExists(
            atPath: "\(project.resolvedWorktreesBasePath())/\(name)"
        )
        guard !nameInUse && !dirExists else { return false }

        let branchExists = await git.branchExists(repoPath: project.repoPath, branchName: name)
        let slug = Self.repoSlug(from: project.name)
        let settings = persistence.loadSettings()
        let agentType = resolveAgentType(for: project.id, requestedAgentType: nil, settings: settings)
        let firstTabSlug = Self.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: agentType))
        let tmuxExists = await tmux.hasSession(name: Self.buildSessionName(repoSlug: slug, threadName: name, tabSlug: firstTabSlug))
        return !branchExists && !tmuxExists
    }

    // MARK: - Agent Trust

    func trustDirectoryIfNeeded(_ path: String, agentType: AgentType?) {
        switch agentType {
        case .claude:
            ClaudeTrustHelper.trustDirectory(path)
        case .codex:
            CodexTrustHelper.trustDirectory(path)
        case .custom, .none:
            break
        }
    }

    func resolveAgentType(
        for projectId: UUID,
        requestedAgentType: AgentType?,
        settings: AppSettings
    ) -> AgentType? {
        let activeAgents = settings.availableActiveAgents
        guard !activeAgents.isEmpty else { return nil }
        if activeAgents.count == 1 {
            return activeAgents[0]
        }
        if let requestedAgentType, activeAgents.contains(requestedAgentType) {
            return requestedAgentType
        }

        let project = settings.projects.first(where: { $0.id == projectId })
        if let projectDefault = project?.agentType, activeAgents.contains(projectDefault) {
            return projectDefault
        }
        if let globalDefault = settings.effectiveGlobalDefaultAgentType, activeAgents.contains(globalDefault) {
            return globalDefault
        }
        return activeAgents[0]
    }

    func isTabNameTaken(_ name: String, existingNames: [String]) async -> Bool {
        if existingNames.contains(name) { return true }
        return await tmux.hasSession(name: name)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let magentArchivedThreadsDidChange = Notification.Name("magentArchivedThreadsDidChange")
    static let magentDeadSessionsDetected = Notification.Name("magentDeadSessionsDetected")
    static let magentAgentCompletionDetected = Notification.Name("magentAgentCompletionDetected")
    static let magentAgentWaitingForInput = Notification.Name("magentAgentWaitingForInput")
    static let magentAgentBusySessionsChanged = Notification.Name("magentAgentBusySessionsChanged")
    static let magentAgentRateLimitChanged = Notification.Name("magentAgentRateLimitChanged")
    static let magentGlobalRateLimitSummaryChanged = Notification.Name("magentGlobalRateLimitSummaryChanged")
    static let magentSectionsDidChange = Notification.Name("magentSectionsDidChange")
    static let magentOpenSettings = Notification.Name("magentOpenSettings")
    static let magentShowDiffViewer = Notification.Name("magentShowDiffViewer")
    static let magentHideDiffViewer = Notification.Name("magentHideDiffViewer")
    static let magentDiffViewerScrolledToFile = Notification.Name("magentDiffViewerScrolledToFile")
    static let magentNavigateToThread = Notification.Name("magentNavigateToThread")
    static let magentPullRequestInfoChanged = Notification.Name("magentPullRequestInfoChanged")
    static let magentJiraTicketInfoChanged = Notification.Name("magentJiraTicketInfoChanged")
    static let magentStatusSyncCompleted = Notification.Name("magentStatusSyncCompleted")
    static let magentPromptTOCVisibilityChanged = Notification.Name("magentPromptTOCVisibilityChanged")
    static let magentSettingsDidChange = Notification.Name("magentSettingsDidChange")
    static let magentUpdateStateChanged = Notification.Name("magentUpdateStateChanged")
    static let magentThreadCreationFinished = Notification.Name("magentThreadCreationFinished")
    /// Posted by `injectAfterStart` just before it begins waiting for the agent TUI
    /// so that the loading overlay knows to suppress poll-timer dismissal.
    static let magentAgentInjectionStarted = Notification.Name("magentAgentInjectionStarted")
    /// Posted by `injectAfterStart` when an initial prompt is queued and waiting for
    /// the agent to become ready, so the UI can show a "pending injection" banner.
    static let magentPendingPromptInjection = Notification.Name("magentPendingPromptInjection")
    /// Posted by `injectAfterStart` after all tmux keys (including Enter) are sent.
    /// Carries "sessionName" (String) and "includedInitialPrompt" (Bool).
    static let magentAgentKeysInjected = Notification.Name("magentAgentKeysInjected")
    /// Posted by `injectAfterStart` when an initial prompt was never injected because
    /// the agent prompt marker failed to appear within the timeout window.
    static let magentInitialPromptInjectionFailed = Notification.Name("magentInitialPromptInjectionFailed")
    /// Posted by `removeTabBySessionName` just before model cleanup begins.
    /// Carries "threadId" (UUID) and "sessionName" (String) so the terminal
    /// detail view can remove the surface immediately and prevent a Ghostty
    /// use-after-free when the tmux session (and its process) was killed via
    /// the IPC path, which doesn't call removeFromSuperview() directly.
    static let magentTabWillClose = Notification.Name("magentTabWillClose")
    /// Posted when a pending prompt recovery is added or removed for a thread.
    /// Carries "threadId" (UUID).
    static let magentPendingPromptRecovery = Notification.Name("magentPendingPromptRecovery")
    /// Posted by ThreadDetailViewController when the user clicks "Reopen as Thread"
    /// on a per-thread recovery banner. Carries "projectId" (UUID), "tempFileURL" (URL),
    /// and "prefill" (AgentLaunchSheetPrefill).
    static let magentRecoveryReopenRequested = Notification.Name("magentRecoveryReopenRequested")
}

// MARK: - Errors

enum ThreadManagerError: LocalizedError {
    case threadNotFound
    case invalidName
    case invalidPrompt
    case invalidDescription
    case duplicateName
    case invalidTabIndex
    case cannotDeleteMainThread
    case cannotRenameMainThread
    case nameGenerationFailed
    case worktreePathConflict([String])
    case noExpectedBranch
    case archiveCancelled
    case localFileSyncFailed(String)

    var errorDescription: String? {
        switch self {
        case .threadNotFound:
            return "Thread not found"
        case .invalidName:
            return "Invalid name. Name must not be empty or contain slashes."
        case .invalidPrompt:
            return "Prompt must not be empty."
        case .invalidDescription:
            return "Invalid description. Use 1-8 words with at least one letter."
        case .duplicateName:
            return "A thread with that name already exists."
        case .invalidTabIndex:
            return "Invalid tab index."
        case .cannotDeleteMainThread:
            return "Main threads cannot be deleted."
        case .cannotRenameMainThread:
            return "Main threads cannot be renamed."
        case .nameGenerationFailed:
            return "Could not generate a thread name. Ensure Claude or Codex is configured and reachable, then try again."
        case .worktreePathConflict(let names):
            let list = names.joined(separator: ", ")
            return "Cannot move worktrees — the following directories already exist in the destination: \(list)"
        case .noExpectedBranch:
            return "No expected branch configured. Set the default branch in project settings."
        case .archiveCancelled:
            return "Archive cancelled."
        case .localFileSyncFailed(let message):
            return message
        }
    }
}
