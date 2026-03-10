import AppKit
import Foundation
import MagentCore

extension ThreadManager {

    func sidebarGroup(for thread: MagentThread) -> ThreadSidebarListState {
        thread.sidebarListState
    }

    func placeThreadAtBottomOfSidebarGroup(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread)
        let maxOrder = threads
            .filter {
                $0.id != thread.id &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                sidebarGroup(for: $0) == sidebarGroup(for: thread) &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .max() ?? -1
        threads[index].displayOrder = maxOrder + 1
    }

    // MARK: - Dock Badge

    @MainActor
    func updateDockBadge() {
        let settings = persistence.loadSettings()
        guard settings.showDockBadgeAndBounceForUnreadCompletions else {
            NSApp.dockTile.badgeLabel = nil
            return
        }

        let unreadCount = threads.filter { !$0.isArchived && $0.hasUnreadAgentCompletion }.count
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }

    @MainActor
    func requestDockBounceForUnreadCompletionIfNeeded() {
        let settings = persistence.loadSettings()
        guard settings.showDockBadgeAndBounceForUnreadCompletions else { return }
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - Section Management

    @MainActor
    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].sectionId = sectionId
        placeThreadAtBottomOfSidebarGroup(threadId: thread.id)

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isPinned.toggle()
        if threads[index].isPinned {
            threads[index].isSidebarHidden = false
        }
        placeThreadAtBottomOfSidebarGroup(threadId: threadId)

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadHidden(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isSidebarHidden.toggle()
        if threads[index].isSidebarHidden {
            threads[index].isPinned = false
        }
        placeThreadAtBottomOfSidebarGroup(threadId: threadId)

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Reorders a thread to a specific index within its sidebar group in a section.
    /// Reassigns sequential displayOrders for all sidebar groups in that section.
    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[threadIndex]
        let projectId = thread.projectId
        let targetGroup = sidebarGroup(for: thread)

        for group in ThreadSidebarListState.allCases {
            var threadsInGroup = threads.filter {
                ($0.id != threadId || group != targetGroup) &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == projectId &&
                sidebarGroup(for: $0) == group &&
                effectiveSectionId(for: $0) == sectionId
            }
            threadsInGroup.sort { $0.displayOrder < $1.displayOrder }

            if group == targetGroup {
                let clampedIndex = max(0, min(targetIndex, threadsInGroup.count))
                threadsInGroup.insert(thread, at: clampedIndex)
            }

            for (order, groupedThread) in threadsInGroup.enumerated() {
                if let i = threads.firstIndex(where: { $0.id == groupedThread.id }) {
                    threads[i].displayOrder = order
                }
            }
        }

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Bumps a thread to the top of its sidebar group within its section by setting
    /// displayOrder to min(group) - 1.
    func bumpThreadToTopOfSection(_ threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread)

        let groupMin = threads
            .filter {
                $0.id != threadId &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                sidebarGroup(for: $0) == sidebarGroup(for: thread) &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .min() ?? 0

        threads[index].displayOrder = groupMin - 1
    }

    /// Returns the effective section ID for a thread, falling back to the configured default
    /// section for the thread's project when the thread has no section or an unrecognized one.
    func effectiveSectionId(for thread: MagentThread) -> UUID? {
        let settings = persistence.loadSettings()
        let projectSections = settings.sections(for: thread.projectId)
        let knownIds = Set(projectSections.map(\.id))
        if let sid = thread.sectionId, knownIds.contains(sid) {
            return sid
        }
        return settings.defaultSection(for: thread.projectId)?.id
    }

    @MainActor
    func reassignThreads(fromSection oldSectionId: UUID, toSection newSectionId: UUID) {
        var changed = false
        for i in threads.indices where threads[i].sectionId == oldSectionId {
            threads[i].sectionId = newSectionId
            changed = true
        }
        guard changed else { return }
        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }
}
