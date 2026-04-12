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

@MainActor
final class ReusableTerminalViewCache {
    static let shared = ReusableTerminalViewCache()

    static let maxCachedViews = 8
    static let maxIdleAge: TimeInterval = 60 * 60

    private struct Entry {
        let sessionName: String
        let view: TerminalSurfaceView
        let reuseKey: String
        let cachedAt: Date
        var lastAccessedAt: Date
    }

    private var entriesBySession: [String: Entry] = [:]
    private var fifoSessionNames: [String] = []

    func take(sessionName: String, reuseKey: String) -> TerminalSurfaceView? {
        pruneExpiredEntries()
        guard var entry = entriesBySession.removeValue(forKey: sessionName) else { return nil }
        guard entry.reuseKey == reuseKey else {
            fifoSessionNames.removeAll { $0 == sessionName }
            return nil
        }
        fifoSessionNames.removeAll { $0 == sessionName }
        entry.lastAccessedAt = Date()
        return entry.view
    }

    func store(_ view: TerminalSurfaceView, sessionName: String, reuseKey: String) {
        pruneExpiredEntries()
        remove(sessionName: sessionName)

        view.preserveSurfaceOnDetach = true
        view.removeFromSuperview()
        view.isHidden = true

        let now = Date()
        entriesBySession[sessionName] = Entry(
            sessionName: sessionName,
            view: view,
            reuseKey: reuseKey,
            cachedAt: now,
            lastAccessedAt: now
        )
        fifoSessionNames.append(sessionName)
        evictOverflowIfNeeded()
    }

    func remove(sessionName: String) {
        entriesBySession.removeValue(forKey: sessionName)
        fifoSessionNames.removeAll { $0 == sessionName }
    }

    func removeAll() {
        entriesBySession.removeAll()
        fifoSessionNames.removeAll()
    }

    /// Evict cached views whose sessions are about to be killed (archive/delete).
    /// This prevents ghostty from calling _exit() when the PTY closes on a cached surface.
    func evictSessions(_ sessionNames: [String]) {
        for name in sessionNames {
            remove(sessionName: name)
        }
    }

    private func pruneExpiredEntries(now: Date = Date()) {
        let expiredSessionNames = entriesBySession.compactMap { sessionName, entry -> String? in
            guard now.timeIntervalSince(entry.lastAccessedAt) > Self.maxIdleAge else { return nil }
            return sessionName
        }
        guard !expiredSessionNames.isEmpty else { return }
        for sessionName in expiredSessionNames {
            remove(sessionName: sessionName)
        }
    }

    private func evictOverflowIfNeeded() {
        while entriesBySession.count > Self.maxCachedViews {
            guard let oldestSessionName = fifoSessionNames.first else { return }
            fifoSessionNames.removeFirst()
            entriesBySession.removeValue(forKey: oldestSessionName)
        }
    }
}

// MARK: - ThreadDetailViewController

final class ThreadDetailViewController: NSViewController {
    static let lastOpenedThreadDefaultsKey = "MagentLastOpenedThreadID"
    static let lastOpenedTabDefaultsKey = "MagentLastOpenedSessionName"
    static let promptTOCPositionDefaultsPrefix = "MagentPromptTOCPosition"
    static let promptTOCSizeDefaultsPrefix = "MagentPromptTOCSize"
    static let promptTOCVisibilityDefaultsKey = "MagentPromptTOCVisibilityHidden"
    static let promptTOCMinimumWidth: CGFloat = 320
    static let promptTOCMinimumHeight: CGFloat = 250
    static let promptTOCCollapsedWidth: CGFloat = 185
    static let promptTOCCollapsedHeight: CGFloat = 36

    let showsHeaderInfoStrip: Bool
    var thread: MagentThread
    let threadManager = ThreadManager.shared
    let headerInfoStrip = PopoutInfoStripView()
    let tabBarStack = NSStackView()
    let terminalContainer: NSView = AppBackgroundView()
    let topBar = NSStackView()
    let openPRButton = MiddleClickButton()
    let openInJiraButton = MiddleClickButton()
    let openInXcodeButton = NSButton()
    let openInFinderButton = NSButton()
    let resyncLocalPathsButton = NSButton()
    let archiveThreadButton = NSButton()
    let reviewButton = NSButton()
    let continueInButton = NSButton()
    let exportContextButton = NSButton()
    let terminalBannerOverlay = BannerOverlayView()
    let scrollOverlay = TerminalScrollOverlayView()
    let togglePromptTOCButton = NSButton()
    let addTabButton = NSButton()
    let floatingScrollToBottomButton = TerminalScrollToBottomPillButton()

    // MARK: - Tab Slot Model
    /// Display-order mapping: `tabSlots[i]` tells what content `tabItems[i]` shows.
    enum TabSlot: Equatable {
        case terminal(sessionName: String)
        case web(identifier: String)
        case draft(identifier: String)
    }
    var tabItems: [TabItemView] = []
    var tabSlots: [TabSlot] = []
    /// Terminal views indexed by `thread.tmuxSessionNames` (creation order, NOT display order).
    var terminalViews: [TerminalSurfaceView] = []
    /// Web tab entries in creation order (NOT display order).
    var webTabs: [WebTabEntry] = []
    var draftTabs: [DraftTabEntry] = []
    var activeDraftTabId: String?
    var activeWebTabId: String?
    var currentTabIndex = 0
    /// Index of the non-closable "primary" tab. -1 means all tabs are closable (main threads).
    var primaryTabIndex = 0
    var pinnedCount = 0
    /// Placeholder views shown for detached tabs, keyed by sessionName.
    var detachedTabPlaceholders: [String: DetachedTabPlaceholderView] = [:]
    var loadingOverlay: NSView?
    var loadingLabel: NSTextField?
    var loadingDetailLabel: NSTextField?
    var loadingPollTimer: Timer?
    /// Debounces the reveal of `loadingOverlay` so fast-path session prep
    /// (e.g. revisiting a known-good thread) never shows the overlay at all.
    /// Cancelled by `dismissLoadingOverlay()`.
    var loadingOverlayRevealTimer: Timer?
    var loadingOverlaySessionName: String?
    /// Set to true while `injectAfterStart` has a prompt in-flight; prevents the
    /// poll timer from dismissing the overlay before keys are actually sent.
    var loadingOverlayWaitingForInjection = false
    var loadingOverlayInjectionObservers: [NSObjectProtocol] = []
    var initialPromptFailureBanner: BannerView?
    var initialPromptFailureBannerSessionName: String?
    var initialPromptFailureBannerTopConstraint: NSLayoutConstraint?
    var pendingPromptBanner: BannerView?
    var pendingPromptBannerSessionName: String?
    var pendingPromptBannerTopConstraint: NSLayoutConstraint?
    var recoveryBanner: BannerView?
    var recoveryBannerTopConstraint: NSLayoutConstraint?
    var preparedSessions: Set<String> = []
    var sessionPreparationTasks: [String: Task<Bool, Never>] = [:]
    var sessionPreparationTaskTokens: [String: UUID] = [:]
    var backgroundSessionPreparationTask: Task<Void, Never>?
    var startupOverlayRequiredSessions: Set<String> = []
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
    static let diffMaxFileCount = 2_000
    static let diffMaxLineCount = 60_000

    let prJiraSeparator = VerticalSeparatorView()
    let pinSeparator = VerticalSeparatorView()

    init(thread: MagentThread, showsHeaderInfoStrip: Bool = true) {
        self.showsHeaderInfoStrip = showsHeaderInfoStrip
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

        // Observe Keep Alive changes (from sidebar thread context menu)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeepAliveChanged(_:)),
            name: .magentKeepAliveChanged,
            object: nil
        )

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
            selector: #selector(handleJiraTicketInfoChanged),
            name: .magentJiraTicketInfoChanged,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSectionsDidChange),
            name: .magentSectionsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThreadsDidChange),
            name: .magentThreadsDidChange,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInitialPromptInjectionFailedNotification(_:)),
            name: .magentInitialPromptInjectionFailed,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAgentKeysInjectedNotification(_:)),
            name: .magentAgentKeysInjected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePendingPromptInjectionNotification(_:)),
            name: .magentPendingPromptInjection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePendingPromptRecoveryNotification(_:)),
            name: .magentPendingPromptRecovery,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTabReturnedToThread(_:)),
            name: .magentTabReturnedToThread,
            object: nil
        )

        refreshRecoveryBanner()

        Task {
            await setupTabs()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        clampPromptTOCPositionIfNeeded()
    }


    /// Clean up views that live outside our own view hierarchy (e.g. on window.contentView)
    /// before this controller is removed. Called from SplitContentContainerViewController.setContent
    /// since deinit can't access @MainActor properties.
    func cleanUpBeforeRemoval() {
        // DiffImageOverlayView lives on window.contentView, not on our view,
        // so it survives view controller replacement and blocks all mouse events.
        diffImageOverlay?.removeFromSuperview()
        diffImageOverlay = nil
        loadingOverlay?.removeFromSuperview()
        loadingOverlay = nil
    }

    deinit {
        promptTOCRefreshTask?.cancel()
        scrollFABRefreshTask?.cancel()
        backgroundSessionPreparationTask?.cancel()
        sessionPreparationTasks.values.forEach { $0.cancel() }
        dismissInitialPromptFailureBanner()
        dismissPendingPromptBanner()
        NotificationCenter.default.removeObserver(self)
    }

    func cacheTerminalViewsForReuse() {
        for (index, sessionName) in thread.tmuxSessionNames.enumerated() {
            guard index < terminalViews.count else { continue }
            // Skip sessions whose views are in a pop-out window, not here
            guard !PopoutWindowManager.shared.isTabDetached(sessionName: sessionName) else { continue }
            ReusableTerminalViewCache.shared.store(
                terminalViews[index],
                sessionName: sessionName,
                reuseKey: terminalReuseKey(for: sessionName)
            )
        }
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
        openPRButton.toolTip = "Open Pull Request\n\(externalLinkTooltip(clickDestinationInApp: prefersInAppExternalLinks()))"

        openInJiraButton.bezelStyle = .texturedRounded
        openInJiraButton.image = jiraButtonImage()
        openInJiraButton.imageScaling = .scaleProportionallyDown
        openInJiraButton.target = self
        openInJiraButton.action = #selector(openInJiraTapped)
        openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenInJira) + "\n" + externalLinkTooltip(clickDestinationInApp: prefersInAppExternalLinks())
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
            accessibilityDescription: "Sync local-only files"
        )
        resyncLocalPathsButton.imageScaling = .scaleProportionallyDown
        resyncLocalPathsButton.target = self
        resyncLocalPathsButton.action = #selector(resyncLocalPathsTapped)
        resyncLocalPathsButton.toolTip = "Sync local-only files"
        resyncLocalPathsButton.isHidden = resyncLocalPathsButtonShouldBeHidden()


        archiveThreadButton.bezelStyle = .texturedRounded
        archiveThreadButton.image = NSImage(
            systemSymbolName: "archivebox",
            accessibilityDescription: String(localized: .ThreadStrings.threadArchiveTitle)
        )
        archiveThreadButton.target = self
        archiveThreadButton.action = #selector(archiveThreadTapped)
        archiveThreadButton.isHidden = thread.isMain

        reviewButton.bezelStyle = .texturedRounded
        reviewButton.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: String(localized: .NotificationStrings.reviewChanges))
        reviewButton.target = self
        reviewButton.action = #selector(reviewButtonTapped)
        reviewButton.toolTip = String(localized: .NotificationStrings.reviewButtonTooltip)
        reviewButton.isHidden = true

        continueInButton.bezelStyle = .texturedRounded
        continueInButton.image = NSImage(systemSymbolName: "arrowshape.turn.up.forward", accessibilityDescription: "Continue in...")
        continueInButton.target = self
        continueInButton.action = #selector(continueInButtonTapped(_:))
        continueInButton.toolTip = "Continue in another agent"

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

        prJiraSeparator.translatesAutoresizingMaskIntoConstraints = false
        prJiraSeparator.isHidden = true
        prJiraSeparator.setContentHuggingPriority(.required, for: .horizontal)
        prJiraSeparator.setContentCompressionResistancePriority(.required, for: .horizontal)
        prJiraSeparator.setContentHuggingPriority(.required, for: .vertical)
        prJiraSeparator.setContentCompressionResistancePriority(.required, for: .vertical)

        let archiveSeparator = VerticalSeparatorView()
        archiveSeparator.translatesAutoresizingMaskIntoConstraints = false
        archiveSeparator.isHidden = thread.isMain
        archiveSeparator.setContentHuggingPriority(.required, for: .horizontal)
        archiveSeparator.setContentCompressionResistancePriority(.required, for: .horizontal)
        archiveSeparator.setContentHuggingPriority(.required, for: .vertical)
        archiveSeparator.setContentCompressionResistancePriority(.required, for: .vertical)

        topBar.orientation = .horizontal
        topBar.spacing = 4
        topBar.alignment = .centerY
        topBar.detachesHiddenViews = true
        topBar.translatesAutoresizingMaskIntoConstraints = false
        // Review button next to add-tab, then tab bar, then PR/Jira, then utility buttons, then archive
        for view in [addTabButton, reviewButton, continueInButton, tabBarStack, openPRButton, openInJiraButton, prJiraSeparator, openInXcodeButton, openInFinderButton, exportContextButton, resyncLocalPathsButton, archiveSeparator, archiveThreadButton] as [NSView] {
            topBar.addArrangedSubview(view)
        }
        let trailingTopBarSpacing: CGFloat = 8
        for view in [
            tabBarStack,
            openPRButton,
            openInJiraButton,
            prJiraSeparator,
            openInXcodeButton,
            openInFinderButton,
            exportContextButton,
            resyncLocalPathsButton,
            archiveSeparator,
        ] as [NSView] {
            topBar.setCustomSpacing(trailingTopBarSpacing, after: view)
        }

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        (terminalContainer as? AppBackgroundView)?.onEffectiveAppearanceChanged = { [weak self] in
            self?.refreshTerminalChromeAppearance()
        }

        view.addSubview(topBar)
        if showsHeaderInfoStrip {
            headerInfoStrip.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(headerInfoStrip)
        }
        view.addSubview(terminalContainer)
        setupPromptTOCOverlay()

        terminalBottomToView = terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        if showsHeaderInfoStrip {
            NSLayoutConstraint.activate([
                headerInfoStrip.topAnchor.constraint(equalTo: view.topAnchor),
                headerInfoStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                headerInfoStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                headerInfoStrip.heightAnchor.constraint(equalToConstant: 48),

                topBar.topAnchor.constraint(equalTo: headerInfoStrip.bottomAnchor, constant: 4),
                topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                topBar.heightAnchor.constraint(equalToConstant: 32),

                terminalContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
                terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalBottomToView!,
            ])
        } else {
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
        }

        setupTerminalBannerOverlay()
        setupScrollFAB()
        setupScrollOverlay()
        refreshOverlayVisibilitySettings()
        refreshTerminalChromeAppearance()
        refreshHeaderInfoStrip()
    }

    func setupTerminalBannerOverlay() {
        terminalBannerOverlay.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminalBannerOverlay)
        NSLayoutConstraint.activate([
            terminalBannerOverlay.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminalBannerOverlay.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminalBannerOverlay.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            terminalBannerOverlay.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])
        bringTerminalBannerOverlayToFront()
    }

    func bringTerminalBannerOverlayToFront() {
        guard terminalBannerOverlay.superview === terminalContainer else { return }
        terminalContainer.addSubview(terminalBannerOverlay, positioned: .above, relativeTo: nil)
    }

    // MARK: - Tab Setup

    private func setupTabs(requireStartupOverlayForInitialSession: Bool = false) async {
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
        let hasNonTerminalTabsOnly = sessions.isEmpty
            && (!thread.persistedWebTabs.isEmpty || !thread.persistedDraftTabs.isEmpty)

        if sessions.isEmpty && !hasNonTerminalTabsOnly {
            // Thread has no tabs at all — create a fallback terminal session so the user
            // still has somewhere to land when opening an otherwise empty thread.
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
            // Pass nil — this is a plain terminal fallback, not an agent session.
            // Using defaultAgentType here would cause agent resume/recovery to trigger
            // incorrectly when this session is recreated.
            threadManager.registerFallbackSession(fallbackName, for: thread.id, agentType: nil)
            // Refresh local copy after manager update
            if let latest = threadManager.threads.first(where: { $0.id == thread.id }) {
                thread = latest
            }
        }

        let pinned = sessions.filter { pinnedSet.contains($0) }
        let unpinned = sessions.filter { !pinnedSet.contains($0) }
        let orderedSessions = pinned + unpinned
        pinnedCount = pinned.count

        await MainActor.run {
            preparedSessions.removeAll()
            sessionPreparationTasks.values.forEach { $0.cancel() }
            sessionPreparationTasks.removeAll()
            sessionPreparationTaskTokens.removeAll()
            backgroundSessionPreparationTask?.cancel()
            backgroundSessionPreparationTask = nil

            // Clear any existing web/draft tabs from a previous setupTabs call
            for wt in webTabs { wt.view?.removeFromSuperview() }
            webTabs.removeAll()
            for dt in draftTabs { dt.viewController?.view.removeFromSuperview() }
            draftTabs.removeAll()
            tabSlots.removeAll()
            activeWebTabId = nil
            activeDraftTabId = nil

            for (i, sessionName) in orderedSessions.enumerated() {
                let title = thread.displayName(for: sessionName, at: i)
                createTabItem(title: title, closable: true, pinned: i < pinnedCount)
                tabSlots.append(.terminal(sessionName: sessionName))
            }

            // Build terminalViews outside the display-order loop because this array
            // must be parallel to thread.tmuxSessionNames (canonical order), not
            // orderedSessions (display order with pinned tabs first).
            terminalViews = thread.tmuxSessionNames.map(makeTerminalView(for:))

            // Restore persisted web tabs (pages load lazily on selection).
            // Pinned web tabs are inserted into the pinned section; unpinned appended at end.
            restoreWebTabItems()

            // Restore persisted draft tabs (view controllers created lazily on selection).
            restoreDraftTabItems()

            rebuildTabBar()
            rebindAllTabActions()
        }

        // Non-terminal thread: skip terminal session setup entirely, just restore the
        // selected draft/web tab instead of inventing a fallback tmux session name.
        if hasNonTerminalTabsOnly {
            await MainActor.run {
                dismissLoadingOverlay()
                if let idx = resolveLastSelectedSlotIndex() ?? tabSlots.indices.first {
                    selectTab(at: idx)
                } else {
                    showEmptyState()
                }
            }
            return
        }

        // Resolve whether the last-selected tab was a non-terminal tab (web/draft).
        // If so, we still prepare terminal sessions in the background but select the
        // non-terminal tab at the end.
        let nonTerminalSlotIndex: Int? = await MainActor.run {
            resolveLastSelectedSlotIndex().flatMap { idx in
                guard idx < tabSlots.count else { return nil }
                switch tabSlots[idx] {
                case .web, .draft: return idx
                case .terminal: return nil
                }
            }
        }

        let initialIndex: Int
        let defaults = UserDefaults.standard
        let defaultsThreadId = defaults
            .string(forKey: Self.lastOpenedThreadDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let defaultsSession = defaults.string(forKey: Self.lastOpenedTabDefaultsKey)

        if defaultsThreadId == thread.id,
           let defaultsSession,
           let savedIndex = orderedSessions.firstIndex(of: defaultsSession) {
            initialIndex = savedIndex
        } else if let lastSelected = thread.lastSelectedTabIdentifier,
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
            // Only show terminal loading overlay if we're actually restoring to a terminal tab.
            if nonTerminalSlotIndex == nil {
                startLoadingOverlayTracking(sessionName: initialSessionName, agentType: initialAgentType)

                if requireStartupOverlayForInitialSession {
                    requireStartupOverlay(for: initialSessionName)
                }
            }

            // Initialize indicator dots from thread model
            for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
                if case .terminal(let sessionName) = slot {
                    tabItems[i].hasUnreadCompletion = thread.unreadCompletionSessions.contains(sessionName)
                    tabItems[i].hasWaitingForInput = thread.waitingForInputSessions.contains(sessionName)
                    tabItems[i].hasBusy = thread.busySessions.contains(sessionName)
                    tabItems[i].hasRateLimit = thread.rateLimitedSessions[sessionName] != nil
                    tabItems[i].isRateLimitPropagated = thread.rateLimitedSessions[sessionName]?.isPropagated ?? false
                    tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
                    tabItems[i].isSessionDead = thread.deadSessions.contains(sessionName)
                }
            }
            refreshTabTooltips()

            // If restoring to a non-terminal tab, select it immediately before terminal prep.
            if let slotIndex = nonTerminalSlotIndex {
                selectTab(at: slotIndex)
            }
        }

        let recreatedInitialSession = await ensureSessionPrepared(sessionName: initialSessionName) { [weak self] action in
            guard let self,
                  initialSessionName == self.loadingOverlaySessionName else { return }
            self.updateLoadingOverlayDetail(action?.loadingOverlayDetail)
        }

        await MainActor.run {
            if nonTerminalSlotIndex == nil {
                // Resolve the display index from session name — web tab restoration may have
                // shifted indices since initialIndex was computed.
                let resolvedIndex = displayIndex(forSession: initialSessionName) ?? initialIndex
                let selected = selectPreparedTab(at: resolvedIndex)
                if !selected {
                    // Do not leave a blank terminal area on startup if the initial
                    // prepared attach misses. Keep loading visible and retry through
                    // the full selection path, which revalidates/recreates as needed.
                    loadingLabel?.stringValue = "Preparing terminal session..."
                    updateLoadingOverlayDetail("Initial terminal attach missed; retrying tmux/session validation.")
                    selectTab(at: resolvedIndex)
                    return
                }
                let keepStartupOverlay = recreatedInitialSession || consumeStartupOverlayRequirement(for: initialSessionName)
                if !keepStartupOverlay {
                    dismissLoadingOverlay()
                }
            }
            prepareSessionsInBackground(orderedSessions.enumerated().compactMap { offset, sessionName in
                offset == initialIndex ? nil : sessionName
            })
        }
    }

    func currentSessionName() -> String? {
        guard currentTabIndex >= 0, currentTabIndex < tabSlots.count else { return nil }
        if case .terminal(let name) = tabSlots[currentTabIndex] { return name }
        return nil
    }

    func currentSlot() -> TabSlot? {
        guard currentTabIndex >= 0, currentTabIndex < tabSlots.count else { return nil }
        return tabSlots[currentTabIndex]
    }

    /// Look up a terminal view by tmux session name (not display index).
    func terminalView(forSession name: String) -> TerminalSurfaceView? {
        guard let idx = thread.tmuxSessionNames.firstIndex(of: name) else { return nil }
        guard idx < terminalViews.count else { return nil }
        return terminalViews[idx]
    }

    /// The terminal view for the currently selected tab, or nil if it's a web tab.
    func currentTerminalView() -> TerminalSurfaceView? {
        guard let name = currentSessionName() else { return nil }
        return terminalView(forSession: name)
    }

    /// Display index for a given terminal session name, or nil.
    func displayIndex(forSession name: String) -> Int? {
        tabSlots.firstIndex(of: .terminal(sessionName: name))
    }

    /// Display index for a given web tab identifier, or nil.
    func displayIndex(forWebIdentifier id: String) -> Int? {
        tabSlots.firstIndex(of: .web(identifier: id))
    }

    /// Resolve the last-selected tab slot index from persisted state.
    /// Checks UserDefaults (current app session) first, then the per-thread persisted identifier.
    func resolveLastSelectedSlotIndex() -> Int? {
        let defaults = UserDefaults.standard
        let defaultsThreadId = defaults
            .string(forKey: Self.lastOpenedThreadDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let defaultsIdentifier = defaults.string(forKey: Self.lastOpenedTabDefaultsKey)

        // Priority 1: UserDefaults (current app session, matches this thread)
        if defaultsThreadId == thread.id, let id = defaultsIdentifier,
           let idx = slotIndex(forIdentifier: id) {
            return idx
        }
        // Priority 2: Per-thread persisted identifier (survives app restart)
        if let id = thread.lastSelectedTabIdentifier,
           let idx = slotIndex(forIdentifier: id) {
            return idx
        }
        return nil
    }

    /// Find the tab slot index for a given identifier (session name, web id, or draft id).
    private func slotIndex(forIdentifier id: String) -> Int? {
        tabSlots.firstIndex { slot in
            switch slot {
            case .terminal(let name): return name == id
            case .web(let identifier): return identifier == id
            case .draft(let identifier): return identifier == id
            }
        }
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
        let reuseKey = terminalReuseKey(for: sessionName)
        let resolvedThread = latestThreadSnapshot()
        let view: TerminalSurfaceView
        if let cachedView = ReusableTerminalViewCache.shared.take(
            sessionName: sessionName,
            reuseKey: reuseKey
        ) {
            view = cachedView
        } else {
            let tmuxCommand = buildTmuxCommand(for: sessionName)
            view = TerminalSurfaceView(
                workingDirectory: resolvedThread.worktreePath,
                command: tmuxCommand
            )
        }
        configureTerminalViewHandlers(view, sessionName: sessionName)
        return view
    }

    func rebuildDetachedTerminalView(for sessionName: String) {
        guard let termIdx = thread.tmuxSessionNames.firstIndex(of: sessionName),
              termIdx < terminalViews.count else { return }

        let existingView = terminalViews[termIdx]
        guard existingView.superview == nil else { return }

        ReusableTerminalViewCache.shared.remove(sessionName: sessionName)
        terminalViews[termIdx] = makeTerminalView(for: sessionName)
    }

    private func configureTerminalViewHandlers(_ view: TerminalSurfaceView, sessionName: String) {
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
            await TmuxService.shared.recentMouseOpenableURL(sessionName: sessionName)
        }
        view.resolveTmuxVisibleOpenableURL = { [sessionName = sessionName] xFraction, yFraction in
            await TmuxService.shared.visibleOpenableURL(
                sessionName: sessionName,
                xFraction: xFraction,
                yFraction: yFraction
            )
        }
        view.openURLHandler = { [weak self] url, openOppositeDestination in
            self?.openTerminalLink(url, openOppositeDestination: openOppositeDestination)
        }
    }

    private func openTerminalLink(_ url: URL, openOppositeDestination: Bool) {
        let forceInApp: Bool?
        if openOppositeDestination {
            forceInApp = !prefersInAppExternalLinks()
        } else {
            forceInApp = nil
        }
        openExternalWebDestination(
            url: url,
            identifier: "web:\(url.absoluteString)",
            title: WebURLNormalizer.shortHost(from: url) ?? url.absoluteString,
            iconType: .web,
            forceInApp: forceInApp
        )
    }

    func terminalReuseKey(for sessionName: String) -> String {
        Self.terminalReuseKey(for: latestThreadSnapshot(), sessionName: sessionName)
    }

    private func latestThreadSnapshot() -> MagentThread {
        threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
    }

    static func terminalReuseKey(for thread: MagentThread, sessionName: String) -> String {
        "\(thread.worktreePath)\n\(buildTmuxCommand(for: sessionName, in: thread))"
    }

    private func buildTmuxCommand(for sessionName: String) -> String {
        Self.buildTmuxCommand(for: sessionName, in: latestThreadSnapshot())
    }

    static func buildTmuxCommand(for sessionName: String, in thread: MagentThread) -> String {
        let threadManager = ThreadManager.shared
        let settings = PersistenceService.shared.loadSettings()
        let isAgentSession = thread.agentTmuxSessions.contains(sessionName)
        let selectedAgentType = threadManager.agentType(for: thread, sessionName: sessionName)

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
            "export MAGENT_THREAD_ID=\(thread.id.uuidString)",
        ]
        if thread.isMain {
            envParts.append("export MAGENT_WORKTREE_NAME=main")
        } else {
            envParts.append("export MAGENT_WORKTREE_PATH=\(wd)")
            envParts.append("export MAGENT_WORKTREE_NAME=\(thread.name)")
        }
        if let selectedAgentType {
            envParts.append("export MAGENT_AGENT_TYPE=\(selectedAgentType.rawValue)")
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
        let ensureTerminalFeatures = TmuxService.ensureTerminalFeaturesShellCommand()
        let tmuxInner = "tmux send-keys -t \(sessionName) -X cancel 2>/dev/null; tmux attach-session -t \(sessionName) 2>/dev/null || { tmux new-session -d -s \(sessionName) -c \(quotedWd) \(quotedStartCmd) && { \(ensureTerminalFeatures); } && tmux attach-session -t \(sessionName); }"
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
        guard let userInfo = notification.userInfo else {
            NSLog("[TabClose] handleTabWillClose: missing userInfo")
            return
        }
        guard let threadId = userInfo["threadId"] as? UUID else {
            NSLog("[TabClose] handleTabWillClose: missing threadId in userInfo")
            return
        }
        guard threadId == thread.id else {
            NSLog("[TabClose] handleTabWillClose: ignoring notification for threadId=\(threadId), current thread=\(thread.id)")
            return
        }
        guard let sessionName = userInfo["sessionName"] as? String else {
            NSLog("[TabClose] handleTabWillClose: missing sessionName for threadId=\(threadId)")
            return
        }

        // Find display index via tabSlots.
        guard let displayIndex = tabSlots.firstIndex(of: .terminal(sessionName: sessionName)) else {
            NSLog("[TabClose] handleTabWillClose: session \(sessionName) missing from tabSlots for threadId=\(threadId)")
            return
        }
        // Find terminal array index.
        guard let termIdx = thread.tmuxSessionNames.firstIndex(of: sessionName),
              termIdx < terminalViews.count else {
            NSLog("[TabClose] handleTabWillClose: session \(sessionName) missing from thread/terminalViews for threadId=\(threadId); tmuxSessions=\(thread.tmuxSessionNames.count) terminalViews=\(terminalViews.count)")
            return
        }

        GhosttyAppManager.log("handleTabWillClose: threadId=\(threadId) session=\(sessionName) displayIndex=\(displayIndex)")

        // Remove the surface view.  This triggers viewDidMoveToWindow(nil) → destroySurface()
        // → ghostty_surface_free, preventing the zombie-surface crash.
        terminalViews[termIdx].removeFromSuperview()
        terminalViews.remove(at: termIdx)

        if displayIndex < tabItems.count {
            tabItems.remove(at: displayIndex)
        }
        if displayIndex < tabSlots.count {
            tabSlots.remove(at: displayIndex)
        }

        // Keep pinnedCount / primaryTabIndex in sync.
        if displayIndex < pinnedCount { pinnedCount -= 1 }
        if displayIndex == primaryTabIndex {
            primaryTabIndex = 0
        } else if primaryTabIndex > displayIndex {
            primaryTabIndex -= 1
        }

        // Prune our local thread copy so subsequent index lookups stay correct.
        thread.tmuxSessionNames.removeAll { $0 == sessionName }
        thread.pinnedTmuxSessions.removeAll { $0 == sessionName }
        thread.customTabNames.removeValue(forKey: sessionName)
        thread.manuallyRenamedTabs.remove(sessionName)
        thread.agentTmuxSessions.removeAll { $0 == sessionName }
        thread.unreadCompletionSessions.remove(sessionName)
        thread.busySessions.remove(sessionName)
        thread.waitingForInputSessions.remove(sessionName)
        thread.hasUnsubmittedInputSessions.remove(sessionName)
        threadManager.clearInitialPromptInjectionFailure(for: sessionName)
        startupOverlayRequiredSessions.remove(sessionName)
        ReusableTerminalViewCache.shared.remove(sessionName: sessionName)

        rebindAllTabActions()
        rebuildTabBar()

        if tabItems.isEmpty {
            showEmptyState()
        } else {
            let newIndex = min(displayIndex, tabItems.count - 1)
            selectTab(at: newIndex)
        }
    }

    @objc private func handleKeepAliveChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id else { return }
        // Refresh from the manager's fresh state.
        if let freshThread = threadManager.threads.first(where: { $0.id == thread.id }) {
            thread.isKeepAlive = freshThread.isKeepAlive
            thread.didOfferKeepAlivePromotion = freshThread.didOfferKeepAlivePromotion
            thread.protectedTmuxSessions = freshThread.protectedTmuxSessions
        }
        refreshTabStatusIndicators()
        rebindAllTabActions()
        refreshHeaderInfoStrip()
    }

    @objc private func handleDeadSessionsNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let deadSessions = userInfo["deadSessions"] as? [String] else { return }

        for sessionName in deadSessions {
            guard let displayIdx = displayIndex(forSession: sessionName),
                  displayIdx < tabItems.count else { continue }

            if displayIdx == currentTabIndex {
                // The visible session was auto-recreated by checkForDeadSessions.
                // Replace the terminal view so the user sees the fresh session.
                if let termIdx = thread.tmuxSessionNames.firstIndex(of: sessionName),
                   termIdx < terminalViews.count {
                    let oldView = terminalViews[termIdx]
                    oldView.removeFromSuperview()
                    ReusableTerminalViewCache.shared.remove(sessionName: sessionName)

                    let newView = makeTerminalView(for: sessionName)
                    terminalViews[termIdx] = newView
                    selectTab(at: displayIdx)
                }
                tabItems[displayIdx].isSessionDead = false
            } else {
                // Background dead sessions — just dim the tab.
                tabItems[displayIdx].isSessionDead = true
            }
        }
        refreshTabTooltips()
    }

    @objc private func handleAgentCompletionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let unreadSessions = userInfo["unreadSessions"] as? Set<String> else { return }

        thread.unreadCompletionSessions = unreadSessions
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                tabItems[i].hasUnreadCompletion = unreadSessions.contains(sessionName)
            }
        }
        refreshTabTooltips()
        refreshDiffViewerIfVisible()
        syncTransientState()
        schedulePromptTOCRefresh()
        refreshHeaderInfoStrip()
    }

    @objc private func handleInitialPromptInjectionFailedNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let sessionName = userInfo["sessionName"] as? String,
              thread.tmuxSessionNames.contains(sessionName) else {
            return
        }
        // Pending banner is no longer needed — failure banner takes over
        if pendingPromptBannerSessionName == sessionName {
            dismissPendingPromptBanner()
        }
        refreshInitialPromptFailureBanner()
    }

    @objc private func handleAgentKeysInjectedNotification(_ notification: Notification) {
        guard let sessionName = notification.userInfo?["sessionName"] as? String else { return }
        let includedInitialPrompt = (notification.userInfo?["includedInitialPrompt"] as? Bool) == true

        // Dismiss pending-injection UI only when this completion actually sent the prompt.
        if includedInitialPrompt, pendingPromptBannerSessionName == sessionName {
            dismissPendingPromptBanner()
        }

        guard includedInitialPrompt else { return }
        guard threadManager.initialPromptInjectionFailure(for: sessionName) != nil else { return }
        threadManager.clearInitialPromptInjectionFailure(for: sessionName)
        refreshInitialPromptFailureBanner()
    }

    @objc private func handlePendingPromptInjectionNotification(_ notification: Notification) {
        guard let sessionName = notification.userInfo?["sessionName"] as? String,
              thread.tmuxSessionNames.contains(sessionName) else {
            return
        }
        refreshPendingPromptBanner()
    }

    @objc private func handleAgentWaitingNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let waitingSessions = userInfo["waitingSessions"] as? Set<String> else { return }

        thread.waitingForInputSessions = waitingSessions
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                tabItems[i].hasWaitingForInput = waitingSessions.contains(sessionName)
            }
        }
        refreshTabTooltips()
        syncTransientState()
        refreshHeaderInfoStrip()
    }

    @objc private func handleAgentBusyNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let threadId = userInfo["threadId"] as? UUID,
              threadId == thread.id,
              let busySessions = userInfo["busySessions"] as? Set<String> else { return }

        thread.busySessions = busySessions
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                tabItems[i].hasBusy = busySessions.contains(sessionName)
            }
        }
        refreshTabTooltips()
        syncTransientState()
        refreshHeaderInfoStrip()
    }

    @objc private func handleAgentRateLimitNotification(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == thread.id,
              let latest = threadManager.threads.first(where: { $0.id == thread.id }) else { return }

        thread.rateLimitedSessions = latest.rateLimitedSessions
        thread.unreadRateLimitSessions = latest.unreadRateLimitSessions
        for (i, slot) in tabSlots.enumerated() where i < tabItems.count {
            if case .terminal(let sessionName) = slot {
                let info = thread.rateLimitedSessions[sessionName]
                tabItems[i].hasRateLimit = info != nil
                tabItems[i].isRateLimitPropagated = info?.isPropagated ?? false
                tabItems[i].rateLimitAgentType = info?.agentType
                tabItems[i].rateLimitTooltip = rateLimitTooltip(for: sessionName)
                tabItems[i].hasUnreadRateLimit = thread.unreadRateLimitSessions.contains(sessionName)
            }
        }
        refreshTabTooltips()
        refreshHeaderInfoStrip()
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
        // Web-only threads (no tmux sessions) are handled inside setupTabs which
        // selects the first web tab automatically.
        refreshHeaderInfoStrip()
        Task { await setupTabs(requireStartupOverlayForInitialSession: true) }
    }

    func showCreationOverlay() {
        ensureLoadingOverlay()
        loadingLabel?.stringValue = "Creating thread..."
        // Immediate reveal — thread creation (worktree + tmux) always exceeds the
        // debounce window, so the user should see feedback right away.
        revealLoadingOverlay(after: 0)
    }

    @objc private func handlePullRequestInfoChanged() {
        syncTransientState()
    }

    @objc private func handleJiraTicketInfoChanged() {
        guard let latest = threadManager.threads.first(where: { $0.id == thread.id }) else { return }
        thread.actualBranch = latest.actualBranch
        thread.verifiedJiraTicket = latest.verifiedJiraTicket
        refreshJiraButton()
        refreshHeaderInfoStrip()
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

    @objc private func handleSectionsDidChange() {
        refreshHeaderInfoStrip()
    }

    @objc private func handleThreadsDidChange() {
        refreshHeaderInfoStrip()
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
        resyncLocalPathsButton.isHidden = resyncLocalPathsButtonShouldBeHidden()
        refreshOpenPRButtonIcon()
        refreshJiraButton()
        refreshOverlayVisibilitySettings()
        updateTerminalScrollControlsState()
        refreshHeaderInfoStrip()
    }

    private func reloadTerminalViewsForUpdatedTerminalPreferences() {
        guard !terminalViews.isEmpty else { return }

        ReusableTerminalViewCache.shared.removeAll()
        for terminalView in terminalViews {
            terminalView.removeFromSuperview()
        }

        terminalViews = thread.tmuxSessionNames.map(makeTerminalView(for:))

        let selectedIndex = min(currentTabIndex, tabSlots.count - 1)
        selectTab(at: selectedIndex)
    }

    func resyncLocalPathsButtonShouldBeHidden() -> Bool {
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        guard let project else { return true }
        guard project.hasCopyLocalFileSyncEntries else { return true }
        let projectId = thread.projectId

        let activeProjectThreadCount = threadManager.threads.lazy.filter {
            !$0.isArchived && $0.projectId == projectId
        }.count
        return activeProjectThreadCount < 2
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
                systemSymbolName: "text.magnifyingglass",
                accessibilityDescription: String(localized: .NotificationStrings.reviewChanges)
            )
            exportContextButton.image = NSImage(
                systemSymbolName: "square.and.arrow.up",
                accessibilityDescription: String(localized: .NotificationStrings.contextExport)
            )
            resyncLocalPathsButton.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "Sync local-only files"
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

    func refreshHeaderInfoStrip() {
        guard isViewLoaded, showsHeaderInfoStrip else { return }
        let latest = threadManager.threads.first(where: { $0.id == thread.id }) ?? thread
        headerInfoStrip.refresh(from: latest)
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

    func refreshInitialPromptFailureBanner() {
        guard let sessionName = currentSessionName(),
              let failure = threadManager.initialPromptInjectionFailure(for: sessionName) else {
            dismissInitialPromptFailureBanner()
            return
        }
        showInitialPromptFailureBanner(sessionName: sessionName, failure: failure)
    }

    private func copyPromptToPasteboard(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    private func retryInitialPromptInjection(
        sessionName: String,
        failure: ThreadManager.InitialPromptInjectionFailureInfo
    ) {
        let injection = threadManager.effectiveInjection(for: thread.projectId)
        if failure.requiresAgentRelaunch {
            let relaunched = threadManager.relaunchAgentInExistingSession(
                sessionName: sessionName,
                initialPrompt: failure.prompt,
                shouldSubmitInitialPrompt: failure.shouldSubmitInitialPrompt,
                agentContext: injection.agentContext,
                agentType: failure.agentType
            )
            if !relaunched {
                threadManager.injectAfterStart(
                    sessionName: sessionName,
                    terminalCommand: "",
                    agentContext: injection.agentContext,
                    initialPrompt: failure.prompt,
                    shouldSubmitInitialPrompt: failure.shouldSubmitInitialPrompt,
                    agentType: failure.agentType
                )
            }
        } else {
            threadManager.injectAfterStart(
                sessionName: sessionName,
                terminalCommand: "",
                agentContext: injection.agentContext,
                initialPrompt: failure.prompt,
                shouldSubmitInitialPrompt: failure.shouldSubmitInitialPrompt,
                agentType: failure.agentType
            )
        }
        refreshInitialPromptFailureBanner()
    }

    private func showInitialPromptFailureBanner(
        sessionName: String,
        failure: ThreadManager.InitialPromptInjectionFailureInfo
    ) {
        if initialPromptFailureBannerSessionName == sessionName,
           initialPromptFailureBanner != nil {
            return
        }

        dismissInitialPromptFailureBanner()

        let banner = BannerView(config: BannerConfig(
            message: failure.requiresAgentRelaunch
                ? "The agent stopped during launch and this tab is now at a shell prompt."
                : "Initial prompt injection failed for this tab.",
            style: .warning,
            duration: nil,
            isDismissible: false,
            actions: [
                BannerAction(title: failure.requiresAgentRelaunch ? "Relaunch Agent" : "Inject Prompt") { [weak self] in
                    guard let self else { return }
                    self.retryInitialPromptInjection(sessionName: sessionName, failure: failure)
                },
                BannerAction(title: "Copy Prompt") { [weak self] in
                    guard let self else { return }
                    self.copyPromptToPasteboard(failure.prompt)
                    self.threadManager.clearTrackedInitialPromptInjection(for: sessionName)
                    self.refreshInitialPromptFailureBanner()
                },
                BannerAction(title: "Already Injected") { [weak self] in
                    guard let self else { return }
                    self.threadManager.clearTrackedInitialPromptInjection(for: sessionName)
                    self.refreshInitialPromptFailureBanner()
                },
            ]
        ))
        bringTerminalBannerOverlayToFront()
        banner.translatesAutoresizingMaskIntoConstraints = false
        terminalBannerOverlay.addSubview(banner)
        let topConstraint = banner.topAnchor.constraint(equalTo: terminalBannerOverlay.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            topConstraint,
            banner.centerXAnchor.constraint(equalTo: terminalBannerOverlay.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: terminalBannerOverlay.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: terminalBannerOverlay.trailingAnchor, constant: -20),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])

        initialPromptFailureBanner = banner
        initialPromptFailureBannerSessionName = sessionName
        initialPromptFailureBannerTopConstraint = topConstraint
    }

    // MARK: - Pending Prompt Injection Banner

    func refreshPendingPromptBanner() {
        guard let sessionName = currentSessionName(),
              let pending = threadManager.pendingPromptInjection(for: sessionName) else {
            dismissPendingPromptBanner()
            return
        }
        showPendingPromptBanner(sessionName: sessionName, pending: pending)
    }

    private func showPendingPromptBanner(
        sessionName: String,
        pending: ThreadManager.InitialPromptInjectionFailureInfo
    ) {
        if pendingPromptBannerSessionName == sessionName,
           pendingPromptBanner != nil {
            return
        }

        dismissPendingPromptBanner()

        let banner = BannerView(config: BannerConfig(
            message: "Prompt will be injected once the agent is ready.",
            style: .info,
            duration: nil,
            isDismissible: false,
            actions: [
                BannerAction(title: "Copy Prompt") { [weak self] in
                    self?.copyPromptToPasteboard(pending.prompt)
                },
                BannerAction(title: "Inject Now") { [weak self] in
                    guard let self else { return }
                    self.dismissPendingPromptBanner()
                    self.threadManager.injectPendingPromptNow(
                        sessionName: sessionName,
                        prompt: pending.prompt,
                        shouldSubmitInitialPrompt: pending.shouldSubmitInitialPrompt,
                        agentType: pending.agentType
                    )
                },
            ]
        ))
        bringTerminalBannerOverlayToFront()
        banner.translatesAutoresizingMaskIntoConstraints = false
        terminalBannerOverlay.addSubview(banner)
        let topConstraint = banner.topAnchor.constraint(equalTo: terminalBannerOverlay.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            topConstraint,
            banner.centerXAnchor.constraint(equalTo: terminalBannerOverlay.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: terminalBannerOverlay.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: terminalBannerOverlay.trailingAnchor, constant: -20),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])

        pendingPromptBanner = banner
        pendingPromptBannerSessionName = sessionName
        pendingPromptBannerTopConstraint = topConstraint
    }

    private func dismissPendingPromptBanner() {
        pendingPromptBanner?.removeFromSuperview()
        pendingPromptBanner = nil
        pendingPromptBannerSessionName = nil
        pendingPromptBannerTopConstraint = nil
    }

    private func dismissInitialPromptFailureBanner() {
        initialPromptFailureBanner?.removeFromSuperview()
        initialPromptFailureBanner = nil
        initialPromptFailureBannerSessionName = nil
        initialPromptFailureBannerTopConstraint = nil
    }

    // MARK: - Pending Prompt Recovery Banner

    @objc private func handlePendingPromptRecoveryNotification(_ notification: Notification) {
        guard let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == thread.id else {
            return
        }
        refreshRecoveryBanner()
    }

    @objc private func handleTabReturnedToThread(_ notification: Notification) {
        guard let sessionName = notification.userInfo?["sessionName"] as? String,
              let threadId = notification.userInfo?["threadId"] as? UUID,
              threadId == thread.id else { return }
        returnDetachedTab(sessionName: sessionName)
    }

    func refreshRecoveryBanner() {
        let recoveries = threadManager.pendingPromptRecoveries(for: thread.id)
        guard let first = recoveries.first else {
            dismissRecoveryBanner()
            return
        }
        showRecoveryBanner(recovery: first, total: recoveries.count)
    }

    private func showRecoveryBanner(
        recovery: ThreadManager.PendingPromptRecoveryInfo,
        total: Int
    ) {
        // Already showing — skip (actions will refresh on next cycle).
        guard recoveryBanner == nil else { return }

        let threadId = thread.id
        let countSuffix = total > 1 ? " (\(total) prompts)" : ""
        let promptPreview = recovery.prompt.magentPromptPreview(maxLength: 140, singleLine: true)
        let promptDetails = recovery.prompt.magentPromptPreview(maxLength: 500, singleLine: false)
        let banner = BannerView(config: BannerConfig(
            message: "Unsubmitted tab prompt recovered for this thread.\(countSuffix)\nPreview: \(promptPreview)",
            style: .warning,
            duration: nil,
            isDismissible: true,
            actions: [
                BannerAction(title: "Copy Prompt") { [weak self] in
                    self?.copyPromptToPasteboard(recovery.prompt)
                },
                BannerAction(title: "Reopen as Thread") { [weak self] in
                    guard let self else { return }
                    let prefill = AgentLaunchSheetPrefill(
                        prompt: recovery.prompt,
                        description: nil,
                        branchName: nil,
                        agentType: recovery.agentType,
                        modelId: recovery.modelId,
                        reasoningLevel: recovery.reasoningLevel,
                        selectionRaw: recovery.agentType?.rawValue ?? "terminal",
                        isDraft: false
                    )
                    self.threadManager.removePendingPromptRecovery(for: threadId, tempFileURL: recovery.tempFileURL)
                    self.dismissRecoveryBanner()
                    NotificationCenter.default.post(
                        name: .magentRecoveryReopenRequested,
                        object: nil,
                        userInfo: [
                            "projectId": recovery.projectId,
                            "tempFileURL": recovery.tempFileURL,
                            "prefill": prefill,
                        ]
                    )
                    // Show next recovery banner if any remain.
                    self.refreshRecoveryBanner()
                },
                BannerAction(title: "Discard") { [weak self] in
                    guard let self else { return }
                    try? FileManager.default.removeItem(at: recovery.tempFileURL)
                    self.threadManager.removePendingPromptRecovery(for: threadId, tempFileURL: recovery.tempFileURL)
                    self.dismissRecoveryBanner()
                    // Show next recovery banner if any remain.
                    self.refreshRecoveryBanner()
                },
            ],
            details: promptDetails,
            detailsCollapsedTitle: "Show More",
            detailsExpandedTitle: "Hide More"
        ))
        // Dismiss just hides the banner — data stays alive and the banner reappears
        // next time the thread is selected.
        banner.onDismiss = { [weak self] in
            self?.dismissRecoveryBanner()
        }
        bringTerminalBannerOverlayToFront()
        banner.translatesAutoresizingMaskIntoConstraints = false
        terminalBannerOverlay.addSubview(banner)
        let topConstraint = banner.topAnchor.constraint(equalTo: terminalBannerOverlay.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            topConstraint,
            banner.centerXAnchor.constraint(equalTo: terminalBannerOverlay.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: terminalBannerOverlay.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: terminalBannerOverlay.trailingAnchor, constant: -20),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])

        recoveryBanner = banner
        recoveryBannerTopConstraint = topConstraint
    }

    private func dismissRecoveryBanner() {
        recoveryBanner?.removeFromSuperview()
        recoveryBanner = nil
        recoveryBannerTopConstraint = nil
    }

}

final class VerticalSeparatorView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 18) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        bounds.fill()
    }
}
