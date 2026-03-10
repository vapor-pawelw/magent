import Cocoa
import MagentCore

private final class SplitContentContainerViewController: NSViewController {
    private var currentChild: NSViewController?
    private var currentChildConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView()
    }

    func setContent(_ child: NSViewController) {
        if currentChild === child { return }

        if let currentChild {
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

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredSidebarWidth = resolvedSavedSidebarWidth()

        threadListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: threadListVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
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

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers {
            case "n":
                self.threadListVC.requestNewThread()
                return nil
            case "t":
                self.newTabShortcut()
                return nil
            case "w":
                self.closeTabShortcut()
                return nil
            default:
                return event
            }
        }
    }

    private func applyInitialSidebarWidthIfNeeded() {
        guard !didApplyInitialSidebarWidth else { return }
        guard let sidebarItem else { return }
        guard splitViewItems.count >= 2 else { return }

        didApplyInitialSidebarWidth = true

        // If the sidebar was persisted as collapsed, force it visible so thread list
        // state is always discoverable after relaunch.
        if sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
        }

        let clampedWidth = resolvedSavedSidebarWidth()
        preferredSidebarWidth = clampedWidth
        splitView.setPosition(clampedWidth, ofDividerAt: 0)
        threadListVC.refreshSidebarLayout(forceColumnRefit: true)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        threadListVC.refreshSidebarLayout(forceColumnRefit: true)
        guard !isRestoringSidebarWidth else { return }
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
        currentDetailVC?.addTabFromKeyboard()
    }

    private func closeTabShortcut() {
        currentDetailVC?.closeCurrentTab()
    }

    private func showThread(_ thread: MagentThread) {
        Task { await ThreadManager.shared.cleanupStaleMagentSessions() }

        // Sidebar items can be stale snapshots; always resolve the latest thread model.
        let resolvedThread = ThreadManager.shared.threads.first(where: { $0.id == thread.id }) ?? thread

        // Skip if already showing this thread (preserves terminal scrollback)
        if currentDetailVC?.thread.id == resolvedThread.id { return }

        // Check if worktree exists on disk
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedThread.worktreePath, isDirectory: &isDir) && isDir.boolValue

        if exists {
            presentThread(resolvedThread)
        } else {
            recoverAndShowThread(resolvedThread)
        }
    }

    private func presentThread(_ thread: MagentThread) {
        let detailVC = ThreadDetailViewController(thread: thread)
        currentDetailVC = detailVC

        preserveSidebarWidthDuringContentChange {
            contentContainerVC.setContent(detailVC)
        }

        if AppFeatures.jiraIntegrationEnabled, thread.jiraUnassigned {
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
        let alreadyShowing = currentDetailVC?.thread.id == threadId

        // Pre-seed UserDefaults so a newly-created ThreadDetailViewController
        // opens on the correct tab during its async setup.
        if let sessionName {
            UserDefaults.standard.set(threadId.uuidString, forKey: "MagentLastOpenedThreadID")
            UserDefaults.standard.set(sessionName, forKey: "MagentLastOpenedSessionName")
        }

        // Select the thread in the sidebar (creates ThreadDetailViewController if needed)
        threadListVC.selectThread(byId: threadId)

        // If the thread was already showing, tabs are set up — select directly
        if alreadyShowing, let sessionName, let detailVC = currentDetailVC {
            if let tabIndex = detailVC.thread.tmuxSessionNames.firstIndex(of: sessionName) {
                detailVC.selectTab(at: tabIndex)
            }
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

    private func showEmptyState() {
        currentDetailVC = nil
        ThreadManager.shared.setActiveThread(nil)
        preserveSidebarWidthDuringContentChange {
            contentContainerVC.setContent(emptyStateVC)
        }
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
        ThreadManager.shared.setActiveThread(thread.id)
        showThread(thread)
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
            showEmptyState()
        }
    }

    func threadList(_ controller: ThreadListViewController, didDeleteThread thread: MagentThread) {
        if currentDetailVC?.thread.id == thread.id {
            showEmptyState()
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
