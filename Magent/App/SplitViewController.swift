import Cocoa

final class SplitViewController: NSSplitViewController {

    private let threadListVC = ThreadListViewController()
    private let emptyStateVC = EmptyStateViewController()
    private var currentDetailVC: ThreadDetailViewController?

    override func viewDidLoad() {
        super.viewDidLoad()

        threadListVC.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: threadListVC)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(contentListWithViewController: emptyStateVC)
        addSplitViewItem(contentItem)

        splitView.dividerStyle = .thin
    }

    // MARK: - Keyboard Shortcuts

    override func viewDidAppear() {
        super.viewDidAppear()

        setupWindowToolbar()

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

    private func newTabShortcut() {
        currentDetailVC?.addTabFromKeyboard()
    }

    private func closeTabShortcut() {
        currentDetailVC?.closeCurrentTab()
    }

    private func showThread(_ thread: MagentThread) {
        // Skip if already showing this thread (preserves terminal scrollback)
        if currentDetailVC?.thread.id == thread.id { return }

        // Check if worktree exists on disk
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: thread.worktreePath, isDirectory: &isDir) && isDir.boolValue

        if exists {
            presentThread(thread)
        } else {
            recoverAndShowThread(thread)
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

    @objc private func settingsTapped() {
        let settingsVC = SettingsSplitViewController()
        presentAsSheet(settingsVC)
    }

    private func showEmptyState() {
        currentDetailVC = nil
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
        showThread(thread)
    }

    func threadList(_ controller: ThreadListViewController, didRenameThread thread: MagentThread) {
        // Keep old terminal tabs with "(renamed)" suffix and open a fresh agent tab
        // in the renamed worktree path.
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
            let button = NSButton(image: NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")!, target: self, action: #selector(settingsTapped))
            button.bezelStyle = .texturedRounded
            item.view = button
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
