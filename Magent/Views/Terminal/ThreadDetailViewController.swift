import Cocoa
import GhosttyBridge

// MARK: - TabItemView

private final class TabItemView: NSView, NSMenuDelegate {

    let pinIcon: NSImageView
    let completionDot: NSView
    let titleLabel: NSTextField
    let closeButton: NSButton
    var isDragging = false

    var isSelected = false {
        didSet { updateAppearance() }
    }

    var showCloseButton: Bool {
        get { !closeButton.isHidden }
        set { closeButton.isHidden = !newValue }
    }

    var showPinIcon: Bool {
        get { !pinIcon.isHidden }
        set { pinIcon.isHidden = !newValue }
    }

    var hasUnreadCompletion: Bool {
        get { !completionDot.isHidden }
        set { completionDot.isHidden = !newValue }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onPin: (() -> Void)?

    init(title: String) {
        pinIcon = NSImageView()
        completionDot = NSView()
        titleLabel = NSTextField(labelWithString: title)
        closeButton = NSButton()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Pin icon
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinIcon.contentTintColor = NSColor(resource: .textSecondary)
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.isHidden = true
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)

        // Completion dot (green circle)
        completionDot.wantsLayer = true
        completionDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        completionDot.layer?.cornerRadius = 4
        completionDot.translatesAutoresizingMaskIntoConstraints = false
        completionDot.isHidden = true
        completionDot.setContentHuggingPriority(.required, for: .horizontal)
        completionDot.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Close button — use xmark.circle.fill for visibility
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Layout using an internal stack
        let contentStack = NSStackView(views: [pinIcon, completionDot, titleLabel, closeButton])
        contentStack.orientation = .horizontal
        contentStack.spacing = 4
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12),
            completionDot.widthAnchor.constraint(equalToConstant: 8),
            completionDot.heightAnchor.constraint(equalToConstant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Right-click menu
        let tabMenu = NSMenu()
        tabMenu.delegate = self
        menu = tabMenu

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        guard !isDragging else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden {
            let closeBounds = closeButton.convert(closeButton.bounds, to: self)
            if closeBounds.contains(loc) { return }
        }
        onSelect?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func renameTapped() {
        onRename?()
    }

    @objc private func pinTapped() {
        onPin?()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected
            ? NSColor(resource: .primaryBrand).withAlphaComponent(0.2).cgColor
            : NSColor(resource: .surface).withAlphaComponent(0.5).cgColor
        titleLabel.textColor = isSelected ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if showCloseButton {
            let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeTapped), keyEquivalent: "")
            closeItem.target = self
            menu.addItem(closeItem)
        }

        let pinTitle = showPinIcon ? "Unpin Tab" : "Pin Tab"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinTapped), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if onRename != nil {
            menu.addItem(.separator())
            let renameItem = NSMenuItem(title: "Rename Tab...", action: #selector(renameTapped), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
        }
    }
}

// MARK: - ThreadDetailViewController

final class ThreadDetailViewController: NSViewController {

    private static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    private static let lastOpenedSessionDefaultsKey = "MagentLastOpenedSessionName"

    private(set) var thread: MagentThread
    private let threadManager = ThreadManager.shared
    private let tabBarStack = NSStackView()
    private let terminalContainer = NSView()
    private let openPRButton = NSButton()
    private let openInFinderButton = NSButton()
    private let archiveThreadButton = NSButton()
    private let addTabButton = NSButton()

    private var tabItems: [TabItemView] = []
    private var terminalViews: [TerminalSurfaceView] = []
    private var currentTabIndex = 0
    /// Index of the non-closable "primary" tab. -1 means all tabs are closable (main threads).
    private var primaryTabIndex = 0
    private var pinnedCount = 0
    private var loadingOverlay: NSView?
    private var loadingPollTimer: Timer?

    private let pinSeparator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }()

    init(thread: MagentThread) {
        self.thread = thread
        self.primaryTabIndex = thread.isMain ? -1 : 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor

        GhosttyAppManager.shared.initialize()

        setupUI()
        refreshOpenPRButtonIcon()
        setupLoadingOverlay()

        // Observe dead session notifications for mid-use terminal replacement
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeadSessionsNotification(_:)),
            name: .magentDeadSessionsDetected,
            object: nil
        )

        // Observe agent completion notifications for tab dot indicators
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentCompletionNotification(_:)),
            name: .magentAgentCompletionDetected,
            object: nil
        )

        Task {
            await setupTabs()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        tabBarStack.orientation = .horizontal
        tabBarStack.spacing = 4
        tabBarStack.alignment = .centerY
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false

        openPRButton.bezelStyle = .texturedRounded
        openPRButton.image = openPRButtonImage(for: .unknown)
        openPRButton.imageScaling = .scaleProportionallyDown
        openPRButton.target = self
        openPRButton.action = #selector(openPRTapped(_:))
        openPRButton.toolTip = "Open Pull Request in Browser"

        openInFinderButton.bezelStyle = .texturedRounded
        openInFinderButton.image = finderButtonImage()
        openInFinderButton.imageScaling = .scaleProportionallyDown
        openInFinderButton.target = self
        openInFinderButton.action = #selector(openInFinderTapped)
        openInFinderButton.toolTip = thread.isMain ? "Open Project Root in Finder" : "Open Worktree in Finder"

        archiveThreadButton.bezelStyle = .texturedRounded
        archiveThreadButton.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archive Thread")
        archiveThreadButton.target = self
        archiveThreadButton.action = #selector(archiveThreadTapped)
        archiveThreadButton.isHidden = thread.isMain

        addTabButton.bezelStyle = .texturedRounded
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        addTabButton.target = self
        addTabButton.action = #selector(addTabTapped)

        let topBar = NSStackView(views: [tabBarStack, openInFinderButton, openPRButton, archiveThreadButton, addTabButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor

        view.addSubview(topBar)
        view.addSubview(terminalContainer)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 32),

            terminalContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Tab Setup

    private func setupTabs() async {
        if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
            thread = latest
        }

        let settings = PersistenceService.shared.loadSettings()
        let selectedAgentType = thread.selectedAgentType ?? threadManager.effectiveAgentType(for: thread.projectId)

        // Determine tab order with pinned tabs first
        let pinnedSet = Set(thread.pinnedTmuxSessions)

        let sessions: [String]
        if thread.isMain {
            let sanitizedName = ThreadManager.sanitizeForTmux(
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            sessions = thread.tmuxSessionNames.isEmpty ? ["magent-main-\(sanitizedName)"] : thread.tmuxSessionNames
        } else {
            sessions = thread.tmuxSessionNames.isEmpty ? ["magent-\(thread.name)"] : thread.tmuxSessionNames
        }

        let pinned = sessions.filter { pinnedSet.contains($0) }
        let unpinned = sessions.filter { !pinnedSet.contains($0) }
        let orderedSessions = pinned + unpinned
        pinnedCount = pinned.count

        for (i, sessionName) in orderedSessions.enumerated() {
            // Ensure the session exists and matches this thread context.
            _ = await threadManager.recreateSessionIfNeeded(
                sessionName: sessionName,
                thread: thread
            )

            await MainActor.run {
                let title = thread.displayName(for: sessionName, at: i)
                let closable = thread.isMain ? true : (i != primaryTabIndex)
                createTabItem(title: title, closable: closable, pinned: i < pinnedCount)

                let terminalView = makeTerminalView(for: sessionName)
                terminalViews.append(terminalView)
            }
        }

        thread.tmuxSessionNames = orderedSessions

        await MainActor.run {
            rebuildTabBar()
            let initialIndex: Int
            let defaults = UserDefaults.standard
            let defaultsThreadId = defaults
                .string(forKey: Self.lastOpenedThreadDefaultsKey)
                .flatMap(UUID.init(uuidString:))
            let defaultsSession = defaults.string(forKey: Self.lastOpenedSessionDefaultsKey)

            if defaultsThreadId == thread.id,
               let defaultsSession,
               let savedIndex = orderedSessions.firstIndex(of: defaultsSession) {
                initialIndex = savedIndex
            } else if let lastSelected = thread.lastSelectedTmuxSessionName,
                      let savedIndex = orderedSessions.firstIndex(of: lastSelected) {
                initialIndex = savedIndex
            } else {
                initialIndex = 0
            }

            // Initialize completion dots from thread model
            for (i, sessionName) in orderedSessions.enumerated() where i < tabItems.count {
                tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
            }

            selectTab(at: initialIndex)
        }
    }

    private func makeTerminalView(for sessionName: String) -> TerminalSurfaceView {
        let tmuxCommand = buildTmuxCommand(for: sessionName)
        let view = TerminalSurfaceView(
            workingDirectory: thread.worktreePath,
            command: tmuxCommand
        )
        view.onCopy = { [sessionName = sessionName] in
            Task { await TmuxService.shared.copySelectionToClipboard(sessionName: sessionName) }
        }
        view.onSubmitLine = { [weak self, sessionName = sessionName] line in
            Task { @MainActor [weak self] in
                await self?.handleSubmittedLine(line, sessionName: sessionName)
            }
        }
        return view
    }

    private func buildTmuxCommand(for sessionName: String) -> String {
        let settings = PersistenceService.shared.loadSettings()
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)
        let selectedAgentType = thread.selectedAgentType ?? threadManager.effectiveAgentType(for: thread.projectId)

        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let projectName = project?.name ?? "project"
        if thread.isMain {
            let projectPath = thread.worktreePath
            let envExports = "export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=main && export MAGENT_PROJECT_NAME=\(projectName)"
            let startCmd: String
            if isAgentSession, let selectedAgentType {
                let unset = selectedAgentType == .claude ? " && unset CLAUDECODE" : ""
                startCmd = "\(envExports) && cd \(projectPath)\(unset) && \(settings.command(for: selectedAgentType))"
            } else {
                startCmd = "\(envExports) && cd \(projectPath) && exec zsh -l"
            }
            if isAgentSession {
                // Use a plain POSIX shell for tmux bootstrap to avoid user zsh startup side effects
                // (e.g. login hooks printing text before attach).
                return "/bin/sh -c 'tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(projectPath)\" \"\(startCmd)\" && tmux attach-session -t \(sessionName); }'"
            }
            // Force cwd on every open for terminal tabs, even if shell init changes it.
            return "/bin/sh -c 'tmux send-keys -t \(sessionName) \"cd \(projectPath)\" Enter 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(projectPath)\" \"\(startCmd)\" && tmux send-keys -t \(sessionName) \"cd \(projectPath)\" Enter && tmux attach-session -t \(sessionName); }'"
        } else {
            let wd = thread.worktreePath
            let projectPath = project?.repoPath ?? wd
            let envExports = "export MAGENT_WORKTREE_PATH=\(wd) && export MAGENT_PROJECT_PATH=\(projectPath) && export MAGENT_WORKTREE_NAME=\(thread.name) && export MAGENT_PROJECT_NAME=\(projectName)"
            let startCmd: String
            if isAgentSession, let selectedAgentType {
                let unset = selectedAgentType == .claude ? " && unset CLAUDECODE" : ""
                startCmd = "\(envExports) && cd \(wd)\(unset) && \(settings.command(for: selectedAgentType))"
            } else {
                startCmd = "\(envExports) && cd \(wd) && exec zsh -l"
            }
            if isAgentSession {
                // Use a plain POSIX shell for tmux bootstrap to avoid user zsh startup side effects
                // (e.g. login hooks printing text before attach).
                return "/bin/sh -c 'tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(wd)\" \"\(startCmd)\" && tmux attach-session -t \(sessionName); }'"
            }
            // Force cwd on every open for terminal tabs, even if shell init changes it.
            return "/bin/sh -c 'tmux send-keys -t \(sessionName) \"cd \(wd)\" Enter 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(wd)\" \"\(startCmd)\" && tmux send-keys -t \(sessionName) \"cd \(wd)\" Enter && tmux attach-session -t \(sessionName); }'"
        }
    }

    @objc private func handleDeadSessionsNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let deadSessions = userInfo["deadSessions"] as? [String] else { return }

        // The monitor already recreated the tmux sessions.
        // Replace the terminal views that were attached to the old (dead) sessions.
        for sessionName in deadSessions {
            guard let i = thread.tmuxSessionNames.firstIndex(of: sessionName),
                  i < terminalViews.count else { continue }

            let wasSelected = (i == currentTabIndex)
            let oldView = terminalViews[i]
            oldView.removeFromSuperview()

            let newView = makeTerminalView(for: sessionName)
            terminalViews[i] = newView

            if wasSelected {
                selectTab(at: i)
            }
        }
    }

    @objc private func handleAgentCompletionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let unreadSessions = userInfo["unreadSessions"] as? Set<String> else { return }

        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasUnreadCompletion = unreadSessions.contains(sessionName)
        }
    }

    // MARK: - Tab Bar Layout

    private func rebuildTabBar() {
        for sv in tabBarStack.arrangedSubviews {
            tabBarStack.removeArrangedSubview(sv)
            sv.removeFromSuperview()
        }

        for i in 0..<pinnedCount where i < tabItems.count {
            tabItems[i].showPinIcon = true
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        if pinnedCount > 0 && pinnedCount < tabItems.count {
            tabBarStack.addArrangedSubview(pinSeparator)
        }

        for i in pinnedCount..<tabItems.count {
            tabItems[i].showPinIcon = false
            tabBarStack.addArrangedSubview(tabItems[i])
        }

        // Flexible spacer so tabs stay compact and don't stretch
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabBarStack.addArrangedSubview(spacer)
    }

    // MARK: - Tab Management

    private func createTabItem(title: String, closable: Bool, pinned: Bool = false) {
        let index = tabItems.count
        let item = TabItemView(title: title)
        item.showCloseButton = closable
        item.showPinIcon = pinned
        item.onSelect = { [weak self] in self?.selectTab(at: index) }
        item.onClose = { [weak self] in self?.closeTab(at: index) }
        item.onRename = { [weak self] in self?.showTabRenameDialog(at: index) }
        item.onPin = { [weak self] in self?.togglePin(at: index) }

        // Pan gesture for drag-to-reorder
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:)))
        pan.delegate = self
        item.addGestureRecognizer(pan)

        tabItems.append(item)
    }

    private func selectTab(at index: Int) {
        for tv in terminalViews {
            tv.removeFromSuperview()
        }

        guard index < terminalViews.count else { return }

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        let terminalView = terminalViews[index]
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        view.window?.makeFirstResponder(terminalView)
        currentTabIndex = index

        if index < thread.tmuxSessionNames.count {
            let sessionName = thread.tmuxSessionNames[index]
            if thread.lastSelectedTmuxSessionName != sessionName {
                thread.lastSelectedTmuxSessionName = sessionName
                threadManager.updateLastSelectedSession(for: thread.id, sessionName: sessionName)
            }
            UserDefaults.standard.set(thread.id.uuidString, forKey: Self.lastOpenedThreadDefaultsKey)
            UserDefaults.standard.set(sessionName, forKey: Self.lastOpenedSessionDefaultsKey)

            // Clear unread completion dot for this tab
            tabItems[index].hasUnreadCompletion = false
            threadManager.markSessionCompletionSeen(threadId: thread.id, sessionName: sessionName)
        }
    }

    private func rebindTabActions() {
        for (i, item) in tabItems.enumerated() {
            item.onSelect = { [weak self] in self?.selectTab(at: i) }
            item.onClose = { [weak self] in self?.closeTab(at: i) }
            item.onRename = { [weak self] in self?.showTabRenameDialog(at: i) }
            item.onPin = { [weak self] in self?.togglePin(at: i) }
            item.showCloseButton = (i != primaryTabIndex)
            item.showPinIcon = (i < pinnedCount)
        }
    }

    // MARK: - Drag-to-Reorder

    @objc private func handleTabDrag(_ gesture: NSPanGestureRecognizer) {
        guard let draggedView = gesture.view as? TabItemView,
              let dragIndex = tabItems.firstIndex(where: { $0 === draggedView }) else { return }

        switch gesture.state {
        case .began:
            draggedView.isDragging = true
            draggedView.alphaValue = 0.85
            draggedView.layer?.zPosition = 100

        case .changed:
            let translation = gesture.translation(in: tabBarStack)
            draggedView.layer?.transform = CATransform3DMakeTranslation(translation.x, 0, 0)

            let draggedCenter = draggedView.frame.midX + translation.x

            // Constrain swaps within pinned/unpinned group
            let isPinned = dragIndex < pinnedCount
            let rangeStart = isPinned ? 0 : pinnedCount
            let rangeEnd = isPinned ? pinnedCount : tabItems.count

            // Check left neighbor
            if dragIndex > rangeStart {
                let leftTab = tabItems[dragIndex - 1]
                if draggedCenter < leftTab.frame.midX {
                    swapAdjacentTabs(dragIndex, dragIndex - 1, draggedView: draggedView, gesture: gesture)
                    return
                }
            }

            // Check right neighbor
            if dragIndex < rangeEnd - 1 {
                let rightTab = tabItems[dragIndex + 1]
                if draggedCenter > rightTab.frame.midX {
                    swapAdjacentTabs(dragIndex, dragIndex + 1, draggedView: draggedView, gesture: gesture)
                    return
                }
            }

        case .ended, .cancelled:
            draggedView.isDragging = false
            draggedView.alphaValue = 1.0
            draggedView.layer?.zPosition = 0
            draggedView.layer?.transform = CATransform3DIdentity
            persistTabOrder()
            rebindTabActions()

        default:
            break
        }
    }

    private func swapAdjacentTabs(_ indexA: Int, _ indexB: Int, draggedView: TabItemView, gesture: NSPanGestureRecognizer) {
        let otherView = (tabItems[indexA] === draggedView) ? tabItems[indexB] : tabItems[indexA]
        let otherOldFrame = otherView.frame

        // Swap in model arrays
        tabItems.swapAt(indexA, indexB)
        if indexA < terminalViews.count && indexB < terminalViews.count {
            terminalViews.swapAt(indexA, indexB)
        }
        if indexA < thread.tmuxSessionNames.count && indexB < thread.tmuxSessionNames.count {
            thread.tmuxSessionNames.swapAt(indexA, indexB)
        }

        // Update tracking indices
        if primaryTabIndex == indexA { primaryTabIndex = indexB }
        else if primaryTabIndex == indexB { primaryTabIndex = indexA }

        if currentTabIndex == indexA { currentTabIndex = indexB }
        else if currentTabIndex == indexB { currentTabIndex = indexA }

        // Swap positions in the stack view (removeArrangedSubview does NOT remove from superview)
        swapInStack(draggedView, otherView)

        // Force layout so frames update
        tabBarStack.layoutSubtreeIfNeeded()

        // Animate the other view from its old position to the new one
        let otherNewFrame = otherView.frame
        otherView.frame = otherOldFrame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            otherView.animator().frame = otherNewFrame
        }

        // Reset translation — the dragged view is now at a new stack position
        gesture.setTranslation(.zero, in: tabBarStack)
        draggedView.layer?.transform = CATransform3DIdentity
    }

    private func swapInStack(_ viewA: NSView, _ viewB: NSView) {
        guard let idxA = tabBarStack.arrangedSubviews.firstIndex(of: viewA),
              let idxB = tabBarStack.arrangedSubviews.firstIndex(of: viewB) else { return }

        let minIdx = min(idxA, idxB)
        let maxIdx = max(idxA, idxB)
        let viewAtMin = tabBarStack.arrangedSubviews[minIdx]
        let viewAtMax = tabBarStack.arrangedSubviews[maxIdx]

        // Remove from higher index first so lower index stays stable
        tabBarStack.removeArrangedSubview(viewAtMax)
        tabBarStack.removeArrangedSubview(viewAtMin)
        // Re-insert swapped
        tabBarStack.insertArrangedSubview(viewAtMax, at: minIdx)
        tabBarStack.insertArrangedSubview(viewAtMin, at: maxIdx)
    }

    private func moveTab(from source: Int, to dest: Int) {
        guard source != dest else { return }

        let item = tabItems.remove(at: source)
        tabItems.insert(item, at: dest)

        let terminal = terminalViews.remove(at: source)
        terminalViews.insert(terminal, at: dest)

        if source < thread.tmuxSessionNames.count {
            var sessions = thread.tmuxSessionNames
            let session = sessions.remove(at: source)
            sessions.insert(session, at: min(dest, sessions.count))
            thread.tmuxSessionNames = sessions
        }

        // Update primaryTabIndex
        if primaryTabIndex >= 0 {
            if primaryTabIndex == source {
                primaryTabIndex = dest
            } else if source < primaryTabIndex && dest >= primaryTabIndex {
                primaryTabIndex -= 1
            } else if source > primaryTabIndex && dest <= primaryTabIndex {
                primaryTabIndex += 1
            }
        }

        // Update currentTabIndex
        if currentTabIndex == source {
            currentTabIndex = dest
        } else if source < currentTabIndex && dest >= currentTabIndex {
            currentTabIndex -= 1
        } else if source > currentTabIndex && dest <= currentTabIndex {
            currentTabIndex += 1
        }
    }

    private func persistTabOrder() {
        threadManager.reorderTabs(for: thread.id, newOrder: thread.tmuxSessionNames)
        let pinnedSessions = (0..<pinnedCount).compactMap { i -> String? in
            guard i < thread.tmuxSessionNames.count else { return nil }
            return thread.tmuxSessionNames[i]
        }
        threadManager.updatePinnedTabs(for: thread.id, pinnedSessions: pinnedSessions)
    }

    // MARK: - Pin/Unpin

    private func togglePin(at index: Int) {
        if index < pinnedCount {
            unpinTab(at: index)
        } else {
            pinTab(at: index)
        }
    }

    private func pinTab(at index: Int) {
        guard index >= pinnedCount else { return }
        moveTab(from: index, to: pinnedCount)
        pinnedCount += 1
        rebindTabActions()
        rebuildTabBar()
        persistTabOrder()
    }

    private func unpinTab(at index: Int) {
        guard index < pinnedCount else { return }
        pinnedCount -= 1
        moveTab(from: index, to: pinnedCount)
        rebindTabActions()
        rebuildTabBar()
        persistTabOrder()
    }

    // MARK: - Open PR/MR

    @objc private func openPRTapped(_ sender: NSButton) {
        Task {
            let settings = PersistenceService.shared.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            guard !remotes.isEmpty else {
                BannerManager.shared.show(message: "No git remotes found", style: .warning)
                return
            }

            let branch = thread.branchName
            let defaultBranch: String?
            if let projectDefaultBranch = project.defaultBranch {
                defaultBranch = projectDefaultBranch
            } else {
                defaultBranch = await GitService.shared.detectDefaultBranch(repoPath: project.repoPath)
            }

            if remotes.count == 1 {
                await MainActor.run {
                    openRemoteURL(remotes[0], branch: branch, defaultBranch: defaultBranch)
                }
            } else {
                // Find the "primary" remote — prefer origin
                let origin = remotes.first(where: { $0.name == "origin" })
                if let origin, remotes.allSatisfy({ $0.host == origin.host && $0.repoPath == origin.repoPath }) {
                    // All remotes point to the same place
                    await MainActor.run {
                        openRemoteURL(origin, branch: branch, defaultBranch: defaultBranch)
                    }
                } else {
                    await MainActor.run {
                        showRemoteMenu(remotes: remotes, branch: branch, defaultBranch: defaultBranch, relativeTo: sender)
                    }
                }
            }
        }
    }

    private func refreshOpenPRButtonIcon() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let settings = PersistenceService.shared.loadSettings()
            guard let project = settings.projects.first(where: { $0.id == self.thread.projectId }) else {
                self.openPRButton.image = self.openPRButtonImage(for: .unknown)
                return
            }

            let remotes = await GitService.shared.getRemotes(repoPath: project.repoPath)
            let provider = self.preferredHostingProvider(from: remotes)
            self.openPRButton.image = self.openPRButtonImage(for: provider)
            self.openPRButton.toolTip = self.openPRTooltip(for: provider)
        }
    }

    private func preferredHostingProvider(from remotes: [GitRemote]) -> GitHostingProvider {
        guard !remotes.isEmpty else { return .unknown }

        if let first = remotes.first,
           remotes.allSatisfy({ $0.host == first.host && $0.repoPath == first.repoPath }) {
            return first.provider
        }

        if let origin = remotes.first(where: { $0.name == "origin" }) {
            return origin.provider
        }

        return remotes.first(where: { $0.provider != .unknown })?.provider ?? .unknown
    }

    private func openPRButtonImage(for provider: GitHostingProvider) -> NSImage {
        if let image = hostIcon(for: provider) {
            return image
        }
        return NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open Pull Request") ?? NSImage()
    }

    private func openPRTooltip(for provider: GitHostingProvider) -> String {
        switch provider {
        case .github:
            return "Open GitHub Pull Request in Browser"
        case .gitlab:
            return "Open GitLab Merge Request in Browser"
        case .bitbucket:
            return "Open Bitbucket Pull Request in Browser"
        case .unknown:
            return "Open Pull Request in Browser"
        }
    }

    private func hostIcon(for provider: GitHostingProvider) -> NSImage? {
        let imageName: String?
        switch provider {
        case .github:
            imageName = "RepoHostGitHub"
        case .gitlab:
            imageName = "RepoHostGitLab"
        case .bitbucket:
            imageName = "RepoHostBitbucket"
        case .unknown:
            imageName = nil
        }

        guard let imageName, let baseImage = NSImage(named: NSImage.Name(imageName)) else { return nil }
        let sourceImage = (baseImage.copy() as? NSImage) ?? baseImage
        sourceImage.size = NSSize(width: 16, height: 16)

        if provider == .github {
            // GitHub favicon is dark; keep it readable in dark mode with a subtle light badge.
            let size = NSSize(width: 16, height: 16)
            let composed = NSImage(size: size, flipped: false) { _ in
                let rect = NSRect(origin: .zero, size: size)
                let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                NSColor.white.setFill()
                bgPath.fill()
                NSColor.black.withAlphaComponent(0.16).setStroke()
                bgPath.lineWidth = 1
                bgPath.stroke()

                let iconRect = rect.insetBy(dx: 2, dy: 2)
                sourceImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            composed.isTemplate = false
            return composed
        }

        sourceImage.isTemplate = false
        return sourceImage
    }

    private func showRemoteMenu(remotes: [GitRemote], branch: String, defaultBranch: String?, relativeTo button: NSButton) {
        let menu = NSMenu(title: "Select Remote")
        for remote in remotes {
            let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL
            guard let url else { continue }
            let title = "\(remote.name) (\(remote.host)/\(remote.repoPath))"
            let item = NSMenuItem(title: title, action: #selector(remoteMenuItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = hostIcon(for: remote.provider)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func remoteMenuItemTapped(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRemoteURL(_ remote: GitRemote, branch: String, defaultBranch: String?) {
        guard let url = remote.pullRequestURL(for: branch, defaultBranch: defaultBranch) ?? remote.openPullRequestsURL ?? remote.repoWebURL else {
            BannerManager.shared.show(message: "Could not construct URL for remote \(remote.name)", style: .warning)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func finderButtonImage() -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        image.size = NSSize(width: 14, height: 14)
        return image
    }

    private func finderTargetPath() -> String {
        if thread.isMain {
            let settings = PersistenceService.shared.loadSettings()
            if let projectPath = settings.projects.first(where: { $0.id == thread.projectId })?.repoPath {
                return projectPath
            }
        }
        return thread.worktreePath
    }

    @objc private func openInFinderTapped() {
        let path = NSString(string: finderTargetPath()).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)

        guard exists, isDirectory.boolValue else {
            let targetName = thread.isMain ? "project root" : "worktree"
            BannerManager.shared.show(message: "Could not open \(targetName) in Finder because the directory is missing.", style: .warning)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Add Tab

    @objc private func archiveThreadTapped() {
        guard !thread.isMain else { return }
        let threadToArchive = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread

        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == threadToArchive.projectId })
        let defaultBranch = project?.defaultBranch ?? "main"

        Task {
            let git = GitService.shared
            let clean = await git.isClean(worktreePath: threadToArchive.worktreePath)
            let merged = await git.isMergedInto(worktreePath: threadToArchive.worktreePath, baseBranch: defaultBranch)

            await MainActor.run {
                if clean && merged {
                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(threadToArchive)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Archive Thread"
                    var reasons: [String] = []
                    if !clean { reasons.append("uncommitted changes") }
                    if !merged { reasons.append("commits not in \(defaultBranch)") }
                    alert.informativeText = "The thread \"\(threadToArchive.name)\" has \(reasons.joined(separator: " and ")). Archiving will remove its worktree directory but keep the git branch \"\(threadToArchive.branchName)\"."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Archive")
                    alert.addButton(withTitle: "Cancel")

                    let response = alert.runModal()
                    guard response == .alertFirstButtonReturn else { return }

                    self.performWithSpinner(message: "Archiving thread...", errorTitle: "Archive Failed") {
                        try await self.threadManager.archiveThread(threadToArchive)
                    }
                }
            }
        }
    }

    @objc private func addTabTapped() {
        presentAddTabAgentMenu()
    }

    private func presentAddTabAgentMenu() {
        let settings = PersistenceService.shared.loadSettings()
        let activeAgents = settings.availableActiveAgents

        let menu = NSMenu()

        if let defaultAgent = threadManager.effectiveAgentType(for: thread.projectId) {
            let defaultItem = NSMenuItem(
                title: "Use Project Default (\(defaultAgent.displayName))",
                action: #selector(addTabMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            defaultItem.target = self
            defaultItem.representedObject = ["mode": "default"] as [String: String]
            menu.addItem(defaultItem)
        }

        for agent in activeAgents {
            let item = NSMenuItem(title: agent.displayName, action: #selector(addTabMenuItemTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["mode": "agent", "agentRaw": agent.rawValue] as [String: String]
            menu.addItem(item)
        }

        if menu.items.count > 0 {
            menu.addItem(.separator())
        }

        let terminalItem = NSMenuItem(
            title: "Terminal",
            action: #selector(addTabMenuItemTapped(_:)),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.representedObject = ["mode": "terminal"] as [String: String]
        menu.addItem(terminalItem)

        menu.popUp(positioning: nil, at: NSPoint(x: addTabButton.bounds.minX, y: addTabButton.bounds.minY), in: addTabButton)
    }

    @objc private func addTabMenuItemTapped(_ sender: NSMenuItem) {
        let data = sender.representedObject as? [String: String]
        let mode = data?["mode"] ?? "default"
        switch mode {
        case "terminal":
            addTab(using: nil, useAgentCommand: false)
        case "agent":
            let raw = data?["agentRaw"] ?? ""
            addTab(using: AgentType(rawValue: raw), useAgentCommand: true)
        default:
            addTab(using: nil, useAgentCommand: true)
        }
    }

    private func addTab(using agentType: AgentType?, useAgentCommand: Bool) {
        Task {
            do {
                let tab = try await threadManager.addTab(
                    to: thread,
                    useAgentCommand: useAgentCommand,
                    requestedAgentType: agentType
                )
                let latestThread = self.threadManager.threads.first(where: { $0.id == self.thread.id }) ?? self.thread
                _ = await self.threadManager.recreateSessionIfNeeded(
                    sessionName: tab.tmuxSessionName,
                    thread: latestThread
                )
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }
                    let terminalView = self.makeTerminalView(for: tab.tmuxSessionName)
                    self.terminalViews.append(terminalView)

                    let index = self.tabItems.count
                    self.createTabItem(title: "Tab \(index)", closable: true)
                    self.rebuildTabBar()
                    self.selectTab(at: index)
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Error"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    func addTabFromKeyboard() {
        addTabTapped()
    }

    // MARK: - Update & Rename

    func updateThread(_ updated: MagentThread) {
        thread = updated
    }

    func handleRename(_ updated: MagentThread) {
        thread = updated

        // Update onCopy closures to use the new (renamed) tmux session names
        for (i, terminalView) in terminalViews.enumerated() {
            if i < thread.tmuxSessionNames.count {
                let newSessionName = thread.tmuxSessionNames[i]
                terminalView.onCopy = {
                    Task { await TmuxService.shared.copySelectionToClipboard(sessionName: newSessionName) }
                }
                terminalView.onSubmitLine = { [weak self, sessionName = newSessionName] line in
                    Task { @MainActor [weak self] in
                        await self?.handleSubmittedLine(line, sessionName: sessionName)
                    }
                }
            }
        }

        // Refresh tab labels to reflect re-keyed custom names
        for (i, item) in tabItems.enumerated() where i < thread.tmuxSessionNames.count {
            item.titleLabel.stringValue = thread.displayName(for: thread.tmuxSessionNames[i], at: i)
        }
    }

    @MainActor
    private func handleSubmittedLine(_ line: String, sessionName: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let previousThread = thread
        await threadManager.autoRenameThreadAfterFirstPromptIfNeeded(
            threadId: thread.id,
            sessionName: sessionName,
            prompt: trimmed
        )

        guard let updated = threadManager.threads.first(where: { $0.id == thread.id }) else { return }
        if updated.name != previousThread.name || updated.worktreePath != previousThread.worktreePath {
            handleRename(updated)
        }
    }

    // MARK: - Close Tab

    func closeCurrentTab() {
        closeTab(at: currentTabIndex)
    }

    private func closeTab(at index: Int) {
        // Cannot close the primary tab
        if index == primaryTabIndex { return }
        guard index < thread.tmuxSessionNames.count else { return }

        let sessionName = thread.tmuxSessionNames[index]

        let alert = NSAlert()
        alert.messageText = "Close Tab"
        alert.informativeText = "This will close the terminal session. Are you sure?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            do {
                // Find the index by session name in the manager's model (may differ from local index)
                guard let managerThread = self.threadManager.threads.first(where: { $0.id == self.thread.id }),
                      let managerIndex = managerThread.tmuxSessionNames.firstIndex(of: sessionName) else {
                    throw ThreadManagerError.invalidTabIndex
                }
                try await threadManager.removeTab(from: thread, at: managerIndex)
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                    }

                    self.terminalViews[index].removeFromSuperview()
                    self.terminalViews.remove(at: index)

                    self.tabItems.remove(at: index)

                    // Adjust pinnedCount and primaryTabIndex
                    if index < self.pinnedCount {
                        self.pinnedCount -= 1
                    }
                    if self.primaryTabIndex > index {
                        self.primaryTabIndex -= 1
                    }

                    self.rebindTabActions()
                    self.rebuildTabBar()

                    let newIndex = min(index, self.tabItems.count - 1)
                    if newIndex >= 0 {
                        self.selectTab(at: newIndex)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Error"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Rename Dialog

    private func showTabRenameDialog(at index: Int) {
        guard index < thread.tmuxSessionNames.count else { return }
        let sessionName = thread.tmuxSessionNames[index]
        let currentCustomName = thread.customTabNames[sessionName]
        let defaultName = index == 0 ? "Main" : "Tab \(index)"

        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = currentCustomName ?? ""
        textField.placeholderString = defaultName
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != currentCustomName else { return }

        Task {
            do {
                try await threadManager.renameTab(
                    threadId: thread.id,
                    sessionName: sessionName,
                    newDisplayName: newName
                )
                await MainActor.run {
                    if let updated = self.threadManager.threads.first(where: { $0.id == self.thread.id }) {
                        self.thread = updated
                        // Update tab label
                        if index < self.tabItems.count {
                            self.tabItems[index].titleLabel.stringValue = updated.displayName(
                                for: updated.tmuxSessionNames[index],
                                at: index
                            )
                        }
                        // Re-bind closures in case session name changed
                        self.handleRename(updated)
                    }
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Rename Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Loading Overlay

    private func setupLoadingOverlay() {
        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Starting agent...")
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        view.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        loadingOverlay = overlay

        let sessionName: String
        if thread.isMain {
            let settings = PersistenceService.shared.loadSettings()
            let sanitizedName = ThreadManager.sanitizeForTmux(
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            sessionName = thread.tmuxSessionNames.first ?? "magent-main-\(sanitizedName)"
        } else {
            sessionName = thread.tmuxSessionNames.first ?? "magent-\(thread.name)"
        }
        let startTime = Date()
        let maxWait: TimeInterval = 15

        loadingPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= maxWait {
                timer.invalidate()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.loadingPollTimer = nil
                    self.dismissLoadingOverlay()
                }
                return
            }

            Task {
                let ready = await self.isAgentReady(sessionName: sessionName)
                if ready {
                    await MainActor.run {
                        self.loadingPollTimer?.invalidate()
                        self.loadingPollTimer = nil
                        self.dismissLoadingOverlay()
                    }
                }
            }
        }
    }

    private func isAgentReady(sessionName: String) async -> Bool {
        let result = await ShellExecutor.execute(
            "tmux capture-pane -t '\(sessionName)' -p 2>/dev/null"
        )
        guard result.exitCode == 0 else { return false }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.contains("╭") || output.contains("Claude") || output.count > 50
    }

    private func dismissLoadingOverlay() {
        guard let overlay = loadingOverlay else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadingOverlay?.removeFromSuperview()
                self?.loadingOverlay = nil
            }
        }
    }

    private func performWithSpinner(message: String, errorTitle: String, work: @escaping () async throws -> Void) {
        guard let window = view.window else { return }

        let sheetVC = NSViewController()
        sheetVC.view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheetVC.view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: sheetVC.view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: sheetVC.view.centerYAnchor),
        ])

        window.contentViewController?.presentAsSheet(sheetVC)

        Task {
            do {
                try await work()
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                }
            } catch {
                await MainActor.run {
                    window.contentViewController?.dismiss(sheetVC)
                    let alert = NSAlert()
                    alert.messageText = errorTitle
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - NSGestureRecognizerDelegate

extension ThreadDetailViewController: NSGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? NSPanGestureRecognizer,
              let tabView = pan.view as? TabItemView else { return true }

        let location = pan.location(in: tabView)
        let closeBounds = tabView.closeButton.convert(tabView.closeButton.bounds, to: tabView)
        if closeBounds.contains(location) { return false }

        return true
    }
}
