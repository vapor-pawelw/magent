import AppKit
import Foundation
import UserNotifications

extension ThreadManager {

    // MARK: - Waiting-for-Input Detection

    func checkForWaitingForInput() async {
        let settings = persistence.loadSettings()
        let playSound = settings.playSoundForAgentCompletion
        var changed = false
        var changedThreadIds = Set<UUID>()
        var notifyPairs: [(threadId: UUID, sessionName: String)] = []

        let waitingSnapshot: [(id: UUID, sessions: [String])] = threads
            .filter { !$0.isArchived }
            .map { ($0.id, $0.agentTmuxSessions) }
        for (threadId, sessions) in waitingSnapshot {
            for session in sessions {
                guard let ti = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                let wasWaiting = threads[ti].waitingForInputSessions.contains(session)
                let isBusy = threads[ti].busySessions.contains(session)

                // Only check busy sessions (or already-waiting sessions to detect resolution)
                guard isBusy || wasWaiting else { continue }

                guard let paneContent = await tmux.capturePane(sessionName: session) else { continue }
                guard let i = threads.firstIndex(where: { $0.id == threadId }) else { continue }
                let isWaiting = matchesWaitingForInputPattern(paneContent)

                if isWaiting && !wasWaiting {
                    // Transition: busy → waiting
                    threads[i].busySessions.remove(session)
                    threads[i].waitingForInputSessions.insert(session)
                    changed = true
                    changedThreadIds.insert(threads[i].id)

                    let isActiveThread = threads[i].id == activeThreadId
                    let isActiveTab = isActiveThread && threads[i].lastSelectedTmuxSessionName == session
                    if !isActiveTab && !notifiedWaitingSessions.contains(session) {
                        notifiedWaitingSessions.insert(session)
                        notifyPairs.append((threadId, session))
                    }
                } else if !isWaiting && wasWaiting {
                    // Transition: waiting → cleared (user provided input)
                    threads[i].waitingForInputSessions.remove(session)
                    notifiedWaitingSessions.remove(session)
                    changed = true
                    changedThreadIds.insert(threads[i].id)
                    // syncBusy will re-mark as busy on the same tick
                }
            }
        }

        guard changed else { return }
        for (threadId, sessionName) in notifyPairs {
            guard let thread = threads.first(where: { $0.id == threadId }) else { continue }
            let projectName = settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "Project"
            sendAgentWaitingNotification(for: thread, projectName: projectName, playSound: playSound, sessionName: sessionName)
        }

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            for threadId in changedThreadIds {
                if let thread = threads.first(where: { $0.id == threadId }) {
                    postBusySessionsChangedNotification(for: thread)
                }
            }
            for i in threads.indices where !threads[i].isArchived && threads[i].hasWaitingForInput {
                NotificationCenter.default.post(
                    name: .magentAgentWaitingForInput,
                    object: self,
                    userInfo: [
                        "threadId": threads[i].id,
                        "waitingSessions": threads[i].waitingForInputSessions
                    ]
                )
            }
        }
    }

    private func matchesWaitingForInputPattern(_ text: String) -> Bool {
        // Trim trailing whitespace/newlines and look at the last non-empty lines
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmedLines = lines.suffix(20).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmedLines.isEmpty else { return false }
        let lastChunk = trimmedLines.suffix(15).joined(separator: "\n")

        // Claude Code plan mode
        if lastChunk.contains("Would you like to proceed?") { return true }

        // Claude Code permission prompts
        if lastChunk.contains("Do you want to") && (lastChunk.contains("Yes") || lastChunk.contains("No")) { return true }

        // Codex approval prompts
        if lastChunk.contains("approve") && lastChunk.contains("deny") { return true }

        // Claude Code AskUserQuestion / interactive prompt: ❯ selector at line start
        // Only match when ❯ is at the start of a line (interactive selector indicator),
        // not just anywhere in terminal (e.g. Claude Code's input prompt character).
        let lastFew = trimmedLines.suffix(6)
        let hasSelectorAtLineStart = lastFew.contains { $0.hasPrefix("\u{276F}") }
        if hasSelectorAtLineStart && lastFew.contains(where: { $0.range(of: #"^\u{276F}?\s*\d+\."#, options: .regularExpression) != nil }) { return true }

        // Claude Code ExitPlanMode / plan approval prompt
        if lastChunk.contains("Do you want me to go ahead") { return true }

        return false
    }

    private func sendAgentWaitingNotification(for thread: MagentThread, projectName: String, playSound: Bool, sessionName: String) {
        let settings = persistence.loadSettings()

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Agent Needs Input"
            content.body = "\(projectName) · \(thread.name)"
            if playSound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.agentCompletionSoundName))
            }
            content.userInfo = ["threadId": thread.id.uuidString, "sessionName": sessionName]

            let request = UNNotificationRequest(
                identifier: "magent-agent-waiting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

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
}
