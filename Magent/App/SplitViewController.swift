import Cocoa
import MagentCore

private final class SplitContentContainerViewController: NSViewController {
    fileprivate var currentChild: NSViewController?
    private var currentChildConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView()
    }

    func setContent(_ child: NSViewController) {
        if currentChild === child { return }

        if let currentChild {
            // Clean up views that live outside the VC's own hierarchy (e.g.
            // DiffImageOverlayView on window.contentView) before removing.
            (currentChild as? ThreadDetailViewController)?.cleanUpBeforeRemoval()
            NSLayoutConstraint.deactivate(currentChildConstraints)
            currentChildConstraints.removeAll()
            currentChild.view.removeFromSuperview()
            currentChild.removeFromParent()
        }

        addChild(child)
        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        currentChildConstraints = [
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(currentChildConstraints)

        currentChild = child
    }
}

final class SplitViewController: NSSplitViewController {

    private static let sidebarWidthDefaultsKey = "MagentSidebarWidth"
    private static let sidebarHiddenDefaultsKey = "MagentSidebarHidden"
    private static let defaultSidebarWidth: CGFloat = 280

    private let threadListVC = ThreadListViewController()
    private let emptyStateVC = EmptyStateViewController()
    private let contentContainerVC = SplitContentContainerViewController()
    private var currentDetailVC: ThreadDetailViewController?
    private var settingsWindowController: NSWindowController?
    private var sidebarItem: NSSplitViewItem?
    private var didApplyInitialSidebarWidth = false
    private var preferredSidebarWidth: CGFloat = defaultSidebarWidth
    private var enforcedSidebarWidth: CGFloat?
    private var isRestoringSidebarWidth = false
    private var isTogglingSidebarCollapse = false
    private var keyEventMonitor: Any?
    private var cachedKeyBindings: KeyBindingSettings = KeyBindingSettings()
    private weak var observedWindowForFocusNotifications: NSWindow?

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredSidebarWidth = resolvedSavedSidebarWidth()

        threadListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: threadListVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        // `sidebarWithViewController:` already configures `canCollapse = true`
        // as part of the sidebar behavior — no explicit assignment needed.
        // Seed the collapsed state from persistence before adding to the split view.
        // Setting `isCollapsed` directly (instead of via the animator) avoids any
        // launch-time animation while still being respected by NSSplitViewController.
        if UserDefaults.standard.bool(forKey: Self.sidebarHiddenDefaultsKey) {
            sidebarItem.isCollapsed = true
        }
        self.sidebarItem = sidebarItem
        addSplitViewItem(sidebarItem)

        contentContainerVC.setContent(emptyStateVC)
        let contentItem = NSSplitViewItem(contentListWithViewController: contentContainerVC)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
        splitView.delegate = self
    }

    // MARK: - Keyboard Shortcuts

    override func viewWillAppear() {
        super.viewWillAppear()
        applyInitialSidebarWidthIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        applyInitialSidebarWidthIfNeeded()
        setupWindowToolbar()
        installWindowFocusObserversIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsFromNotification),
            name: .magentOpenSettings,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNavigateToThread),
            name: .magentNavigateToThread,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenExternalLinkInApp(_:)),
            name: .magentOpenExternalLinkInApp,
            object: nil
        )

        reloadKeyBindings()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyBindingsDidChange),
            name: .magentKeyBindingsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThreadReturnedToMain(_:)),
            name: .magentThreadReturnedToMain,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThreadPoppedOut(_:)),
            name: .magentThreadPoppedOut,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePopOutThreadRequested(_:)),
            name: .magentPopOutThreadRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVisibleThreadCompletionDetected(_:)),
            name: .magentAgentCompletionDetected,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectVisibilityChanged(_:)),
            name: .magentProjectVisibilityDidChange,
            object: nil
        )
    }

    /// Forwarded from the main menu's "New Thread" item (⌘N).
    @objc func requestNewThread() {
        requestNewThread(contextThread: nil, presentingWindow: nil)
    }

    func requestNewThread(contextThread: MagentThread?, presentingWindow: NSWindow?) {
        threadListVC.requestNewThread(contextThread: contextThread, presentingWindow: presentingWindow)
    }

    /// Forwarded from the main menu's "New Thread from Branch" item (⌘⇧N).
    @objc func requestNewThreadFromBranch() {
        requestNewThreadFromBranch(contextThread: nil, presentingWindow: nil)
    }

    func requestNewThreadFromBranch(contextThread: MagentThread?, presentingWindow: NSWindow?) {
        threadListVC.requestNewThreadFromBranch(contextThread: contextThread, presentingWindow: presentingWindow)
    }

    /// Forwarded from the main menu's "AI Rename" item (⌘⇧R).
    @objc func requestAIRename() {
        requestAIRename(contextThread: nil, presentingWindow: nil)
    }

    func requestAIRename(contextThread: MagentThread?, presentingWindow: NSWindow?) {
        guard let thread = contextThread ?? threadListVC.selectedThreadFromState(),
              !thread.isMain else {
            NSSound.beep()
            return
        }
        threadListVC.presentAIRenameSheet(for: thread, presentingWindow: presentingWindow)
    }

    // MARK: - Key Bindings

    @objc private func keyBindingsDidChange() {
        reloadKeyBindings()
    }

    private func reloadKeyBindings() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        cachedKeyBindings = PersistenceService.shared.loadSettings().keyBindings

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Skip if event targets a pop-out window — let the pop-out handle its own shortcuts
        if let eventWindow = event.window,
           PopoutWindowManager.shared.isPopoutWindow(eventWindow) {
            return event
        }

        let eventModifiers = KeyModifiers.from(event.modifierFlags.intersection(.deviceIndependentFlagsMask))

        if matchesBinding(.newTab, keyCode: event.keyCode, modifiers: eventModifiers) {
            newTabShortcut()
            return nil
        }
        if matchesBinding(.closeTab, keyCode: event.keyCode, modifiers: eventModifiers) {
            closeTabShortcut()
            return nil
        }
        if matchesBinding(.newThreadFromBranch, keyCode: event.keyCode, modifiers: eventModifiers) {
            requestNewThreadFromBranch()
            return nil
        }
        if matchesBinding(.newThread, keyCode: event.keyCode, modifiers: eventModifiers) {
            requestNewThread()
            return nil
        }
        if matchesBinding(.popOutThread, keyCode: event.keyCode, modifiers: eventModifiers) {
            popOutCurrentThread()
            return nil
        }
        if matchesBinding(.detachTab, keyCode: event.keyCode, modifiers: eventModifiers) {
            let settings = PersistenceService.shared.loadSettings()
            guard settings.isTabDetachFeatureEnabled else { return nil }
            _ = performDetachTabShortcut(contextThreadId: nil)
            return nil
        }
        if matchesBinding(.toggleSidebar, keyCode: event.keyCode, modifiers: eventModifiers) {
            // Key-repeat would otherwise flicker the sidebar — swallow repeats.
            guard !event.isARepeat else { return nil }
            toggleSidebar(nil)
            return nil
        }

        return event
    }

    private func matchesBinding(_ action: KeyBindingAction, keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        let binding = cachedKeyBindings.binding(for: action)
        return binding.keyCode == keyCode && binding.modifiers == modifiers
    }

    // MARK: - Sidebar Visibility

    /// Toggle the sidebar with animation and persist the new state.
    /// Routed through `toggleSidebar(_:)` so that menu items using the standard
    /// `toggleSidebar:` first-responder action get AppKit's automatic
    /// "Hide Sidebar" / "Show Sidebar" title swap for free.
    override func toggleSidebar(_ sender: Any?) {
        beginSidebarCollapseAnimationGuard()
        super.toggleSidebar(sender)
        persistSidebarHiddenState()
    }

    /// Reveal the sidebar if hidden, used by user actions that focus a
    /// thread (status bar popovers, top info strip click, navigate-to-thread
    /// notifications, restore archived). No-op if already visible.
    func revealSidebarIfHidden() {
        guard let sidebarItem, sidebarItem.isCollapsed else { return }
        beginSidebarCollapseAnimationGuard()
        sidebarItem.animator().isCollapsed = false
        persistSidebarHiddenState()
    }

    private func persistSidebarHiddenState() {
        guard let sidebarItem else { return }
        UserDefaults.standard.set(sidebarItem.isCollapsed, forKey: Self.sidebarHiddenDefaultsKey)
    }

    /// Suppress the preferred-width snap-back path in
    /// `splitViewDidResizeSubviews` while NSSplitViewController's collapse /
    /// expand animation is running. Intermediate frames have width values
    /// between 0 and `preferredSidebarWidth`; without this guard, the
    /// restore branch would call `setPosition(preferredSidebarWidth, 0)`
    /// every frame and fight the animator.
    private func beginSidebarCollapseAnimationGuard() {
        isTogglingSidebarCollapse = true
        // NSSplitViewController's collapse animation settles in ~0.25s.
        // A short margin covers settle frames and any layout side effects.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.isTogglingSidebarCollapse = false
        }
    }

    private func applyInitialSidebarWidthIfNeeded() {
        guard !didApplyInitialSidebarWidth else { return }
        guard let sidebarItem else { return }
        guard splitViewItems.count >= 2 else { return }

        didApplyInitialSidebarWidth = true

        let clampedWidth = resolvedSavedSidebarWidth()
        preferredSidebarWidth = clampedWidth
        // Skip setPosition while collapsed — it would fight the persisted hidden
        // state by snapping the divider to a non-zero position and effectively
        // re-expanding the sidebar at launch.
        if !sidebarItem.isCollapsed {
            splitView.setPosition(clampedWidth, ofDividerAt: 0)
        }
        threadListVC.refreshSidebarLayout(forceColumnRefit: true)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        threadListVC.refreshSidebarLayout(forceColumnRefit: true)
        guard !isRestoringSidebarWidth else { return }
        // During the collapse/expand animation, intermediate frames carry
        // widths between 0 and `preferredSidebarWidth`. Skip the preferred-
        // width restoration path so we don't snap-back every frame.
        guard !isTogglingSidebarCollapse else { return }
        guard let sidebarItem else { return }
        let width = sidebarItem.viewController.view.frame.width
        guard width.isFinite, width > 0 else { return }
        let clampedWidth = min(max(width, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
        let deltaFromPreferred = abs(clampedWidth - preferredSidebarWidth)

        if let enforcedSidebarWidth {
            if abs(clampedWidth - enforcedSidebarWidth) > 0.5 {
                restoreSidebarWidth(enforcedSidebarWidth)
            }
            return
        }
        let isUserDrivenResize = splitView.inLiveResize || isMouseDrivenResizeEvent()
        if isUserDrivenResize {
            preferredSidebarWidth = clampedWidth
            UserDefaults.standard.set(Double(clampedWidth), forKey: Self.sidebarWidthDefaultsKey)
            return
        }

        // Ignore spontaneous width shifts caused by internal layout changes
        // (for example when sidebar content updates after thread selection).
        // Sidebar width should only change via user divider drags.
        if deltaFromPreferred > 0.1 {
            restoreSidebarWidth(preferredSidebarWidth)
        }
    }

    private func isMouseDrivenResizeEvent() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return true
        default:
            return false
        }
    }

    private func newTabShortcut() {
        _ = performNewTabShortcut(contextThreadId: nil)
    }

    private func closeTabShortcut() {
        _ = performCloseTabShortcut(contextThreadId: nil)
    }

    func selectedThreadForContextRouting() -> MagentThread? {
        currentDetailVC?.thread ?? threadListVC.selectedThreadFromState()
    }

    @discardableResult
    func performNewTabShortcut(contextThreadId: UUID?) -> Bool {
        if let threadId = contextThreadId {
            if let controller = PopoutWindowManager.shared.threadWindows[threadId] {
                controller.detailVC.addTabFromKeyboard()
                return true
            }
            if let currentDetailVC, currentDetailVC.thread.id == threadId {
                currentDetailVC.addTabFromKeyboard()
                return true
            }
            if !PopoutWindowManager.shared.isThreadPoppedOut(threadId),
               ThreadManager.shared.threads.contains(where: { $0.id == threadId }) {
                threadListVC.selectThread(byId: threadId)
                if let currentDetailVC, currentDetailVC.thread.id == threadId {
                    currentDetailVC.addTabFromKeyboard()
                    return true
                }
            }
            return false
        }

        guard let currentDetailVC else { return false }
        currentDetailVC.addTabFromKeyboard()
        return true
    }

    @discardableResult
    func performCloseTabShortcut(contextThreadId: UUID?) -> Bool {
        if let threadId = contextThreadId {
            if let controller = PopoutWindowManager.shared.threadWindows[threadId] {
                controller.detailVC.closeCurrentTab()
                return true
            }
            if let currentDetailVC, currentDetailVC.thread.id == threadId {
                currentDetailVC.closeCurrentTab()
                return true
            }
            return false
        }

        guard let currentDetailVC else { return false }
        currentDetailVC.closeCurrentTab()
        return true
    }

    @discardableResult
    func performDetachTabShortcut(contextThreadId: UUID?) -> Bool {
        let settings = PersistenceService.shared.loadSettings()
        guard settings.isTabDetachFeatureEnabled else { return false }

        if let threadId = contextThreadId {
            if let controller = PopoutWindowManager.shared.threadWindows[threadId] {
                controller.detailVC.detachCurrentTabFromKeyboard()
                return true
            }
            if let currentDetailVC, currentDetailVC.thread.id == threadId {
                currentDetailVC.detachCurrentTabFromKeyboard()
                return true
            }
            return false
        }

        guard let currentDetailVC else { return false }
        currentDetailVC.detachCurrentTabFromKeyboard()
        return true
    }

    private func showThread(_ thread: MagentThread) {
        Task {
            // Keep thread switching from immediately killing sessions that only look
            // stale because metadata or UI state is still catching up.
            _ = await ThreadManager.shared.cleanupStaleMagentSessions(minimumStaleAge: 30)
        }

        // Sidebar items can be stale snapshots; always resolve the latest thread model.
        let resolvedThread = ThreadManager.shared.threads.first(where: { $0.id == thread.id }) ?? thread

        // Refresh statuses for the thread being deselected (so its row updates while we view another)
        if let previousId = currentDetailVC?.thread.id, previousId != resolvedThread.id,
           let previousThread = ThreadManager.shared.threads.first(where: { $0.id == previousId }) {
            ThreadManager.shared.refreshJiraTicketForSelectedThread(previousThread)
            ThreadManager.shared.refreshPRForSelectedThread(previousThread)
        }

        // Refresh Jira ticket title/status and PR status in the background
        ThreadManager.shared.refreshJiraTicketForSelectedThread(resolvedThread)
        ThreadManager.shared.refreshPRForSelectedThread(resolvedThread)

        // Skip if already showing this thread (preserves terminal scrollback)
        if currentDetailVC?.thread.id == resolvedThread.id { return }

        // Pending threads have no worktree yet — show directly so the detail view
        // can display the creation progress overlay while setup completes in background.
        if ThreadManager.shared.pendingThreadIds.contains(resolvedThread.id) {
            presentThread(resolvedThread)
            return
        }

        // Check if worktree exists on disk
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedThread.worktreePath, isDirectory: &isDir) && isDir.boolValue

        if exists {
            presentThread(resolvedThread)
        } else {
            recoverAndShowThread(resolvedThread)
        }
    }

    private func installWindowFocusObserversIfNeeded() {
        guard let window = view.window, observedWindowForFocusNotifications !== window else { return }
        if let previousWindow = observedWindowForFocusNotifications {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: previousWindow
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMainWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        observedWindowForFocusNotifications = window
    }

    private func focusedThreadIdForCompletionRead() -> UUID? {
        if let detailVC = currentDetailVC {
            return detailVC.thread.id
        }
        if contentContainerVC.currentChild is DetachedThreadPlaceholderView {
            return ThreadManager.shared.activeThreadId
        }
        return nil
    }

    private func markFocusedThreadCompletionSeenIfNeeded() {
        guard view.window?.isKeyWindow == true,
              let threadId = focusedThreadIdForCompletionRead() else { return }
        ThreadManager.shared.markThreadCompletionSeen(threadId: threadId)
    }

    private func presentThread(_ thread: MagentThread) {
        currentDetailVC?.cacheTerminalViewsForReuse()
        let detailVC = ThreadDetailViewController(thread: thread)
        currentDetailVC = detailVC

        preserveSidebarWidthDuringContentChange {
            contentContainerVC.setContent(detailVC)
        }

        if AppFeatures.jiraSyncEnabled, thread.jiraUnassigned {
            BannerManager.shared.show(
                message: "This ticket is no longer assigned to you",
                style: .info,
                duration: 5.0
            )
        }
    }

    private func recoverAndShowThread(_ thread: MagentThread) {
        if thread.isMain {
            BannerManager.shared.show(
                message: "Repository not found at \(thread.worktreePath)",
                style: .error,
                duration: nil,
                isDismissible: true
            )
            return
        }

        BannerManager.shared.show(
            message: "Recreating worktree for '\(thread.name)'...",
            style: .info,
            duration: nil,
            isDismissible: false
        )

        Task {
            let result = await ThreadManager.shared.recoverWorktree(for: thread)
            await MainActor.run {
                switch result {
                case .recovered:
                    BannerManager.shared.show(
                        message: "Worktree '\(thread.name)' recovered successfully",
                        style: .info,
                        duration: 3.0
                    )
                    // Fetch updated thread from manager
                    if let updated = ThreadManager.shared.threads.first(where: { $0.id == thread.id }) {
                        presentThread(updated)
                    } else {
                        presentThread(thread)
                    }
                case .mainThreadMissing:
                    BannerManager.shared.show(
                        message: "Repository not found — cannot recover worktree",
                        style: .error,
                        duration: 5.0
                    )
                case .projectNotFound:
                    BannerManager.shared.show(
                        message: "Project no longer exists — cannot recover worktree",
                        style: .error,
                        duration: 5.0
                    )
                case .failed(let error):
                    BannerManager.shared.show(
                        message: "Failed to recover worktree: \(error.localizedDescription)",
                        style: .error,
                        duration: 5.0
                    )
                }
            }
        }
    }

    private static let settingsToolbarItemId = NSToolbarItem.Identifier("settings")
    private static let recentlyArchivedToolbarItemId = NSToolbarItem.Identifier("recentlyArchived")

    private var recentlyArchivedPopover: NSPopover?

    private func setupWindowToolbar() {
        guard let window = view.window, window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "MagentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        settingsTapped()
    }

    @objc private func handleNavigateToThread(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        let sessionName = notification.userInfo?["sessionName"] as? String
        let centerInSidebar = notification.userInfo?["centerInSidebar"] as? Bool ?? false
        let alreadyShowing = currentDetailVC?.thread.id == threadId

        // Pre-seed UserDefaults so a newly-created ThreadDetailViewController
        // opens on the correct tab during its async setup.
        if let sessionName {
            UserDefaults.standard.set(threadId.uuidString, forKey: "MagentLastOpenedThreadID")
            UserDefaults.standard.set(sessionName, forKey: "MagentLastOpenedSessionName")
        }

        // User-driven navigation should reveal the sidebar so the focused row
        // is visible. This is opt-in: posters must set
        // `userInfo["revealSidebarIfHidden"] == true` to trigger the reveal.
        // Programmatic posters (restore flows, background reconcile, etc.)
        // leave the flag off and will not silently un-hide the sidebar.
        // Closing pop-outs deliberately does not post this notification at all.
        if notification.userInfo?["revealSidebarIfHidden"] as? Bool == true {
            revealSidebarIfHidden()
        }

        // Select the thread in the sidebar (creates ThreadDetailViewController if needed)
        threadListVC.selectThread(byId: threadId, scrollRowToVisible: !centerInSidebar)
        if centerInSidebar {
            threadListVC.centerAndPulseThreadRow(byId: threadId)
        }

        // If the thread was already showing, tabs are set up — select directly
        if alreadyShowing, let sessionName, let detailVC = currentDetailVC {
            if let tabIndex = detailVC.displayIndex(forSession: sessionName) {
                detailVC.selectTab(at: tabIndex)
            }
        }

        markFocusedThreadCompletionSeenIfNeeded()
    }

    @objc private func handleMainWindowDidBecomeKey(_ notification: Notification) {
        currentDetailVC?.currentTerminalView()?.markAsActiveSurface()
        markFocusedThreadCompletionSeenIfNeeded()
    }

    @objc private func handleVisibleThreadCompletionDetected(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == focusedThreadIdForCompletionRead(),
              view.window?.isKeyWindow == true else { return }
        ThreadManager.shared.markThreadCompletionSeen(threadId: threadId)
    }

    @objc private func handleOpenExternalLinkInApp(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              let url = userInfo["url"] as? URL,
              let identifier = userInfo["identifier"] as? String,
              let title = userInfo["title"] as? String,
              let iconRawValue = userInfo["iconType"] as? String,
              let iconType = WebTabIconType(rawValue: iconRawValue) else { return }

        let openTab = { [weak self] in
            guard let self,
                  let detailVC = self.currentDetailVC,
                  detailVC.thread.id == threadId else { return }
            detailVC.loadViewIfNeeded()
            detailVC.openWebTab(url: url, identifier: identifier, title: title, iconType: iconType)
        }

        if currentDetailVC?.thread.id == threadId {
            openTab()
            return
        }

        threadListVC.selectThread(byId: threadId)
        DispatchQueue.main.async {
            openTab()
        }
    }

    @objc private func handleProjectVisibilityChanged(_ notification: Notification) {
        guard let projectId = notification.userInfo?["projectId"] as? UUID,
              let isHidden = notification.userInfo?["isHidden"] as? Bool,
              isHidden else { return }

        let selectedInHiddenProject = threadListVC.selectedThreadFromState()?.projectId == projectId
        let hadProjectPopouts = PopoutWindowManager.shared.closePopouts(forProjectId: projectId)
        guard selectedInHiddenProject || hadProjectPopouts else { return }

        threadListVC.selectFirstAvailableThread()
        if threadListVC.selectedThreadFromState() == nil {
            showEmptyState()
        }
    }

    @objc private func recentlyArchivedTapped(_ sender: NSButton) {
        if let existing = recentlyArchivedPopover, existing.isShown {
            existing.close()
            return
        }

        let popover = NSPopover()
        popover.contentViewController = RecentlyArchivedPopoverViewController()
        popover.behavior = .transient
        popover.animates = true
        recentlyArchivedPopover = popover

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func settingsTapped() {
        if let existing = settingsWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsVC = SettingsSplitViewController()
        let window = NSWindow(contentViewController: settingsVC)
        window.title = String(localized: .AppStrings.settingsWindowTitle)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: 700, height: 500)
        window.center()
        window.delegate = self

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showEmptyState(skipTerminalCache: Bool = false) {
        if !skipTerminalCache {
            currentDetailVC?.cacheTerminalViewsForReuse()
        }
        currentDetailVC = nil
        ThreadManager.shared.setActiveThread(nil)
        preserveSidebarWidthDuringContentChange {
            contentContainerVC.setContent(emptyStateVC)
        }
    }

    // MARK: - Pop-out Windows

    private func presentDetachedThreadPlaceholder(_ thread: MagentThread) {
        currentDetailVC?.cacheTerminalViewsForReuse()
        currentDetailVC = nil
        let placeholder = DetachedThreadPlaceholderView(thread: thread)
        placeholder.onShowWindow = { PopoutWindowManager.shared.bringToFront(threadId: thread.id) }
        placeholder.onReturnToMain = {
            PopoutWindowManager.shared.returnThreadToMain(thread.id)
        }
        preserveSidebarWidthDuringContentChange {
            contentContainerVC.setContent(placeholder)
        }
    }

    func popOutCurrentThread() {
        guard let detailVC = currentDetailVC else { return }
        let thread = detailVC.thread
        guard !thread.isMain else { return }
        guard !ThreadManager.shared.pendingThreadIds.contains(thread.id) else { return }

        detailVC.cacheTerminalViewsForReuse()
        currentDetailVC = nil
        PopoutWindowManager.shared.popOutThread(thread, from: view.window)
        selectFallbackMainThread(afterPoppingOut: thread.id)
        threadListVC.refreshThreadRowInPlace(threadId: thread.id)
    }

    @objc private func handleThreadReturnedToMain(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        if threadListVC.diffInspectionThreadID == threadId {
            threadListVC.setDiffInspectionContextToSelectedThread()
            focusMainWindowAndCurrentThread()
        }
        threadListVC.refreshThreadRowInPlace(threadId: threadId)
    }

    @objc private func handleThreadPoppedOut(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        if threadListVC.selectedThreadID == threadId {
            selectFallbackMainThread(afterPoppingOut: threadId)
        }
        threadListVC.refreshThreadRowInPlace(threadId: threadId)
    }

    @objc private func handlePopOutThreadRequested(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID else { return }
        // Only replace the main content with the detached placeholder when the
        // currently active thread is the one being popped out.
        if let detailVC = currentDetailVC, detailVC.thread.id == threadId {
            popOutCurrentThread()
        } else if let thread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) {
            PopoutWindowManager.shared.popOutThread(thread, from: view.window)
            if threadListVC.selectedThreadID == threadId {
                selectFallbackMainThread(afterPoppingOut: threadId)
            }
            threadListVC.refreshThreadRowInPlace(threadId: thread.id)
        }
    }

    private func selectFallbackMainThread(afterPoppingOut threadId: UUID) {
        let fallback = ThreadManager.shared.threads.first { thread in
            thread.id != threadId && !PopoutWindowManager.shared.isThreadPoppedOut(thread.id)
        }
        guard let fallback else {
            showEmptyState()
            return
        }
        // Fallback selection happens as a side-effect of pop-out (including drop-to-replace
        // and move-between-popouts). The user's scroll position in the sidebar should not
        // jump to wherever the fallback row happens to live.
        threadListVC.selectThread(byId: fallback.id, scrollRowToVisible: false)
    }

    private func focusMainWindowAndCurrentThread() {
        NSApp.activate(ignoringOtherApps: true)
        view.window?.makeKeyAndOrderFront(nil)
        currentDetailVC?.focusCurrentTabForNavigation()
    }

    private func preserveSidebarWidthDuringContentChange(_ change: () -> Void) {
        let preservedWidth = currentSidebarWidth() ?? preferredSidebarWidth
        enforcedSidebarWidth = preservedWidth
        change()
        restoreSidebarWidth(preservedWidth)
        DispatchQueue.main.async { [weak self] in
            self?.restoreSidebarWidth(preservedWidth)
            DispatchQueue.main.async { [weak self] in
                if self?.enforcedSidebarWidth == preservedWidth {
                    self?.enforcedSidebarWidth = nil
                }
            }
        }
    }

    private func currentSidebarWidth() -> CGFloat? {
        guard let sidebarItem else { return nil }
        let width = sidebarItem.viewController.view.frame.width
        guard width.isFinite, width > 0 else { return nil }
        return min(max(width, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
    }

    private func resolvedSavedSidebarWidth() -> CGFloat {
        guard let sidebarItem else { return Self.defaultSidebarWidth }
        let savedWidth = UserDefaults.standard.object(forKey: Self.sidebarWidthDefaultsKey) as? Double
        let targetWidth = CGFloat(savedWidth ?? Double(Self.defaultSidebarWidth))
        return min(max(targetWidth, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
    }

    private func restoreSidebarWidth(_ width: CGFloat?) {
        guard let width else { return }
        guard let sidebarItem else { return }
        guard splitViewItems.count >= 2 else { return }
        let clampedWidth = min(max(width, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
        if let currentWidth = currentSidebarWidth(), abs(currentWidth - clampedWidth) <= 0.5 {
            preferredSidebarWidth = clampedWidth
            return
        }

        preferredSidebarWidth = clampedWidth
        isRestoringSidebarWidth = true
        defer { isRestoringSidebarWidth = false }
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(clampedWidth, ofDividerAt: 0)
        threadListVC.refreshSidebarLayout(forceColumnRefit: true)
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, let enforcedSidebarWidth else {
            return proposedPosition
        }
        return enforcedSidebarWidth
    }
}

// MARK: - ThreadListDelegate

extension SplitViewController: ThreadListDelegate {
    func threadList(_ controller: ThreadListViewController, didSelectThread thread: MagentThread) {
        if PopoutWindowManager.shared.isThreadPoppedOut(thread.id) {
            PopoutWindowManager.shared.bringToFront(threadId: thread.id)
            threadListVC.setDiffInspectionContext(threadId: thread.id, isPopoutContext: true)
            threadListVC.centerAndPulseThreadRow(byId: thread.id)
            return
        }
        ThreadManager.shared.setActiveThread(thread.id)
        showThread(thread)
        currentDetailVC?.focusCurrentTabForNavigation()
        markFocusedThreadCompletionSeenIfNeeded()
        threadListVC.refreshDiffPanelForSelectedThread()
    }

    func threadList(_ controller: ThreadListViewController, didRenameThread thread: MagentThread) {
        // Update thread reference and rebind onCopy closures to new tmux session names.
        // Existing terminal connections survive rename since tmux rename-session keeps clients attached.
        guard currentDetailVC?.thread.id == thread.id else { return }
        currentDetailVC?.handleRename(thread)
    }

    func threadList(_ controller: ThreadListViewController, didArchiveThread thread: MagentThread) {
        if currentDetailVC?.thread.id == thread.id {
            showEmptyState(skipTerminalCache: true)
        }
    }

    func threadList(_ controller: ThreadListViewController, didDeleteThread thread: MagentThread) {
        if currentDetailVC?.thread.id == thread.id {
            showEmptyState(skipTerminalCache: true)
        }
    }

    func threadListDidRequestSettings(_ controller: ThreadListViewController) {
        settingsTapped()
    }
}

// MARK: - NSToolbarDelegate

extension SplitViewController: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == Self.recentlyArchivedToolbarItemId {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let title = "Recently Archived"
            item.label = title
            item.toolTip = title
            let button = NSButton()
            button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: title)
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = #selector(recentlyArchivedTapped(_:))
            button.isBordered = false
            item.view = button
            return item
        }
        if itemIdentifier == Self.settingsToolbarItemId {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let settingsTitle = String(localized: .CommonStrings.commonSettings)
            item.label = settingsTitle
            item.toolTip = settingsTitle
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: settingsTitle)
            item.target = self
            item.action = #selector(settingsTapped)
            return item
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.recentlyArchivedToolbarItemId, Self.settingsToolbarItemId]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.recentlyArchivedToolbarItemId, Self.settingsToolbarItemId]
    }
}

extension SplitViewController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow == settingsWindowController?.window {
            settingsWindowController = nil
        }
    }
}
