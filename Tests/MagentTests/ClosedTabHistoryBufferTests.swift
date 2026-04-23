import Foundation
import Testing
import MagentCore

@Suite("ClosedTabHistoryBuffer")
struct ClosedTabHistoryBufferTests {

    @Test("push/pop is LIFO")
    func lifoOrder() {
        var buffer = ClosedTabHistoryBuffer(limit: 10)
        let first = ClosedTabSnapshot.draft(
            PersistedDraftTab(identifier: "draft:1", agentType: .codex, prompt: "first")
        )
        let second = ClosedTabSnapshot.draft(
            PersistedDraftTab(identifier: "draft:2", agentType: .codex, prompt: "second")
        )

        buffer.push(first)
        buffer.push(second)

        #expect(buffer.popLast() == second)
        #expect(buffer.popLast() == first)
        #expect(buffer.popLast() == nil)
    }

    @Test("enforces max history limit")
    func enforcesLimit() {
        var buffer = ClosedTabHistoryBuffer(limit: 3)
        for index in 0..<5 {
            buffer.push(
                .draft(
                    PersistedDraftTab(
                        identifier: "draft:\(index)",
                        agentType: .codex,
                        prompt: "p\(index)"
                    )
                )
            )
        }

        #expect(buffer.entries.count == 3)
        #expect(buffer.entries == [
            .draft(PersistedDraftTab(identifier: "draft:2", agentType: .codex, prompt: "p2")),
            .draft(PersistedDraftTab(identifier: "draft:3", agentType: .codex, prompt: "p3")),
            .draft(PersistedDraftTab(identifier: "draft:4", agentType: .codex, prompt: "p4")),
        ])
    }

    @Test("init trims oversized seed entries")
    func initTrimsSeedEntries() {
        let buffer = ClosedTabHistoryBuffer(
            limit: 2,
            entries: [
                .draft(PersistedDraftTab(identifier: "a", agentType: .codex, prompt: "a")),
                .draft(PersistedDraftTab(identifier: "b", agentType: .codex, prompt: "b")),
                .draft(PersistedDraftTab(identifier: "c", agentType: .codex, prompt: "c")),
            ]
        )

        #expect(buffer.entries == [
            .draft(PersistedDraftTab(identifier: "b", agentType: .codex, prompt: "b")),
            .draft(PersistedDraftTab(identifier: "c", agentType: .codex, prompt: "c")),
        ])
    }
}
