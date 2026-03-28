import AppKit
import Foundation
import UserNotifications
import MagentCore

extension ThreadManager {

    // MARK: - Dead Session Detection

    func checkForDeadSessions() async {
        let liveSessions: Set<String>
        do {
            liveSessions = Set(try await tmux.listSessions())
        } catch {
            // tmux server not running — all sessions are dead
            liveSessions = []
        }

        var changed = false
        for (index, thread) in threads.enumerated() {
            guard !thread.isArchived else { continue }

            let currentDead = Set(thread.tmuxSessionNames.filter {
                !liveSessions.contains($0)
            })
            guard currentDead != thread.deadSessions else { continue }

            let newlyDead = currentDead.subtracting(thread.deadSessions)
            threads[index].deadSessions = currentDead
            changed = true

            // Auto-recreate the currently visible session so the user isn't
            // stuck on a dead terminal — but not if it was intentionally evicted.
            // Other dead sessions stay dead until selected.
            if let visibleSession = thread.lastSelectedTabIdentifier,
               thread.id == activeThreadId,
               newlyDead.contains(visibleSession),
               !evictedIdleSessions.contains(visibleSession) {
                _ = await recreateSessionIfNeeded(
                    sessionName: visibleSession,
                    thread: thread
                )
            }

            if !newlyDead.isEmpty {
                let newlyDeadCopy = Array(newlyDead)
                let threadId = thread.id
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .magentDeadSessionsDetected,
                        object: self,
                        userInfo: [
                            "deadSessions": newlyDeadCopy,
                            "threadId": threadId
                        ]
                    )
                }
            }
        }

        if changed {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
            }
        }
    }

    // MARK: - Agent Completion Detection

    func checkForAgentCompletions() async {
        let sessions = await tmux.consumeAgentCompletionSessions()
        guard !sessions.isEmpty else { return }

        let now = Date()
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        let orderedUniqueSessions = sessions.reduce(into: [String]()) { result, session in
            if !result.contains(session) {
                result.append(session)
            }
        }

        var changed = false
        var changedThreadIds = Set<UUID>()
        var newlyUnreadThreadIds = Set<UUID>()

        for session in orderedUniqueSessions {
            if let previous = recentBellBySession[session], now.timeIntervalSince(previous) < 1.0 {
                continue
            }
            recentBellBySession[session] = now

            guard let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) else {
                continue
            }

            threads[index].lastAgentCompletionAt = now
            if settings.autoReorderThreadsOnAgentCompletion {
                bumpThreadToTopOfSection(threads[index].id)
            }
            threads[index].busySessions.remove(session)
            threads[index].waitingForInputSessions.remove(session)
            threads[index].hasUnsubmittedInputSessions.remove(session)
            notifiedWaitingSessions.remove(session)

            let isActiveThread = threads[index].id == activeThreadId
            let isActiveTab = isActiveThread && threads[index].lastSelectedTabIdentifier == session
            if !isActiveTab {
                let hadUnreadCompletion = threads[index].hasUnreadAgentCompletion
                threads[index].unreadCompletionSessions.insert(session)
                if !hadUnreadCompletion {
                    newlyUnreadThreadIds.insert(threads[index].id)
                }
            }
            changed = true
            changedThreadIds.insert(threads[index].id)
            scheduleAgentConversationIDRefresh(threadId: threads[index].id, sessionName: session)

            let projectName = settings.projects.first(where: { $0.id == threads[index].projectId })?.name ?? "Project"
            sendAgentCompletionNotification(for: threads[index], projectName: projectName, playSound: playSound, sessionName: session)
        }

        guard changed else { return }
        persistence.debouncedSaveActiveThreads(threads)

        // Refresh dirty and delivered states only for threads that just completed,
        // not the full scan — avoids running git-status on every thread on each bell.
        for threadId in changedThreadIds {
            await refreshDirtyState(for: threadId)
            await refreshDeliveredState(for: threadId)
        }

        // Trigger auto-rename for threads that haven't been renamed yet.
        // This covers the case where a thread is not currently displayed
        // (no ThreadDetailViewController), so the TOC-based rename path
        // never fires. We spawn these as fire-and-forget tasks to avoid
        // blocking the completion notification flow.
        for session in orderedUniqueSessions {
            if let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }),
               !threads[index].didAutoRenameFromFirstPrompt,
               !threads[index].isMain {
                let threadId = threads[index].id
                Task {
                    await triggerAutoRenameFromBellIfNeeded(threadId: threadId, sessionName: session)
                }
            }
        }

        await MainActor.run {
            updateDockBadge()
            if !newlyUnreadThreadIds.isEmpty {
                requestDockBounceForUnreadCompletionIfNeeded()
            }
            delegate?.threadManager(self, didUpdateThreads: threads)
            for threadId in changedThreadIds {
                if let thread = threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChangedNotification(for: thread)
                }
            }
            for session in orderedUniqueSessions {
                if let index = threads.firstIndex(where: { !$0.isArchived && $0.agentTmuxSessions.contains(session) }) {
                    NotificationCenter.default.post(
                        name: .magentAgentCompletionDetected,
                        object: self,
                        userInfo: [
                            "threadId": threads[index].id,
                            "unreadSessions": threads[index].unreadCompletionSessions
                        ]
                    )
                }
            }
        }
    }

    private func sendAgentCompletionNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = String(localized: .NotificationStrings.notificationsAgentFinishedTitle)
            content.body = "\(projectName) · \(thread.taskDescription ?? thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

            let request = UNNotificationRequest(
                identifier: "magent-agent-finished-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        // Play sound directly via NSSound as a fallback — UNNotification sound
        // can be throttled by macOS when many notifications are delivered.
        if playSound {
            let soundName = settings.agentCompletionSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: - Busy Session Sync

    /// Syncs `busySessions` by detecting what agent is actually running in each pane,
    /// then applying agent-specific idle/busy logic. If no known agent is detected
    /// (terminal session), the session is treated as not busy.
    func syncBusySessionsFromProcessState() async {
        var changed = false
        var busyChangedThreadIds = Set<UUID>()
        var rateLimitChangedThreadIds = Set<UUID>()

        func publishBusySyncChangesIfNeeded() async {
            guard changed else {
                // Even when no busy state flipped, tick the debounce timers so
                // pending transitions can commit after their 1-second window.
                for i in threads.indices {
                    threads[i].updateBusyStateDuration()
                }
                return
            }
            for i in threads.indices where busyChangedThreadIds.contains(threads[i].id) {
                threads[i].updateBusyStateDuration()
            }
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in busyChangedThreadIds {
                    if let thread = threads.first(where: { $0.id == threadId }) {
                        postBusySessionsChangedNotification(for: thread)
                    }
                }
                for threadId in rateLimitChangedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: self,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
            await publishRateLimitSummaryIfNeeded()
        }

        // Reconcile stale transient state first. This catches session renames or
        // removals performed outside Magent and prevents stuck busy/waiting flags.
        for i in threads.indices where !threads[i].isArchived {
            if pruneTransientSessionStateToKnownAgentSessions(threadIndex: i) {
                changed = true
                busyChangedThreadIds.insert(threads[i].id)
            }
        }

        // Collect all agent sessions across non-archived threads
        var allAgentSessions = Set<String>()
        for thread in threads where !thread.isArchived {
            allAgentSessions.formUnion(thread.agentTmuxSessions)
        }
        guard !allAgentSessions.isEmpty else {
            await publishBusySyncChangesIfNeeded()
            return
        }

        let paneStates = await tmux.activePaneStates(forSessions: allAgentSessions)
        guard !paneStates.isEmpty else {
            await publishBusySyncChangesIfNeeded()
            return
        }

        // Only fall back to a full child-process scan for panes whose current command
        // does not already identify the running agent.
        let unresolvedPanePids = Set(
            paneStates.values.compactMap { paneState -> pid_t? in
                guard paneState.pid > 0 else { return nil }
                guard detectedAgentType(from: paneState.command) == nil else { return nil }
                return paneState.pid
            }
        )
        let childProcessesByPid = await tmux.childProcesses(forParents: unresolvedPanePids)

        // Snapshot thread IDs and their sessions before iterating. The `threads`
        // array can shrink during `await` suspension points (e.g. archive), which
        // would invalidate raw indices and cause an out-of-bounds crash.
        let threadSnapshot: [(id: UUID, sessions: [String])] = threads
            .filter { !$0.isArchived }
            .map { ($0.id, $0.agentTmuxSessions) }

        for (threadId, sessions) in threadSnapshot {
            for session in sessions {
                guard let paneState = paneStates[session] else { continue }
                guard let ti = threads.firstIndex(where: { $0.id == threadId }) else { continue }

                if threads[ti].waitingForInputSessions.contains(session) { continue }

                let children = detectedAgentType(from: paneState.command) == nil
                    ? childProcessesByPid[paneState.pid] ?? []
                    : []
                let detectedAgent = detectedRunningAgentType(
                    paneCommand: paneState.command,
                    childProcesses: children
                )

                switch detectedAgent {
                case .codex?:
                    // Codex: busy only while "• esc to interrupt)" is visible in the latest scope
                    let isBusy = await paneShowsEscToInterrupt(sessionName: session)
                    guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                    if isBusy {
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        let recoveredIds = await clearRateLimitAfterRecovery(threadId: threadId, sessionName: session)
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                    } else if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    // When Codex is idle, check for unsubmitted typed input.
                    if !isBusy {
                        if await syncUnsubmittedInputState(threadId: threadId, sessionName: session, agentType: .codex) {
                            changed = true
                            busyChangedThreadIds.insert(threadId)
                        }
                    } else {
                        // Agent is busy — clear any stale unsubmitted-input flag.
                        if let ci = threads.firstIndex(where: { $0.id == threadId }),
                           threads[ci].hasUnsubmittedInputSessions.contains(session) {
                            threads[ci].hasUnsubmittedInputSessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threadId)
                        }
                    }

                case .claude?:
                    // Claude: skip if a completion bell was received recently — the bell fires
                    // just before process exit, so the process name can lag behind briefly.
                    let recentlyCompleted: Bool = {
                        guard let bellDate = recentBellBySession[session] else { return false }
                        return Date().timeIntervalSince(bellDate) < 5.0
                    }()
                    if recentlyCompleted { continue }

                    let content = await tmux.cachedCapturePane(sessionName: session)
                    if let content, isAtRateLimitPrompt(content) {
                        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        if setPromptRateLimitMarker(threadId: threadId, session: session) {
                            changed = true
                            rateLimitChangedThreadIds.insert(threadId)
                        }
                        if threads[i].busySessions.contains(session) {
                            threads[i].busySessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        if threads[i].hasUnsubmittedInputSessions.contains(session) {
                            threads[i].hasUnsubmittedInputSessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                    } else if let content, isAgentIdleAtPrompt(content) {
                        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        if threads[i].busySessions.contains(session) {
                            threads[i].busySessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        if clearPromptRateLimitMarker(threadId: threadId, session: session) {
                            changed = true
                            rateLimitChangedThreadIds.insert(threadId)
                        }
                        // Check for unsubmitted typed input at the idle prompt.
                        if await syncUnsubmittedInputState(threadId: threadId, sessionName: session, agentType: .claude) {
                            changed = true
                            busyChangedThreadIds.insert(threadId)
                        }
                    } else {
                        // Claude is running but not idle at prompt — treat as busy
                        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        // Clear unsubmitted-input flag — user submitted or agent took over.
                        if threads[i].hasUnsubmittedInputSessions.contains(session) {
                            threads[i].hasUnsubmittedInputSessions.remove(session)
                            changed = true
                            busyChangedThreadIds.insert(threads[i].id)
                        }
                        if clearPromptRateLimitMarker(threadId: threadId, session: session) {
                            changed = true
                            rateLimitChangedThreadIds.insert(threadId)
                        }
                        let recoveredIds = await clearRateLimitAfterRecovery(
                            threadId: threadId,
                            sessionName: session,
                            paneContent: content
                        )
                        if !recoveredIds.isEmpty {
                            rateLimitChangedThreadIds.formUnion(recoveredIds)
                            changed = true
                        }
                    }

                case .custom?, nil:
                    // No known agent detected — terminal session or agent has exited.
                    // Clear any stale busy/waiting/rate-limit/unsubmitted-input state.
                    guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                    if threads[i].busySessions.contains(session) {
                        threads[i].busySessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    if threads[i].waitingForInputSessions.contains(session) {
                        threads[i].waitingForInputSessions.remove(session)
                        notifiedWaitingSessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    if threads[i].hasUnsubmittedInputSessions.contains(session) {
                        threads[i].hasUnsubmittedInputSessions.remove(session)
                        changed = true
                        busyChangedThreadIds.insert(threads[i].id)
                    }
                    if clearPromptRateLimitMarker(threadId: threadId, session: session) {
                        changed = true
                        rateLimitChangedThreadIds.insert(threadId)
                    }
                }
            }
        }

        // Stamp sessionLastBusyAt for all currently-busy sessions so idle eviction
        // knows when a session was last actively working.
        let busyNow = Date()
        for thread in threads where !thread.isArchived {
            for session in thread.busySessions {
                sessionLastBusyAt[session] = busyNow
            }
        }

        await publishBusySyncChangesIfNeeded()
    }

/// Checks whether the agent appears to be idle at its input prompt by looking
    /// at the pane content. The definitive busy signal is the "esc to interrupt"
    /// status bar text that Claude Code shows while processing. If that text is
    /// present, the agent is busy. If a ❯ prompt is visible without
    /// "esc to interrupt", the agent is idle (even if the user has typed text
    /// at the prompt but hasn't submitted it yet).
    /// Returns true when the "esc to interrupt" status bar text is visible in the
    /// last 15 non-empty lines of pane content. This is the definitive Claude Code
    /// busy signal — present while the agent is actively processing, absent when idle.
    func paneContentShowsEscToInterrupt(_ paneContent: String) -> Bool {
        let nonEmpty = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(15)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return nonEmpty.contains(where: isEscToInterruptStatusLine)
    }

    private func isEscToInterruptStatusLine(_ line: String) -> Bool {
        // Only treat status-like lines as busy markers. This avoids false
        // positives when the phrase appears in normal conversation text.
        let directStatusMatch = line.range(
            of: #"^\s*(?:[•⏵]+[[:space:]]*)?esc to interrupt\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if directStatusMatch { return true }

        // Claude can render status with leading context, e.g.:
        // "⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"
        // May also have trailing content like "7% until auto-compact"
        return line.range(
            of: #"\s·\s*esc to interrupt\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isAgentIdleAtPrompt(_ paneContent: String) -> Bool {
        // "esc to interrupt" is shown in the status bar while Claude processes
        // → definitely busy, regardless of prompt visibility.
        if paneContentShowsEscToInterrupt(paneContent) { return false }

        let nonEmpty = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .suffix(15)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // ❯ prompt visible without the busy status bar → agent is idle
        let hasPrompt = nonEmpty.contains(where: { $0.hasPrefix("\u{276F}") })
        return hasPrompt
    }

    /// Detects the Claude Code interactive rate-limit prompt, which shows options
    /// like "Stop and wait for limit to reset" / "Switch to extra usage".
    /// When this prompt is visible, the agent is blocked but not actively processing,
    /// so we should show a rate-limit marker instead of a busy spinner.
    private func isAtRateLimitPrompt(_ paneContent: String) -> Bool {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let recentLines = lines.suffix(30)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !recentLines.isEmpty else { return false }

        let normalized = recentLines
            .joined(separator: "\n")
            .lowercased()
        let hasLimitContext = normalized.contains("limit")
            || normalized.contains("rate")
            || normalized.contains("quota")
        let hasWaitChoice = normalized.contains("stop and wait for limit to reset")
            || normalized.contains("stop and wait for limits to reset")
            || normalized.contains("stop and wait")
        let hasSwitchChoice = normalized.contains("switch to extra usage")
            || normalized.contains("switch to max")
            || normalized.contains("switch to pro")

        return hasLimitContext && (hasWaitChoice || hasSwitchChoice)
    }

    /// Sets a prompt-based rate-limit marker for the session. Returns true if
    /// the rate-limit state changed (for notification tracking).
    /// Does not overwrite text-based markers from checkForRateLimitedSessions.
    @discardableResult
    private func setPromptRateLimitMarker(threadId: UUID, session: String) -> Bool {
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        if let existing = threads[i].rateLimitedSessions[session], !existing.isPromptBased {
            return false // don't overwrite text-based marker
        }
        let marker = AgentRateLimitInfo(
            resetAt: Date.distantFuture,
            resetDescription: nil,
            detectedAt: Date(),
            isPromptBased: true
        )
        if threads[i].rateLimitedSessions[session] != marker {
            threads[i].rateLimitedSessions[session] = marker
            return true
        }
        return false
    }

    /// Clears a prompt-based rate-limit marker for the session. Returns true if
    /// a prompt-based marker was actually removed.
    @discardableResult
    private func clearPromptRateLimitMarker(threadId: UUID, session: String) -> Bool {
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        if let existing = threads[i].rateLimitedSessions[session], existing.isPromptBased {
            threads[i].rateLimitedSessions.removeValue(forKey: session)
            return true
        }
        return false
    }

    private func paneShowsEscToInterrupt(sessionName: String) async -> Bool {
        // Capture enough history to include at least one scope separator so we can
        // ignore stale matches from older scopes.
        guard let paneContent = await tmux.cachedCapturePane(sessionName: sessionName, lastLines: 200) else {
            return false
        }

        let lines = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        let scopeSeparatorIndex = lines.lastIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 20 else { return false }
            return trimmed.allSatisfy { $0 == "─" }
        })

        let latestScopeStart = scopeSeparatorIndex.map { lines.index(after: $0) } ?? lines.startIndex
        let latestScopeLines = lines[latestScopeStart...]

        // In Codex output, "• esc to interrupt)" appears inside the active
        // "Working (...)" status line while the model is processing.
        return latestScopeLines.contains { line in
            line.localizedCaseInsensitiveContains("• esc to interrupt)")
        }
    }

    // MARK: - Unsubmitted Input Detection

    /// Checks whether the agent prompt has user-typed (non-placeholder) text that
    /// hasn't been submitted. Uses ANSI-aware pane capture to distinguish real
    /// input from dim placeholder text.
    /// Number of lines to capture for unsubmitted-input detection. Matches the
    /// prompt-readiness capture depth so tall panes don't cause false negatives.
    private static let unsubmittedInputCaptureLines = 120

    /// Checks whether the agent prompt has user-typed (non-placeholder) text.
    /// Uses a two-phase approach to avoid a full ANSI tmux capture on every tick:
    /// 1. Quick check: if the already-cached plain-text capture shows the prompt
    ///    line is bare (marker only, no trailing text), skip the ANSI capture.
    /// 2. Full check: ANSI-aware capture to distinguish dim placeholder from real input.
    private func checkForUnsubmittedInput(sessionName: String, agentType: AgentType) async -> Bool {
        let marker: String
        switch agentType {
        case .claude: marker = "\u{276F}"  // ❯
        case .codex:  marker = "\u{203A}"  // ›
        case .custom: return false
        }

        // Phase 1: quick pre-filter using the already-cached plain-text capture.
        // If the prompt line has no text after the marker, there's nothing to protect.
        if let plainContent = await tmux.cachedCapturePane(
            sessionName: sessionName,
            lastLines: Self.unsubmittedInputCaptureLines
        ) {
            let plainLines = plainContent
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let lastPrompt = plainLines.last(where: { $0.hasPrefix(marker) }) {
                let afterMarker = lastPrompt.dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespaces)
                if afterMarker.isEmpty {
                    return false  // bare prompt — no input to protect
                }
            }
        }

        // Phase 2: ANSI-aware capture to distinguish placeholder from real input.
        guard let ansiContent = await tmux.capturePaneWithEscapes(
            sessionName: sessionName,
            lastLines: Self.unsubmittedInputCaptureLines
        ) else {
            return false
        }

        let lines = ansiContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let promptLine = lines.last(where: {
            Self.stripAnsiEscapes($0).trimmingCharacters(in: .whitespaces).hasPrefix(marker)
        }) else {
            return false
        }

        // isPromptLineEmpty returns true when text after marker is absent or placeholder (dim).
        // If it returns false, the user has typed real input.
        return !Self.isPromptLineEmpty(promptLine, marker: marker)
    }

    /// Updates the `hasUnsubmittedInputSessions` set for a thread+session based on
    /// ANSI-aware prompt inspection. Returns true if the set changed.
    @discardableResult
    private func syncUnsubmittedInputState(
        threadId: UUID,
        sessionName: String,
        agentType: AgentType
    ) async -> Bool {
        let hasInput = await checkForUnsubmittedInput(sessionName: sessionName, agentType: agentType)
        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { return false }
        if hasInput {
            if !threads[i].hasUnsubmittedInputSessions.contains(sessionName) {
                threads[i].hasUnsubmittedInputSessions.insert(sessionName)
                return true
            }
        } else {
            if threads[i].hasUnsubmittedInputSessions.contains(sessionName) {
                threads[i].hasUnsubmittedInputSessions.remove(sessionName)
                return true
            }
        }
        return false
    }

    // MARK: - Mark Completion / Waiting / Busy

    @MainActor
    func markThreadCompletionSeen(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].hasUnreadAgentCompletion else { return }
        threads[index].unreadCompletionSessions.removeAll()
        persistence.debouncedSaveActiveThreads(threads)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionCompletionSeen(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].unreadCompletionSessions.contains(sessionName) else { return }
        threads[index].unreadCompletionSessions.remove(sessionName)
        persistence.debouncedSaveActiveThreads(threads)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionWaitingSeen(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].waitingForInputSessions.contains(sessionName) else { return }
        threads[index].waitingForInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionBusy(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].agentTmuxSessions.contains(sessionName) else { return }
        // Clear waiting/unsubmitted state — user submitted a prompt
        threads[index].waitingForInputSessions.remove(sessionName)
        threads[index].hasUnsubmittedInputSessions.remove(sessionName)
        notifiedWaitingSessions.remove(sessionName)
        guard !threads[index].busySessions.contains(sessionName) else { return }
        threads[index].busySessions.insert(sessionName)
        delegate?.threadManager(self, didUpdateThreads: threads)
        postBusySessionsChangedNotification(for: threads[index])
    }

    // MARK: - Busy Sessions Notification

    @MainActor
    func postBusySessionsChangedNotification(for thread: MagentThread) {
        NotificationCenter.default.post(
            name: .magentAgentBusySessionsChanged,
            object: self,
            userInfo: [
                "threadId": thread.id,
                "busySessions": thread.busySessions
            ]
        )
    }
}
