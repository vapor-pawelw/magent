import Cocoa

final class SplitViewController: NSSplitViewController {

    private static let sidebarWidthDefaultsKey = "MagentSidebarWidth"
    private static let defaultSidebarWidth: CGFloat = 280

    private let threadListVC = ThreadListViewController()
    private let emptyStateVC = EmptyStateViewController()
    private var currentDetailVC: ThreadDetailViewController?
    private var settingsWindowController: NSWindowController?
    private var sidebarItem: NSSplitViewItem?
    private var didApplyInitialSidebarWidth = false

    override func viewDidLoad() {
        super.viewDidLoad()

        threadListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: threadListVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 420
        self.sidebarItem = sidebarItem
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(contentListWithViewController: emptyStateVC)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
        splitView.delegate = self
    }

    // MARK: - Keyboard Shortcuts

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

        let savedWidth = UserDefaults.standard.object(forKey: Self.sidebarWidthDefaultsKey) as? Double
        let targetWidth = CGFloat(savedWidth ?? Double(Self.defaultSidebarWidth))
        let clampedWidth = min(max(targetWidth, sidebarItem.minimumThickness), sidebarItem.maximumThickness)
        splitView.setPosition(clampedWidth, ofDividerAt: 0)
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sidebarItem else { return }
        let width = sidebarItem.viewController.view.frame.width
        guard width.isFinite, width > 0 else { return }
        UserDefaults.standard.set(Double(width), forKey: Self.sidebarWidthDefaultsKey)
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

        // Replace the content split view item
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }
        let contentItem = NSSplitViewItem(contentListWithViewController: detailVC)
        addSplitViewItem(contentItem)
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

    @objc private func settingsTapped() {
        if let existing = settingsWindowController?.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsVC = SettingsSplitViewController()
        let window = NSWindow(contentViewController: settingsVC)
        window.title = "Settings"
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
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }
        let contentItem = NSSplitViewItem(contentListWithViewController: emptyStateVC)
        addSplitViewItem(contentItem)
    }
}

// MARK: - ThreadListDelegate

extension SplitViewController: ThreadListDelegate {
    func threadList(_ controller: ThreadListViewController, didSelectThread thread: MagentThread) {
        ThreadManager.shared.setActiveThread(thread.id)
        showThread(thread)
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
        if itemIdentifier == Self.settingsToolbarItemId {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"
            item.toolTip = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.target = self
            item.action = #selector(settingsTapped)
            return item
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.settingsToolbarItemId]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.settingsToolbarItemId]
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
