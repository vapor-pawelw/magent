import AppKit
import Foundation
import MagentCore

extension ThreadManager {

    private func usesProjectWideOrdering(for projectId: UUID, settings: AppSettings) -> Bool {
        !settings.shouldUseThreadSections(for: projectId)
    }

    private func displayOrderGroup(
        projectId: UUID,
        isPinned: Bool,
        sectionId: UUID?,
        settings: AppSettings,
        excluding excludedThreadId: UUID? = nil
    ) -> [MagentThread] {
        let orderAcrossProject = usesProjectWideOrdering(for: projectId, settings: settings)
        return threads.filter {
            $0.id != excludedThreadId &&
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            $0.isPinned == isPinned &&
            (
                orderAcrossProject ||
                effectiveSectionId(for: $0, settings: settings) == sectionId
            )
        }
    }

    func assignThreadToBottomOfVisiblePinGroup(
        _ threadId: UUID,
        forcedSectionId: UUID? = nil
    ) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let thread = threads[index]
        let scopeSectionId = forcedSectionId ?? effectiveSectionId(for: thread, settings: settings)
        let maxOrder = displayOrderGroup(
            projectId: thread.projectId,
            isPinned: thread.isPinned,
            sectionId: scopeSectionId,
            settings: settings,
            excluding: threadId
        )
        .map(\.displayOrder)
        .max() ?? -1
        threads[index].displayOrder = maxOrder + 1
    }

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
        assignThreadToBottomOfVisiblePinGroup(thread.id, forcedSectionId: sectionId)

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].isPinned.toggle()
        assignThreadToBottomOfVisiblePinGroup(threadId)

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Reorders a thread to a specific index within its visible pin group.
    /// When sections are hidden, the whole project behaves like one combined section.
    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID?) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[threadIndex]
        let projectId = thread.projectId
        let isPinned = thread.isPinned
        let settings = persistence.loadSettings()

        var group = displayOrderGroup(
            projectId: projectId,
            isPinned: isPinned,
            sectionId: sectionId,
            settings: settings,
            excluding: threadId
        )
        group.sort { $0.displayOrder < $1.displayOrder }

        let clampedIndex = max(0, min(targetIndex, group.count))
        group.insert(thread, at: clampedIndex)

        // Reassign sequential displayOrders for this visible group.
        for (order, t) in group.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        var otherGroup = displayOrderGroup(
            projectId: projectId,
            isPinned: !isPinned,
            sectionId: sectionId,
            settings: settings
        )
        otherGroup.sort { $0.displayOrder < $1.displayOrder }
        for (order, t) in otherGroup.enumerated() {
            if let i = threads.firstIndex(where: { $0.id == t.id }) {
                threads[i].displayOrder = order
            }
        }

        try? persistence.saveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func reorderThreadInVisibleProjectList(_ threadId: UUID, toIndex targetIndex: Int) {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let scopeSectionId = effectiveSectionId(for: thread, settings: settings)
        reorderThread(threadId, toIndex: targetIndex, inSection: scopeSectionId)
    }

    /// Bumps a thread to the top of its visible pin group by setting displayOrder
    /// to min(group) - 1.
    func bumpThreadToTopOfSection(_ threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread, settings: settings)

        let groupMin = displayOrderGroup(
            projectId: thread.projectId,
            isPinned: thread.isPinned,
            sectionId: sectionId,
            settings: settings,
            excluding: threadId
        )
        .map(\.displayOrder)
        .min() ?? 0

        threads[index].displayOrder = groupMin - 1
    }

    /// Returns the effective section ID for a thread, falling back to the configured default
    /// section for the thread's project when the thread has no section or an unrecognized one.
    func effectiveSectionId(for thread: MagentThread) -> UUID? {
        effectiveSectionId(for: thread, settings: persistence.loadSettings())
    }

    func effectiveSectionId(for thread: MagentThread, settings: AppSettings) -> UUID? {
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
