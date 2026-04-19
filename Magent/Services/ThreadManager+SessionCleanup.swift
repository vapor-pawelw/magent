import Foundation
import MagentCore

// All session cleanup logic lives in SessionLifecycleService (Phase 4).
extension ThreadManager {

    var totalSessionCount: Int { sessionLifecycleService.totalSessionCount }
    var liveSessionCount: Int { sessionLifecycleService.liveSessionCount }
    var protectedSessionCount: Int { sessionLifecycleService.protectedSessionCount }

    func isSessionProtected(_ sessionName: String, in thread: MagentThread) -> Bool {
        sessionLifecycleService.isSessionProtected(sessionName, in: thread)
    }

    func isSessionProtected(_ sessionName: String, in thread: MagentThread, settings: AppSettings) -> Bool {
        sessionLifecycleService.isSessionProtected(sessionName, in: thread, settings: settings)
    }

    func collectCleanupCandidates() -> [CleanupCandidate] {
        sessionLifecycleService.collectCleanupCandidates()
    }

    @discardableResult
    func cleanupIdleSessions() async -> Int {
        await sessionLifecycleService.cleanupIdleSessions()
    }

    func toggleSessionKeepAlive(threadId: UUID, sessionName: String) {
        sessionLifecycleService.toggleSessionKeepAlive(threadId: threadId, sessionName: sessionName)
    }

    func toggleSectionKeepAlive(projectId: UUID, sectionId: UUID) {
        sessionLifecycleService.toggleSectionKeepAlive(projectId: projectId, sectionId: sectionId)
    }

    func toggleThreadKeepAlive(threadId: UUID) {
        sessionLifecycleService.toggleThreadKeepAlive(threadId: threadId)
    }

    func killSession(threadId: UUID, sessionName: String) async {
        await sessionLifecycleService.killSession(threadId: threadId, sessionName: sessionName)
    }

    func killAllSessions(threadId: UUID) async {
        await sessionLifecycleService.killAllSessions(threadId: threadId)
    }
}
