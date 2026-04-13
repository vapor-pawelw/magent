import Cocoa
import MagentCore

// MARK: - Protocol

@MainActor
protocol PopoutStateProviding: AnyObject {
    var poppedOutThreadIds: Set<UUID> { get }
    var detachedSessionNames: Set<String> { get }
    var visibleSessionNames: Set<String> { get }
    func isThreadPoppedOut(_ threadId: UUID) -> Bool
    func isTabDetached(sessionName: String) -> Bool
    func isPopoutWindow(_ window: NSWindow) -> Bool
}

// MARK: - Concrete Manager

@MainActor
final class PopoutWindowManager: PopoutStateProviding {
    static let shared = PopoutWindowManager()

    private(set) var threadWindows: [UUID: ThreadPopoutWindowController] = [:]
    private(set) var tabWindows: [String: TabPopoutWindowController] = [:]
    private var suppressAutomaticStateSaves = false
    private var hasRestoredPersistedState = false
    private(set) var isApplicationTerminating = false

    // MARK: - PopoutStateProviding

    var poppedOutThreadIds: Set<UUID> {
        Set(threadWindows.keys)
    }

    var detachedSessionNames: Set<String> {
        Set(tabWindows.keys)
    }

    /// All session names currently visible in pop-out windows — used by idle eviction
    /// and session cleanup to protect these sessions from being killed.
    var visibleSessionNames: Set<String> {
        var sessions = Set<String>()
        for controller in threadWindows.values {
            let vc = controller.detailVC
            let index = vc.currentTabIndex
            if index >= 0, index < vc.tabSlots.count,
               case .terminal(let sessionName) = vc.tabSlots[index] {
                sessions.insert(sessionName)
            }
        }
        for (sessionName, _) in tabWindows {
            sessions.insert(sessionName)
        }
        return sessions
    }

    func isThreadPoppedOut(_ threadId: UUID) -> Bool {
        threadWindows[threadId] != nil
    }

    func isTabDetached(sessionName: String) -> Bool {
        tabWindows[sessionName] != nil
    }

    func isPopoutWindow(_ window: NSWindow) -> Bool {
        for controller in threadWindows.values {
            if controller.window === window { return true }
        }
        for controller in tabWindows.values {
            if controller.window === window { return true }
        }
        return false
    }

    func beginApplicationTermination() {
        isApplicationTerminating = true
    }

    // MARK: - Thread Pop-out

    @discardableResult
    func popOutThread(_ thread: MagentThread, from sourceWindow: NSWindow?) -> ThreadPopoutWindowController {
        if let existing = threadWindows[thread.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let controller = ThreadPopoutWindowController(thread: thread, sourceWindow: sourceWindow)
        threadWindows[thread.id] = controller
        controller.window?.makeKeyAndOrderFront(nil)

        NotificationCenter.default.post(
            name: .magentThreadPoppedOut,
            object: nil,
            userInfo: ["threadId": thread.id]
        )

        saveStateIfAllowed()

        return controller
    }

    func returnThreadToMain(_ threadId: UUID) {
        closePoppedOutThread(threadId, postReturnNotification: true)
    }

    func returnAllThreadsToMain() {
        let threadIds = Array(threadWindows.keys)
        for threadId in threadIds {
            returnThreadToMain(threadId)
        }
    }

    /// Replaces the thread shown in one pop-out window with another thread.
    /// The existing pop-out thread is returned to the main window.
    func replacePoppedOutThread(targetThreadId: UUID, with newThreadId: UUID, in frame: NSRect?) {
        guard targetThreadId != newThreadId else {
            bringToFront(threadId: targetThreadId)
            return
        }
        guard threadWindows[targetThreadId] != nil else { return }
        guard let newThread = ThreadManager.shared.threads.first(where: { $0.id == newThreadId }),
              !newThread.isMain else { return }

        let targetFrame = frame ?? threadWindows[targetThreadId]?.window?.frame

        returnThreadToMain(targetThreadId)

        if let existingNewThreadWindow = threadWindows[newThreadId] {
            if let targetFrame {
                existingNewThreadWindow.window?.setFrame(targetFrame, display: true)
            }
            existingNewThreadWindow.window?.makeKeyAndOrderFront(nil)
            saveStateIfAllowed()
            return
        }

        let newController = popOutThread(newThread, from: nil)
        if let targetFrame {
            newController.window?.setFrame(targetFrame, display: true)
        }
    }

    /// Moves an already-popped-out thread into another pop-out window, returning
    /// the target thread to the main window and closing the dragged thread's old window.
    func movePoppedOutThread(targetThreadId: UUID, draggedThreadId: UUID, to frame: NSRect?) {
        guard targetThreadId != draggedThreadId else { return }
        guard threadWindows[targetThreadId] != nil,
              threadWindows[draggedThreadId] != nil,
              let draggedThread = ThreadManager.shared.threads.first(where: { $0.id == draggedThreadId }),
              !draggedThread.isMain else { return }

        let targetFrame = frame ?? threadWindows[targetThreadId]?.window?.frame
        returnThreadToMain(targetThreadId)
        closePoppedOutThread(draggedThreadId, postReturnNotification: false)

        let newController = popOutThread(draggedThread, from: nil)
        if let targetFrame {
            newController.window?.setFrame(targetFrame, display: true)
        }
        saveStateIfAllowed()
    }

    /// Swaps the window positions of two already-popped-out threads.
    func swapPoppedOutThreads(_ firstThreadId: UUID, _ secondThreadId: UUID) {
        guard firstThreadId != secondThreadId,
              let firstController = threadWindows[firstThreadId],
              let secondController = threadWindows[secondThreadId],
              let firstThread = ThreadManager.shared.threads.first(where: { $0.id == firstThreadId }),
              let secondThread = ThreadManager.shared.threads.first(where: { $0.id == secondThreadId }),
              !firstThread.isMain,
              !secondThread.isMain else { return }

        let firstFrame = firstController.window?.frame
        let secondFrame = secondController.window?.frame

        closePoppedOutThread(firstThreadId, postReturnNotification: false)
        closePoppedOutThread(secondThreadId, postReturnNotification: false)

        let movedSecond = popOutThread(secondThread, from: nil)
        if let firstFrame {
            movedSecond.window?.setFrame(firstFrame, display: true)
        }

        let movedFirst = popOutThread(firstThread, from: nil)
        if let secondFrame {
            movedFirst.window?.setFrame(secondFrame, display: true)
        }

        saveStateIfAllowed()
    }

    /// Closes every pop-out window (thread and detached tab) that belongs to the
    /// given project. Returns true when at least one pop-out was closed.
    @discardableResult
    func closePopouts(forProjectId projectId: UUID) -> Bool {
        let threadsById = Dictionary(uniqueKeysWithValues: ThreadManager.shared.threads.map { ($0.id, $0) })

        let tabSessionsToClose = tabWindows.compactMap { sessionName, controller -> String? in
            guard let thread = threadsById[controller.threadId], thread.projectId == projectId else { return nil }
            return sessionName
        }
        let threadIdsToClose = threadWindows.keys.filter { threadId in
            guard let thread = threadsById[threadId] else { return false }
            return thread.projectId == projectId
        }

        let hadAny = !tabSessionsToClose.isEmpty || !threadIdsToClose.isEmpty
        for sessionName in tabSessionsToClose {
            returnTabToThread(sessionName: sessionName)
        }
        for threadId in threadIdsToClose {
            returnThreadToMain(threadId)
        }
        return hadAny
    }

    // MARK: - Tab Detach

    @discardableResult
    func detachTab(sessionName: String, thread: MagentThread, from sourceWindow: NSWindow?) -> TabPopoutWindowController {
        if let existing = tabWindows[sessionName] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }

        let controller = TabPopoutWindowController(
            sessionName: sessionName,
            thread: thread,
            sourceWindow: sourceWindow
        )
        tabWindows[sessionName] = controller
        controller.window?.makeKeyAndOrderFront(nil)

        NotificationCenter.default.post(
            name: .magentTabDetached,
            object: nil,
            userInfo: ["sessionName": sessionName, "threadId": thread.id]
        )

        saveStateIfAllowed()

        return controller
    }

    func returnTabToThread(sessionName: String) {
        guard let controller = tabWindows.removeValue(forKey: sessionName) else { return }
        controller.cacheTerminalViewForReuse()
        controller.isReturningToThread = true
        controller.tearDown()
        controller.window?.close()

        NotificationCenter.default.post(
            name: .magentTabReturnedToThread,
            object: nil,
            userInfo: ["sessionName": sessionName, "threadId": controller.threadId]
        )

        saveStateIfAllowed()
    }

    // MARK: - Bring to Front

    func bringToFront(threadId: UUID) {
        guard let controller = threadWindows[threadId] else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusCurrentTabForNavigation()
    }

    func bringToFront(sessionName: String) {
        tabWindows[sessionName]?.window?.makeKeyAndOrderFront(nil)
    }

    func revealAllWindowsWithoutFocus() {
        let previousKeyWindow = NSApp.keyWindow

        for controller in threadWindows.values {
            revealWindowWithoutFocus(controller.window)
        }
        for controller in tabWindows.values {
            revealWindowWithoutFocus(controller.window)
        }

        // Keep whatever was key before reveal as key. This method should never
        // promote a random pop-out window to focused/key state.
        previousKeyWindow?.makeKey()
    }

    // MARK: - Close All

    func closeAll() {
        suppressAutomaticStateSaves = true
        defer { suppressAutomaticStateSaves = false }

        for (threadId, _) in threadWindows {
            returnThreadToMain(threadId)
        }
        for (sessionName, _) in tabWindows {
            returnTabToThread(sessionName: sessionName)
        }
    }

    // MARK: - Persistence

    func saveState() {
        var threadPopouts: [PopoutWindowState.ThreadPopout] = []
        for (threadId, controller) in threadWindows {
            guard let frame = controller.window?.frame else { continue }
            threadPopouts.append(.init(
                threadId: threadId,
                windowFrame: .init(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.size.width),
                    height: Double(frame.size.height)
                )
            ))
        }

        var tabPopouts: [PopoutWindowState.TabPopout] = []
        for (sessionName, controller) in tabWindows {
            guard let frame = controller.window?.frame else { continue }
            tabPopouts.append(.init(
                threadId: controller.threadId,
                sessionName: sessionName,
                windowFrame: .init(
                    x: Double(frame.origin.x),
                    y: Double(frame.origin.y),
                    width: Double(frame.size.width),
                    height: Double(frame.size.height)
                )
            ))
        }

        let state = PopoutWindowState(threadPopouts: threadPopouts, tabPopouts: tabPopouts)
        PersistenceService.shared.savePopoutWindowState(state)
    }

    @discardableResult
    func restoreState(threads: [MagentThread]) -> Bool {
        guard !hasRestoredPersistedState else { return false }
        guard let state = PersistenceService.shared.loadPopoutWindowState() else { return false }
        hasRestoredPersistedState = true
        return applyPersistedState(state, threads: threads)
    }

    @discardableResult
    func ensurePersistedWindowsRestored(threads: [MagentThread]) -> Bool {
        guard let state = PersistenceService.shared.loadPopoutWindowState() else { return false }
        return applyPersistedState(state, threads: threads)
    }

    @discardableResult
    private func applyPersistedState(_ state: PopoutWindowState, threads: [MagentThread]) -> Bool {
        let threadPopouts = deduplicatedThreadPopouts(from: state.threadPopouts)
        let tabPopouts = deduplicatedTabPopouts(from: state.tabPopouts)
        var restoredAny = false

        for popout in threadPopouts {
            guard let thread = threads.first(where: { $0.id == popout.threadId }) else { continue }
            guard !thread.isMain else { continue }

            closeDuplicateThreadWindows(threadId: thread.id, keeping: threadWindows[thread.id])

            let controller: ThreadPopoutWindowController
            let wasCreated: Bool
            if let existing = threadWindows[thread.id] {
                controller = existing
                wasCreated = false
            } else {
                let created = ThreadPopoutWindowController(thread: thread, sourceWindow: nil)
                threadWindows[thread.id] = created
                controller = created
                wasCreated = true
            }
            revealWindowWithoutFocus(controller.window)

            let frame = NSRect(
                x: popout.windowFrame.x,
                y: popout.windowFrame.y,
                width: popout.windowFrame.width,
                height: popout.windowFrame.height
            )
            if isFrameVisibleOnCurrentScreens(frame) {
                controller.window?.setFrame(frame, display: true)
            }
            restoredAny = true

            if wasCreated {
                NotificationCenter.default.post(
                    name: .magentThreadPoppedOut,
                    object: nil,
                    userInfo: ["threadId": thread.id]
                )
            }
        }

        for popout in tabPopouts {
            guard let thread = threads.first(where: { $0.id == popout.threadId }) else { continue }
            guard thread.tmuxSessionNames.contains(popout.sessionName) else { continue }

            closeDuplicateTabWindows(sessionName: popout.sessionName, keeping: tabWindows[popout.sessionName])

            let controller: TabPopoutWindowController
            let wasCreated: Bool
            if let existing = tabWindows[popout.sessionName] {
                controller = existing
                wasCreated = false
            } else {
                let created = TabPopoutWindowController(
                    sessionName: popout.sessionName,
                    thread: thread,
                    sourceWindow: nil
                )
                tabWindows[popout.sessionName] = created
                controller = created
                wasCreated = true
            }
            revealWindowWithoutFocus(controller.window)

            let frame = NSRect(
                x: popout.windowFrame.x,
                y: popout.windowFrame.y,
                width: popout.windowFrame.width,
                height: popout.windowFrame.height
            )
            if isFrameVisibleOnCurrentScreens(frame) {
                controller.window?.setFrame(frame, display: true)
            }
            restoredAny = true

            if wasCreated {
                NotificationCenter.default.post(
                    name: .magentTabDetached,
                    object: nil,
                    userInfo: ["sessionName": popout.sessionName, "threadId": thread.id]
                )
            }
        }
        return restoredAny
    }

    // MARK: - Notification Observers

    private var archiveObserver: NSObjectProtocol?
    private var tabCloseObserver: NSObjectProtocol?

    func startObserving() {
        archiveObserver = NotificationCenter.default.addObserver(
            forName: .magentArchivedThreadsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let currentThreadIds = Set(ThreadManager.shared.threads.map(\.id))
                for threadId in self.threadWindows.keys {
                    if !currentThreadIds.contains(threadId) {
                        self.returnThreadToMain(threadId)
                    }
                }
                for (sessionName, controller) in self.tabWindows {
                    if !currentThreadIds.contains(controller.threadId) {
                        self.returnTabToThread(sessionName: sessionName)
                    }
                }
            }
        }

        tabCloseObserver = NotificationCenter.default.addObserver(
            forName: .magentTabWillClose,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let sessionName = notification.userInfo?["sessionName"] as? String
            MainActor.assumeIsolated {
                guard let self,
                      let sessionName else { return }
                if self.tabWindows[sessionName] != nil {
                    self.returnTabToThread(sessionName: sessionName)
                }
            }
        }
    }

    // MARK: - Helpers

    private func saveStateIfAllowed() {
        guard !suppressAutomaticStateSaves else { return }
        saveState()
    }

    private func closePoppedOutThread(_ threadId: UUID, postReturnNotification: Bool) {
        guard let controller = threadWindows.removeValue(forKey: threadId) else { return }
        controller.detailVC.cacheTerminalViewsForReuse()
        // Prevent windowWillClose from re-entering the return flow while we re-home windows.
        controller.isReturningToMain = true
        controller.tearDown()
        controller.window?.close()

        if postReturnNotification {
            NotificationCenter.default.post(
                name: .magentThreadReturnedToMain,
                object: nil,
                userInfo: ["threadId": threadId]
            )
            saveStateIfAllowed()
        }
    }

    private func deduplicatedThreadPopouts(
        from popouts: [PopoutWindowState.ThreadPopout]
    ) -> [PopoutWindowState.ThreadPopout] {
        var seen = Set<UUID>()
        return popouts.reversed().filter { popout in
            seen.insert(popout.threadId).inserted
        }.reversed()
    }

    private func deduplicatedTabPopouts(
        from popouts: [PopoutWindowState.TabPopout]
    ) -> [PopoutWindowState.TabPopout] {
        var seen = Set<String>()
        return popouts.reversed().filter { popout in
            seen.insert(popout.sessionName).inserted
        }.reversed()
    }

    private func closeDuplicateThreadWindows(
        threadId: UUID,
        keeping keeper: ThreadPopoutWindowController?
    ) {
        let duplicateControllers: [ThreadPopoutWindowController] = NSApp.windows.compactMap { window -> ThreadPopoutWindowController? in
            guard let controller = window.windowController as? ThreadPopoutWindowController,
                  controller.threadId == threadId,
                  controller !== keeper else { return nil }
            return controller
        }
        for controller in duplicateControllers {
            controller.isReturningToMain = true
            controller.tearDown()
            controller.window?.close()
        }
    }

    private func closeDuplicateTabWindows(
        sessionName: String,
        keeping keeper: TabPopoutWindowController?
    ) {
        let duplicateControllers: [TabPopoutWindowController] = NSApp.windows.compactMap { window -> TabPopoutWindowController? in
            guard let controller = window.windowController as? TabPopoutWindowController,
                  controller.sessionName == sessionName,
                  controller !== keeper else { return nil }
            return controller
        }
        for controller in duplicateControllers {
            controller.isReturningToThread = true
            controller.window?.close()
        }
    }

    private func isFrameVisibleOnCurrentScreens(_ frame: NSRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.visibleFrame.intersects(frame) {
                return true
            }
        }
        return false
    }

    private func revealWindowWithoutFocus(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFront(nil)
    }
}
