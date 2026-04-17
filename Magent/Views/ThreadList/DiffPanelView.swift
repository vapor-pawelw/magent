import Cocoa
import MagentCore

// MARK: - Flipped clip view for top-aligned scroll content

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Drag handle for resizing

private final class DiffPanelResizeHandle: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}

// MARK: - Clickable file row

private final class DiffFileRowView: NSView {
    let filePath: String
    var workingStatus: FileWorkingStatus = .committed
    var onClick: ((String) -> Void)?
    var onSecondaryClick: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onShowInFinder: ((String) -> Void)?
    var onCopyFilename: ((String) -> Void)?
    var onStageToggle: ((String) -> Void)?
    var onDiscard: ((String, FileWorkingStatus) -> Void)?

    var isFileSelected: Bool = false {
        didSet {
            wantsLayer = true
            if isFileSelected {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                layer?.cornerRadius = 4
            } else {
                layer?.backgroundColor = nil
            }
        }
    }

    init(filePath: String) {
        self.filePath = filePath
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?(filePath)
            return
        }
        onClick?(filePath)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSecondaryClick?(filePath)

        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Filename", action: #selector(copyFilenameToPasteboard), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(showInFinderFromMenu(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = OpenActionIcons.finderIcon(size: 16)
        menu.addItem(finderItem)

        if workingStatus != .committed {
            menu.addItem(.separator())
            let stageTitle = workingStatus == .staged ? "Unstage" : "Stage"
            let stageItem = NSMenuItem(title: stageTitle, action: #selector(stageToggleFromMenu), keyEquivalent: "")
            stageItem.target = self
            menu.addItem(stageItem)

            let discardItem = NSMenuItem(title: "Discard Changes", action: #selector(discardFromMenu), keyEquivalent: "")
            discardItem.target = self
            discardItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Discard changes")
            menu.addItem(discardItem)
        }

        return menu
    }

    @objc private func copyFilenameToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(filePath, forType: .string)
    }

    @objc private func showInFinderFromMenu(_ sender: NSMenuItem) {
        onShowInFinder?(filePath)
    }

    @objc private func stageToggleFromMenu() {
        onStageToggle?(filePath)
    }

    @objc private func discardFromMenu() {
        onDiscard?(filePath, workingStatus)
    }
}

// MARK: - Clickable commit row

private final class CommitRowView: NSView {
    let commitHash: String
    var commitMessage: String = ""
    var onClick: ((String) -> Void)?
    var onSecondaryClick: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onDiscardUncommittedChanges: (() -> Void)?

    var isSelected: Bool = false {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : nil
            layer?.cornerRadius = isSelected ? 4 : 0
        }
    }

    init(commitHash: String) {
        self.commitHash = commitHash
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(commitHash)
        } else {
            onClick?(commitHash)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSecondaryClick?(commitHash)

        if commitHash == "__uncommitted__" {
            guard onDiscardUncommittedChanges != nil else { return nil }
            let menu = NSMenu()
            let discardItem = NSMenuItem(
                title: "Discard Changes",
                action: #selector(discardUncommittedChangesFromMenu),
                keyEquivalent: ""
            )
            discardItem.target = self
            discardItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Discard changes")
            menu.addItem(discardItem)
            return menu
        }

        let menu = NSMenu()

        let copyHash = NSMenuItem(title: "Copy Hash", action: #selector(copyHashToPasteboard), keyEquivalent: "")
        copyHash.target = self
        menu.addItem(copyHash)

        let copyMessage = NSMenuItem(title: "Copy Message", action: #selector(copyMessageToPasteboard), keyEquivalent: "")
        copyMessage.target = self
        menu.addItem(copyMessage)

        return menu
    }

    @objc private func copyHashToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commitHash, forType: .string)
    }

    @objc private func copyMessageToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commitMessage, forType: .string)
    }

    @objc private func discardUncommittedChangesFromMenu() {
        onDiscardUncommittedChanges?()
    }
}

private enum DiffPanelTab {
    case commits
    case changes
}

final class DiffPanelView: NSView {

    private let handleView = DiffPanelResizeHandle()
    private let separatorView = NSView()
    private let tabBarStack = NSStackView()
    private let commitsTabButton = NSButton()
    private let changesTabButton = NSButton()
    private let topRightButtonStack = NSStackView()
    private let refreshButton = NSButton()
    private let infoButton = NSButton()
    private let contextThreadBadgeView = NSView()
    private let commitContextLabel = NSTextField(labelWithString: "")
    private let scrollView = NonFlashingScrollView()
    private let stackView = NSStackView()
    private let branchInfoLabel = NSTextField(labelWithString: "")
    private let baseLineLabel = NSTextField(labelWithString: "⤷ ")
    private let baseBranchButton = NSButton()
    private let baseLineStack = NSStackView()
    private let remoteStatusLabel = NSTextField(labelWithString: "")
    private let branchInfoStack = NSStackView()

    // Working-tree entries (always loaded from git status)
    private var uncommittedEntries: [FileDiffEntry] = []
    // Entries for the currently selected commit (populated on commit selection)
    private var commitEntries: [FileDiffEntry] = []
    private var commits: [BranchCommit] = []
    private var activeTab: DiffPanelTab = .commits
    // nil = "Uncommitted" selected; non-nil = a commit hash is selected
    private var selectedCommitHash: String? = nil
    private var selectedFilePath: String?
    private var worktreePath: String?
    private var hasMoreCommits = false
    private var forceVisible = false
    private var contextThreadIndicatorText: String?

    // MARK: - Collapse state
    private static let collapsedKey = "DiffPanelView.collapsed"
    private var isCollapsed: Bool = UserDefaults.standard.bool(forKey: DiffPanelView.collapsedKey) {
        didSet { UserDefaults.standard.set(isCollapsed, forKey: Self.collapsedKey) }
    }
    private let collapseButton = NSButton()
    private var tabBarTopToHandleConstraint: NSLayoutConstraint!
    private var tabBarTopToContextBadgeConstraint: NSLayoutConstraint!
    /// Active only in collapsed mode — pins branch info directly below the separator
    private var collapsedTopConstraint: NSLayoutConstraint!

    // MARK: - Commit detail mode
    private var isInCommitDetailMode = false
    private var commitDetailHash: String? = nil
    private var commitDetailEntries: [FileDiffEntry] = []
    private let commitDetailHeaderView = NSView()
    private let backButton = NSButton()
    private let commitDetailTitleLabel = NSTextField(labelWithString: "")

    private var heightConstraint: NSLayoutConstraint!
    private var expandedHeight: CGFloat = DiffPanelView.defaultHeight
    private static let minHeight: CGFloat = 60
    private static let maxHeight: CGFloat = 500
    private static let defaultHeight: CGFloat = 140
    private static let heightKey = "DiffPanelView.height"

    private var isDragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0

    var onLoadMoreCommits: (() -> Void)?
    /// Called when the ALL CHANGES tab needs branch-wide entries loaded.
    var onAllChangesRequested: (() -> Void)?
    /// Called when the user selects a commit (nil = "Uncommitted").
    var onCommitSelected: ((String?) -> Void)?
    /// Called when the user double-taps a commit row (nil = "Uncommitted"). Second arg is display title.
    var onCommitDoubleTapped: ((String?, String) -> Void)?
    /// Called when the user clicks the base branch label to change it.
    var onBaseBranchClicked: ((_ anchorView: NSView) -> Void)?
    /// Called when the user requests a manual git refresh for the selected thread.
    var onRefreshRequested: (() -> Void)?

    private var allBranchEntries: [FileDiffEntry]?
    private var isLoadingAllChanges = false

    /// The entries currently shown in the ALL CHANGES tab.
    private var activeEntries: [FileDiffEntry] {
        allBranchEntries ?? []
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        // Resize handle area at top
        handleView.wantsLayer = true
        handleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handleView)

        // Separator (visual line inside the handle area)
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.4).cgColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        handleView.addSubview(separatorView)

        // Tab bar — COMMITS first (leftmost), then CHANGES
        let commitsBtn = commitsTabButton
        commitsBtn.title = "COMMITS"
        commitsBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        commitsBtn.contentTintColor = NSColor.labelColor  // active by default
        commitsBtn.isBordered = false
        commitsBtn.alignment = .left
        commitsBtn.lineBreakMode = .byTruncatingTail
        commitsBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        commitsBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commitsBtn.target = self
        commitsBtn.action = #selector(commitsTabTapped)
        commitsBtn.translatesAutoresizingMaskIntoConstraints = false
        commitsBtn.isHidden = true

        let changesBtn = changesTabButton
        changesBtn.title = "ALL CHANGES"
        changesBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        changesBtn.contentTintColor = NSColor(resource: .textSecondary)
        changesBtn.isBordered = false
        changesBtn.alignment = .left
        changesBtn.lineBreakMode = .byTruncatingTail
        changesBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        changesBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        changesBtn.target = self
        changesBtn.action = #selector(changesTabTapped)
        changesBtn.translatesAutoresizingMaskIntoConstraints = false

        tabBarStack.orientation = .horizontal
        tabBarStack.spacing = 12
        tabBarStack.alignment = .centerY
        tabBarStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabBarStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabBarStack.addArrangedSubview(commitsBtn)
        tabBarStack.addArrangedSubview(changesBtn)
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBarStack)

        let topRightButtonConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh changes panel"
        )?.withSymbolConfiguration(topRightButtonConfig)
        refreshButton.isBordered = false
        refreshButton.contentTintColor = NSColor(resource: .textSecondary).withAlphaComponent(0.6)
        refreshButton.target = self
        refreshButton.action = #selector(refreshButtonTapped)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.toolTip = "Refresh git status, branch, commits, and changes"
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Info button — shows color legend popover
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Color legend")?.withSymbolConfiguration(topRightButtonConfig)
        infoButton.isBordered = false
        infoButton.contentTintColor = NSColor(resource: .textSecondary).withAlphaComponent(0.6)
        infoButton.target = self
        infoButton.action = #selector(infoButtonTapped)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.toolTip = "Color legend"
        infoButton.setContentHuggingPriority(.required, for: .horizontal)
        infoButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        topRightButtonStack.orientation = .horizontal
        topRightButtonStack.spacing = 6
        topRightButtonStack.alignment = .centerY
        topRightButtonStack.setContentHuggingPriority(.required, for: .horizontal)
        topRightButtonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        topRightButtonStack.translatesAutoresizingMaskIntoConstraints = false
        topRightButtonStack.addArrangedSubview(refreshButton)
        topRightButtonStack.addArrangedSubview(infoButton)
        addSubview(topRightButtonStack)

        contextThreadBadgeView.wantsLayer = true
        contextThreadBadgeView.layer?.cornerRadius = 5
        contextThreadBadgeView.layer?.borderWidth = 1
        contextThreadBadgeView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        contextThreadBadgeView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        contextThreadBadgeView.translatesAutoresizingMaskIntoConstraints = false
        contextThreadBadgeView.isHidden = true
        addSubview(contextThreadBadgeView)

        // Context badge label — highlights when diff panel shows a non-selected thread.
        commitContextLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        commitContextLabel.textColor = NSColor.controlAccentColor
        commitContextLabel.lineBreakMode = .byTruncatingTail
        commitContextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commitContextLabel.translatesAutoresizingMaskIntoConstraints = false
        commitContextLabel.isHidden = true
        contextThreadBadgeView.addSubview(commitContextLabel)

        // Stack view for file/commit entries
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Use flipped clip view so content aligns to top
        let flippedClip = FlippedClipView()
        flippedClip.drawsBackground = false
        scrollView.contentView = flippedClip
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Branch info at the bottom — line 1: branch name, line 2: "Base: " + clickable button
        branchInfoLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchInfoLabel.textColor = NSColor(resource: .textSecondary).withAlphaComponent(0.7)
        branchInfoLabel.lineBreakMode = .byTruncatingMiddle
        branchInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        baseLineLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        baseLineLabel.textColor = NSColor(resource: .textSecondary).withAlphaComponent(0.7)
        baseLineLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        baseLineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        baseBranchButton.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        baseBranchButton.isBordered = false
        baseBranchButton.contentTintColor = NSColor.controlAccentColor
        baseBranchButton.target = self
        baseBranchButton.action = #selector(baseBranchTapped)
        baseBranchButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        baseBranchButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        baseBranchButton.toolTip = "Click to change base branch"

        baseLineStack.orientation = .horizontal
        baseLineStack.spacing = 0
        baseLineStack.alignment = .firstBaseline
        baseLineStack.addArrangedSubview(baseLineLabel)
        baseLineStack.addArrangedSubview(baseBranchButton)

        remoteStatusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        remoteStatusLabel.textColor = NSColor(resource: .textSecondary).withAlphaComponent(0.7)
        remoteStatusLabel.lineBreakMode = .byTruncatingTail
        remoteStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        remoteStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteStatusLabel.isHidden = true

        // Collapse/expand chevron — sits at the trailing edge of the branch info area
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        // Expanded → chevron.down (click to collapse downward); collapsed → chevron.up (click to expand upward)
        collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse panel")?.withSymbolConfiguration(chevronConfig)
        collapseButton.isBordered = false
        collapseButton.contentTintColor = NSColor(resource: .textSecondary).withAlphaComponent(0.6)
        collapseButton.target = self
        collapseButton.action = #selector(collapseToggleTapped)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        collapseButton.setContentHuggingPriority(.required, for: .horizontal)
        collapseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        collapseButton.toolTip = "Collapse to show only branch info"
        // Generous tap target
        collapseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        collapseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        addSubview(collapseButton)

        branchInfoStack.orientation = .vertical
        branchInfoStack.spacing = 1
        branchInfoStack.alignment = .leading
        branchInfoStack.addArrangedSubview(branchInfoLabel)
        branchInfoStack.addArrangedSubview(baseLineStack)
        branchInfoStack.addArrangedSubview(remoteStatusLabel)
        branchInfoStack.translatesAutoresizingMaskIntoConstraints = false
        branchInfoStack.isHidden = true
        addSubview(branchInfoStack)

        // Commit detail header — replaces tab bar in commit detail mode
        backButton.title = "‹ Back"
        backButton.font = .systemFont(ofSize: 11, weight: .semibold)
        backButton.contentTintColor = NSColor.controlAccentColor
        backButton.isBordered = false
        backButton.target = self
        backButton.action = #selector(backButtonTapped)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        commitDetailTitleLabel.font = .systemFont(ofSize: 11)
        commitDetailTitleLabel.textColor = NSColor(resource: .textSecondary)
        commitDetailTitleLabel.lineBreakMode = .byTruncatingMiddle
        commitDetailTitleLabel.maximumNumberOfLines = 1
        commitDetailTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commitDetailTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        commitDetailHeaderView.translatesAutoresizingMaskIntoConstraints = false
        commitDetailHeaderView.isHidden = true
        commitDetailHeaderView.addSubview(backButton)
        commitDetailHeaderView.addSubview(commitDetailTitleLabel)
        addSubview(commitDetailHeaderView)

        backButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: commitDetailHeaderView.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: commitDetailHeaderView.centerYAnchor),

            commitDetailTitleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            commitDetailTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topRightButtonStack.leadingAnchor, constant: -4),
            commitDetailTitleLabel.centerYAnchor.constraint(equalTo: commitDetailHeaderView.centerYAnchor),
        ])

        let savedHeight = UserDefaults.standard.object(forKey: Self.heightKey) as? CGFloat ?? Self.defaultHeight
        let clampedHeight = min(max(savedHeight, Self.minHeight), Self.maxHeight)
        expandedHeight = clampedHeight
        heightConstraint = heightAnchor.constraint(equalToConstant: clampedHeight)

        tabBarTopToHandleConstraint = tabBarStack.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4)
        tabBarTopToContextBadgeConstraint = tabBarStack.topAnchor.constraint(equalTo: contextThreadBadgeView.bottomAnchor, constant: 4)

        NSLayoutConstraint.activate([
            handleView.topAnchor.constraint(equalTo: topAnchor),
            handleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            handleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            handleView.heightAnchor.constraint(equalToConstant: 6),

            separatorView.centerYAnchor.constraint(equalTo: handleView.centerYAnchor),
            separatorView.leadingAnchor.constraint(equalTo: handleView.leadingAnchor, constant: 8),
            separatorView.trailingAnchor.constraint(equalTo: handleView.trailingAnchor, constant: -8),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            tabBarStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBarStack.trailingAnchor.constraint(lessThanOrEqualTo: topRightButtonStack.leadingAnchor, constant: -4),

            topRightButtonStack.centerYAnchor.constraint(equalTo: tabBarStack.centerYAnchor),
            topRightButtonStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            contextThreadBadgeView.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4),
            contextThreadBadgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contextThreadBadgeView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            commitContextLabel.topAnchor.constraint(equalTo: contextThreadBadgeView.topAnchor, constant: 2),
            commitContextLabel.leadingAnchor.constraint(equalTo: contextThreadBadgeView.leadingAnchor, constant: 8),
            commitContextLabel.trailingAnchor.constraint(equalTo: contextThreadBadgeView.trailingAnchor, constant: -8),
            commitContextLabel.bottomAnchor.constraint(equalTo: contextThreadBadgeView.bottomAnchor, constant: -2),

            scrollView.topAnchor.constraint(equalTo: tabBarStack.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: branchInfoStack.topAnchor, constant: -4),

            branchInfoStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchInfoStack.trailingAnchor.constraint(lessThanOrEqualTo: collapseButton.leadingAnchor, constant: -4),
            branchInfoStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            collapseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            collapseButton.centerYAnchor.constraint(equalTo: branchInfoStack.centerYAnchor),

            commitDetailHeaderView.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4),
            commitDetailHeaderView.leadingAnchor.constraint(equalTo: leadingAnchor),
            commitDetailHeaderView.trailingAnchor.constraint(equalTo: trailingAnchor),
            commitDetailHeaderView.heightAnchor.constraint(equalTo: tabBarStack.heightAnchor),

            heightConstraint,

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            tabBarTopToHandleConstraint,
        ])

        // Collapsed-mode constraint: branch info sits right below the separator
        collapsedTopConstraint = branchInfoStack.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4)
        collapsedTopConstraint.isActive = false

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDiffViewerScrolledToFile(_:)),
            name: .magentDiffViewerScrolledToFile,
            object: nil
        )

        // Set initial chevron direction from persisted state
        applyCollapsedState(animated: false)

        clear()
    }

    // MARK: - Drag to resize

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !isCollapsed, location.y >= bounds.maxY - 6 {
            isDragging = true
            dragStartY = NSEvent.mouseLocation.y
            dragStartHeight = heightConstraint.constant
        } else {
            // Check if click landed on a file row; if not, deselect
            let windowPoint = event.locationInWindow
            if let hitView = window?.contentView?.hitTest(windowPoint) {
                var current: NSView? = hitView
                var foundRow = false
                while let v = current {
                    if v is DiffFileRowView || v is CommitRowView {
                        foundRow = true
                        break
                    }
                    if v === self { break }
                    current = v.superview
                }
                if !foundRow {
                    deselectFile()
                }
            }
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { super.mouseDragged(with: event); return }
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        let newHeight = min(max(dragStartHeight + delta, Self.minHeight), Self.maxHeight)
        heightConstraint.constant = newHeight
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            expandedHeight = min(max(heightConstraint.constant, Self.minHeight), Self.maxHeight)
            UserDefaults.standard.set(heightConstraint.constant, forKey: Self.heightKey)
        } else {
            super.mouseUp(with: event)
        }
    }

    // MARK: - Keyboard Navigation

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard activeTab == .changes, !activeEntries.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch Int(event.keyCode) {
        case 126: // Up arrow
            let currentIndex = activeEntries.firstIndex(where: { $0.relativePath == selectedFilePath })
            let newIndex: Int
            if let idx = currentIndex {
                newIndex = idx > 0 ? idx - 1 : activeEntries.count - 1
            } else {
                newIndex = activeEntries.count - 1
            }
            selectFile(activeEntries[newIndex].relativePath)

        case 125: // Down arrow
            let currentIndex = activeEntries.firstIndex(where: { $0.relativePath == selectedFilePath })
            let newIndex: Int
            if let idx = currentIndex {
                newIndex = idx < activeEntries.count - 1 ? idx + 1 : 0
            } else {
                newIndex = 0
            }
            selectFile(activeEntries[newIndex].relativePath)

        case 53: // Escape
            deselectFile()
            window?.makeFirstResponder(nil)

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - File Selection

    private func selectFile(_ filePath: String) {
        NSLog("[DiffPanel] selectFile: %@", filePath)
        selectedFilePath = filePath
        updateRowSelectionAppearance()
        window?.makeFirstResponder(self)
        NSLog("[DiffPanel] posting magentShowDiffViewer notification")
        var userInfo: [String: Any] = ["filePath": filePath]
        if isInCommitDetailMode {
            if let hash = commitDetailHash {
                userInfo["commitHash"] = hash
            } else {
                userInfo["mode"] = "uncommitted"
            }
        } else if let hash = selectedCommitHash {
            userInfo["commitHash"] = hash
        }
        NotificationCenter.default.post(
            name: .magentShowDiffViewer,
            object: nil,
            userInfo: userInfo
        )
        NSLog("[DiffPanel] notification posted, returning")
    }

    private func deselectFile() {
        guard selectedFilePath != nil else { return }
        selectedFilePath = nil
        updateRowSelectionAppearance()
        NotificationCenter.default.post(
            name: .magentHideDiffViewer,
            object: nil
        )
    }

    @objc private func handleDiffViewerScrolledToFile(_ notification: Notification) {
        guard let filePath = notification.userInfo?["filePath"] as? String else { return }
        syncSelectionFromDiffViewer(filePath: filePath)
    }

    /// Updates selection to match the diff viewer's sticky header without re-triggering the diff viewer.
    private func syncSelectionFromDiffViewer(filePath: String) {
        guard activeTab == .changes, selectedFilePath != filePath else { return }
        let previousPath = selectedFilePath
        selectedFilePath = filePath
        // Only touch the two affected rows instead of all rows.
        for case let row as DiffFileRowView in stackView.arrangedSubviews
            where row.filePath == filePath || row.filePath == previousPath {
            row.isFileSelected = (row.filePath == filePath)
        }
    }

    private func selectFileForContextMenu(_ filePath: String) {
        selectedFilePath = filePath
        updateRowSelectionAppearance()
    }

    private func updateRowSelectionAppearance() {
        for case let row as DiffFileRowView in stackView.arrangedSubviews {
            row.isFileSelected = (row.filePath == selectedFilePath)
        }
    }

    private func fileURL(for relativePath: String) -> URL? {
        guard let worktreePath, !worktreePath.isEmpty else { return nil }
        return URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
    }

    private func openFileInDefaultApp(_ relativePath: String) {
        guard let url = fileURL(for: relativePath) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            BannerManager.shared.show(
                message: "Could not open \(relativePath) because the file is missing.",
                style: .warning
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showFileInFinder(_ relativePath: String) {
        guard let url = fileURL(for: relativePath) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            BannerManager.shared.show(
                message: "Could not show \(relativePath) in Finder because the file is missing.",
                style: .warning
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Stage / Unstage

    private func toggleStage(path: String, currentStatus: FileWorkingStatus) {
        guard let worktreePath else { return }
        Task {
            let gitService = GitService.shared
            if currentStatus == .staged {
                await gitService.unstageFile(worktreePath: worktreePath, relativePath: path)
            } else {
                await gitService.stageFile(worktreePath: worktreePath, relativePath: path)
            }
            onRefreshRequested?()
        }
    }

    private func discardChanges(path: String, currentStatus: FileWorkingStatus) {
        guard let worktreePath else { return }
        let targetDescription = currentStatus == .untracked ? "remove this untracked file" : "discard the tracked file changes"
        let alert = NSAlert()
        alert.messageText = "Discard Changes?"
        alert.informativeText = currentStatus == .untracked
            ? "This will permanently remove \(path). This cannot be undone."
            : "This will permanently discard the changes to \(path). This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let didDiscard = await GitService.shared.discardFile(
                worktreePath: worktreePath,
                relativePath: path,
                workingStatus: currentStatus
            )
            if didDiscard {
                optimisticallyRemoveFile(path: path)
                onRefreshRequested?()
            } else {
                BannerManager.shared.show(
                    message: "Could not \(targetDescription) for \(path).",
                    style: .warning
                )
            }
        }
    }

    private func discardAllUncommittedChanges() {
        guard let worktreePath else { return }
        guard !uncommittedEntries.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Discard All Uncommitted Changes?"
        alert.informativeText = "This will permanently discard all uncommitted changes in this thread. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trackedPaths = Set(
            uncommittedEntries
                .filter { $0.workingStatus != .untracked }
                .map(\.relativePath)
        )
        let untrackedPaths = Set(
            uncommittedEntries
                .filter { $0.workingStatus == .untracked }
                .map(\.relativePath)
        )
        let allPaths = Array(trackedPaths.union(untrackedPaths))

        Task {
            var failedCount = 0
            for path in trackedPaths {
                let didDiscard = await GitService.shared.discardFile(
                    worktreePath: worktreePath,
                    relativePath: path,
                    workingStatus: .unstaged
                )
                if !didDiscard {
                    failedCount += 1
                }
            }
            for path in untrackedPaths {
                let didDiscard = await GitService.shared.discardFile(
                    worktreePath: worktreePath,
                    relativePath: path,
                    workingStatus: .untracked
                )
                if !didDiscard {
                    failedCount += 1
                }
            }

            if failedCount == 0 {
                for path in allPaths {
                    optimisticallyRemoveFile(path: path)
                }
                onRefreshRequested?()
            } else {
                BannerManager.shared.show(
                    message: "Could not discard \(failedCount) change\(failedCount == 1 ? "" : "s").",
                    style: .warning
                )
                onRefreshRequested?()
            }
        }
    }

    // MARK: - Commit Selection

    private func selectCommit(_ hash: String?) {
        // hash == nil means "Uncommitted"
        guard selectedCommitHash != hash else { return }
        selectedCommitHash = hash
        commitEntries = []
        selectedFilePath = nil
        deselectFileWithoutHidingViewer()
        updateCommitRowSelectionAppearance()
        onCommitSelected?(hash)
    }

    private func deselectFileWithoutHidingViewer() {
        selectedFilePath = nil
        updateRowSelectionAppearance()
    }

    private func updateCommitRowSelectionAppearance() {
        for subview in stackView.arrangedSubviews {
            if let row = subview as? CommitRowView {
                row.isSelected = (row.commitHash == (selectedCommitHash ?? "__uncommitted__"))
            }
        }
    }

    // MARK: - Content Updates

    func update(
        with newEntries: [FileDiffEntry],
        allBranchEntries newAllBranchEntries: [FileDiffEntry]? = nil,
        commits newCommits: [BranchCommit] = [],
        hasMoreCommits: Bool = false,
        forceVisible: Bool = false,
        worktreePath: String? = nil,
        branchName: String? = nil,
        baseBranch: String? = nil,
        upstreamStatus: BranchUpstreamStatus? = nil,
        preserveSelection: Bool = false
    ) {
        uncommittedEntries = newEntries
        allBranchEntries = newAllBranchEntries
        isLoadingAllChanges = false
        commits = newCommits
        self.worktreePath = worktreePath
        self.hasMoreCommits = hasMoreCommits
        self.forceVisible = forceVisible

        // Always exit commit detail mode when panel data is refreshed (thread change)
        resetCommitDetailMode()

        // Preserve current commit selection and tab if requested
        let hashStillExists = preserveSelection && selectedCommitHash != nil
            && newCommits.contains(where: { $0.shortHash == selectedCommitHash })
        if hashStillExists {
            // Keep selectedCommitHash and activeTab; clear only the loaded entry list so it reloads
            commitEntries = []
            selectedFilePath = nil
        } else if preserveSelection {
            // No specific commit selected (e.g. "Unreleased"/CHANGES tab), but still preserve the
            // current tab so a background refresh doesn't yank the user back to COMMITS
            selectedCommitHash = nil
            commitEntries = []
            selectedFilePath = nil
        } else {
            selectedCommitHash = nil
            commitEntries = []
            selectedFilePath = nil
            // Reset to COMMITS tab (leftmost/default)
            activeTab = .commits
        }

        let hasContent = !newEntries.isEmpty || !(newAllBranchEntries?.isEmpty ?? true) || !newCommits.isEmpty
        // Show tab bar if there are any commits to browse
        commitsTabButton.isHidden = !hasContent && !forceVisible

        updateTabTitles()

        // Hide panel only when there's nothing to show
        if !hasContent && !forceVisible {
            branchInfoStack.isHidden = true
            setPanelVisible(false)
            return
        }

        setPanelVisible(true)
        rebuildRows()

        // If a commit selection was preserved, re-trigger entry loading (commitEntries was cleared)
        if hashStillExists, let hash = selectedCommitHash {
            onCommitSelected?(hash)
        }

        updateBranchInfo(branchName: branchName, baseBranch: baseBranch, upstreamStatus: upstreamStatus)
    }

    /// Immediately removes the file from the visible list without waiting for a git refresh.
    /// The async refresh triggered after this will confirm the final state.
    func optimisticallyRemoveFile(path: String) {
        uncommittedEntries.removeAll { $0.relativePath == path }
        allBranchEntries?.removeAll { $0.relativePath == path }
        updateTabTitles()
        guard activeTab == .changes, !isInCommitDetailMode else { return }
        rebuildRows()
    }

    func updateAllBranchEntries(_ entries: [FileDiffEntry]) {
        allBranchEntries = entries
        isLoadingAllChanges = false
        updateTabTitles()

        guard activeTab == .changes, !isInCommitDetailMode else { return }
        rebuildRows()
    }

    /// Called by the controller after loading files for the selected commit.
    func updateCommitEntries(hash: String, entries: [FileDiffEntry], subject: String) {
        guard selectedCommitHash == hash else { return }
        commitEntries = entries
        // If already on CHANGES tab, rebuild
        if activeTab == .changes {
            rebuildRows()
        }
    }

    func updateBranchInfo(branchName: String?, baseBranch: String?, upstreamStatus: BranchUpstreamStatus?) {
        if let branch = branchName, !branch.isEmpty {
            let branchSuffix = upstreamStatus?.inlineSuffix ?? ""
            branchInfoLabel.stringValue = branch + (branchSuffix.isEmpty ? "" : " \(branchSuffix)")

            var toolTip = "Branch: \(branch)"
            if let upstreamStatus, let upstream = upstreamStatus.displayUpstreamRef {
                toolTip += "\nUpstream: \(upstream)"
                if let suffix = upstreamStatus.inlineSuffix {
                    toolTip += " \(suffix)"
                }
            } else if let upstreamStatus {
                toolTip += "\n\(upstreamStatus.tooltipText)"
            }
            branchInfoLabel.toolTip = toolTip
            branchInfoLabel.isHidden = false
        } else {
            branchInfoLabel.isHidden = true
        }

        if let branch = branchName, !branch.isEmpty, let base = baseBranch, !base.isEmpty {
            let displayBase = base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base
            baseBranchButton.title = displayBase
            baseBranchButton.toolTip = "Click to change base branch"
            baseLineStack.isHidden = false
        } else {
            baseLineStack.isHidden = true
        }

        remoteStatusLabel.isHidden = true

        branchInfoStack.isHidden = branchInfoLabel.isHidden && baseLineStack.isHidden && remoteStatusLabel.isHidden
    }

    @objc private func baseBranchTapped() {
        onBaseBranchClicked?(baseBranchButton)
    }

    func clear() {
        resetCommitDetailMode()
        uncommittedEntries = []
        allBranchEntries = nil
        isLoadingAllChanges = false
        commitEntries = []
        commits = []
        activeTab = .commits
        selectedCommitHash = nil
        selectedFilePath = nil
        worktreePath = nil
        hasMoreCommits = false
        forceVisible = false
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commitsTabButton.isHidden = true
        contextThreadIndicatorText = nil
        commitContextLabel.stringValue = ""
        updateContextThreadIndicatorVisibility()
        branchInfoLabel.isHidden = true
        baseLineStack.isHidden = true
        remoteStatusLabel.isHidden = true
        updateTabTitles()
        branchInfoStack.isHidden = true
        collapseButton.isHidden = true
        setPanelVisible(false)
    }

    private func updateTabTitles() {
        if commits.isEmpty {
            commitsTabButton.title = "COMMITS"
        } else {
            commitsTabButton.title = hasMoreCommits ? "COMMITS (\(commits.count)+)" : "COMMITS (\(commits.count))"
        }

        let totalChanges = allBranchEntries?.count
        if let totalChanges, totalChanges > 0 {
            changesTabButton.title = "ALL CHANGES (\(totalChanges))"
        } else {
            changesTabButton.title = "ALL CHANGES"
        }

        let activeColor = NSColor.labelColor
        let inactiveColor = NSColor(resource: .textSecondary)
        commitsTabButton.contentTintColor = activeTab == .commits ? activeColor : inactiveColor
        changesTabButton.contentTintColor = activeTab == .changes ? activeColor : inactiveColor
        infoButton.isHidden = activeTab == .commits
    }

    private func rebuildRows() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isInCommitDetailMode {
            rebuildCommitDetailRows()
            return
        }
        switch activeTab {
        case .commits:
            rebuildCommitsRows()
        case .changes:
            rebuildChangesRows()
        }
    }

    private func rebuildCommitsRows() {
        updateContextThreadIndicatorVisibility()
        // "Uncommitted" row — only shown when there are uncommitted changes
        if !uncommittedEntries.isEmpty {
            let uncommittedRow = makeUncommittedRow()
            stackView.addArrangedSubview(uncommittedRow)
            uncommittedRow.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            uncommittedRow.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }

        if uncommittedEntries.isEmpty && commits.isEmpty {
            let row = makeEmptyStateRow(message: "No commits")
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        for commit in commits {
            let row = makeCommitRow(commit)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
        if hasMoreCommits {
            let row = makeLoadMoreRow()
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    private func rebuildChangesRows() {
        updateContextThreadIndicatorVisibility()

        if allBranchEntries == nil {
            if !isLoadingAllChanges {
                isLoadingAllChanges = true
                onAllChangesRequested?()
            }

            let row = makeEmptyStateRow(message: "Loading changes…")
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        let entries = activeEntries
        if entries.count > ThreadDetailViewController.diffMaxFileCount {
            let row = makeEmptyStateRow(message: "Diff is too large (\(entries.count) files).")
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        if entries.isEmpty {
            let row = makeEmptyStateRow(message: "No changes in this branch")
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        } else {
            for entry in entries {
                let row = makeEntryRow(entry)
                stackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        }
    }

    @objc private func infoButtonTapped() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makeLegendViewController()
        popover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .minY)
    }

    @objc private func refreshButtonTapped() {
        onRefreshRequested?()
    }

    private func makeLegendViewController() -> NSViewController {
        let items: [(NSColor, String)] = [
            (NSColor(red: 0.35, green: 0.65, blue: 0.35, alpha: 1.0), "Staged — changes staged for commit"),
            (NSColor(red: 0.78, green: 0.3, blue: 0.3, alpha: 1.0),   "Unstaged — modified, not yet staged"),
            (NSColor(red: 0.76, green: 0.65, blue: 0.42, alpha: 1.0), "Untracked — new file"),
            (.secondaryLabelColor,                                      "Committed — part of branch diff"),
        ]

        let contentInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 16)

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false

        for (color, label) in items {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = color.cgColor
            dot.layer?.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 11)
            text.textColor = .labelColor
            text.maximumNumberOfLines = 1

            let row = NSStackView(views: [dot, text])
            row.orientation = .horizontal
            row.spacing = 7
            row.alignment = .centerY
            outerStack.addArrangedSubview(row)
        }

        let vc = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: contentInsets.top),
            outerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: contentInsets.left),
            outerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -contentInsets.right),
            outerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -contentInsets.bottom),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
        ])
        vc.view = container
        return vc
    }

    @objc private func commitsTabTapped() {
        guard activeTab != .commits else { return }
        activeTab = .commits
        selectedFilePath = nil
        updateTabTitles()
        rebuildRows()
    }

    @objc private func changesTabTapped() {
        guard activeTab != .changes else {
            // Tapping active Changes tab opens the full diff viewer
            guard !activeEntries.isEmpty else { return }
            var userInfo: [String: Any]? = nil
            if let hash = selectedCommitHash {
                userInfo = ["commitHash": hash]
            }
            NotificationCenter.default.post(name: .magentShowDiffViewer, object: nil, userInfo: userInfo)
            return
        }
        activeTab = .changes
        selectedCommitHash = nil
        commitEntries = []
        updateTabTitles()
        rebuildRows()
    }

    func setRefreshInProgress(_ isRefreshing: Bool) {
        refreshButton.isEnabled = !isRefreshing
        refreshButton.alphaValue = isRefreshing ? 0.45 : 1
        refreshButton.toolTip = isRefreshing
            ? "Refreshing git status, branch, commits, and changes..."
            : "Refresh git status, branch, commits, and changes"
    }

    func setContextThreadIndicator(_ text: String?, isPopout: Bool = false) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        contextThreadIndicatorText = (trimmed?.isEmpty == false) ? trimmed : nil
        commitContextLabel.stringValue = contextThreadIndicatorText ?? ""
        applyContextBadgeColors(isPopout: isPopout)
        updateContextThreadIndicatorVisibility()
    }

    func clearContextThreadIndicator() {
        setContextThreadIndicator(nil)
    }

    private func applyContextBadgeColors(isPopout: Bool) {
        let baseColor: NSColor = isPopout ? .systemPurple : .controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.contextThreadBadgeView.layer?.backgroundColor = baseColor.withAlphaComponent(0.1).cgColor
            self.contextThreadBadgeView.layer?.borderColor = baseColor.withAlphaComponent(0.7).cgColor
        }
        commitContextLabel.textColor = baseColor
    }

    // MARK: - Commit Detail Mode

    func enterCommitDetailMode(hash: String?, title: String, entries: [FileDiffEntry]) {
        isInCommitDetailMode = true
        commitDetailHash = hash
        commitDetailEntries = entries
        commitDetailTitleLabel.stringValue = title
        selectedFilePath = nil

        tabBarStack.isHidden = true
        infoButton.isHidden = true
        updateContextThreadIndicatorVisibility()
        commitDetailHeaderView.isHidden = false

        rebuildRows()
    }

    @objc private func backButtonTapped() {
        resetCommitDetailMode()
        activeTab = .commits
        selectedCommitHash = nil
        commitEntries = []
        updateTabTitles()
        rebuildRows()
        NotificationCenter.default.post(name: .magentHideDiffViewer, object: nil)
    }

    private func resetCommitDetailMode() {
        guard isInCommitDetailMode else { return }
        isInCommitDetailMode = false
        commitDetailHash = nil
        commitDetailEntries = []
        commitDetailHeaderView.isHidden = true
        tabBarStack.isHidden = false
        updateContextThreadIndicatorVisibility()
        // infoButton visibility is restored by updateTabTitles()
    }

    private func updateContextThreadIndicatorVisibility() {
        // Commit detail mode uses a dedicated header row (with a back button),
        // so suppress the context badge there to avoid header overlap.
        let isVisible = contextThreadIndicatorText != nil && !isInCommitDetailMode
        contextThreadBadgeView.isHidden = !isVisible
        commitContextLabel.isHidden = !isVisible
        tabBarTopToHandleConstraint.isActive = !isVisible
        tabBarTopToContextBadgeConstraint.isActive = isVisible
    }

    private func rebuildCommitDetailRows() {
        if commitDetailEntries.count > ThreadDetailViewController.diffMaxFileCount {
            let row = makeEmptyStateRow(message: "Diff is too large (\(commitDetailEntries.count) files).")
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            return
        }

        if commitDetailEntries.isEmpty {
            let msg = commitDetailHash == nil ? "No uncommitted changes" : "No changes in this commit"
            let row = makeEmptyStateRow(message: msg)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        } else {
            for entry in commitDetailEntries {
                let row = makeEntryRow(entry)
                stackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        }
    }

    private func makeUncommittedRow() -> NSView {
        let container = CommitRowView(commitHash: "__uncommitted__")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isSelected = (selectedCommitHash == nil)
        container.onClick = { [weak self] _ in
            self?.selectCommit(nil)
        }
        container.onSecondaryClick = { [weak self] _ in
            self?.selectCommit(nil)
        }
        container.onDoubleClick = { [weak self] _ in
            self?.onCommitDoubleTapped?(nil, "Uncommitted changes")
        }
        container.onDiscardUncommittedChanges = { [weak self] in
            self?.discardAllUncommittedChanges()
        }

        let label = NSTextField(labelWithString: "Uncommitted")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "")
        let count = uncommittedEntries.count
        if count > 0 {
            countLabel.stringValue = "\(count) file\(count == 1 ? "" : "s")"
        } else {
            countLabel.stringValue = "clean"
        }
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = NSColor(resource: .textSecondary)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(countLabel)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),

            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: 22),
        ])

        return container
    }

    private func makeEntryRow(_ entry: FileDiffEntry) -> NSView {
        let container = DiffFileRowView(filePath: entry.relativePath)
        container.workingStatus = entry.workingStatus
        container.translatesAutoresizingMaskIntoConstraints = false
        let isDirectory = isDirectoryPath(entry.relativePath)
        if isDirectory {
            container.onClick = { [weak self] _ in
                self?.deselectFile()
            }
            container.onSecondaryClick = { [weak self] _ in
                self?.deselectFile()
            }
            container.onDoubleClick = { [weak self] path in
                self?.showFileInFinder(path)
            }
        } else {
            container.onClick = { [weak self] path in
                self?.selectFile(path)
            }
            container.onSecondaryClick = { [weak self] path in
                self?.selectFileForContextMenu(path)
            }
            container.onDoubleClick = { [weak self] path in
                self?.openFileInDefaultApp(path)
            }
        }
        container.onShowInFinder = { [weak self] path in
            self?.showFileInFinder(path)
        }
        container.onStageToggle = { [weak self] path in
            self?.toggleStage(path: path, currentStatus: entry.workingStatus)
        }
        container.onDiscard = { [weak self] path, status in
            self?.discardChanges(path: path, currentStatus: status)
        }

        let displayPath = entry.relativePath.hasSuffix("/") ? String(entry.relativePath.dropLast()) : entry.relativePath
        let basename = (displayPath as NSString).lastPathComponent
        let filename = isDirectory ? "\(basename)/" : basename
        let dirPath = (displayPath as NSString).deletingLastPathComponent
        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.allowsDefaultTighteningForTruncation = false

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: filename,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: colorForStatus(entry.workingStatus),
            ]
        ))
        if !dirPath.isEmpty && !isDirectory {
            var truncatedDir = dirPath
            let maxDirChars = max(0, 50 - filename.count)
            if truncatedDir.count > maxDirChars {
                truncatedDir = "…" + truncatedDir.suffix(max(0, maxDirChars - 1))
            }
            attributed.append(NSAttributedString(
                string: "  " + truncatedDir,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor(resource: .textSecondary).withAlphaComponent(0.7),
                ]
            ))
        }
        nameLabel.attributedStringValue = attributed
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        let pathTooltip = fullPathTooltip(for: entry.relativePath)
        nameLabel.toolTip = pathTooltip
        container.toolTip = pathTooltip

        var nameLeadingAnchor = container.leadingAnchor
        var nameLeadingConstant: CGFloat = 12
        if let icon = directoryIcon(for: entry, isDirectory: isDirectory) {
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = icon
            iconView.contentTintColor = colorForStatus(entry.workingStatus)
            iconView.toolTip = pathTooltip
            container.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 12),
                iconView.heightAnchor.constraint(equalToConstant: 12),
            ])
            nameLeadingAnchor = iconView.trailingAnchor
            nameLeadingConstant = 5
        }
        container.addSubview(nameLabel)

        // Stats labels
        let statsStack = NSStackView()
        statsStack.orientation = .horizontal
        statsStack.spacing = 4
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        statsStack.setContentHuggingPriority(.required, for: .horizontal)
        statsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        if entry.additions > 0 {
            let addLabel = NSTextField(labelWithString: "+\(entry.additions)")
            addLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            addLabel.textColor = NSColor(red: 0.35, green: 0.65, blue: 0.35, alpha: 1.0)
            addLabel.translatesAutoresizingMaskIntoConstraints = false
            statsStack.addArrangedSubview(addLabel)
        }

        if entry.deletions > 0 {
            let delLabel = NSTextField(labelWithString: "-\(entry.deletions)")
            delLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            delLabel.textColor = NSColor(red: 0.78, green: 0.3, blue: 0.3, alpha: 1.0)
            delLabel.translatesAutoresizingMaskIntoConstraints = false
            statsStack.addArrangedSubview(delLabel)
        }

        if entry.workingStatus == .untracked && entry.additions == 0 && entry.deletions == 0 {
            let untrackedLabel = NSTextField(labelWithString: "new")
            untrackedLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            untrackedLabel.textColor = colorForStatus(.untracked)
            untrackedLabel.translatesAutoresizingMaskIntoConstraints = false
            statsStack.addArrangedSubview(untrackedLabel)
        }

        container.addSubview(statsStack)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameLeadingAnchor, constant: nameLeadingConstant),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsStack.leadingAnchor, constant: -6),

            statsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: 18),
        ])

        return container
    }

    private func makeEmptyStateRow(message: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])

        return container
    }

    private func makeCommitRow(_ commit: BranchCommit) -> NSView {
        let container = CommitRowView(commitHash: commit.shortHash)
        container.commitMessage = commit.subject
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isSelected = (selectedCommitHash == commit.shortHash)
        container.onClick = { [weak self] hash in
            self?.selectCommit(hash)
        }
        container.onDoubleClick = { [weak self] hash in
            guard let self else { return }
            let subject = self.commits.first(where: { $0.shortHash == hash })?.subject ?? ""
            let title = subject.isEmpty ? hash : "\(hash) — \(subject)"
            self.onCommitDoubleTapped?(hash, title)
        }

        let hashLabel = NSTextField(labelWithString: commit.shortHash)
        hashLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hashLabel.textColor = NSColor(resource: .textSecondary).withAlphaComponent(0.7)
        hashLabel.setContentHuggingPriority(.required, for: .horizontal)
        hashLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hashLabel.translatesAutoresizingMaskIntoConstraints = false

        let subjectLabel = NSTextField(labelWithString: commit.subject)
        subjectLabel.font = .systemFont(ofSize: 11)
        subjectLabel.textColor = .labelColor
        subjectLabel.maximumNumberOfLines = 3
        subjectLabel.cell?.wraps = true
        subjectLabel.cell?.truncatesLastVisibleLine = true
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.toolTip = "\(commit.shortHash) \(commit.subject)\n\(commit.authorName) · \(commit.date)"

        container.addSubview(hashLabel)
        container.addSubview(subjectLabel)

        NSLayoutConstraint.activate([
            hashLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hashLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),

            subjectLabel.leadingAnchor.constraint(equalTo: hashLabel.trailingAnchor, constant: 6),
            subjectLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            subjectLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            subjectLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),

            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])

        return container
    }

    private func makeLoadMoreRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "Load More Commits", target: self, action: #selector(loadMoreCommitsTapped))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor.controlAccentColor
        button.alignment = .left
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])

        return container
    }

    @objc private func loadMoreCommitsTapped() {
        onLoadMoreCommits?()
    }

    private func isDirectoryPath(_ relativePath: String) -> Bool {
        if relativePath.hasSuffix("/") {
            return true
        }
        guard let url = fileURL(for: relativePath) else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func directoryIcon(for entry: FileDiffEntry, isDirectory: Bool) -> NSImage? {
        guard isDirectory else { return nil }
        let symbolName: String
        switch entry.workingStatus {
        case .untracked:
            symbolName = "folder.badge.plus"
        case .committed, .staged, .unstaged:
            symbolName = "folder"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Directory")?
            .withSymbolConfiguration(config)
    }

    private func fullPathTooltip(for relativePath: String) -> String {
        guard let url = fileURL(for: relativePath) else { return relativePath }
        return url.path
    }

    private func colorForStatus(_ status: FileWorkingStatus) -> NSColor {
        switch status {
        case .committed:
            return .secondaryLabelColor
        case .staged:
            return NSColor(red: 0.35, green: 0.65, blue: 0.35, alpha: 1.0)
        case .unstaged:
            return NSColor(red: 0.78, green: 0.3, blue: 0.3, alpha: 1.0)
        case .untracked:
            return NSColor(red: 0.76, green: 0.65, blue: 0.42, alpha: 1.0)
        }
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            collapseButton.isHidden = false
            if isCollapsed {
                applyCollapsedLayout()
            } else {
                let clamped = min(max(expandedHeight, Self.minHeight), Self.maxHeight)
                expandedHeight = clamped
                heightConstraint.constant = clamped
            }
            isHidden = false
        } else {
            collapseButton.isHidden = true
            if !isHidden && !isCollapsed && heightConstraint.constant > 0 {
                expandedHeight = min(max(heightConstraint.constant, Self.minHeight), Self.maxHeight)
            }
            heightConstraint.constant = 0
            isHidden = true
        }
    }

    // MARK: - Collapse / Expand

    @objc private func collapseToggleTapped() {
        isCollapsed.toggle()
        applyCollapsedState(animated: true)
    }

    /// Collapsed height: handle (6) + gap (4) + branch info intrinsic + bottom (6)
    private var collapsedHeight: CGFloat {
        let branchSize = branchInfoStack.fittingSize.height
        return 6 + 4 + max(branchSize, 24) + 6
    }

    private func applyCollapsedState(animated: Bool) {
        let chevronName = isCollapsed ? "chevron.up" : "chevron.down"
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        collapseButton.image = NSImage(systemSymbolName: chevronName, accessibilityDescription: isCollapsed ? "Expand panel" : "Collapse panel")?.withSymbolConfiguration(chevronConfig)
        collapseButton.toolTip = isCollapsed ? "Expand to show commits and changes" : "Collapse to show only branch info"

        let apply = {
            if self.isCollapsed {
                self.applyCollapsedLayout()
            } else {
                self.applyExpandedLayout()
            }
            self.superview?.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    private func applyCollapsedLayout() {
        // Keep handleView (separator line) visible; drag is blocked by isCollapsed check
        tabBarStack.isHidden = true
        topRightButtonStack.isHidden = true
        commitContextLabel.isHidden = true
        scrollView.isHidden = true
        commitDetailHeaderView.isHidden = true
        collapsedTopConstraint.isActive = true
        heightConstraint.constant = collapsedHeight
    }

    private func applyExpandedLayout() {
        collapsedTopConstraint.isActive = false
        tabBarStack.isHidden = false
        topRightButtonStack.isHidden = false
        // commitContextLabel visibility is managed by rebuildRows
        scrollView.isHidden = false
        // commitDetailHeaderView visibility is managed by commit detail mode
        let clamped = min(max(expandedHeight, Self.minHeight), Self.maxHeight)
        expandedHeight = clamped
        heightConstraint.constant = clamped
    }
}
