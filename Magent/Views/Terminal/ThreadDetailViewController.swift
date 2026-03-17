import Cocoa
import GhosttyBridge
import MagentCore

// MARK: - AppBackgroundView

/// NSView that keeps its layer background synced with the .appBackground color asset
/// across both light and dark appearance changes.
final class AppBackgroundView: NSView {
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
        onEffectiveAppearanceChanged?()
    }

    private func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        }
    }
}

// MARK: - ThreadDetailViewController

final class ThreadDetailViewController: NSViewController {

    static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    static let lastOpenedSessionDefaultsKey = "MagentLastOpenedSessionName"
    static let promptTOCPositionDefaultsPrefix = "MagentPromptTOCPosition"
    static let promptTOCSizeDefaultsPrefix = "MagentPromptTOCSize"
    static let promptTOCVisibilityDefaultsKey = "MagentPromptTOCVisibilityHidden"
    static let promptTOCMinimumWidth: CGFloat = 320
    static let promptTOCMinimumHeight: CGFloat = 250
    static let promptTOCCollapsedWidth: CGFloat = 185
    static let promptTOCCollapsedHeight: CGFloat = 36

    var thread: MagentThread
    let threadManager = ThreadManager.shared
    let tabBarStack = NSStackView()
    let terminalContainer: NSView = AppBackgroundView()
    let topBar = NSStackView()
    let openPRButton = NSButton()
    let openInJiraButton = NSButton()
    let openInXcodeButton = NSButton()
    let openInFinderButton = NSButton()
    let resyncLocalPathsButton = NSButton()
    let resyncLocalPathsSpinner = NSProgressIndicator()
    let archiveThreadButton = NSButton()
    let reviewButton = NSButton()
    let exportContextButton = NSButton()
    let scrollOverlay = TerminalScrollOverlayView()
    let togglePromptTOCButton = NSButton()
    let addTabButton = NSButton()
    let floatingScrollToBottomButton = TerminalScrollToBottomPillButton()

    var tabItems: [TabItemView] = []
    var terminalViews: [TerminalSurfaceView] = []
    var currentTabIndex = 0
    /// Index of the non-closable "primary" tab. -1 means all tabs are closable (main threads).
    var primaryTabIndex = 0
    var pinnedCount = 0
    var loadingOverlay: NSView?
    var loadingLabel: NSTextField?
    var loadingDetailLabel: NSTextField?
    var loadingPollTimer: Timer?
    var loadingOverlaySessionName: String?
    /// Set to true while `injectAfterStart` has a prompt in-flight; prevents the
    /// poll timer from dismissing the overlay before keys are actually sent.
    var loadingOverlayWaitingForInjection = false
    var loadingOverlayInjectionObservers: [NSObjectProtocol] = []
    var preparedSessions: Set<String> = []
    var sessionPreparationTasks: [String: Task<Void, Never>] = [:]
    var backgroundSessionPreparationTask: Task<Void, Never>?
    var emptyStateView: NSView?
    var promptTOCView: PromptTableOfContentsView?
    var promptTOCTopConstraint: NSLayoutConstraint?
    var promptTOCTrailingConstraint: NSLayoutConstraint?
    var promptTOCWidthConstraint: NSLayoutConstraint?
    var promptTOCHeightConstraint: NSLayoutConstraint?
    var promptTOCRefreshTask: Task<Void, Never>?
    var promptTOCEntries: [PromptTOCEntry] = []
    var promptTOCSessionName: String?
    var scrollOverlayTrailingConstraint: NSLayoutConstraint?
    var scrollOverlayBottomConstraint: NSLayoutConstraint?
    var scrollOverlayDragStartTrailing: CGFloat = 16
    var scrollOverlayDragStartBottom: CGFloat = 16
    var scrollFABRefreshTask: Task<Void, Never>?
    var isScrollFABVisible = false
    var scrollFABAnimationGeneration: UInt = 0

    var promptTOCDragStartOrigin: NSPoint = .zero
    var promptTOCExpandedSize: NSSize = NSSize(width: 320, height: 250)
    var promptTOCResizeStartSize: NSSize = .zero
    var promptTOCResizeStartTop: CGFloat = 0
    var promptTOCResizeStartTrailing: CGFloat = 0
    var promptTOCCanShowForCurrentTab = false
    var showScrollToBottomIndicator = true
    var showTerminalScrollOverlay = true
    var showPromptTOCOverlay = true
    var currentTerminalMouseWheelBehavior: TerminalMouseWheelBehavior?

    // MARK: - Inline Diff Viewer
    var diffVC: InlineDiffViewController?
    var isLoadingDiffViewer = false
    /// The commit hash currently shown in the diff viewer, or nil for working-tree diff.
    var currentDiffCommitHash: String? = nil
    /// When true, the diff viewer shows working-tree changes only (ignores base branch).
    var currentDiffForceWorkingTree: Bool = false
    var terminalBottomToView: NSLayoutConstraint?
    var terminalBottomToDiff: NSLayoutConstraint?
    var diffHeightConstraint: NSLayoutConstraint?
    var diffImageOverlay: DiffImageOverlayView?
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
        let rootView = AppBackgroundView()
        rootView.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshTerminalChromeAppearance()
        }
        view = rootView
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
        ensureLoadingOverlay()
        currentTerminalMouseWheelBehavior = PersistenceService.shared.loadSettings().terminalMouseWheelBehavior

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged(_:)),
            name: .magentSettingsDidChange,
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThreadCreationFinished(_:)),
            name: .magentThreadCreationFinished,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabWillCloseNotification(_:)),
            name: .magentTabWillClose,
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
        scrollFABRefreshTask?.cancel()
        backgroundSessionPreparationTask?.cancel()
        sessionPreparationTasks.values.forEach { $0.cancel() }
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
        openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenInJira)
        openInJiraButton.isHidden = true

        openInXcodeButton.bezelStyle = .texturedRounded
        openInXcodeButton.imageScaling = .scaleProportionallyDown
        openInXcodeButton.target = self
        openInXcodeButton.action = #selector(openInXcodeTapped)
        openInXcodeButton.toolTip = String(localized: .ThreadStrings.threadOpenProject)
        openInXcodeButton.isHidden = true

        openInFinderButton.bezelStyle = .texturedRounded
        openInFinderButton.image = finderButtonImage()
        openInFinderButton.imageScaling = .scaleProportionallyDown
        openInFinderButton.target = self
        openInFinderButton.action = #selector(openInFinderTapped)
        openInFinderButton.toolTip = thread.isMain
            ? String(localized: .ThreadStrings.threadOpenProjectRootInFinder)
            : String(localized: .ThreadStrings.threadOpenWorktreeInFinder)

        resyncLocalPathsButton.bezelStyle = .texturedRounded
        resyncLocalPathsButton.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Resync Local Paths"
        )
        resyncLocalPathsButton.imageScaling = .scaleProportionallyDown
        resyncLocalPathsButton.target = self
        resyncLocalPathsButton.action = #selector(resyncLocalPathsTapped)
        resyncLocalPathsButton.toolTip = "Resync Local Sync Paths"
        resyncLocalPathsButton.isHidden = resyncLocalPathsButtonShouldBeHidden()


        resyncLocalPathsSpinner.style = .spinning
        resyncLocalPathsSpinner.controlSize = .small
        resyncLocalPathsSpinner.isDisplayedWhenStopped = false
        resyncLocalPathsSpinner.translatesAutoresizingMaskIntoConstraints = false
        resyncLocalPathsSpinner.isHidden = resyncLocalPathsButtonShouldBeHidden()

        archiveThreadButton.bezelStyle = .texturedRounded
        archiveThreadButton.image = NSImage(
            systemSymbolName: "archivebox",
            accessibilityDescription: String(localized: .ThreadStrings.threadArchiveTitle)
        )
        archiveThreadButton.target = self
        archiveThreadButton.action = #selector(archiveThreadTapped)
        archiveThreadButton.isHidden = thread.isMain

        reviewButton.bezelStyle = .texturedRounded
        reviewButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: String(localized: .NotificationStrings.reviewChanges))
        reviewButton.target = self
        reviewButton.action = #selector(reviewButtonTapped)
        reviewButton.toolTip = String(localized: .NotificationStrings.reviewButtonTooltip)
        reviewButton.isHidden = true

        exportContextButton.bezelStyle = .texturedRounded
        exportContextButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: .NotificationStrings.contextExport))
        exportContextButton.target = self
        exportContextButton.action = #selector(exportContextButtonTapped)
        exportContextButton.toolTip = "Export terminal context as Markdown"

        togglePromptTOCButton.bezelStyle = .texturedRounded
        togglePromptTOCButton.imageScaling = .scaleProportionallyDown
        togglePromptTOCButton.target = self
        togglePromptTOCButton.action = #selector(togglePromptTOCTapped)

        addTabButton.bezelStyle = .texturedRounded
        addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
        addTabButton.target = self
        addTabButton.action = #selector(addTabTapped)
        let addTabContextMenu = NSMenu()
        addTabContextMenu.delegate = self
        addTabButton.menu = addTabContextMenu
        updatePromptTOCToggleButtonState(canShow: false)

        let separator = VerticalSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = thread.isMain
        separator.setContentHuggingPriority(.required, for: .horizontal)
        separator.setContentCompressionResistancePriority(.required, for: .horizontal)
        separator.setContentHuggingPriority(.required, for: .vertical)
        separator.setContentCompressionResistancePriority(.required, for: .vertical)

        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.alignment = .centerY
        topBar.translatesAutoresizingMaskIntoConstraints = false
        for view in [addTabButton, tabBarStack, openInXcodeButton, openInFinderButton, openPRButton, openInJiraButton, reviewButton, exportContextButton, resyncLocalPathsButton, resyncLocalPathsSpinner, separator, archiveThreadButton] {
            topBar.addArrangedSubview(view)
        }

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        (terminalContainer as? AppBackgroundView)?.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshTerminalChromeAppearance()
        }

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
        setupScrollOverlay()
        refreshOverlayVisibilitySettings()
        refreshTerminalChromeAppearance()
    }

    // MARK: - Tab Setup

    private func setupTabs() async {
        // If the thread is still being created (worktree + tmux setup in progress),
        // show the creation overlay and wait for the magentThreadCreationFinished notification.
        if threadManager.pendingThreadIds.contains(thread.id) {
            await MainActor.run { showCreationOverlay() }
            return
        }

        if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
            thread = latest
        }

        let settings = PersistenceService.shared.loadSettings()
        let defaultAgentType = threadManager.effectiveAgentType(for: thread.projectId)

        // Determine tab order with pinned tabs first
        let pinnedSet = Set(thread.pinnedTmuxSessions)

        var sessions: [String] = thread.tmuxSessionNames
        if sessions.isEmpty {
            // Thread has no sessions — create a fallback and register it in the manager
            // so that recreateSessionIfNeeded sees it as an agent session and close-tab works.
            let slug = TmuxSessionNaming.repoSlug(from:
                settings.projects.first(where: { $0.id == thread.projectId })?.name ?? "project"
            )
            let firstTabSlug = TmuxSessionNaming.sanitizeForTmux(TmuxSessionNaming.defaultTabDisplayName(for: defaultAgentType))
            let fallbackName: String
            if thread.isMain {
                fallbackName = TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: nil, tabSlug: firstTabSlug)
            } else {
                fallbackName = TmuxSessionNaming.buildSessionName(repoSlug: slug, threadName: thread.name, tabSlug: firstTabSlug)
            }
            sessions = [fallbackName]
            threadManager.registerFallbackSession(fallbackName, for: thread.id, agentType: defaultAgentType)
            // Refresh local copy after manager update
            if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
                thread = latest
            }
        }

        let pinned = sessions.filter { pinnedSet.contains($0) }
        let unpinned = sessions.filter { !pinnedSet.contains($0) }
        let orderedSessions = pinned + unpinned
        pinnedCount = pinned.count
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

        let initialSessionName = orderedSessions[initialIndex]
        let initialAgentType = await threadManager.loadingOverlayAgentType(
            for: thread,
            sessionName: initialSessionName
        )

        await MainActor.run {
            preparedSessions.removeAll()
            sessionPreparationTasks.values.forEach { $0.cancel() }
            sessionPreparationTasks.removeAll()
            backgroundSessionPreparationTask?.cancel()
            backgroundSessionPreparationTask = nil

            startLoadingOverlayTracking(sessionName: initialSessionName, agentType: initialAgentType)

            for (i, sessionName) in orderedSessions.enumerated() {
                let title = thread.displayName(for: sessionName, at: i)
                createTabItem(title: title, closable: true, pinned: i < pinnedCount)

                let terminalView = makeTerminalView(for: sessionName)
                terminalViews.append(terminalView)
            }

            rebuildTabBar()
            rebindTabActions()

            // Initialize indicator dots from thread model
            for (i, sessionName) in orderedSessions.enumerated() where i < tabItems.count {
                tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
                tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
                tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
            }
        }

        await ensureSessionPrepared(sessionName: initialSessionName) { [weak self] action in
            guard let self,
                  initialSessionName == self.loadingOverlaySessionName else { return }
            self.updateLoadingOverlayDetail(action?.loadingOverlayDetail)
        }

        await MainActor.run {
            selectPreparedTab(at: initialIndex)
            prepareSessionsInBackground(orderedSessions.enumerated().compactMap { offset, sessionName in
                offset == initialIndex ? nil : sessionName
            })
        }
    }

    func currentSessionName() -> String? {
        guard currentTabIndex >= 0, currentTabIndex < thread.tmuxSessionNames.count else { return nil }
        return thread.tmuxSessionNames[currentTabIndex]
    }

    func updateTerminalScrollControlsState() {
        refreshOverlayVisibilitySettings()
        scrollOverlay.isScrollEnabled = currentSessionName() != nil
        scheduleScrollFABVisibilityRefresh()
    }

    func refreshOverlayVisibilitySettings() {
        let settings = PersistenceService.shared.loadSettings()
        showScrollToBottomIndicator = settings.showScrollToBottomIndicator
        showTerminalScrollOverlay = settings.showTerminalScrollOverlay
        showPromptTOCOverlay = settings.showPromptTOCOverlay

        scrollOverlay.isHidden = !showTerminalScrollOverlay
        if !showScrollToBottomIndicator {
            setScrollFABVisible(false)
        }
        applyPromptTOCVisibility()
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
        view.onScroll = { [weak self] in
            self?.scheduleScrollFABVisibilityRefresh()
        }
        view.resolveTmuxMouseOpenableURL = { [sessionName = sessionName] in
            TmuxService.shared.recentMouseOpenableURL(sessionName: sessionName)
        }
        view.resolveTmuxVisibleOpenableURL = { [sessionName = sessionName] xFraction, yFraction in
            await TmuxService.shared.visibleOpenableURL(
                sessionName: sessionName,
                xFraction: xFraction,
                yFraction: yFraction
            )
        }
        return view
    }

    private func buildTmuxCommand(for sessionName: String) -> String {
        let settings = PersistenceService.shared.loadSettings()
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)
        let selectedAgentType = threadManager.effectiveAgentType(for: thread.projectId)

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
            startCmd = threadManager.terminalStartCommand(
                envExports: envExportsWithSocket,
                workingDirectory: wd
            )
        }

        let sq = ShellExecutor.shellQuote
        let quotedWd = sq(wd)
        let quotedStartCmd = sq(startCmd)
        let tmuxInner = "tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \(quotedWd) \(quotedStartCmd) && tmux attach-session -t \(sessionName); }"
        return "/bin/sh -c \(sq(tmuxInner))"
    }

    /// Handles `magentTabWillClose` posted by `removeTabBySessionName` immediately before
    /// it mutates the model.  Running synchronously on the MainActor ensures the
    /// Ghostty surface is freed (via removeFromSuperview → viewDidMoveToWindow → destroySurface)
    /// before ghostty_app_tick can see the zombie surface and crash.
    ///
    /// This covers both the IPC path (which never calls removeFromSuperview directly) and acts
    /// as an early-cleanup fast-path for the GUI path (where closeTab's MainActor.run block
    /// will subsequently find the index already gone and return via its bounds-guard).
    @objc private func handleTabWillCloseNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let sessionName = userInfo["sessionName"] as? String else { return }

        // Find the view index in our local (potentially stale) tmuxSessionNames copy.
        // We look in thread.tmuxSessionNames rather than the model because removeTabBySessionName
        // posts this notification *before* mutating threads[], so both copies still have the session.
        guard let tabIndex = thread.tmuxSessionNames.firstIndex(of: sessionName) else { return }
        guard tabIndex < terminalViews.count else { return }

        GhosttyAppManager.log("handleTabWillClose: threadId=\(threadId) session=\(sessionName) tabIndex=\(tabIndex)")

        // Remove the surface view.  This triggers viewDidMoveToWindow(nil) → destroySurface()
        // → ghostty_surface_free, preventing the zombie-surface crash.
        terminalViews[tabIndex].removeFromSuperview()
        terminalViews.remove(at: tabIndex)

        if tabIndex < tabItems.count {
            tabItems.remove(at: tabIndex)
        }

        // Keep pinnedCount / primaryTabIndex in sync.
        if tabIndex < pinnedCount { pinnedCount -= 1 }
        if tabIndex == primaryTabIndex {
            primaryTabIndex = 0
        } else if primaryTabIndex > tabIndex {
            primaryTabIndex -= 1
        }

        // Prune our local thread copy so subsequent index lookups stay correct.
        thread.tmuxSessionNames.removeAll { $0 == sessionName }
        thread.pinnedTmuxSessions.removeAll { $0 == sessionName }
        thread.customTabNames.removeValue(forKey: sessionName)
        thread.agentTmuxSessions.removeAll { $0 == sessionName }
        thread.unreadCompletionSessions.remove(sessionName)
        thread.busySessions.remove(sessionName)
        thread.waitingForInputSessions.remove(sessionName)

        rebindTabActions()
        rebuildTabBar()

        if tabItems.isEmpty {
            showEmptyState()
        } else {
            let newIndex = min(tabIndex, tabItems.count - 1)
            if newIndex != currentTabIndex || tabItems.count == terminalViews.count {
                selectTab(at: newIndex)
            }
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

    @objc private func handleThreadCreationFinished(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == thread.id else { return }

        dismissLoadingOverlay()

        guard notification.userInfo?["error"] == nil else {
            // Thread creation failed; the pending thread will be removed from the sidebar.
            return
        }

        // Thread is ready — reload tabs now that sessions exist.
        Task { await setupTabs() }
    }

    func showCreationOverlay() {
        ensureLoadingOverlay()
        loadingLabel?.stringValue = "Creating thread..."
        loadingOverlay?.alphaValue = 1
        loadingOverlay?.isHidden = false
    }

    @objc private func handlePullRequestInfoChanged() {
        syncTransientState()
    }

    @objc private func handleShowDiffViewerNotification(_ notification: Notification) {
        let filePath = notification.userInfo?["filePath"] as? String
        let commitHash = notification.userInfo?["commitHash"] as? String
        let forceWorkingTree = (notification.userInfo?["mode"] as? String) == "uncommitted"
        showDiffViewer(scrollToFile: filePath, commitHash: commitHash, forceWorkingTreeDiff: forceWorkingTree)
    }

    @objc private func handleHideDiffViewerNotification() {
        hideDiffViewer()
    }

    @objc private func handleSettingsChanged(_ notification: Notification) {
        let settings = PersistenceService.shared.loadSettings()
        let previousMouseWheelBehavior = currentTerminalMouseWheelBehavior
        currentTerminalMouseWheelBehavior = settings.terminalMouseWheelBehavior

        if let previousMouseWheelBehavior,
           previousMouseWheelBehavior != settings.terminalMouseWheelBehavior {
            // Wheel behavior is a surface-time Ghostty setting, so update the shared
            // embedded prefs before recreating any terminal surfaces.
            GhosttyAppManager.shared.applyEmbeddedPreferences(
                embeddedPreferences(for: settings),
                effectiveAppearance: view.effectiveAppearance
            )
            reloadTerminalViewsForUpdatedTerminalPreferences()
        }
        let resyncHidden = resyncLocalPathsButtonShouldBeHidden()
        resyncLocalPathsButton.isHidden = resyncHidden
        if resyncHidden { resyncLocalPathsSpinner.isHidden = true }
        refreshOverlayVisibilitySettings()
        updateTerminalScrollControlsState()
    }

    private func reloadTerminalViewsForUpdatedTerminalPreferences() {
        guard !terminalViews.isEmpty else { return }

        let selectedIndex = min(currentTabIndex, terminalViews.count - 1)
        let sessionNames = thread.tmuxSessionNames

        for terminalView in terminalViews {
            terminalView.removeFromSuperview()
        }

        terminalViews = sessionNames.map(makeTerminalView(for:))

        if sessionNames.indices.contains(selectedIndex) {
            selectTab(at: selectedIndex)
        }
    }

    func resyncLocalPathsButtonShouldBeHidden() -> Bool {
        guard !thread.isMain else { return true }
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        return project?.normalizedLocalFileSyncPaths.isEmpty ?? true
    }

    private var topBarButtons: [NSButton] {
        [
            addTabButton,
            openInXcodeButton,
            openInFinderButton,
            openPRButton,
            openInJiraButton,
            reviewButton,
            exportContextButton,
            resyncLocalPathsButton,
            archiveThreadButton,
        ]
    }

    private func refreshTerminalChromeAppearance() {
        guard isViewLoaded else { return }

        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
            terminalContainer.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
            archiveThreadButton.image = NSImage(
                systemSymbolName: "archivebox",
                accessibilityDescription: String(localized: .ThreadStrings.threadArchiveTitle)
            )
            reviewButton.image = NSImage(
                systemSymbolName: "eye",
                accessibilityDescription: String(localized: .NotificationStrings.reviewChanges)
            )
            exportContextButton.image = NSImage(
                systemSymbolName: "square.and.arrow.up",
                accessibilityDescription: String(localized: .NotificationStrings.contextExport)
            )
            resyncLocalPathsButton.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Resync Local Paths"
            )
            addTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Tab")
            updatePromptTOCToggleButtonState(canShow: promptTOCCanShowForCurrentTab)

            for button in topBarButtons {
                button.appearance = view.effectiveAppearance
                button.needsDisplay = true
            }

            topBar.needsDisplay = true
            pinSeparator.needsDisplay = true
        }
    }

    private func embeddedPreferences(for settings: AppSettings) -> GhosttyEmbeddedPreferences {
        let appearanceMode: GhosttyEmbeddedAppearanceMode
        switch settings.appAppearanceMode {
        case .system:
            appearanceMode = .system
        case .light:
            appearanceMode = .light
        case .dark:
            appearanceMode = .dark
        }

        let mouseWheelBehavior: GhosttyEmbeddedMouseWheelBehavior
        switch settings.terminalMouseWheelBehavior {
        case .magentDefaultScroll:
            mouseWheelBehavior = .magentDefaultScroll
        case .inheritGhosttyGlobal:
            mouseWheelBehavior = .inheritGhosttyGlobal
        case .allowAppsToCapture:
            mouseWheelBehavior = .allowAppsToCapture
        }

        return GhosttyEmbeddedPreferences(
            appearanceMode: appearanceMode,
            mouseWheelBehavior: mouseWheelBehavior
        )
    }

}

private final class VerticalSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}
