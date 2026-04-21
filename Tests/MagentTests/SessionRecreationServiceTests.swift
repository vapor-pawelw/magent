import Foundation
import Testing
import MagentCore

@Suite
struct SessionRecreationServiceTests {

    // MARK: - isSessionPreparedFastPath

    @Test
    func fastPathReturnsTrueForFreshMatchingCacheEntry() {
        let (service, tracker) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: thread.id, validatedAt: Date())

        #expect(service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    @Test
    func fastPathReturnsFalseWhenNoCacheEntryExists() {
        let (service, _) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    @Test
    func fastPathClearsAndReturnsFalseForStaleEntryOlderThanTTL() {
        let (service, tracker) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        // One second past the TTL so the entry is definitely stale.
        let stale = Date().addingTimeInterval(-(SessionRecreationService.knownGoodSessionTTL + 1))
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: thread.id, validatedAt: stale)

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
        // Stale entry must be scrubbed so the slow path won't re-encounter it.
        #expect(tracker.knownGoodSessionContexts["ma-alpha"] == nil)
    }

    @Test
    func fastPathReturnsFalseWhenCachedThreadIdDoesNotMatch() {
        let (service, tracker) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: UUID(), validatedAt: Date())

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    @Test
    func fastPathReturnsFalseWhenSessionIsDead() {
        let (service, tracker) = makeService()
        var thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        thread.deadSessions = ["ma-alpha"]
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: thread.id, validatedAt: Date())

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    @Test
    func fastPathReturnsFalseWhenSessionIsEvicted() {
        let (service, tracker) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: thread.id, validatedAt: Date())
        tracker.evictedIdleSessions = ["ma-alpha"]

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    @Test
    func fastPathReturnsFalseWhileSessionIsBeingRecreated() {
        let (service, tracker) = makeService()
        let thread = makeThread(name: "alpha", sessions: ["ma-alpha"])
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(threadId: thread.id, validatedAt: Date())
        tracker.sessionsBeingRecreated = ["ma-alpha"]

        #expect(!service.isSessionPreparedFastPath(sessionName: "ma-alpha", thread: thread))
    }

    // MARK: - markSessionContextKnownGood

    @Test
    func markSessionContextKnownGoodWritesAllFieldsWithCurrentTimestamp() {
        let (service, tracker) = makeService()
        let threadId = UUID()
        let before = Date()

        service.markSessionContextKnownGood(
            sessionName: "ma-alpha",
            threadId: threadId,
            expectedPath: "/tmp/worktree",
            projectPath: "/repo",
            isAgentSession: true
        )

        let after = Date()
        let cached = tracker.knownGoodSessionContexts["ma-alpha"]
        #expect(cached != nil)
        #expect(cached?.threadId == threadId)
        #expect(cached?.expectedPath == "/tmp/worktree")
        #expect(cached?.projectPath == "/repo")
        #expect(cached?.isAgentSession == true)
        if let validatedAt = cached?.validatedAt {
            #expect(validatedAt >= before)
            #expect(validatedAt <= after)
        }
    }

    @Test
    func markSessionContextKnownGoodOverwritesExistingEntry() {
        let (service, tracker) = makeService()
        let originalThreadId = UUID()
        let newThreadId = UUID()
        tracker.knownGoodSessionContexts["ma-alpha"] = makeContext(
            threadId: originalThreadId,
            validatedAt: Date(timeIntervalSince1970: 0)
        )

        service.markSessionContextKnownGood(
            sessionName: "ma-alpha",
            threadId: newThreadId,
            expectedPath: "/tmp/new",
            projectPath: "/repo-new",
            isAgentSession: false
        )

        let cached = tracker.knownGoodSessionContexts["ma-alpha"]
        #expect(cached?.threadId == newThreadId)
        #expect(cached?.expectedPath == "/tmp/new")
        #expect(cached?.projectPath == "/repo-new")
        #expect(cached?.isAgentSession == false)
    }

    // MARK: - Helpers

    private func makeService() -> (SessionRecreationService, SessionTracker) {
        let store = ThreadStore()
        let tracker = SessionTracker()
        let service = SessionRecreationService(
            store: store,
            sessionTracker: tracker,
            persistence: PersistenceService.shared,
            tmux: TmuxService.shared
        )
        return (service, tracker)
    }

    private func makeThread(name: String, sessions: [String]) -> MagentThread {
        MagentThread(
            projectId: UUID(),
            name: name,
            worktreePath: "/tmp/\(name)",
            branchName: "branch-\(name)",
            tmuxSessionNames: sessions
        )
    }

    private func makeContext(threadId: UUID, validatedAt: Date) -> KnownGoodSessionContext {
        KnownGoodSessionContext(
            threadId: threadId,
            expectedPath: "/tmp/worktree",
            projectPath: "/repo",
            isAgentSession: true,
            validatedAt: validatedAt
        )
    }
}
