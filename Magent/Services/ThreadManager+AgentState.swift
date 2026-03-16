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

        for thread in threads {
            guard !thread.isArchived else { continue }

            let deadSessions = thread.tmuxSessionNames.filter { !liveSessions.contains($0) }
            guard !deadSessions.isEmpty else { continue }

            for sessionName in deadSessions {
                _ = await recreateSessionIfNeeded(
                    sessionName: sessionName,
                    thread: thread
                )
            }

            // Notify UI so terminal views can be replaced.
            // Must post on MainActor: the observer accesses terminalViews/tabItems (UI state).
            let deadSessionsCopy = deadSessions
            let threadId = thread.id
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .magentDeadSessionsDetected,
                    object: self,
                    userInfo: [
                        "deadSessions": deadSessionsCopy,
                        "threadId": threadId
                    ]
                )
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
            notifiedWaitingSessions.remove(session)

            let isActiveThread = threads[index].id == activeThreadId
            let isActiveTab = isActiveThread && threads[index].lastSelectedTmuxSessionName == session
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
        try? persistence.saveActiveThreads(threads)

        // Refresh dirty and delivered states only for threads that just completed,
        // not the full scan — avoids running git-status on every thread on each bell.
        for threadId in changedThreadIds {
            await refreshDirtyState(for: threadId)
            await refreshDeliveredState(for: threadId)
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
            guard changed else { return }
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

        // Collect pane PIDs so we can fetch child processes for agent detection
        var allPanePids = Set<pid_t>()
        for (_, paneState) in paneStates where paneState.pid > 0 {
            allPanePids.insert(paneState.pid)
        }
        let childProcessesByPid = await tmux.childProcesses(forParents: allPanePids)

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

                let children = childProcessesByPid[paneState.pid] ?? []
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
                    } else {
                        // Claude is running but not idle at prompt — treat as busy
                        guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                        if !threads[i].busySessions.contains(session) {
                            threads[i].busySessions.insert(session)
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
                    // Clear any stale busy/waiting/rate-limit state.
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
                    if clearPromptRateLimitMarker(threadId: threadId, session: session) {
                        changed = true
                        rateLimitChangedThreadIds.insert(threadId)
                    }
                }
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
        guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 200) else {
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

    // MARK: - Mark Completion / Waiting / Busy

    @MainActor
    func markThreadCompletionSeen(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].hasUnreadAgentCompletion else { return }
        threads[index].unreadCompletionSessions.removeAll()
        try? persistence.saveActiveThreads(threads)
        updateDockBadge()
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func markSessionCompletionSeen(threadId: UUID, sessionName: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        guard threads[index].unreadCompletionSessions.contains(sessionName) else { return }
        threads[index].unreadCompletionSessions.remove(sessionName)
        try? persistence.saveActiveThreads(threads)
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
        // Clear waiting state — user submitted a prompt
        threads[index].waitingForInputSessions.remove(sessionName)
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
