import Foundation
import Testing
import MagentCore

@Suite
struct SessionTrackerTests {

    @Test
    func cleanupForThreadRemovesAllTrackedStateForProvidedSessions() {
        let tracker = SessionTracker()
        let now = Date()
        let sessionA = "ma-thread-1"
        let sessionB = "ma-thread-2"
        let untouched = "ma-untouched"

        tracker.sessionLastVisitedAt = [sessionA: now, sessionB: now, untouched: now]
        tracker.sessionLastBusyAt = [sessionA: now, sessionB: now, untouched: now]
        tracker.evictedIdleSessions = [sessionA, sessionB, untouched]
        tracker.sessionsBeingRecreated = [sessionA, sessionB, untouched]
        tracker.knownGoodSessionContexts = [
            sessionA: KnownGoodSessionContext(
                threadId: UUID(),
                expectedPath: "/tmp/a",
                projectPath: "/repo",
                isAgentSession: true,
                validatedAt: now
            ),
            sessionB: KnownGoodSessionContext(
                threadId: UUID(),
                expectedPath: "/tmp/b",
                projectPath: "/repo",
                isAgentSession: true,
                validatedAt: now
            ),
            untouched: KnownGoodSessionContext(
                threadId: UUID(),
                expectedPath: "/tmp/c",
                projectPath: "/repo",
                isAgentSession: false,
                validatedAt: now
            ),
        ]
        tracker.lastRuntimeDetectedAgentBySession = [
            sessionA: (.codex, now),
            sessionB: (.claude, now),
            untouched: (.codex, now),
        ]

        tracker.cleanupForThread(sessionNames: [sessionA, sessionB])

        #expect(tracker.sessionLastVisitedAt[sessionA] == nil)
        #expect(tracker.sessionLastVisitedAt[sessionB] == nil)
        #expect(tracker.sessionLastVisitedAt[untouched] != nil)

        #expect(tracker.sessionLastBusyAt[sessionA] == nil)
        #expect(tracker.sessionLastBusyAt[sessionB] == nil)
        #expect(tracker.sessionLastBusyAt[untouched] != nil)

        #expect(!tracker.evictedIdleSessions.contains(sessionA))
        #expect(!tracker.evictedIdleSessions.contains(sessionB))
        #expect(tracker.evictedIdleSessions.contains(untouched))

        #expect(!tracker.sessionsBeingRecreated.contains(sessionA))
        #expect(!tracker.sessionsBeingRecreated.contains(sessionB))
        #expect(tracker.sessionsBeingRecreated.contains(untouched))

        #expect(tracker.knownGoodSessionContexts[sessionA] == nil)
        #expect(tracker.knownGoodSessionContexts[sessionB] == nil)
        #expect(tracker.knownGoodSessionContexts[untouched] != nil)

        #expect(tracker.lastRuntimeDetectedAgentBySession[sessionA] == nil)
        #expect(tracker.lastRuntimeDetectedAgentBySession[sessionB] == nil)
        #expect(tracker.lastRuntimeDetectedAgentBySession[untouched] != nil)
    }

    @Test
    func seedVisitTimestampsAssignsProvidedDate() {
        let tracker = SessionTracker()
        let seededAt = Date(timeIntervalSince1970: 1_723_000_000)
        tracker.sessionLastVisitedAt["existing"] = .distantPast

        tracker.seedVisitTimestamps(for: ["first", "second"], at: seededAt)

        #expect(tracker.sessionLastVisitedAt["first"] == seededAt)
        #expect(tracker.sessionLastVisitedAt["second"] == seededAt)
        #expect(tracker.sessionLastVisitedAt["existing"] == .distantPast)
    }

    @Test
    func seedVisitTimestampsOverwritesExistingSessionTimestamp() {
        let tracker = SessionTracker()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        tracker.sessionLastVisitedAt["session"] = older

        tracker.seedVisitTimestamps(for: ["session"], at: newer)

        #expect(tracker.sessionLastVisitedAt["session"] == newer)
    }

    @Test
    func cleanupForThreadIsNoOpForUnknownSessionNames() {
        let tracker = SessionTracker()
        let now = Date()
        tracker.sessionLastVisitedAt["known"] = now
        tracker.sessionLastBusyAt["known"] = now
        tracker.evictedIdleSessions = ["known"]

        tracker.cleanupForThread(sessionNames: ["missing"])

        #expect(tracker.sessionLastVisitedAt["known"] == now)
        #expect(tracker.sessionLastBusyAt["known"] == now)
        #expect(tracker.evictedIdleSessions.contains("known"))
    }

    @Test
    func evictionMarkingRoundTrip() {
        let tracker = SessionTracker()
        let session = "ma-evict-me"

        tracker.markEvicted(session)
        #expect(tracker.isEvicted(session))

        tracker.clearEviction(session)
        #expect(!tracker.isEvicted(session))
    }
}
