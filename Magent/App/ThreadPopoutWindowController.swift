import Cocoa
import MagentCore

private final class ThreadPopoutDragDestinationView: NSView {
    var validateDraggedThreadId: ((UUID) -> Bool)?
    var didChangeDragHover: ((UUID?) -> Void)?
    var didDropThreadId: ((UUID) -> Void)?

    private var hoveredThreadId: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let threadId = Self.draggedThreadId(from: sender),
              validateDraggedThreadId?(threadId) == true else {
            updateHoveredThread(nil)
            return []
        }
        updateHoveredThread(threadId)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateHoveredThread(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let threadId = hoveredThreadId else { return false }
        didDropThreadId?(threadId)
        updateHoveredThread(nil)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        updateHoveredThread(nil)
    }

    private func updateHoveredThread(_ threadId: UUID?) {
        guard hoveredThreadId != threadId else { return }
        hoveredThreadId = threadId
        didChangeDragHover?(threadId)
    }

    private static func draggedThreadId(from info: NSDraggingInfo) -> UUID? {
        guard let pasteboardItem = info.draggingPasteboard.pasteboardItems?.first,
              let uuidString = pasteboardItem.string(forType: .string) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }
}

@MainActor
final class ThreadPopoutWindowController: NSWindowController, NSWindowDelegate {
    let threadId: UUID
    let detailVC: ThreadDetailViewController
    private let infoStrip: PopoutInfoStripView
    private let dragDestinationView = ThreadPopoutDragDestinationView()
    private let replaceDropOverlay = NSView()
    private let replaceDropTitleLabel = NSTextField(labelWithString: "")
    private let replaceDropSubtitleLabel = NSTextField(labelWithString: "")
    private var keyEventMonitor: Any?

    /// Set to true when `PopoutWindowManager.returnThreadToMain` is driving the close,
    /// so `windowWillClose` does not re-enter the return flow.
    var isReturningToMain = false

    init(thread: MagentThread, sourceWindow: NSWindow?) {
        self.threadId = thread.id
        self.infoStrip = PopoutInfoStripView()
        self.detailVC = ThreadDetailViewController(
            thread: thread,
            showsHeaderInfoStrip: false,
            isPopoutContext: true
        )

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

        let rootView = dragDestinationView
        rootView.wantsLayer = true
        rootView.validateDraggedThreadId = { [weak self] draggedThreadId in
            self?.canAcceptDraggedThread(draggedThreadId) ?? false
        }
        rootView.didChangeDragHover = { [weak self] draggedThreadId in
            self?.updateReplaceDropOverlay(for: draggedThreadId)
        }
        rootView.didDropThreadId = { [weak self] draggedThreadId in
            self?.handleDroppedThread(draggedThreadId)
        }

        infoStrip.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(infoStrip)

        let detailView = detailVC.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(detailView)

        setupReplaceDropOverlay(in: rootView)

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

    private func setupReplaceDropOverlay(in rootView: NSView) {
        replaceDropOverlay.translatesAutoresizingMaskIntoConstraints = false
        replaceDropOverlay.wantsLayer = true
        replaceDropOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        replaceDropOverlay.isHidden = true

        replaceDropTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        replaceDropTitleLabel.alignment = .center
        replaceDropTitleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        replaceDropTitleLabel.textColor = .white
        replaceDropTitleLabel.lineBreakMode = .byTruncatingTail
        replaceDropTitleLabel.maximumNumberOfLines = 1

        replaceDropSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        replaceDropSubtitleLabel.alignment = .center
        replaceDropSubtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        replaceDropSubtitleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        replaceDropSubtitleLabel.lineBreakMode = .byWordWrapping
        replaceDropSubtitleLabel.maximumNumberOfLines = 2

        replaceDropOverlay.addSubview(replaceDropTitleLabel)
        replaceDropOverlay.addSubview(replaceDropSubtitleLabel)
        rootView.addSubview(replaceDropOverlay)

        NSLayoutConstraint.activate([
            replaceDropOverlay.topAnchor.constraint(equalTo: rootView.topAnchor),
            replaceDropOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            replaceDropOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            replaceDropOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            replaceDropTitleLabel.centerXAnchor.constraint(equalTo: replaceDropOverlay.centerXAnchor),
            replaceDropTitleLabel.centerYAnchor.constraint(equalTo: replaceDropOverlay.centerYAnchor, constant: -12),
            replaceDropTitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: replaceDropOverlay.leadingAnchor, constant: 24),
            replaceDropTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: replaceDropOverlay.trailingAnchor, constant: -24),

            replaceDropSubtitleLabel.topAnchor.constraint(equalTo: replaceDropTitleLabel.bottomAnchor, constant: 8),
            replaceDropSubtitleLabel.centerXAnchor.constraint(equalTo: replaceDropOverlay.centerXAnchor),
            replaceDropSubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: replaceDropOverlay.leadingAnchor, constant: 24),
            replaceDropSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: replaceDropOverlay.trailingAnchor, constant: -24),
        ])
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

        let newThreadBinding = bindings.binding(for: .newThread)
        if event.keyCode == newThreadBinding.keyCode
            && flags == newThreadBinding.modifiers.nsEventFlags {
            _ = NSApp.sendAction(#selector(AppDelegate.requestNewThreadFromActiveContext(_:)), to: nil, from: self)
            return nil
        }

        let forkBinding = bindings.binding(for: .newThreadFromBranch)
        if event.keyCode == forkBinding.keyCode
            && flags == forkBinding.modifiers.nsEventFlags {
            _ = NSApp.sendAction(#selector(AppDelegate.requestForkThreadFromActiveContext(_:)), to: nil, from: self)
            return nil
        }

        // Cmd+Shift+O in pop-out → return thread to main (toggle)
        let popOutBinding = bindings.binding(for: .popOutThread)
        if event.keyCode == popOutBinding.keyCode
            && flags == popOutBinding.modifiers.nsEventFlags {
            PopoutWindowManager.shared.returnThreadToMain(threadId)
            return nil
        }

        let detachBinding = bindings.binding(for: .detachTab)
        if event.keyCode == detachBinding.keyCode
            && flags == detachBinding.modifiers.nsEventFlags {
            let settings = PersistenceService.shared.loadSettings()
            guard settings.isTabDetachFeatureEnabled else { return nil }
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
            .magentSectionsDidChange,
            .magentPullRequestInfoChanged,
            .magentJiraTicketInfoChanged,
            .magentKeepAliveChanged,
            .magentFavoritesChanged,
            .magentThreadsDidChange,
        ] {
            nc.addObserver(self, selector: #selector(refreshInfoStrip), name: name, object: nil)
        }

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

        nc.addObserver(
            self,
            selector: #selector(handleCompletionDetected(_:)),
            name: .magentAgentCompletionDetected,
            object: nil
        )
    }

    @objc private func refreshInfoStrip() {
        guard let latestThread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) else { return }
        infoStrip.refresh(from: latestThread)
        window?.title = Self.windowTitle(for: latestThread)
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

    @objc private func handleCompletionDetected(_ notification: Notification) {
        guard let completedThreadId = notification.userInfo?["threadId"] as? UUID,
              completedThreadId == threadId else { return }
        markThreadCompletionSeenIfFocused()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        NotificationCenter.default.post(
            name: .magentFocusedThreadContextChanged,
            object: self,
            userInfo: [
                "threadId": threadId,
                "isPopoutContext": true,
            ]
        )
        detailVC.focusCurrentTabForNavigation()
        detailVC.currentTerminalView()?.markAsActiveSurface()
        markThreadCompletionSeenIfFocused()
    }

    func windowDidMove(_ notification: Notification) {
        PopoutWindowManager.shared.saveState()
    }

    func windowDidResize(_ notification: Notification) {
        PopoutWindowManager.shared.saveState()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        PopoutWindowManager.shared.saveState()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        PopoutWindowManager.shared.saveState()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isReturningToMain else { return }
        guard !PopoutWindowManager.shared.isApplicationTerminating else { return }
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

    private func markThreadCompletionSeenIfFocused() {
        guard window?.isKeyWindow == true else { return }
        ThreadManager.shared.markThreadCompletionSeen(threadId: threadId)
    }

    func focusCurrentTabForNavigation() {
        detailVC.focusCurrentTabForNavigation()
    }

    private func canAcceptDraggedThread(_ draggedThreadId: UUID) -> Bool {
        guard draggedThreadId != threadId else { return false }
        guard let dragged = ThreadManager.shared.threads.first(where: { $0.id == draggedThreadId }) else { return false }
        return !dragged.isMain
    }

    private func updateReplaceDropOverlay(for draggedThreadId: UUID?) {
        guard let draggedThreadId,
              let dragged = ThreadManager.shared.threads.first(where: { $0.id == draggedThreadId }),
              canAcceptDraggedThread(draggedThreadId) else {
            replaceDropOverlay.isHidden = true
            return
        }

        let displayName = dragged.taskDescription ?? dragged.name
        replaceDropTitleLabel.stringValue = "Drop to replace this pop-out"
        replaceDropSubtitleLabel.stringValue = "Open \"\(displayName)\" here and return the current thread to the main window."
        replaceDropOverlay.isHidden = false
    }

    private func handleDroppedThread(_ draggedThreadId: UUID) {
        guard canAcceptDraggedThread(draggedThreadId) else { return }
        guard let window else { return }

        if PopoutWindowManager.shared.isThreadPoppedOut(draggedThreadId) {
            handleDroppedAlreadyPoppedOutThread(draggedThreadId, targetWindowFrame: window.frame)
            return
        }

        let currentThread = ThreadManager.shared.threads.first(where: { $0.id == threadId })
        let draggedThread = ThreadManager.shared.threads.first(where: { $0.id == draggedThreadId })

        let currentThreadName = currentThread?.taskDescription
            ?? currentThread?.name
            ?? "this thread"
        let draggedThreadName = draggedThread?.taskDescription
            ?? draggedThread?.name
            ?? "the dragged thread"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace pop-out thread?"
        alert.informativeText = "Return \"\(currentThreadName)\" to the main window and open \"\(draggedThreadName)\" in this pop-out window?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        PopoutWindowManager.shared.replacePoppedOutThread(targetThreadId: threadId, with: draggedThreadId, in: window.frame)
    }

    private func handleDroppedAlreadyPoppedOutThread(_ draggedThreadId: UUID, targetWindowFrame: NSRect) {
        guard draggedThreadId != threadId else { return }

        let currentThread = ThreadManager.shared.threads.first(where: { $0.id == threadId })
        let draggedThread = ThreadManager.shared.threads.first(where: { $0.id == draggedThreadId })

        let currentThreadName = currentThread?.taskDescription
            ?? currentThread?.name
            ?? "this thread"
        let draggedThreadName = draggedThread?.taskDescription
            ?? draggedThread?.name
            ?? "the dragged thread"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Thread is already popped out"
        alert.informativeText = "\"\(draggedThreadName)\" is already open in another window. Move it here and return \"\(currentThreadName)\" to the main window, or swap the two pop-out windows?"
        alert.addButton(withTitle: "Move Here")
        alert.addButton(withTitle: "Swap Windows")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            PopoutWindowManager.shared.movePoppedOutThread(
                targetThreadId: threadId,
                draggedThreadId: draggedThreadId,
                to: targetWindowFrame
            )
        case .alertSecondButtonReturn:
            PopoutWindowManager.shared.swapPoppedOutThreads(threadId, draggedThreadId)
        default:
            break
        }
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
