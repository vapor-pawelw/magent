import AppKit
import Foundation
import MagentCore

// All agent state logic lives in SessionLifecycleService (Phase 4).
// This file forwards public API calls and exposes helpers used by other ThreadManager extensions.
extension ThreadManager {

    func checkForDeadSessions() async {
        await sessionLifecycleService.checkForDeadSessions()
    }

    func checkForAgentCompletions() async {
        await sessionLifecycleService.checkForAgentCompletions()
    }

    func syncBusySessionsFromProcessState() async {
        await sessionLifecycleService.syncBusySessionsFromProcessState()
    }

    func paneContentShowsEscToInterrupt(_ paneContent: String) -> Bool {
        sessionLifecycleService.paneContentShowsEscToInterrupt(paneContent)
    }

    func paneContentShowsBackgroundActivity(_ paneContent: String) -> Bool {
        sessionLifecycleService.paneContentShowsBackgroundActivity(paneContent)
    }

    @MainActor
    func markThreadCompletionSeen(threadId: UUID) {
        sessionLifecycleService.markThreadCompletionSeen(threadId: threadId)
    }

    @MainActor
    @discardableResult
    func markAllThreadCompletionsSeen() -> Int {
        sessionLifecycleService.markAllThreadCompletionsSeen()
    }

    @MainActor
    func markSessionCompletionSeen(threadId: UUID, sessionName: String) {
        sessionLifecycleService.markSessionCompletionSeen(threadId: threadId, sessionName: sessionName)
    }

    @MainActor
    func markSessionRateLimitSeen(threadId: UUID, sessionName: String) {
        sessionLifecycleService.markSessionRateLimitSeen(threadId: threadId, sessionName: sessionName)
    }

    @MainActor
    func markSessionWaitingSeen(threadId: UUID, sessionName: String) {
        sessionLifecycleService.markSessionWaitingSeen(threadId: threadId, sessionName: sessionName)
    }

    @MainActor
    func markSessionBusy(threadId: UUID, sessionName: String) {
        sessionLifecycleService.markSessionBusy(threadId: threadId, sessionName: sessionName)
    }

    @MainActor
    func postBusySessionsChangedNotification(for thread: MagentThread) {
        sessionLifecycleService.postBusySessionsChangedNotification(for: thread)
    }

    @discardableResult
    func remapTransientSessionState(threadIndex index: Int, sessionRenameMap: [String: String]) -> Bool {
        sessionLifecycleService.remapTransientSessionState(threadIndex: index, sessionRenameMap: sessionRenameMap)
    }

    @discardableResult
    func pruneTransientSessionStateToKnownAgentSessions(threadIndex index: Int) -> Bool {
        sessionLifecycleService.pruneTransientSessionStateToKnownAgentSessions(threadIndex: index)
    }
}
