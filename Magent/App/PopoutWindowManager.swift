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

        return controller
    }

    func returnThreadToMain(_ threadId: UUID) {
        guard let controller = threadWindows.removeValue(forKey: threadId) else { return }
        controller.detailVC.cacheTerminalViewsForReuse()
        // Prevent windowWillClose from re-entering returnThreadToMain
        controller.isReturningToMain = true
        controller.tearDown()
        controller.window?.close()

        NotificationCenter.default.post(
            name: .magentThreadReturnedToMain,
            object: nil,
            userInfo: ["threadId": threadId]
        )
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

        return controller
    }

    func returnTabToThread(sessionName: String) {
        guard let controller = tabWindows.removeValue(forKey: sessionName) else { return }
        controller.cacheTerminalViewForReuse()
        controller.isReturningToThread = true
        controller.window?.close()

        NotificationCenter.default.post(
            name: .magentTabReturnedToThread,
            object: nil,
            userInfo: ["sessionName": sessionName, "threadId": controller.threadId]
        )
    }

    // MARK: - Bring to Front

    func bringToFront(threadId: UUID) {
        threadWindows[threadId]?.window?.makeKeyAndOrderFront(nil)
    }

    func bringToFront(sessionName: String) {
        tabWindows[sessionName]?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Close All

    func closeAll() {
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

    func restoreState(threads: [MagentThread]) {
        guard let state = PersistenceService.shared.loadPopoutWindowState() else { return }

        for popout in state.threadPopouts {
            guard let thread = threads.first(where: { $0.id == popout.threadId }) else { continue }
            guard !thread.isMain else { continue }

            let controller = ThreadPopoutWindowController(thread: thread, sourceWindow: nil)
            threadWindows[thread.id] = controller

            let frame = NSRect(
                x: popout.windowFrame.x,
                y: popout.windowFrame.y,
                width: popout.windowFrame.width,
                height: popout.windowFrame.height
            )
            if isFrameVisibleOnCurrentScreens(frame) {
                controller.window?.setFrame(frame, display: true)
            }
            controller.window?.makeKeyAndOrderFront(nil)

            NotificationCenter.default.post(
                name: .magentThreadPoppedOut,
                object: nil,
                userInfo: ["threadId": thread.id]
            )
        }

        for popout in state.tabPopouts {
            guard let thread = threads.first(where: { $0.id == popout.threadId }) else { continue }
            guard thread.tmuxSessionNames.contains(popout.sessionName) else { continue }

            let controller = TabPopoutWindowController(
                sessionName: popout.sessionName,
                thread: thread,
                sourceWindow: nil
            )
            tabWindows[popout.sessionName] = controller

            let frame = NSRect(
                x: popout.windowFrame.x,
                y: popout.windowFrame.y,
                width: popout.windowFrame.width,
                height: popout.windowFrame.height
            )
            if isFrameVisibleOnCurrentScreens(frame) {
                controller.window?.setFrame(frame, display: true)
            }
            controller.window?.makeKeyAndOrderFront(nil)

            NotificationCenter.default.post(
                name: .magentTabDetached,
                object: nil,
                userInfo: ["sessionName": popout.sessionName, "threadId": thread.id]
            )
        }
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

        tabCloseObserver = NotificationCenter.default.addObserver(
            forName: .magentTabWillClose,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let sessionName = notification.userInfo?["sessionName"] as? String else { return }
            if self.tabWindows[sessionName] != nil {
                self.returnTabToThread(sessionName: sessionName)
            }
        }
    }

    // MARK: - Helpers

    private func isFrameVisibleOnCurrentScreens(_ frame: NSRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.visibleFrame.intersects(frame) {
                return true
            }
        }
        return false
    }
}
