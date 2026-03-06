import Cocoa
import GhosttyBridge

// MARK: - ThreadDetailViewController

final class ThreadDetailViewController: NSViewController {

    static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    static let lastOpenedSessionDefaultsKey = "MagentLastOpenedSessionName"
    static let promptTOCPositionDefaultsPrefix = "MagentPromptTOCPosition"
    static let promptTOCSizeDefaultsPrefix = "MagentPromptTOCSize"
    static let promptTOCVisibilityDefaultsKey = "MagentPromptTOCVisibilityHidden"
    static let promptTOCMinimumWidth: CGFloat = 320
    static let promptTOCMinimumHeight: CGFloat = 250

    var thread: MagentThread
    let threadManager = ThreadManager.shared
    let tabBarStack = NSStackView()
    let terminalContainer = NSView()
    let openPRButton = NSButton()
    let openInJiraButton = NSButton()
    let openInXcodeButton = NSButton()
    let openInFinderButton = NSButton()
    let archiveThreadButton = NSButton()
    let reviewButton = NSButton()
    let exportContextButton = NSButton()
    let scrollPageUpButton = NSButton()
    let scrollPageDownButton = NSButton()
    let scrollToBottomButton = NSButton()
    let togglePromptTOCButton = NSButton()
    let addTabButton = NSButton()
    let floatingScrollToBottomButton = NSButton()

    var tabItems: [TabItemView] = []
    var terminalViews: [TerminalSurfaceView] = []
    var currentTabIndex = 0
    /// Index of the non-closable "primary" tab. -1 means all tabs are closable (main threads).
    var primaryTabIndex = 0
    var pinnedCount = 0
    var loadingOverlay: NSView?
    var loadingDetailLabel: NSTextField?
    var loadingPollTimer: Timer?
    var loadingOverlaySessionName: String?
    var emptyStateView: NSView?
    var promptTOCView: PromptTableOfContentsView?
    var promptTOCTopConstraint: NSLayoutConstraint?
    var promptTOCTrailingConstraint: NSLayoutConstraint?
    var promptTOCWidthConstraint: NSLayoutConstraint?
    var promptTOCHeightConstraint: NSLayoutConstraint?
    var promptTOCRefreshTask: Task<Void, Never>?
    var promptTOCEntries: [PromptTOCEntry] = []
    var promptTOCSessionName: String?
    var promptTOCDragStartOrigin: NSPoint = .zero
    var promptTOCResizeStartSize: NSSize = .zero
    var promptTOCResizeStartTop: CGFloat = 0
    var promptTOCResizeStartTrailing: CGFloat = 0
    var promptTOCCanShowForCurrentTab = false

    // MARK: - Inline Diff Viewer
    var diffVC: InlineDiffViewController?
    var isLoadingDiffViewer = false
    var terminalBottomToView: NSLayoutConstraint?
    var terminalBottomToDiff: NSLayoutConstraint?
    var diffHeightConstraint: NSLayoutConstraint?
    var isDiffDragging = false
    var diffDragStartHeight: CGFloat = 0
    static let diffMinHeight: CGFloat = 100
    static let diffDefaultRatio: CGFloat = 0.7
    static let diffHeightKey = "InlineDiffViewController.height"

    let pinSeparator: NSView = {
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
        refreshJiraButton()
        refreshXcodeButton()
        refreshReviewButtonVisibility()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentRateLimitNotification(_:)),
            name: .magentAgentRateLimitChanged,
            object: nil
        )

        // Observe PR info changes for button title updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePullRequestInfoChanged),
            name: .magentPullRequestInfoChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptTOCVisibilityChanged),
            name: .magentPromptTOCVisibilityChanged,
            object: nil
        )

        // Observe diff viewer open/close requests from sidebar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowDiffViewerNotification(_:)),
            name: .magentShowDiffViewer,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideDiffViewerNotification),
            name: .magentHideDiffViewer,
            object: nil
        )

        // Observe ghostty scrollbar updates to show/hide floating scroll-to-bottom button
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollbarUpdate(_:)),
            name: GhosttyAppManager.ghosttyScrollbarUpdated,
            object: nil
        )

        Task {
            await setupTabs()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        clampPromptTOCPositionIfNeeded()
    }

    deinit {
        promptTOCRefreshTask?.cancel()
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

        openInJiraButton.bezelStyle = .texturedRounded
        openInJiraButton.image = jiraButtonImage()
        openInJiraButton.imageScaling = .scaleProportionallyDown
        openInJiraButton.target = self
        openInJiraButton.action = #selector(openInJiraTapped)
        openInJiraButton.toolTip = "Open in Jira"
        openInJiraButton.isHidden = true

        openInXcodeButton.bezelStyle = .texturedRounded
        openInXcodeButton.imageScaling = .scaleProportionallyDown
        openInXcodeButton.target = self
        openInXcodeButton.action = #selector(openInXcodeTapped)
        openInXcodeButton.toolTip = "Open project"
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

        reviewButton.bezelStyle = .texturedRounded
        reviewButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Review Changes")
        reviewButton.target = self
        reviewButton.action = #selector(reviewButtonTapped)
        reviewButton.toolTip = "Open a new agent tab to review branch changes"
        reviewButton.isHidden = true

        exportContextButton.bezelStyle = .texturedRounded
        exportContextButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export Context")
        exportContextButton.target = self
        exportContextButton.action = #selector(exportContextButtonTapped)
        exportContextButton.toolTip = "Export terminal context as Markdown"

        scrollPageUpButton.bezelStyle = .texturedRounded
        scrollPageUpButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Scroll Up")
        scrollPageUpButton.imageScaling = .scaleProportionallyDown
        scrollPageUpButton.target = self
        scrollPageUpButton.action = #selector(scrollTerminalPageUpTapped)
        scrollPageUpButton.toolTip = "Scroll terminal up one page via tmux history"
        scrollPageUpButton.isEnabled = false

        scrollPageDownButton.bezelStyle = .texturedRounded
        scrollPageDownButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Scroll Down")
        scrollPageDownButton.imageScaling = .scaleProportionallyDown
        scrollPageDownButton.target = self
        scrollPageDownButton.action = #selector(scrollTerminalPageDownTapped)
        scrollPageDownButton.toolTip = "Scroll terminal down one page via tmux history"
        scrollPageDownButton.isEnabled = false

        scrollToBottomButton.bezelStyle = .texturedRounded
        scrollToBottomButton.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Jump to Bottom")
        scrollToBottomButton.imageScaling = .scaleProportionallyDown
        scrollToBottomButton.target = self
        scrollToBottomButton.action = #selector(scrollTerminalToBottomTapped)
        scrollToBottomButton.toolTip = "Jump back to live terminal output"
        scrollToBottomButton.isEnabled = false

        togglePromptTOCButton.bezelStyle = .texturedRounded
        togglePromptTOCButton.imageScaling = .scaleProportionallyDown
        togglePromptTOCButton.target = self
        togglePromptTOCButton.action = #selector(togglePromptTOCTapped)

        addTabButton.bezelStyle = .texturedRounded
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        addTabButton.target = self
        addTabButton.action = #selector(addTabTapped)
        updatePromptTOCToggleButtonState(canShow: false)

        let separator = VerticalSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = thread.isMain
        separator.setContentHuggingPriority(.required, for: .horizontal)
        separator.setContentCompressionResistancePriority(.required, for: .horizontal)
        separator.setContentHuggingPriority(.required, for: .vertical)
        separator.setContentCompressionResistancePriority(.required, for: .vertical)

        let topBar = NSStackView(views: [addTabButton, tabBarStack, openInXcodeButton, openInFinderButton, openPRButton, openInJiraButton, reviewButton, exportContextButton, scrollPageUpButton, scrollPageDownButton, scrollToBottomButton, togglePromptTOCButton, separator, archiveThreadButton])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor

        view.addSubview(topBar)
        view.addSubview(terminalContainer)
        setupPromptTOCOverlay()

        terminalBottomToView = terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 32),

            terminalContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalBottomToView!,
        ])

        setupScrollFAB()
    }

    // MARK: - Tab Setup

    private func setupTabs() async {
        if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
            thread = latest
        }

        let settings = PersistenceService.shared.loadSettings()
        let selectedAgentType = thread.effectiveAgentType ?? threadManager.effectiveAgentType(for: thread.projectId)

        // Determine tab order with pinned tabs first
        let pinnedSet = Set(thread.pinnedTmuxSessions)

        var sessions: [String] = thread.tmuxSessionNames
        if sessions.isEmpty {
            // Thread has no sessions — create a fallback and register it in the manager
            // so that recreateSessionIfNeeded sees it as an agent session and close-tab works.
            let slug = TmuxSessionNaming.repoSlug(from:
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            let firstTabSlug = TmuxSessionNaming.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: selectedAgentType))
            let fallbackName: String
            if thread.isMain {
                fallbackName = TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: nil, tabSlug: firstTabSlug)
            } else {
                fallbackName = TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: thread.name, tabSlug: firstTabSlug)
            }
            sessions = [fallbackName]
            threadManager.registerFallbackSession(fallbackName, for: thread.id, agentType: selectedAgentType)
            // Refresh local copy after manager update
            if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
                thread = latest
            }
        }

        let pinned = sessions.filter { pinnedSet.contains($0) }
        let unpinned = sessions.filter { !pinnedSet.contains($0) }
        let orderedSessions = pinned + unpinned
        pinnedCount = pinned.count

        for (i, sessionName) in orderedSessions.enumerated() {
            // Ensure the session exists and matches this thread context.
            _ = await threadManager.recreateSessionIfNeeded(
                sessionName: sessionName,
                thread: thread,
                onAction: { [weak self] action in
                    guard let self,
                          sessionName == self.loadingOverlaySessionName else { return }
                    self.updateLoadingOverlayDetail(action?.loadingOverlayDetail)
                }
            )

            await MainActor.run {
                let title = thread.displayName(for: sessionName, at: i)
                createTabItem(title: title, closable: true, pinned: i < pinnedCount)

                let terminalView = makeTerminalView(for: sessionName)
                terminalViews.append(terminalView)
            }
        }

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
                tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
                tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
            }

            selectTab(at: initialIndex)
        }
    }

    func currentSessionName() -> String? {
        guard currentTabIndex >= 0, currentTabIndex < thread.tmuxSessionNames.count else { return nil }
        return thread.tmuxSessionNames[currentTabIndex]
    }

    func updateTerminalScrollControlsState() {
        let hasSession = currentSessionName() != nil
        scrollPageUpButton.isEnabled = hasSession
        scrollPageDownButton.isEnabled = hasSession
        scrollToBottomButton.isEnabled = hasSession
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
        let selectedAgentType = thread.effectiveAgentType ?? threadManager.effectiveAgentType(for: thread.projectId)

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

        let envExportsWithSocket = envExports + " && export MAGENT_SOCKET=\(IPCSocketServer.socketPath)"

        let startCmd: String
        if isAgentSession, let selectedAgentType {
            let resumeSessionID = thread.sessionConversationIDs[sessionName]
            startCmd = threadManager.agentStartCommand(
                settings: settings,
                projectId: thread.projectId,
                agentType: selectedAgentType,
                envExports: envExportsWithSocket,
                workingDirectory: wd,
                resumeSessionID: resumeSessionID
            )
        } else {
            startCmd = "\(envExportsWithSocket) && cd \(wd) && exec $SHELL -l"
        }

        let sq = ShellExecutor.shellQuote
        let quotedWd = sq(wd)
        let quotedStartCmd = sq(startCmd)

        if isAgentSession {
            let tmuxInner = "tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \(quotedWd) \(quotedStartCmd) && tmux attach-session -t \(sessionName); }"
            return "/bin/sh -c \(sq(tmuxInner))"
        }
        // Force cwd on every open for terminal tabs, even if shell init changes it.
        let quotedCdWd = sq("cd \(wd)")
        let tmuxInner = "tmux send-keys -t \(sessionName) \(quotedCdWd) Enter 2>/dev/null; tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \(quotedWd) \(quotedStartCmd) && tmux send-keys -t \(sessionName) \(quotedCdWd) Enter && tmux attach-session -t \(sessionName); }"
        return "/bin/sh -c \(sq(tmuxInner))"
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
        refreshDiffViewerIfVisible()
        syncTransientState()
        schedulePromptTOCRefresh()
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
        syncTransientState()
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
        syncTransientState()
    }

    @objc private func handleAgentRateLimitNotification(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == thread.id,
              let latest = threadManager.threads.first(where: { $0.id == thread.id }) else { return }

        thread.rateLimitedSessions = latest.rateLimitedSessions
        for (i, sessionName) in thread.tmuxSessionNames.enumerated() where i < tabItems.count {
            tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
            tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
        }
    }

    @objc private func handlePullRequestInfoChanged() {
        syncTransientState()
    }

    @objc private func handleShowDiffViewerNotification(_ notification: Notification) {
        let filePath = notification.userInfo?["filePath"] as? String
        showDiffViewer(scrollToFile: filePath)
    }

    @objc private func handleHideDiffViewerNotification() {
        hideDiffViewer()
    }

}

private final class VerticalSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}
