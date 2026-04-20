import Foundation
import Testing
import MagentCore

@Suite
struct ThreadStoreTests {

    @Test
    func threadOwningSessionIgnoresArchivedThreads() {
        let projectId = UUID()
        let active = makeThread(
            projectId: projectId,
            name: "active",
            sessions: ["ma-session-1"],
            isArchived: false
        )
        let archived = makeThread(
            projectId: projectId,
            name: "archived",
            sessions: ["ma-session-2"],
            isArchived: true
        )
        let store = ThreadStore()
        store.threads = [active, archived]

        #expect(store.thread(owningSession: "ma-session-1")?.id == active.id)
        #expect(store.thread(owningSession: "ma-session-2") == nil)
    }

    @Test
    func threadIndexOwningSessionIgnoresArchivedThreads() {
        let projectId = UUID()
        let active = makeThread(
            projectId: projectId,
            name: "active",
            sessions: ["ma-session-1"],
            isArchived: false
        )
        let archived = makeThread(
            projectId: projectId,
            name: "archived",
            sessions: ["ma-session-2"],
            isArchived: true
        )
        let store = ThreadStore()
        store.threads = [active, archived]

        #expect(store.threadIndex(owningSession: "ma-session-1") == 0)
        #expect(store.threadIndex(owningSession: "ma-session-2") == nil)
    }

    @Test
    func threadsForProjectExcludesArchivedThreads() {
        let targetProjectId = UUID()
        let otherProjectId = UUID()
        let visible = makeThread(projectId: targetProjectId, name: "visible", isArchived: false)
        let archived = makeThread(projectId: targetProjectId, name: "archived", isArchived: true)
        let other = makeThread(projectId: otherProjectId, name: "other", isArchived: false)
        let store = ThreadStore()
        store.threads = [visible, archived, other]

        let result = store.threads(forProject: targetProjectId)
        #expect(result.map(\.id) == [visible.id])
    }

    @Test
    func activeThreadResolvesOnlyWhenActiveIdMatchesExistingThread() {
        let projectId = UUID()
        let first = makeThread(projectId: projectId, name: "first")
        let second = makeThread(projectId: projectId, name: "second")
        let store = ThreadStore()
        store.threads = [first, second]

        #expect(store.activeThread() == nil)

        store.activeThreadId = first.id
        #expect(store.activeThread()?.id == first.id)

        store.activeThreadId = UUID()
        #expect(store.activeThread() == nil)
    }

    @Test
    func updateByIdMutatesThreadAndReturnsTrue() {
        let projectId = UUID()
        let thread = makeThread(projectId: projectId, name: "before")
        let store = ThreadStore()
        store.threads = [thread]

        let didUpdate = store.update(id: thread.id) { value in
            value.name = "after"
            value.displayOrder = 42
        }

        #expect(didUpdate)
        #expect(store.thread(byId: thread.id)?.name == "after")
        #expect(store.thread(byId: thread.id)?.displayOrder == 42)
    }

    @Test
    func updateByIdReturnsFalseWhenThreadDoesNotExist() {
        let projectId = UUID()
        let thread = makeThread(projectId: projectId, name: "only")
        let missing = UUID()
        let store = ThreadStore()
        store.threads = [thread]

        let didUpdate = store.update(id: missing) { value in
            value.name = "unexpected"
        }

        #expect(!didUpdate)
        #expect(store.thread(byId: thread.id)?.name == "only")
    }

    @Test
    func updateAtReturnsFalseForOutOfBoundsIndex() {
        let projectId = UUID()
        let thread = makeThread(projectId: projectId, name: "only")
        let store = ThreadStore()
        store.threads = [thread]

        let didUpdate = store.update(at: 5) { value in
            value.name = "unexpected"
        }

        #expect(!didUpdate)
        #expect(store.thread(byId: thread.id)?.name == "only")
    }

    private func makeThread(
        projectId: UUID,
        name: String,
        sessions: [String] = [],
        isArchived: Bool = false
    ) -> MagentThread {
        MagentThread(
            projectId: projectId,
            name: name,
            worktreePath: "/tmp/\(name)",
            branchName: "branch-\(name)",
            tmuxSessionNames: sessions,
            isArchived: isArchived
        )
    }
}
