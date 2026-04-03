import Cocoa
import MagentCore

private enum ThreadStatusSummaryKind: String, CaseIterable {
    case busy
    case waiting
    case done
    case rateLimited

    var buttonTitle: String {
        switch self {
        case .busy:
            return "busy"
        case .waiting:
            return "waiting"
        case .done:
            return "done"
        case .rateLimited:
            return "rate-limited"
        }
    }

    var popoverTitle: String {
        switch self {
        case .busy:
            return "Busy Threads"
        case .waiting:
            return "Waiting For Input"
        case .done:
            return "Completed Threads"
        case .rateLimited:
            return "Rate-Limited Threads"
        }
    }

    var symbolName: String {
        switch self {
        case .busy:
            return "circle.dotted"
        case .waiting:
            return "exclamationmark.bubble"
        case .done:
            return "checkmark.circle.fill"
        case .rateLimited:
            return "hourglass"
        }
    }

    var color: NSColor {
        switch self {
        case .busy:
            return .systemBlue
        case .waiting:
            return .systemYellow
        case .done:
            return .systemGreen
        case .rateLimited:
            return .systemOrange
        }
    }

    func matches(_ thread: MagentThread) -> Bool {
        switch self {
        case .busy:
            return thread.isAnyBusy
        case .waiting:
            return thread.hasWaitingForInput
        case .done:
            return thread.hasUnreadAgentCompletion
        case .rateLimited:
            return thread.isBlockedByRateLimit
        }
    }

    var usesPersistentAddedAt: Bool {
        self == .done
    }
}

private struct ThreadStatusSummaryDescriptor: Equatable {
    let kind: ThreadStatusSummaryKind
    let count: Int
}

private struct ThreadStatusPopoverEntry {
    let thread: MagentThread
    let addedAt: Date
}

private final class ThreadStatusPopoverRowView: NSView {
    private let thread: MagentThread
    private let addedAt: Date
    private let projectName: String
    private let onSelect: (UUID) -> Void
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateLayerColors()
        }
    }

    init(
        thread: MagentThread,
        addedAt: Date,
        projectName: String,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.thread = thread
        self.addedAt = addedAt
        self.projectName = projectName
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onSelect(thread.id)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        updateLayerColors()
    }

    private func setupViews() {
        wantsLayer = true
        updateLayerColors()

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        )
        iconView.contentTintColor = NSColor(resource: .textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleText: String
        if let description = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            titleText = description
        } else {
            titleText = thread.name
        }
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(resource: .textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(titleLabel)

        let worktreeName = (thread.worktreePath as NSString).lastPathComponent
        let branchName = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranchName = branchName.isEmpty ? thread.name : branchName
        var branchWorktreeSegments = [resolvedBranchName]
        if resolvedBranchName != worktreeName {
            branchWorktreeSegments.append(worktreeName)
        }
        let branchLabel = NSTextField(labelWithString: branchWorktreeSegments.joined(separator: " · "))
        branchLabel.font = .systemFont(ofSize: 10)
        branchLabel.textColor = NSColor(resource: .textSecondary)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(branchLabel)

        let addedText = Self.relativeTimeString(from: addedAt)
        let metaLabel = NSTextField(labelWithString: "\(projectName) · \(addedText)")
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = NSColor(resource: .textSecondary)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(metaLabel)

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            iconView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 8
            layer?.backgroundColor = isHovered
                ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
    }

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

private final class ThreadStatusPopoverViewController: NSViewController {
    private static let popoverWidth: CGFloat = 340

    private let status: ThreadStatusSummaryKind
    private let onSelectThread: (UUID) -> Void
    private let containerStack = NSStackView()
    private var entries: [ThreadStatusPopoverEntry]

    init(
        status: ThreadStatusSummaryKind,
        entries: [ThreadStatusPopoverEntry],
        onSelectThread: @escaping (UUID) -> Void
    ) {
        self.status = status
        self.entries = entries
        self.onSelectThread = onSelectThread
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 10))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 0
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            containerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            containerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
        ])

        rebuild()
    }

    func update(entries: [ThreadStatusPopoverEntry]) {
        self.entries = entries
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        containerStack.arrangedSubviews.forEach { subview in
            containerStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let headerLabel = NSTextField(labelWithString: status.popoverTitle)
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textPrimary)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 2),
            headerLabel.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerRow.trailingAnchor, constant: -4),
            headerLabel.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -8),
        ])
        containerStack.addArrangedSubview(headerRow)

        let headerSeparator = NSBox()
        headerSeparator.boxType = .separator
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addArrangedSubview(headerSeparator)
        NSLayoutConstraint.activate([
            headerSeparator.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
        ])

        let settings = PersistenceService.shared.loadSettings()
        let projectsById = Dictionary(uniqueKeysWithValues: settings.projects.map { ($0.id, $0.name) })

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                containerStack.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
                ])
            }

            let row = ThreadStatusPopoverRowView(
                thread: entry.thread,
                addedAt: entry.addedAt,
                projectName: projectsById[entry.thread.projectId] ?? "Unknown Project",
                onSelect: onSelectThread
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            containerStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: containerStack.widthAnchor),
            ])
        }

        view.layoutSubtreeIfNeeded()
        let height = containerStack.fittingSize.height + 16
        preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
        view.setFrameSize(NSSize(width: Self.popoverWidth, height: height))
    }
}

// MARK: - Session Cleanup Popover

private final class SessionCleanupPopoverViewController: NSViewController {
    private static let popoverWidth: CGFloat = 260

    private let totalSessions: Int
    private let liveSessions: Int
    private let protectedSessions: Int
    private let idleSessions: Int
    private let zombieCount: Int
    private let zombieParentPid: Int?
    private let isRecoveringTmux: Bool
    private let onCleanup: () -> Void
    private let onRestartTmux: () -> Void

    init(
        totalSessions: Int,
        liveSessions: Int,
        protectedSessions: Int,
        idleSessions: Int,
        zombieCount: Int,
        zombieParentPid: Int?,
        isRecoveringTmux: Bool,
        onCleanup: @escaping () -> Void,
        onRestartTmux: @escaping () -> Void
    ) {
        self.totalSessions = totalSessions
        self.liveSessions = liveSessions
        self.protectedSessions = protectedSessions
        self.idleSessions = idleSessions
        self.zombieCount = zombieCount
        self.zombieParentPid = zombieParentPid
        self.isRecoveringTmux = isRecoveringTmux
        self.onCleanup = onCleanup
        self.onRestartTmux = onRestartTmux
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 10))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // Header
        let headerLabel = NSTextField(labelWithString: "Active Sessions")
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textPrimary)
        stack.addArrangedSubview(headerLabel)

        // Session breakdown
        let deadCount = totalSessions - liveSessions
        let liveLabel = NSTextField(labelWithString: "\(liveSessions) live · \(deadCount) suspended · \(totalSessions) total")
        liveLabel.font = .systemFont(ofSize: 11)
        liveLabel.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(liveLabel)

        if protectedSessions > 0 {
            let protectedLabel = NSTextField(labelWithString: "\(protectedSessions) protected (busy/waiting/shielded/pinned/recently active)")
            protectedLabel.font = .systemFont(ofSize: 11)
            protectedLabel.textColor = NSColor(resource: .textSecondary)
            stack.addArrangedSubview(protectedLabel)
        }

        if zombieCount > 0 || isRecoveringTmux {
            let zombieText: String
            if isRecoveringTmux {
                zombieText = "tmux recovery in progress"
            } else if let zombieParentPid {
                zombieText = "\(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es") on parent \(zombieParentPid)"
            } else {
                zombieText = "\(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es")"
            }
            let zombieLabel = NSTextField(labelWithString: zombieText)
            zombieLabel.font = .systemFont(ofSize: 11)
            zombieLabel.textColor = zombieCount >= 200 ? .systemRed : .systemOrange
            stack.addArrangedSubview(zombieLabel)
        }

        // Cleanup button
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)

        let cleanupButton = NSButton()
        cleanupButton.bezelStyle = .inline
        cleanupButton.isBordered = true
        cleanupButton.target = self
        cleanupButton.action = #selector(cleanupTapped)
        cleanupButton.translatesAutoresizingMaskIntoConstraints = false

        if idleSessions > 0 {
            cleanupButton.title = "Close \(idleSessions) idle session\(idleSessions == 1 ? "" : "s")"
            cleanupButton.isEnabled = true
        } else {
            cleanupButton.title = "All sessions are busy"
            cleanupButton.isEnabled = false
        }

        stack.addArrangedSubview(cleanupButton)

        let restartButton = NSButton()
        restartButton.bezelStyle = .inline
        restartButton.isBordered = true
        restartButton.target = self
        restartButton.action = #selector(restartTmuxTapped)
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        if isRecoveringTmux {
            restartButton.title = "Restarting tmux…"
            restartButton.isEnabled = false
        } else if zombieCount > 0 {
            restartButton.title = "Restart tmux + Recover"
            restartButton.isEnabled = true
        } else {
            restartButton.title = "Restart tmux + Recover"
            restartButton.isEnabled = true
        }

        stack.addArrangedSubview(restartButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 24
        preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
        view.setFrameSize(NSSize(width: Self.popoverWidth, height: height))
    }

    @objc private func cleanupTapped() {
        onCleanup()
    }

    @objc private func restartTmuxTapped() {
        onRestartTmux()
    }
}

/// Persistent status bar at the bottom of the main window showing aggregate thread
/// status counts, rate-limit summary, and sync info.
final class StatusBarView: NSView, NSPopoverDelegate {

    // MARK: - Constants

    static let barHeight: CGFloat = 30

    private static let horizontalPadding: CGFloat = 20

    // MARK: - Subviews

    private let threadStatusStack = NSStackView()
    private let sessionCountButton = NSButton()
    private let rateLimitLabel = NSTextField(labelWithString: "")
    private let syncStatusLabel = NSTextField(labelWithString: "")
    private let syncRefreshButton = NSButton()
    private let separator = NSBox()

    // MARK: - State

    private nonisolated(unsafe) var statusTimer: Timer?
    private var statusButtonsByKind: [ThreadStatusSummaryKind: NSButton] = [:]
    private var lastRenderedThreadSummaries: [ThreadStatusSummaryDescriptor] = []
    private var lastRenderedThreadCount: Int = -1
    private var transientStatusThreadIds: [ThreadStatusSummaryKind: Set<UUID>] = [:]
    private var transientStatusAddedAt: [ThreadStatusSummaryKind: [UUID: Date]] = [:]
    private var activePopoverStatus: ThreadStatusSummaryKind?
    private var activePopover: NSPopover?
    private var sessionCleanupPopover: NSPopover?
    private var lastRenderedSessionCount: Int = -1
    private var lastRenderedLiveSessionCount: Int = -1
    private var lastRenderedZombieCount: Int = -1
    private var lastRenderedTmuxRecoveryState = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTransientStatusTracking()
        setupViews()
        setupObservers()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        statusTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(resource: .surface).cgColor
        }
    }

    // MARK: - Setup

    private func setupTransientStatusTracking() {
        for kind in ThreadStatusSummaryKind.allCases where !kind.usesPersistentAddedAt {
            transientStatusThreadIds[kind] = []
            transientStatusAddedAt[kind] = [:]
        }
    }

    private func setupViews() {
        wantsLayer = true
        updateLayerColors()

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        threadStatusStack.orientation = .horizontal
        threadStatusStack.alignment = .centerY
        threadStatusStack.spacing = 0
        threadStatusStack.translatesAutoresizingMaskIntoConstraints = false
        threadStatusStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        threadStatusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sessionCountButton.isBordered = false
        sessionCountButton.bezelStyle = .inline
        sessionCountButton.focusRingType = .none
        sessionCountButton.setButtonType(.momentaryChange)
        sessionCountButton.target = self
        sessionCountButton.action = #selector(sessionCountTapped)
        sessionCountButton.toolTip = "Active tmux sessions — click to manage"
        sessionCountButton.translatesAutoresizingMaskIntoConstraints = false
        updateSessionCountButton(total: 0, live: 0, zombieCount: 0, isRecoveringTmux: false)

        configureLabel(rateLimitLabel, size: 11)
        rateLimitLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureLabel(syncStatusLabel, size: 11)
        syncStatusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        syncRefreshButton.bezelStyle = .inline
        syncRefreshButton.isBordered = false
        syncRefreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(symbolConfig)
        syncRefreshButton.contentTintColor = .tertiaryLabelColor
        syncRefreshButton.target = self
        syncRefreshButton.action = #selector(syncRefreshTapped)
        syncRefreshButton.toolTip = "Refresh PR and Jira statuses"
        syncRefreshButton.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [sessionCountButton, threadStatusStack])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [rateLimitLabel, syncStatusLabel, syncRefreshButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 12
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),

            syncRefreshButton.widthAnchor.constraint(equalToConstant: 14),
            syncRefreshButton.heightAnchor.constraint(equalToConstant: 14),

            heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
    }

    private func configureLabel(_ label: NSTextField, size: CGFloat) {
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Observers

    private func setupObservers() {
        let nc = NotificationCenter.default
        let sel = #selector(handleStatusChange)

        nc.addObserver(self, selector: sel, name: .magentStatusSyncCompleted, object: nil)
        nc.addObserver(self, selector: sel, name: .magentGlobalRateLimitSummaryChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentCompletionDetected, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentRateLimitChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentBusySessionsChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentWaitingForInput, object: nil)
        nc.addObserver(self, selector: sel, name: .magentThreadCreationFinished, object: nil)
        nc.addObserver(self, selector: sel, name: .magentSessionCleanupCompleted, object: nil)
        nc.addObserver(self, selector: sel, name: .magentDeadSessionsDetected, object: nil)
        nc.addObserver(self, selector: sel, name: .magentTmuxHealthChanged, object: nil)

        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    @objc private func handleStatusChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        updateThreadStatus()
        updateSessionCount()
        updateRateLimitStatus()
        updateSyncStatus()
        rebuildRateLimitMenu()
        rebuildSyncMenu()
    }

    private func updateThreadStatus() {
        let threads = ThreadManager.shared.threads
        syncTransientStatusAddedAt(with: threads)

        let summaries = ThreadStatusSummaryKind.allCases.compactMap { kind -> ThreadStatusSummaryDescriptor? in
            let count = threads.lazy.filter { kind.matches($0) }.count
            guard count > 0 else { return nil }
            return ThreadStatusSummaryDescriptor(kind: kind, count: count)
        }

        let shouldRebuild = summaries != lastRenderedThreadSummaries || threads.count != lastRenderedThreadCount
        let previouslyOpenStatus = activePopover?.isShown == true ? activePopoverStatus : nil

        if shouldRebuild {
            if previouslyOpenStatus != nil {
                activePopover?.close()
            }
            rebuildThreadStatusSegments(summaries: summaries, totalCount: threads.count)
            lastRenderedThreadSummaries = summaries
            lastRenderedThreadCount = threads.count
        }

        refreshActivePopover()

        if shouldRebuild, let status = previouslyOpenStatus {
            showPopover(for: status)
        }
    }

    private func rebuildThreadStatusSegments(summaries: [ThreadStatusSummaryDescriptor], totalCount: Int) {
        statusButtonsByKind.removeAll()
        threadStatusStack.arrangedSubviews.forEach { subview in
            threadStatusStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        guard !summaries.isEmpty else {
            threadStatusStack.addArrangedSubview(
                makeStaticStatusLabel(
                    text: "\(totalCount) thread\(totalCount == 1 ? "" : "s")",
                    color: .tertiaryLabelColor
                )
            )
            return
        }

        for (index, summary) in summaries.enumerated() {
            if index > 0 {
                threadStatusStack.addArrangedSubview(makeSeparatorLabel())
            }
            let button = makeStatusButton(for: summary)
            statusButtonsByKind[summary.kind] = button
            threadStatusStack.addArrangedSubview(button)
        }
    }

    private func makeStatusButton(for summary: ThreadStatusSummaryDescriptor) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: summary.kind.symbolName,
            accessibilityDescription: summary.kind.buttonTitle
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = summary.kind.color
        button.target = self
        button.action = #selector(threadStatusTapped(_:))
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.attributedTitle = NSAttributedString(
            string: "\(summary.count) \(summary.kind.buttonTitle)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: summary.kind.color
            ]
        )
        button.setAccessibilityLabel("\(summary.count) \(summary.kind.buttonTitle)")
        button.identifier = NSUserInterfaceItemIdentifier(summary.kind.rawValue)
        return button
    }

    private func makeSeparatorLabel() -> NSTextField {
        makeStaticStatusLabel(text: "  ·  ", color: .tertiaryLabelColor)
    }

    private func makeStaticStatusLabel(text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func syncTransientStatusAddedAt(with threads: [MagentThread]) {
        let now = Date()
        for kind in ThreadStatusSummaryKind.allCases where !kind.usesPersistentAddedAt {
            let currentIds = Set(threads.filter { kind.matches($0) }.map(\.id))
            let previousIds = transientStatusThreadIds[kind] ?? []
            var addedAtById = transientStatusAddedAt[kind] ?? [:]

            for addedId in currentIds.subtracting(previousIds) {
                addedAtById[addedId] = now
            }
            for removedId in previousIds.subtracting(currentIds) {
                addedAtById.removeValue(forKey: removedId)
            }

            transientStatusThreadIds[kind] = currentIds
            transientStatusAddedAt[kind] = addedAtById
        }
    }

    private func popoverEntries(for status: ThreadStatusSummaryKind) -> [ThreadStatusPopoverEntry] {
        let threads = ThreadManager.shared.threads.filter { status.matches($0) }
        guard !threads.isEmpty else { return [] }

        let newestFirst: [ThreadStatusPopoverEntry]
        if status.usesPersistentAddedAt {
            newestFirst = threads.compactMap { thread in
                guard let addedAt = thread.lastAgentCompletionAt else { return nil }
                return ThreadStatusPopoverEntry(thread: thread, addedAt: addedAt)
            }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.thread.createdAt > rhs.thread.createdAt
            }
        } else {
            let addedAtById = transientStatusAddedAt[status] ?? [:]
            newestFirst = threads.map { thread in
                ThreadStatusPopoverEntry(
                    thread: thread,
                    addedAt: addedAtById[thread.id] ?? thread.createdAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.thread.createdAt > rhs.thread.createdAt
            }
        }

        return Array(newestFirst.prefix(3).reversed())
    }

    private func refreshActivePopover() {
        guard let status = activePopoverStatus,
              let popover = activePopover,
              popover.isShown else { return }

        let entries = popoverEntries(for: status)
        guard !entries.isEmpty else {
            popover.close()
            return
        }

        if let content = popover.contentViewController as? ThreadStatusPopoverViewController {
            content.update(entries: entries)
        }
    }

    private func updateRateLimitStatus() {
        let summary = ThreadManager.shared.globalRateLimitSummaryText()
        if let summary {
            rateLimitLabel.stringValue = "⏳ \(summary)"
            rateLimitLabel.textColor = .systemOrange
            rateLimitLabel.toolTip = summary
            rateLimitLabel.isHidden = false
        } else {
            rateLimitLabel.stringValue = ""
            rateLimitLabel.toolTip = nil
            rateLimitLabel.isHidden = true
        }
    }

    private var baseSyncTooltip: String {
        let hasJira = PersistenceService.shared.loadSettings().projects.contains(where: \.jiraSyncEnabled)
        if hasJira {
            return "Periodically syncs PR status (GitHub) and Jira ticket info for all active threads. Right-click to refresh manually."
        } else {
            return "Periodically syncs PR status (GitHub) for all active threads. Right-click to refresh manually."
        }
    }

    private func syncTooltip(for threadManager: ThreadManager) -> String {
        guard threadManager.lastStatusSyncFailed,
              let failureSummary = threadManager.lastStatusSyncFailureSummary,
              !failureSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseSyncTooltip
        }

        return "\(baseSyncTooltip)\n\nLast failure:\n\(failureSummary)"
    }

    private func updateSyncStatus() {
        let tm = ThreadManager.shared

        guard let lastSync = tm.lastStatusSyncAt else {
            if !tm.threads.isEmpty {
                syncStatusLabel.stringValue = "Syncing…"
                syncStatusLabel.textColor = .tertiaryLabelColor
                syncStatusLabel.toolTip = syncTooltip(for: tm)
                syncRefreshButton.isHidden = true
            } else {
                syncStatusLabel.stringValue = ""
                syncStatusLabel.toolTip = nil
                syncRefreshButton.isHidden = true
            }
            return
        }

        if tm.lastStatusSyncFailed {
            syncStatusLabel.stringValue = "Sync failed \(Self.relativeTimeString(from: lastSync))"
            syncStatusLabel.textColor = .systemRed
        } else {
            syncStatusLabel.stringValue = "Synced \(Self.relativeTimeString(from: lastSync))"
            syncStatusLabel.textColor = .tertiaryLabelColor
        }
        syncStatusLabel.toolTip = syncTooltip(for: tm)
        syncRefreshButton.isHidden = false
    }

    // MARK: - Session Count

    private func updateSessionCount() {
        let tm = ThreadManager.shared
        let total = tm.totalSessionCount
        let live = tm.liveSessionCount
        let zombieCount = tm.lastTmuxZombieSummary?.zombieCount ?? 0
        let isRecoveringTmux = tm.isRestartingTmuxForRecovery
        guard total != lastRenderedSessionCount
            || live != lastRenderedLiveSessionCount
            || zombieCount != lastRenderedZombieCount
            || isRecoveringTmux != lastRenderedTmuxRecoveryState else { return }
        lastRenderedSessionCount = total
        lastRenderedLiveSessionCount = live
        lastRenderedZombieCount = zombieCount
        lastRenderedTmuxRecoveryState = isRecoveringTmux
        updateSessionCountButton(total: total, live: live, zombieCount: zombieCount, isRecoveringTmux: isRecoveringTmux)
    }

    private func updateSessionCountButton(total: Int, live: Int, zombieCount: Int, isRecoveringTmux: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        sessionCountButton.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Sessions"
        )?.withSymbolConfiguration(symbolConfig)
        sessionCountButton.imagePosition = .imageLeading
        sessionCountButton.imageHugsTitle = true
        sessionCountButton.contentTintColor = zombieCount > 0 || isRecoveringTmux ? .systemOrange : .secondaryLabelColor

        let displayText = live < total ? "\(live)/\(total)" : "\(total)"
        let zombieSuffix = zombieCount > 0 ? " · z\(zombieCount)" : ""
        sessionCountButton.attributedTitle = NSAttributedString(
            string: displayText + zombieSuffix,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: zombieCount > 0 || isRecoveringTmux ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            ]
        )
        var accessibilityLabel = "\(live) live, \(total) total sessions"
        if zombieCount > 0 {
            accessibilityLabel += ", \(zombieCount) tmux defunct processes detected"
        }
        if isRecoveringTmux {
            accessibilityLabel += ", tmux recovery in progress"
        }
        sessionCountButton.setAccessibilityLabel(accessibilityLabel)
        if isRecoveringTmux {
            sessionCountButton.toolTip = "Active tmux sessions — tmux recovery in progress"
        } else if zombieCount > 0 {
            sessionCountButton.toolTip = "Active tmux sessions — \(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es") detected"
        } else {
            sessionCountButton.toolTip = "Active tmux sessions — click to manage"
        }
        sessionCountButton.isHidden = total == 0 && zombieCount == 0 && !isRecoveringTmux
    }

    @objc private func sessionCountTapped() {
        if sessionCleanupPopover?.isShown == true {
            sessionCleanupPopover?.close()
            return
        }

        let tm = ThreadManager.shared
        let total = tm.totalSessionCount
        let live = tm.liveSessionCount
        let protectedCount = tm.protectedSessionCount
        let idleCount = live - protectedCount
        let zombieSummary = tm.lastTmuxZombieSummary

        let vc = SessionCleanupPopoverViewController(
            totalSessions: total,
            liveSessions: live,
            protectedSessions: protectedCount,
            idleSessions: max(0, idleCount),
            zombieCount: zombieSummary?.zombieCount ?? 0,
            zombieParentPid: zombieSummary?.parentPid,
            isRecoveringTmux: tm.isRestartingTmuxForRecovery,
            onCleanup: { [weak self] in
                self?.sessionCleanupPopover?.close()
                self?.showCleanupConfirmation()
            },
            onRestartTmux: { [weak self] in
                self?.sessionCleanupPopover?.close()
                Task {
                    await ThreadManager.shared.restartTmuxAndRecoverSessions()
                }
            }
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = vc

        sessionCleanupPopover = popover
        popover.show(relativeTo: sessionCountButton.bounds, of: sessionCountButton, preferredEdge: .maxY)
    }

    private func showCleanupConfirmation() {
        let candidates = ThreadManager.shared.collectCleanupCandidates()
        guard !candidates.isEmpty else {
            BannerManager.shared.show(message: "No idle sessions to clean up.", style: .info)
            return
        }

        // Group candidates by thread.
        var threadOrder: [UUID] = []
        var threadGroups: [UUID: (name: String, isEntire: Bool, tabs: [String])] = [:]
        for c in candidates {
            if threadGroups[c.threadId] == nil {
                threadOrder.append(c.threadId)
                threadGroups[c.threadId] = (name: c.threadName, isEntire: c.isEntireThread, tabs: [])
            }
            if !c.isEntireThread {
                let tabLabel = c.tabDisplayName ?? c.sessionName
                threadGroups[c.threadId]?.tabs.append(tabLabel)
            }
        }

        // Build summary lines.
        var lines: [String] = []
        for tid in threadOrder {
            guard let group = threadGroups[tid] else { continue }
            if group.isEntire {
                lines.append("• \(group.name) (all tabs)")
            } else {
                let tabList = group.tabs.joined(separator: ", ")
                lines.append("• \(group.name): \(tabList)")
            }
        }

        let alert = NSAlert()
        alert.messageText = "Close \(candidates.count) idle session\(candidates.count == 1 ? "" : "s")?"
        alert.informativeText = "The following sessions will be killed. They will be recreated on demand when you revisit the tab. Protected (shielded/pinned) sessions are excluded.\n\nConfigure in Settings → Threads."

        // Scrollable list of sessions.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(CGFloat(lines.count) * 18 + 8, 200)))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = lines.joined(separator: "\n")
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Close Sessions")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            let closed = await ThreadManager.shared.cleanupIdleSessions()
            await MainActor.run {
                if closed > 0 {
                    BannerManager.shared.show(
                        message: "Closed \(closed) idle session\(closed == 1 ? "" : "s").",
                        style: .info
                    )
                }
            }
        }
    }

    // MARK: - Context Menus

    private func rebuildRateLimitMenu() {
        let menu = NSMenu(title: "Rate Limits")
        menu.autoenablesItems = false

        for agent: AgentType in [.claude, .codex] {
            if agent == .codex { menu.addItem(.separator()) }
            let hasActive = ThreadManager.shared.hasActiveRateLimit(for: agent)
            let shortName = agent == .claude ? "Claude" : "Codex"

            let liftItem = NSMenuItem(title: "Lift \(shortName) Limit Now", action: #selector(liftRateLimit(_:)), keyEquivalent: "")
            liftItem.target = self
            liftItem.representedObject = agent.rawValue
            liftItem.isEnabled = hasActive
            menu.addItem(liftItem)

            let ignoreItem = NSMenuItem(title: "Lift + Ignore Current \(shortName) Messages", action: #selector(liftAndIgnoreRateLimit(_:)), keyEquivalent: "")
            ignoreItem.target = self
            ignoreItem.representedObject = agent.rawValue
            ignoreItem.isEnabled = hasActive
            menu.addItem(ignoreItem)
        }

        rateLimitLabel.menu = menu
    }

    private func rebuildSyncMenu() {
        let menu = NSMenu(title: "Sync")
        menu.autoenablesItems = false

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(syncRefreshTapped), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        if ThreadManager.shared.lastStatusSyncFailed,
           let failureSummary = ThreadManager.shared.lastStatusSyncFailureSummary {
            let lines = failureSummary
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty {
                menu.addItem(.separator())

                let headerItem = NSMenuItem(title: "Last Failure", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                menu.addItem(headerItem)

                for line in lines.prefix(6) {
                    let lineItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    lineItem.isEnabled = false
                    menu.addItem(lineItem)
                }
            }
        }

        syncStatusLabel.menu = menu
    }

    // MARK: - Actions

    @objc private func threadStatusTapped(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let status = ThreadStatusSummaryKind(rawValue: rawValue) else { return }

        if activePopoverStatus == status, activePopover?.isShown == true {
            activePopover?.close()
            return
        }

        showPopover(for: status)
    }

    private func showPopover(for status: ThreadStatusSummaryKind) {
        let entries = popoverEntries(for: status)
        guard !entries.isEmpty,
              let anchorButton = statusButtonsByKind[status] else { return }

        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = ThreadStatusPopoverViewController(
            status: status,
            entries: entries,
            onSelectThread: { [weak self] threadId in
                self?.activePopover?.close()
                let sessionName = self?.navigationSessionName(for: status, threadId: threadId)
                NotificationCenter.default.post(
                    name: .magentNavigateToThread,
                    object: self,
                    userInfo: [
                        "threadId": threadId,
                        "sessionName": sessionName as Any
                    ]
                )
            }
        )

        activePopoverStatus = status
        activePopover = popover
        popover.show(relativeTo: anchorButton.bounds, of: anchorButton, preferredEdge: .maxY)
    }

    private func navigationSessionName(for status: ThreadStatusSummaryKind, threadId: UUID) -> String? {
        guard let thread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) else { return nil }

        let orderedTerminalSessions = thread.tmuxSessionNames + thread.agentTmuxSessions.filter { !thread.tmuxSessionNames.contains($0) }

        switch status {
        case .busy:
            return orderedTerminalSessions.first {
                thread.busySessions.contains($0) || thread.magentBusySessions.contains($0)
            }
        case .waiting:
            return orderedTerminalSessions.first {
                thread.waitingForInputSessions.contains($0)
            }
        case .done:
            return orderedTerminalSessions.first {
                thread.unreadCompletionSessions.contains($0)
            }
        case .rateLimited:
            return orderedTerminalSessions.first {
                thread.rateLimitedSessions[$0] != nil
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            if popover === activePopover {
                activePopover = nil
                activePopoverStatus = nil
            }
            if popover === sessionCleanupPopover {
                sessionCleanupPopover = nil
            }
        } else {
            activePopover = nil
            activePopoverStatus = nil
            sessionCleanupPopover = nil
        }
    }

    @objc private func syncRefreshTapped() {
        ThreadManager.shared.forceRefreshStatuses()
        syncStatusLabel.stringValue = "Syncing…"
        syncStatusLabel.textColor = .tertiaryLabelColor
        syncRefreshButton.isHidden = true
    }

    @objc private func liftRateLimit(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }
        Task {
            _ = await ThreadManager.shared.liftRateLimitManually(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                BannerManager.shared.show(message: "\(shortName) rate limit lifted manually.", style: .info)
                refresh()
            }
        }
    }

    @objc private func liftAndIgnoreRateLimit(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }
        Task {
            let ignoredCount = await ThreadManager.shared.liftAndIgnoreCurrentRateLimitFingerprints(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                let message: String
                if ignoredCount > 0 {
                    message = "\(shortName) limit lifted. Ignoring \(ignoredCount) current fingerprint\(ignoredCount == 1 ? "" : "s")."
                } else {
                    message = "\(shortName) limit lifted. No active fingerprints found to ignore."
                }
                BannerManager.shared.show(message: message, style: .info)
                refresh()
            }
        }
    }

    // MARK: - Helpers

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
