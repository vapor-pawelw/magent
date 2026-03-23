import AppKit
import Foundation
import MagentCore

extension ThreadManager {

    func sidebarGroup(for thread: MagentThread) -> ThreadSidebarListState {
        thread.sidebarListState
    }

    private func usesProjectWideOrdering(for projectId: UUID, settings: AppSettings) -> Bool {
        !settings.shouldUseThreadSections(for: projectId)
    }

    private func displayOrderGroup(
        projectId: UUID,
        sidebarGroup: ThreadSidebarListState,
        sectionId: UUID?,
        settings: AppSettings,
        excluding excludedThreadId: UUID? = nil
    ) -> [MagentThread] {
        let orderAcrossProject = usesProjectWideOrdering(for: projectId, settings: settings)
        return threads.filter {
            $0.id != excludedThreadId &&
            !$0.isMain && !$0.isArchived &&
            $0.projectId == projectId &&
            self.sidebarGroup(for: $0) == sidebarGroup &&
            (
                orderAcrossProject ||
                effectiveSectionId(for: $0, settings: settings) == sectionId
            )
        }
    }

    func placeThreadAtBottomOfSidebarGroup(
        threadId: UUID,
        forcedSectionId: UUID? = nil
    ) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let thread = threads[index]
        let scopeSectionId = forcedSectionId ?? effectiveSectionId(for: thread, settings: settings)
        let maxOrder = displayOrderGroup(
            projectId: thread.projectId,
            sidebarGroup: sidebarGroup(for: thread),
            sectionId: scopeSectionId,
            settings: settings,
            excluding: threadId
        )
        .map(\.displayOrder)
        .max() ?? -1
        threads[index].displayOrder = maxOrder + 1
    }

    /// Places a thread immediately after a sibling thread in the display order.
    /// Falls back to `placeThreadAtBottomOfSidebarGroup` when the sibling cannot be found.
    func placeThreadAfterSibling(threadId: UUID, afterThreadId: UUID) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }),
              let siblingIndex = threads.firstIndex(where: { $0.id == afterThreadId }) else {
            placeThreadAtBottomOfSidebarGroup(threadId: threadId)
            return
        }

        let settings = persistence.loadSettings()
        let sibling = threads[siblingIndex]
        let siblingOrder = sibling.displayOrder
        let sectionId = effectiveSectionId(for: sibling, settings: settings)

        // Find all threads in the same group that come after the sibling (by display order)
        // and shift them down by 1 to make room.
        let group = displayOrderGroup(
            projectId: sibling.projectId,
            sidebarGroup: sidebarGroup(for: sibling),
            sectionId: sectionId,
            settings: settings,
            excluding: threadId
        )
        for peer in group where peer.displayOrder > siblingOrder {
            if let i = threads.firstIndex(where: { $0.id == peer.id }) {
                threads[i].displayOrder += 1
            }
        }
        threads[threadIndex].displayOrder = siblingOrder + 1
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
        placeThreadAtBottomOfSidebarGroup(threadId: thread.id, forcedSectionId: sectionId)

        try? persistence.saveActiveThreads(threads)
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

        try? persistence.saveActiveThreads(threads)
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

        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    /// Reorders a thread to a specific index within its visible sidebar group.
    /// When sections are hidden, the whole project behaves like one combined section.
    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID?) {
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[threadIndex]
        let projectId = thread.projectId
        let targetGroup = sidebarGroup(for: thread)
        let settings = persistence.loadSettings()

        for group in ThreadSidebarListState.allCases {
            var threadsInGroup = displayOrderGroup(
                projectId: projectId,
                sidebarGroup: group,
                sectionId: sectionId,
                settings: settings,
                excluding: threadId
            )
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

        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }

    @MainActor
    func reorderThreadInVisibleProjectList(_ threadId: UUID, toIndex targetIndex: Int) {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let scopeSectionId = effectiveSectionId(for: thread, settings: settings)
        reorderThread(threadId, toIndex: targetIndex, inSection: scopeSectionId)
    }

    /// Bumps a thread to the top of its visible sidebar group by setting displayOrder
    /// to min(group) - 1.
    func bumpThreadToTopOfSection(_ threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let settings = persistence.loadSettings()
        let thread = threads[index]
        let sectionId = effectiveSectionId(for: thread, settings: settings)

        let groupMin = displayOrderGroup(
            projectId: thread.projectId,
            sidebarGroup: sidebarGroup(for: thread),
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
    func threadsAssigned(
        toSection sectionId: UUID,
        projectId: UUID? = nil,
        settings: AppSettings
    ) -> [MagentThread] {
        threads.filter {
            threadUsesSection($0, sectionId: sectionId, projectId: projectId, settings: settings)
        }
    }

    @MainActor
    @discardableResult
    func reassignThreadsAssigned(
        toSection oldSectionId: UUID,
        toSection newSectionId: UUID,
        projectId: UUID? = nil,
        settings: AppSettings
    ) -> Int {
        var movedCount = 0
        for index in threads.indices where threadUsesSection(threads[index], sectionId: oldSectionId, projectId: projectId, settings: settings) {
            threads[index].sectionId = newSectionId
            movedCount += 1
        }

        guard movedCount > 0 else { return 0 }
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
        return movedCount
    }

    private func threadUsesSection(
        _ thread: MagentThread,
        sectionId: UUID,
        projectId: UUID?,
        settings: AppSettings
    ) -> Bool {
        guard !thread.isArchived else { return false }

        if let projectId {
            guard thread.projectId == projectId else { return false }
            let knownSectionIds = Set(settings.sections(for: projectId).map(\.id))
            let fallbackId = settings.defaultSection(for: projectId)?.id
            return thread.resolvedSectionId(knownSectionIds: knownSectionIds, fallback: fallbackId) == sectionId
        }

        if let project = settings.projects.first(where: { $0.id == thread.projectId }),
           project.threadSections != nil {
            return false
        }

        let knownSectionIds = Set(settings.threadSections.map(\.id))
        let fallbackId = settings.defaultSection?.id
        return thread.resolvedSectionId(knownSectionIds: knownSectionIds, fallback: fallbackId) == sectionId
    }

    @MainActor
    func reassignThreads(fromSection oldSectionId: UUID, toSection newSectionId: UUID) {
        var changed = false
        for i in threads.indices where threads[i].sectionId == oldSectionId {
            threads[i].sectionId = newSectionId
            changed = true
        }
        guard changed else { return }
        try? persistence.saveActiveThreads(threads)
        delegate?.threadManager(self, didUpdateThreads: threads)
    }
}
