import Cocoa
import GhosttyBridge

// MARK: - TabItemView

final class TabItemView: NSView, NSMenuDelegate {

    let pinIcon: NSImageView
    let busySpinner: NSProgressIndicator
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

    var hasUnreadCompletion: Bool = false {
        didSet { updateIndicator() }
    }

    var hasWaitingForInput: Bool = false {
        didSet { updateIndicator() }
    }

    var hasBusy: Bool = false {
        didSet { updateIndicator() }
    }

    private func updateIndicator() {
        if hasWaitingForInput {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            completionDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            completionDot.isHidden = false
        } else if hasBusy {
            completionDot.isHidden = true
            busySpinner.isHidden = false
            busySpinner.startAnimation(nil)
        } else if hasUnreadCompletion {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            completionDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            completionDot.isHidden = false
        } else {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            completionDot.isHidden = true
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onPin: (() -> Void)?
    var onContinueIn: ((AgentType) -> Void)?
    var onExportContext: (() -> Void)?
    var availableAgentsForContinue: [AgentType] = []

    init(title: String) {
        pinIcon = NSImageView()
        busySpinner = NSProgressIndicator()
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

        // Busy spinner
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isIndeterminate = true
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        busySpinner.isHidden = true
        busySpinner.setContentHuggingPriority(.required, for: .horizontal)
        busySpinner.setContentCompressionResistancePriority(.required, for: .horizontal)

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
        let contentStack = NSStackView(views: [pinIcon, completionDot, busySpinner, titleLabel, closeButton])
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
            busySpinner.widthAnchor.constraint(equalToConstant: 10),
            busySpinner.heightAnchor.constraint(equalToConstant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Right-click menu
        let tabMenu = NSMenu()
        tabMenu.delegate = self
        menu = tabMenu

        updateAppearance()
        updateIndicator()
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

    @objc private func continueInAgentTapped(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentType else { return }
        onContinueIn?(agent)
    }

    @objc private func exportContextTapped() {
        onExportContext?()
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

        // Context transfer items
        if !availableAgentsForContinue.isEmpty || onExportContext != nil {
            menu.addItem(.separator())
        }

        if !availableAgentsForContinue.isEmpty {
            let continueItem = NSMenuItem(title: "Continue in...", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for agent in availableAgentsForContinue {
                let agentItem = NSMenuItem(
                    title: agent.displayName,
                    action: #selector(continueInAgentTapped(_:)),
                    keyEquivalent: ""
                )
                agentItem.target = self
                agentItem.representedObject = agent
                submenu.addItem(agentItem)
            }
            continueItem.submenu = submenu
            menu.addItem(continueItem)
        }

        if onExportContext != nil {
            let exportItem = NSMenuItem(
                title: "Export as Markdown...",
                action: #selector(exportContextTapped),
                keyEquivalent: ""
            )
            exportItem.target = self
            menu.addItem(exportItem)
        }
    }
}

// MARK: - ThreadDetailViewController

final class ThreadDetailViewController: NSViewController {

    private static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    private static let lastOpenedSessionDefaultsKey = "MagentLastOpenedSessionName"

    var thread: MagentThread
    let threadManager = ThreadManager.shared
    let tabBarStack = NSStackView()
    let terminalContainer = NSView()
    let openPRButton = NSButton()
    let openInXcodeButton = NSButton()
    let openInFinderButton = NSButton()
    let archiveThreadButton = NSButton()
    let exportContextButton = NSButton()
    let addTabButton = NSButton()

    var tabItems: [TabItemView] = []
    var terminalViews: [TerminalSurfaceView] = []
    var currentTabIndex = 0
    /// Index of the non-closable "primary" tab. -1 means all tabs are closable (main threads).
    var primaryTabIndex = 0
    var pinnedCount = 0
    var loadingOverlay: NSView?
    var loadingPollTimer: Timer?
    private var emptyStateView: NSView?

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
        refreshXcodeButton()
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

        // Observe agent waiting-for-input notifications for tab dot indicators
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentWaitingNotification(_:)),
            name: .magentAgentWaitingForInput,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentBusyNotification(_:)),
            name: .magentAgentBusySessionsChanged,
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

        openInXcodeButton.bezelStyle = .texturedRounded
        openInXcodeButton.image = xcodeButtonImage()
        openInXcodeButton.imageScaling = .scaleProportionallyDown
        openInXcodeButton.target = self
        openInXcodeButton.action = #selector(openInXcodeTapped)
        openInXcodeButton.toolTip = "Open in Xcode"
        openInXcodeButton.isHidden = true

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

        exportContextButton.bezelStyle = .texturedRounded
        exportContextButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export Context")
        exportContextButton.target = self
        exportContextButton.action = #selector(exportContextButtonTapped)
        exportContextButton.toolTip = "Export terminal context as Markdown"

        addTabButton.bezelStyle = .texturedRounded
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        addTabButton.target = self
        addTabButton.action = #selector(addTabTapped)

        let separator = VerticalSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.setContentHuggingPriority(.required, for: .horizontal)
        separator.setContentCompressionResistancePriority(.required, for: .horizontal)
        separator.setContentHuggingPriority(.required, for: .vertical)
        separator.setContentCompressionResistancePriority(.required, for: .vertical)

        let topBar = NSStackView(views: [tabBarStack, openInXcodeButton, openInFinderButton, openPRButton, exportContextButton, separator, archiveThreadButton, addTabButton])
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
                createTabItem(title: title, closable: true, pinned: i < pinnedCount)

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

            // Initialize indicator dots from thread model
            for (i, sessionName) in orderedSessions.enumerated() where i < tabItems.count {
                tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
            }

            selectTab(at: initialIndex)
        }
    }

    func makeTerminalView(for sessionName: String) -> TerminalSurfaceView {
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
        let wd = thread.worktreePath
        let projectPath: String
        if thread.isMain {
            projectPath = wd
        } else {
            projectPath = project?.repoPath ?? wd
        }

        var envParts = [
            "export MAGENT_PROJECT_PATH=\(projectPath)",
            "export MAGENT_PROJECT_NAME=\(projectName)",
        ]
        if thread.isMain {
            envParts.append("export MAGENT_WORKTREE_NAME=main")
        } else {
            envParts.append("export MAGENT_WORKTREE_PATH=\(wd)")
            envParts.append("export MAGENT_WORKTREE_NAME=\(thread.name)")
        }
        let envExports = envParts.joined(separator: " && ")

        let startCmd: String
        if isAgentSession, let selectedAgentType {
            let unset = selectedAgentType == .claude ? " && unset CLAUDECODE" : ""
            var command = settings.command(for: selectedAgentType)
            if selectedAgentType == .claude {
                command += " --settings /tmp/magent-claude-hooks.json"
            }
            startCmd = "\(envExports) && cd \(wd)\(unset) && \(command); exec $SHELL -l"
        } else {
            startCmd = "\(envExports) && cd \(wd) && exec $SHELL -l"
        }

        if isAgentSession {
            return "/bin/sh -c 'tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(wd)\" \"\(startCmd)\" && tmux attach-session -t \(sessionName); }'"
        }
        // Force cwd on every open for terminal tabs, even if shell init changes it.
        return "/bin/sh -c 'tmux send-keys -t \(sessionName) \"cd \(wd)\" Enter 2>/dev/null; tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \"\(wd)\" \"\(startCmd)\" && tmux send-keys -t \(sessionName) \"cd \(wd)\" Enter && tmux attach-session -t \(sessionName); }'"
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

        thread.unreadCompletionSessions = unreadSessions
        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasUnreadCompletion = unreadSessions.contains(sessionName)
        }
    }

    @objc private func handleAgentWaitingNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let waitingSessions = userInfo["waitingSessions"] as? Set<String> else { return }

        thread.waitingForInputSessions = waitingSessions
        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasWaitingForInput = waitingSessions.contains(sessionName)
        }
    }

    @objc private func handleAgentBusyNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let busySessions = userInfo["busySessions"] as? Set<String> else { return }

        thread.busySessions = busySessions
        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasBusy = busySessions.contains(sessionName)
        }
    }

    // MARK: - Tab Bar Layout

    func rebuildTabBar() {
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

    func createTabItem(title: String, closable: Bool, pinned: Bool = false) {
        let index = tabItems.count
        let settings = PersistenceService.shared.loadSettings()
        let item = TabItemView(title: title)
        item.showCloseButton = closable
        item.showPinIcon = pinned
        item.onSelect = { [weak self] in self?.selectTab(at: index) }
        item.onClose = { [weak self] in self?.closeTab(at: index) }
        item.onRename = { [weak self] in self?.showTabRenameDialog(at: index) }
        item.onPin = { [weak self] in self?.togglePin(at: index) }
        item.onContinueIn = { [weak self] agent in self?.continueTabInAgent(at: index, targetAgent: agent) }
        item.onExportContext = { [weak self] in self?.exportTabContext(at: index) }
        item.availableAgentsForContinue = settings.availableActiveAgents

        // Pan gesture for drag-to-reorder
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTabDrag(_:)))
        pan.delegate = self
        item.addGestureRecognizer(pan)

        tabItems.append(item)
    }

    func selectTab(at index: Int) {
        guard index < terminalViews.count else { return }

        for (i, item) in tabItems.enumerated() {
            item.isSelected = (i == index)
        }

        let terminalView = terminalViews[index]

        // Lazily add the view to the container on first selection (creates the surface).
        // On subsequent selections just show/hide to avoid destroying and recreating
        // the ghostty surface, which causes a visible tmux re-attach scroll animation.
        if terminalView.superview == nil {
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            terminalContainer.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            ])
        }

        for (i, tv) in terminalViews.enumerated() {
            tv.isHidden = (i != index)
        }

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

            // Clear unread completion and waiting dots for this tab
            tabItems[index].hasUnreadCompletion = false
            tabItems[index].hasWaitingForInput = false
            threadManager.markSessionCompletionSeen(threadId: thread.id, sessionName: sessionName)
            threadManager.markSessionWaitingSeen(threadId: thread.id, sessionName: sessionName)
        }
    }

    func showEmptyState() {
        guard emptyStateView == nil else { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "plus.message", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .thin)

        let label = NSTextField(labelWithString: "No open tabs")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Press + in the top right to add a tab")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label, hint])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        terminalContainer.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            container.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])

        emptyStateView = container
    }

    func hideEmptyState() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
    }

    func rebindTabActions() {
        let settings = PersistenceService.shared.loadSettings()
        for (i, item) in tabItems.enumerated() {
            item.onSelect = { [weak self] in self?.selectTab(at: i) }
            item.onClose = { [weak self] in self?.closeTab(at: i) }
            item.onRename = { [weak self] in self?.showTabRenameDialog(at: i) }
            item.onPin = { [weak self] in self?.togglePin(at: i) }
            item.onContinueIn = { [weak self] agent in self?.continueTabInAgent(at: i, targetAgent: agent) }
            item.onExportContext = { [weak self] in self?.exportTabContext(at: i) }
            item.availableAgentsForContinue = settings.availableActiveAgents
            item.showCloseButton = true
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

    func moveTab(from source: Int, to dest: Int) {
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

    func persistTabOrder() {
        threadManager.reorderTabs(for: thread.id, newOrder: thread.tmuxSessionNames)
        let pinnedSessions = (0..<pinnedCount).compactMap { i -> String? in
            guard i < thread.tmuxSessionNames.count else { return nil }
            return thread.tmuxSessionNames[i]
        }
        threadManager.updatePinnedTabs(for: thread.id, pinnedSessions: pinnedSessions)
    }

}

private final class VerticalSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}
