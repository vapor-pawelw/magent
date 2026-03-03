import AppKit
import Foundation

extension ThreadManager {

    // MARK: - Dock Badge

    @MainActor
    func updateDockBadge() {
        let unreadCount = threads.filter({ !$0.isArchived && ($0.hasUnreadAgentCompletion || $0.hasWaitingForInput) }).count
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }

    // MARK: - Section Management

    @MainActor
    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        threads[index].sectionId = sectionId

        // Place at bottom of the matching pin group in the target section
        let maxOrder = threads
            .filter {
                $0.id != thread.id &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .max() ?? -1
        threads[index].displayOrder = maxOrder + 1

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isPinned.toggle()

        // Place at bottom of the new pin group
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread)
        let maxOrder = threads
            .filter {
                $0.id != thread.id &&
                !$0.isMain && !$0.isArchived &&
                $0.projectId == thread.projectId &&
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .max() ?? -1
        threads[index].displayOrder = maxOrder + 1

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Reorders a thread to a specific index within its pin group in a section.
    /// Reassigns sequential displayOrders for all threads in both pin groups of that section.
    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[threadIndex]
        let projectId = thread.projectId
        let isPinned = thread.isPinned

        // Get all threads in the same section, project, and pin group (excluding the dragged thread)
        var group = threads.filter {
            $0.id != threadId &&
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            $0.isPinned == isPinned &&
            effectiveSectionId(for: $0) == sectionId
        }
        // Sort by current display order so we insert relative to existing positions
        group.sort { $0.displayOrder < $1.displayOrder }

        let clampedIndex = max(0, min(targetIndex, group.count))
        group.insert(thread, at: clampedIndex)

        // Reassign sequential displayOrders for this group
        for (order, t) in group.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        // Also reassign sequential displayOrders for the other pin group in the same section
        var otherGroup = threads.filter {
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            $0.isPinned == !isPinned &&
            effectiveSectionId(for: $0) == sectionId
        }
        otherGroup.sort { $0.displayOrder < $1.displayOrder }
        for (order, t) in otherGroup.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Bumps a thread to the top of its pin group within its section by setting
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
                $0.isPinned == thread.isPinned &&
                effectiveSectionId(for: $0) == sectionId
            }
            .map(\.displayOrder)
            .min() ?? 0

        threads[index].displayOrder = groupMin - 1
    }

    /// Returns the effective section ID for a thread, falling back to the first visible section
    /// for the thread's project when the thread has no section or an unrecognized one.
    func effectiveSectionId(for thread: MagentThread) -> UUID? {
        let settings = persistence.loadSettings()
        let projectSections = settings.sections(for: thread.projectId)
        let knownIds = Set(projectSections.map(\.id))
        if let sid = thread.sectionId, knownIds.contains(sid) {
            return sid
        }
        return settings.visibleSections(for: thread.projectId).first?.id
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
