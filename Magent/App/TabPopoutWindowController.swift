import Cocoa
import GhosttyBridge
import MagentCore

@MainActor
final class TabPopoutWindowController: NSWindowController, NSWindowDelegate {
    let sessionName: String
    let threadId: UUID
    private var terminalView: TerminalSurfaceView?
    private let infoStrip: PopoutInfoStripView

    /// Set to true when `PopoutWindowManager.returnTabToThread` is driving the close,
    /// so `windowWillClose` does not re-enter the return flow.
    var isReturningToThread = false

    init(sessionName: String, thread: MagentThread, sourceWindow: NSWindow?) {
        self.sessionName = sessionName
        self.threadId = thread.id
        self.infoStrip = PopoutInfoStripView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 500, height: 300)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = Self.windowTitle(for: thread, sessionName: sessionName)

        super.init(window: window)
        window.delegate = self

        setupViewHierarchy(thread: thread, sessionName: sessionName)
        setupNotificationObservers()

        if let sourceFrame = sourceWindow?.frame {
            let newOrigin = NSPoint(
                x: sourceFrame.origin.x + 60,
                y: sourceFrame.origin.y - 60
            )
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View Hierarchy

    private func setupViewHierarchy(thread: MagentThread, sessionName: String) {
        guard let window else { return }

        let rootView = NSView()
        rootView.wantsLayer = true

        infoStrip.translatesAutoresizingMaskIntoConstraints = false
        infoStrip.configureForTab(thread: thread, sessionName: sessionName)
        rootView.addSubview(infoStrip)

        // Retrieve terminal view from cache (stored by the source ThreadDetailVC before detach)
        let reuseKey = "\(thread.worktreePath)-\(sessionName)"
        if let tv = ReusableTerminalViewCache.shared.take(sessionName: sessionName, reuseKey: reuseKey) {
            tv.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(tv)
            self.terminalView = tv

            NSLayoutConstraint.activate([
                infoStrip.topAnchor.constraint(equalTo: rootView.topAnchor),
                infoStrip.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                infoStrip.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                infoStrip.heightAnchor.constraint(equalToConstant: 48),

                tv.topAnchor.constraint(equalTo: infoStrip.bottomAnchor),
                tv.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                tv.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                tv.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                infoStrip.topAnchor.constraint(equalTo: rootView.topAnchor),
                infoStrip.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                infoStrip.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                infoStrip.heightAnchor.constraint(equalToConstant: 48),
            ])
        }

        window.contentView = rootView
    }

    // MARK: - Cache Terminal View

    func cacheTerminalViewForReuse() {
        guard let tv = terminalView else { return }
        let thread = ThreadManager.shared.threads.first(where: { $0.id == threadId })
        let reuseKey = "\(thread?.worktreePath ?? "")-\(sessionName)"
        ReusableTerminalViewCache.shared.store(tv, sessionName: sessionName, reuseKey: reuseKey)
        self.terminalView = nil
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
        ] {
            nc.addObserver(self, selector: #selector(refreshInfoStrip), name: name, object: nil)
        }

        nc.addObserver(
            self,
            selector: #selector(handleTabWillClose(_:)),
            name: .magentTabWillClose,
            object: nil
        )

        nc.addObserver(
            self,
            selector: #selector(handleArchivedThreadsChanged),
            name: .magentArchivedThreadsDidChange,
            object: nil
        )
    }

    @objc private func refreshInfoStrip() {
        guard let thread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) else { return }
        infoStrip.configureForTab(thread: thread, sessionName: sessionName)
        window?.title = Self.windowTitle(for: thread, sessionName: sessionName)
    }

    @objc private func handleTabWillClose(_ notification: Notification) {
        guard let closedSession = notification.userInfo?["sessionName"] as? String,
              closedSession == sessionName else { return }
        PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
    }

    @objc private func handleArchivedThreadsChanged() {
        let exists = ThreadManager.shared.threads.contains(where: { $0.id == threadId })
        if !exists {
            PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !isReturningToThread else { return }
        PopoutWindowManager.shared.returnTabToThread(sessionName: sessionName)
    }

    // MARK: - Helpers

    private static func windowTitle(for thread: MagentThread, sessionName: String) -> String {
        let threadName = thread.taskDescription ?? thread.name
        let tabIndex = thread.tmuxSessionNames.firstIndex(of: sessionName).map { $0 + 1 } ?? 1
        return "\(threadName) — Tab \(tabIndex)"
    }
}
