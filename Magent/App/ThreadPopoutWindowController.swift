import Cocoa
import MagentCore

@MainActor
final class ThreadPopoutWindowController: NSWindowController, NSWindowDelegate {
    let threadId: UUID
    let detailVC: ThreadDetailViewController
    private let infoStrip: PopoutInfoStripView
    private var keyEventMonitor: Any?

    /// Set to true when `PopoutWindowManager.returnThreadToMain` is driving the close,
    /// so `windowWillClose` does not re-enter the return flow.
    var isReturningToMain = false

    init(thread: MagentThread, sourceWindow: NSWindow?) {
        self.threadId = thread.id
        self.infoStrip = PopoutInfoStripView()
        self.detailVC = ThreadDetailViewController(thread: thread)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 600, height: 400)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = Self.windowTitle(for: thread)

        super.init(window: window)
        window.delegate = self

        setupViewHierarchy()
        setupKeyEventMonitor()
        setupNotificationObservers()

        // Position relative to source window if available
        if let sourceFrame = sourceWindow?.frame {
            let newOrigin = NSPoint(
                x: sourceFrame.origin.x + 40,
                y: sourceFrame.origin.y - 40
            )
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func tearDown() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View Hierarchy

    private func setupViewHierarchy() {
        guard let window else { return }

        let rootView = NSView()
        rootView.wantsLayer = true

        infoStrip.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(infoStrip)

        let detailView = detailVC.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(detailView)

        NSLayoutConstraint.activate([
            infoStrip.topAnchor.constraint(equalTo: rootView.topAnchor),
            infoStrip.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            infoStrip.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            infoStrip.heightAnchor.constraint(equalToConstant: 48),

            detailView.topAnchor.constraint(equalTo: infoStrip.bottomAnchor),
            detailView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        window.contentView = rootView

        // Refresh info strip with current thread state
        if let latestThread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) {
            infoStrip.refresh(from: latestThread)
        }
    }

    // MARK: - Key Event Monitor

    private func setupKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window else { return event }
            return self.handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let settings = PersistenceService.shared.loadSettings()
        let bindings = settings.keyBindings

        // Cmd+Shift+O in pop-out → return thread to main (toggle)
        let popOutBinding = bindings.binding(for: .popOutThread)
        if event.keyCode == popOutBinding.keyCode
            && flags == popOutBinding.modifiers.nsEventFlags {
            PopoutWindowManager.shared.returnThreadToMain(threadId)
            return nil
        }

        // Cmd+Shift+D → detach current tab
        let detachBinding = bindings.binding(for: .detachTab)
        if event.keyCode == detachBinding.keyCode
            && flags == detachBinding.modifiers.nsEventFlags {
            detailVC.detachCurrentTabFromKeyboard()
            return nil
        }

        // Cmd+T → new tab in this thread
        let newTabBinding = bindings.binding(for: .newTab)
        if event.keyCode == newTabBinding.keyCode
            && flags == newTabBinding.modifiers.nsEventFlags {
            detailVC.addTabFromKeyboard()
            return nil
        }

        // Cmd+W → close current tab
        let closeTabBinding = bindings.binding(for: .closeTab)
        if event.keyCode == closeTabBinding.keyCode
            && flags == closeTabBinding.modifiers.nsEventFlags {
            detailVC.closeCurrentTab()
            return nil
        }

        return event
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        let nc = NotificationCenter.default

        for name: Notification.Name in [
            .magentAgentBusySessionsChanged,
            .magentAgentRateLimitChanged,
            .magentAgentCompletionDetected,
            .magentAgentWaitingForInput,
            .magentStatusSyncCompleted,
            .magentSettingsDidChange,
        ] {
            nc.addObserver(self, selector: #selector(refreshInfoStrip), name: name, object: nil)
        }

        nc.addObserver(
            self,
            selector: #selector(handleNavigateToThread(_:)),
            name: .magentNavigateToThread,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handleArchivedThreadsChanged),
            name: .magentArchivedThreadsDidChange,
            object: nil
        )

        // Forward tab-returned notifications to detailVC so it can restore
        // tabs that were detached from this pop-out window.
        nc.addObserver(
            self,
            selector: #selector(handleTabReturnedToThread(_:)),
            name: .magentTabReturnedToThread,
            object: nil
        )
    }

    @objc private func refreshInfoStrip() {
        guard let latestThread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) else { return }
        infoStrip.refresh(from: latestThread)
        window?.title = Self.windowTitle(for: latestThread)
    }

    @objc private func handleNavigateToThread(_ notification: Notification) {
        guard let navigateId = notification.userInfo?["threadId"] as? UUID,
              navigateId == threadId else { return }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleTabReturnedToThread(_ notification: Notification) {
        guard let sessionName = notification.userInfo?["sessionName"] as? String,
              let returnedThreadId = notification.userInfo?["threadId"] as? UUID,
              returnedThreadId == threadId else { return }
        detailVC.returnDetachedTab(sessionName: sessionName)
    }

    @objc private func handleArchivedThreadsChanged() {
        let exists = ThreadManager.shared.threads.contains(where: { $0.id == threadId })
        if !exists {
            PopoutWindowManager.shared.returnThreadToMain(threadId)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isReturningToMain else { return }
        // User closed the window directly — return thread to main
        PopoutWindowManager.shared.returnThreadToMain(threadId)
    }

    // MARK: - Helpers

    private static func windowTitle(for thread: MagentThread) -> String {
        let name = thread.taskDescription ?? thread.name
        let branch = thread.currentBranch
        if !branch.isEmpty {
            return "\(name) — \(branch)"
        }
        return name
    }
}

// MARK: - KeyModifiers → NSEvent.ModifierFlags

extension KeyModifiers {
    var nsEventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}
