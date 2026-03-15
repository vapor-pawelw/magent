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
    var onClick: ((String) -> Void)?
    var onSecondaryClick: ((String) -> Void)?
    var onDoubleClick: ((String) -> Void)?
    var onShowInFinder: ((String) -> Void)?

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
        let finderItem = NSMenuItem(title: "Show in Finder", action: #selector(showInFinderFromMenu(_:)), keyEquivalent: "")
        finderItem.target = self
        finderItem.image = OpenActionIcons.finderIcon(size: 16)
        menu.addItem(finderItem)
        return menu
    }

    @objc private func showInFinderFromMenu(_ sender: NSMenuItem) {
        onShowInFinder?(filePath)
    }
}

// MARK: - Clickable commit row

private final class CommitRowView: NSView {
    let commitHash: String
    var onClick: ((String) -> Void)?

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
        onClick?(commitHash)
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
    private let infoButton = NSButton()
    private let commitContextLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let branchInfoLabel = NSTextField(labelWithString: "")

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
    /// Called when the user selects a commit (nil = "Uncommitted").
    var onCommitSelected: ((String?) -> Void)?

    /// The entries currently shown in the CHANGES tab.
    private var activeEntries: [FileDiffEntry] {
        selectedCommitHash == nil ? uncommittedEntries : commitEntries
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
        changesBtn.title = "CHANGES"
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

        // Info button — shows color legend popover
        let infoConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Color legend")?.withSymbolConfiguration(infoConfig)
        infoButton.isBordered = false
        infoButton.contentTintColor = NSColor(resource: .textSecondary).withAlphaComponent(0.6)
        infoButton.target = self
        infoButton.action = #selector(infoButtonTapped)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        infoButton.toolTip = "Color legend"
        infoButton.setContentHuggingPriority(.required, for: .horizontal)
        infoButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(infoButton)

        // Commit context label — shown under tab bar when viewing a specific commit's changes
        commitContextLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        commitContextLabel.textColor = NSColor(resource: .textSecondary)
        commitContextLabel.lineBreakMode = .byTruncatingTail
        commitContextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commitContextLabel.translatesAutoresizingMaskIntoConstraints = false
        commitContextLabel.isHidden = true
        addSubview(commitContextLabel)

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

        // Branch info at the bottom
        branchInfoLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        branchInfoLabel.textColor = NSColor(resource: .textSecondary).withAlphaComponent(0.7)
        branchInfoLabel.lineBreakMode = .byTruncatingMiddle
        branchInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        branchInfoLabel.isHidden = true
        addSubview(branchInfoLabel)

        let savedHeight = UserDefaults.standard.object(forKey: Self.heightKey) as? CGFloat ?? Self.defaultHeight
        let clampedHeight = min(max(savedHeight, Self.minHeight), Self.maxHeight)
        expandedHeight = clampedHeight
        heightConstraint = heightAnchor.constraint(equalToConstant: clampedHeight)

        NSLayoutConstraint.activate([
            handleView.topAnchor.constraint(equalTo: topAnchor),
            handleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            handleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            handleView.heightAnchor.constraint(equalToConstant: 6),

            separatorView.centerYAnchor.constraint(equalTo: handleView.centerYAnchor),
            separatorView.leadingAnchor.constraint(equalTo: handleView.leadingAnchor, constant: 8),
            separatorView.trailingAnchor.constraint(equalTo: handleView.trailingAnchor, constant: -8),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            tabBarStack.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4),
            tabBarStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBarStack.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -4),

            infoButton.centerYAnchor.constraint(equalTo: tabBarStack.centerYAnchor),
            infoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            commitContextLabel.topAnchor.constraint(equalTo: tabBarStack.bottomAnchor, constant: 2),
            commitContextLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            commitContextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: commitContextLabel.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: branchInfoLabel.topAnchor, constant: -4),

            branchInfoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            branchInfoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            branchInfoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            heightConstraint,

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDiffViewerScrolledToFile(_:)),
            name: .magentDiffViewerScrolledToFile,
            object: nil
        )

        clear()
    }

    // MARK: - Drag to resize

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if location.y >= bounds.maxY - 6 {
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
        if let hash = selectedCommitHash {
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
        commits newCommits: [BranchCommit] = [],
        hasMoreCommits: Bool = false,
        forceVisible: Bool = false,
        worktreePath: String? = nil,
        branchName: String? = nil,
        baseBranch: String? = nil,
        preserveSelection: Bool = false
    ) {
        uncommittedEntries = newEntries
        commits = newCommits
        self.worktreePath = worktreePath
        self.hasMoreCommits = hasMoreCommits
        self.forceVisible = forceVisible

        // Preserve current commit selection and tab if the selected commit still exists in new data
        let hashStillExists = preserveSelection && selectedCommitHash != nil
            && newCommits.contains(where: { $0.shortHash == selectedCommitHash })
        if hashStillExists {
            // Keep selectedCommitHash and activeTab; clear only the loaded entry list so it reloads
            commitEntries = []
            selectedFilePath = nil
        } else {
            selectedCommitHash = nil
            commitEntries = []
            selectedFilePath = nil
            // Reset to COMMITS tab (leftmost/default)
            activeTab = .commits
        }

        // Show COMMITS tab if there are any commits to browse
        commitsTabButton.isHidden = newCommits.isEmpty && newEntries.isEmpty && !forceVisible

        updateTabTitles()

        // Hide panel only when there's nothing to show
        if newEntries.isEmpty && newCommits.isEmpty && !forceVisible {
            branchInfoLabel.isHidden = true
            setPanelVisible(false)
            return
        }

        setPanelVisible(true)
        rebuildRows()

        // If a commit selection was preserved, re-trigger entry loading (commitEntries was cleared)
        if hashStillExists, let hash = selectedCommitHash {
            onCommitSelected?(hash)
        }

        updateBranchInfo(branchName: branchName, baseBranch: baseBranch)
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

    func updateBranchInfo(branchName: String?, baseBranch: String?) {
        guard !uncommittedEntries.isEmpty else {
            branchInfoLabel.isHidden = true
            return
        }

        if let branch = branchName, !branch.isEmpty, let base = baseBranch, !base.isEmpty {
            branchInfoLabel.stringValue = "\(branch) ← \(base)"
            branchInfoLabel.toolTip = "Branch: \(branch)\nBase: \(base)"
            branchInfoLabel.isHidden = false
        } else {
            branchInfoLabel.isHidden = true
        }
    }

    func clear() {
        uncommittedEntries = []
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
        commitContextLabel.isHidden = true
        updateTabTitles()
        branchInfoLabel.isHidden = true
        setPanelVisible(false)
    }

    private func updateTabTitles() {
        if commits.isEmpty {
            commitsTabButton.title = "COMMITS"
        } else {
            commitsTabButton.title = hasMoreCommits ? "COMMITS (\(commits.count)+)" : "COMMITS (\(commits.count))"
        }

        let totalChanges = uncommittedEntries.count
        changesTabButton.title = totalChanges == 0 ? "CHANGES" : "CHANGES (\(totalChanges))"

        let activeColor = NSColor.labelColor
        let inactiveColor = NSColor(resource: .textSecondary)
        commitsTabButton.contentTintColor = activeTab == .commits ? activeColor : inactiveColor
        changesTabButton.contentTintColor = activeTab == .changes ? activeColor : inactiveColor
        infoButton.isHidden = activeTab == .commits
    }

    private func rebuildRows() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch activeTab {
        case .commits:
            rebuildCommitsRows()
        case .changes:
            rebuildChangesRows()
        }
    }

    private func rebuildCommitsRows() {
        commitContextLabel.isHidden = true
        // "Uncommitted" row — always present at top
        let uncommittedRow = makeUncommittedRow()
        stackView.addArrangedSubview(uncommittedRow)
        uncommittedRow.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
        uncommittedRow.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true

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
        let entries = activeEntries

        // Update context label
        if let hash = selectedCommitHash,
           let commit = commits.first(where: { $0.shortHash == hash }) {
            commitContextLabel.stringValue = "from \(commit.shortHash) · \(commit.subject)"
            commitContextLabel.toolTip = "\(commit.shortHash) · \(commit.subject)\n\(commit.authorName) · \(commit.date)"
            commitContextLabel.isHidden = false
        } else {
            commitContextLabel.isHidden = true
        }

        if entries.isEmpty {
            let row = makeEmptyStateRow(message: selectedCommitHash == nil ? "No uncommitted changes" : "No changes in this commit")
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
        commitContextLabel.isHidden = true
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
        updateTabTitles()
        rebuildRows()
    }

    private func makeUncommittedRow() -> NSView {
        let container = CommitRowView(commitHash: "__uncommitted__")
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isSelected = (selectedCommitHash == nil)
        container.onClick = { [weak self] _ in
            self?.selectCommit(nil)
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

        let displayPath = entry.relativePath.hasSuffix("/") ? String(entry.relativePath.dropLast()) : entry.relativePath
        let basename = (displayPath as NSString).lastPathComponent
        let filename = isDirectory ? "\(basename)/" : basename
        let nameLabel = NSTextField(labelWithString: filename)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = colorForStatus(entry.workingStatus)
        nameLabel.lineBreakMode = .byTruncatingHead
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
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isSelected = (selectedCommitHash == commit.shortHash)
        container.onClick = { [weak self] hash in
            self?.selectCommit(hash)
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
            let clamped = min(max(expandedHeight, Self.minHeight), Self.maxHeight)
            expandedHeight = clamped
            heightConstraint.constant = clamped
            isHidden = false
        } else {
            if !isHidden && heightConstraint.constant > 0 {
                expandedHeight = min(max(heightConstraint.constant, Self.minHeight), Self.maxHeight)
            }
            heightConstraint.constant = 0
            isHidden = true
        }
    }
}
