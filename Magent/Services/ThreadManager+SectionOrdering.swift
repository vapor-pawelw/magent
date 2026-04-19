import AppKit
import Foundation
import MagentCore

// Criteria for sidebar sort operations. Used by context-menu sort actions.
enum ThreadSortCriteria {
    case description
    case branchName
    case priority
    case lastActivity
}

// MARK: - Forwarding layer — logic lives in SidebarOrderingService

extension ThreadManager {

    func sidebarGroup(for thread: MagentThread) -> ThreadSidebarListState {
        sidebarOrderingService.sidebarGroup(for: thread)
    }

    func placeThreadAtBottomOfSidebarGroup(
        threadId: UUID,
        forcedSectionId: UUID? = nil
    ) {
        sidebarOrderingService.placeThreadAtBottomOfSidebarGroup(
            threadId: threadId,
            forcedSectionId: forcedSectionId
        )
    }

    func placeThreadAfterSibling(threadId: UUID, afterThreadId: UUID) {
        sidebarOrderingService.placeThreadAfterSibling(threadId: threadId, afterThreadId: afterThreadId)
    }

    // MARK: - Dock Badge

    @MainActor
    func updateDockBadge() {
        sidebarOrderingService.updateDockBadge()
    }

    @MainActor
    func requestDockBounceForUnreadCompletionIfNeeded() {
        sidebarOrderingService.requestDockBounceForUnreadCompletionIfNeeded()
    }

    // MARK: - Section Management

    @MainActor
    func moveThread(_ thread: MagentThread, toSection sectionId: UUID) {
        sidebarOrderingService.moveThread(thread, toSection: sectionId)
    }

    @MainActor
    func toggleThreadPin(threadId: UUID) {
        sidebarOrderingService.toggleThreadPin(threadId: threadId)
    }

    @MainActor
    var favoriteThreadCount: Int {
        sidebarOrderingService.favoriteThreadCount
    }

    @MainActor
    var favoriteThreadsChronological: [MagentThread] {
        sidebarOrderingService.favoriteThreadsChronological
    }

    @MainActor
    func canAddFavoriteThread(excludingThreadId: UUID? = nil) -> Bool {
        sidebarOrderingService.canAddFavoriteThread(excludingThreadId: excludingThreadId)
    }

    @MainActor
    @discardableResult
    func toggleThreadFavorite(threadId: UUID) -> Bool {
        sidebarOrderingService.toggleThreadFavorite(threadId: threadId)
    }

    @MainActor
    func toggleThreadHidden(threadId: UUID) {
        sidebarOrderingService.toggleThreadHidden(threadId: threadId)
    }

    @MainActor
    func reorderThread(_ threadId: UUID, toIndex targetIndex: Int, inSection sectionId: UUID?) {
        sidebarOrderingService.reorderThread(threadId, toIndex: targetIndex, inSection: sectionId)
    }

    @MainActor
    func reorderThreadInVisibleProjectList(_ threadId: UUID, toIndex targetIndex: Int) {
        sidebarOrderingService.reorderThreadInVisibleProjectList(threadId, toIndex: targetIndex)
    }

    func bumpThreadToTopOfSection(_ threadId: UUID) {
        sidebarOrderingService.bumpThreadToTopOfSection(threadId)
    }

    func effectiveSectionId(for thread: MagentThread) -> UUID? {
        sidebarOrderingService.effectiveSectionId(for: thread)
    }

    func effectiveSectionId(for thread: MagentThread, settings: AppSettings) -> UUID? {
        sidebarOrderingService.effectiveSectionId(for: thread, settings: settings)
    }

    @MainActor
    func threadsAssigned(
        toSection sectionId: UUID,
        projectId: UUID? = nil,
        settings: AppSettings
    ) -> [MagentThread] {
        sidebarOrderingService.threadsAssigned(toSection: sectionId, projectId: projectId, settings: settings)
    }

    @MainActor
    @discardableResult
    func reassignThreadsAssigned(
        toSection oldSectionId: UUID,
        toSection newSectionId: UUID,
        projectId: UUID? = nil,
        settings: AppSettings
    ) -> Int {
        sidebarOrderingService.reassignThreadsAssigned(
            toSection: oldSectionId,
            toSection: newSectionId,
            projectId: projectId,
            settings: settings
        )
    }

    @MainActor
    func reassignThreads(fromSection oldSectionId: UUID, toSection newSectionId: UUID) {
        sidebarOrderingService.reassignThreads(fromSection: oldSectionId, toSection: newSectionId)
    }

    // MARK: - Sort by Criteria

    @MainActor
    func sortSection(
        projectId: UUID,
        sectionId: UUID?,
        by criteria: ThreadSortCriteria,
        descending: Bool
    ) {
        sidebarOrderingService.sortSection(
            projectId: projectId,
            sectionId: sectionId,
            by: criteria,
            descending: descending
        )
    }

    @MainActor
    func sortAllSections(projectId: UUID, by criteria: ThreadSortCriteria, descending: Bool) {
        sidebarOrderingService.sortAllSections(projectId: projectId, by: criteria, descending: descending)
    }
}
