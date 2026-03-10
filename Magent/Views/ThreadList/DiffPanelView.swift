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

private enum DiffPanelTab {
    case changes
    case commits
}

final class DiffPanelView: NSView {

    private let handleView = DiffPanelResizeHandle()
    private let separatorView = NSView()
    private let tabBarStack = NSStackView()
    private let changesTabButton = NSButton()
    private let commitsTabButton = NSButton()
    private let infoButton = NSButton()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let branchInfoLabel = NSTextField(labelWithString: "")

    private var entries: [FileDiffEntry] = []
    private var commits: [BranchCommit] = []
    private var activeTab: DiffPanelTab = .changes
    private var selectedFilePath: String?
    private var worktreePath: String?

    private var heightConstraint: NSLayoutConstraint!
    private var expandedHeight: CGFloat = DiffPanelView.defaultHeight
    private static let minHeight: CGFloat = 60
    private static let maxHeight: CGFloat = 500
    private static let defaultHeight: CGFloat = 140
    private static let heightKey = "DiffPanelView.height"

    private var isDragging = false
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0

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

        // Tab bar — Changes + Commits
        let changesBtn = changesTabButton
        changesBtn.title = "CHANGES"
        changesBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        changesBtn.contentTintColor = NSColor(resource: .textSecondary)
        changesBtn.isBordered = false
        changesBtn.alignment = .left
        changesBtn.target = self
        changesBtn.action = #selector(changesTabTapped)
        changesBtn.translatesAutoresizingMaskIntoConstraints = false

        let commitsBtn = commitsTabButton
        commitsBtn.title = "COMMITS"
        commitsBtn.font = .systemFont(ofSize: 11, weight: .semibold)
        commitsBtn.contentTintColor = NSColor(resource: .textSecondary)
        commitsBtn.isBordered = false
        commitsBtn.alignment = .left
        commitsBtn.target = self
        commitsBtn.action = #selector(commitsTabTapped)
        commitsBtn.translatesAutoresizingMaskIntoConstraints = false
        commitsBtn.isHidden = true

        tabBarStack.orientation = .horizontal
        tabBarStack.spacing = 12
        tabBarStack.alignment = .centerY
        tabBarStack.addArrangedSubview(changesBtn)
        tabBarStack.addArrangedSubview(commitsBtn)
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
        addSubview(infoButton)

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

            scrollView.topAnchor.constraint(equalTo: tabBarStack.bottomAnchor, constant: 4),
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
                    if v is DiffFileRowView {
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
        guard activeTab == .changes, !entries.isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch Int(event.keyCode) {
        case 126: // Up arrow
            let currentIndex = entries.firstIndex(where: { $0.relativePath == selectedFilePath })
            let newIndex: Int
            if let idx = currentIndex {
                newIndex = idx > 0 ? idx - 1 : entries.count - 1
            } else {
                newIndex = entries.count - 1
            }
            selectFile(entries[newIndex].relativePath)

        case 125: // Down arrow
            let currentIndex = entries.firstIndex(where: { $0.relativePath == selectedFilePath })
            let newIndex: Int
            if let idx = currentIndex {
                newIndex = idx < entries.count - 1 ? idx + 1 : 0
            } else {
                newIndex = 0
            }
            selectFile(entries[newIndex].relativePath)

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
        NotificationCenter.default.post(
            name: .magentShowDiffViewer,
            object: nil,
            userInfo: ["filePath": filePath]
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

    // MARK: - Content Updates

    func update(
        with newEntries: [FileDiffEntry],
        commits newCommits: [BranchCommit] = [],
        worktreePath: String? = nil,
        branchName: String? = nil,
        baseBranch: String? = nil
    ) {
        entries = newEntries
        commits = newCommits
        selectedFilePath = nil
        self.worktreePath = worktreePath

        // Show Commits tab only when there are 2+ commits
        let showCommitsTab = commits.count > 1
        commitsTabButton.isHidden = !showCommitsTab
        if !showCommitsTab && activeTab == .commits {
            activeTab = .changes
        }

        updateTabTitles()

        if entries.isEmpty && commits.isEmpty {
            branchInfoLabel.isHidden = true
            setPanelVisible(false)
            return
        }

        setPanelVisible(true)
        rebuildRows()

        updateBranchInfo(branchName: branchName, baseBranch: baseBranch)
    }

    func updateBranchInfo(branchName: String?, baseBranch: String?) {
        guard !entries.isEmpty else {
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
        entries = []
        commits = []
        activeTab = .changes
        selectedFilePath = nil
        worktreePath = nil
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        commitsTabButton.isHidden = true
        updateTabTitles()
        branchInfoLabel.isHidden = true
        setPanelVisible(false)
    }

    private func updateTabTitles() {
        changesTabButton.title = entries.isEmpty ? "CHANGES" : "CHANGES (\(entries.count))"
        commitsTabButton.title = commits.isEmpty ? "COMMITS" : "COMMITS (\(commits.count))"

        let activeColor = NSColor.labelColor
        let inactiveColor = NSColor(resource: .textSecondary)
        changesTabButton.contentTintColor = activeTab == .changes ? activeColor : inactiveColor
        commitsTabButton.contentTintColor = activeTab == .commits ? activeColor : inactiveColor
        infoButton.isHidden = activeTab == .commits
    }

    private func rebuildRows() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch activeTab {
        case .changes:
            for entry in entries {
                let row = makeEntryRow(entry)
                stackView.addArrangedSubview(row)
                row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        case .commits:
            for commit in commits {
                let row = makeCommitRow(commit)
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

    @objc private func changesTabTapped() {
        guard activeTab != .changes else {
            // Tapping active Changes tab opens the full diff viewer
            guard !entries.isEmpty else { return }
            NotificationCenter.default.post(name: .magentShowDiffViewer, object: nil, userInfo: nil)
            return
        }
        activeTab = .changes
        updateTabTitles()
        rebuildRows()
    }

    @objc private func commitsTabTapped() {
        guard activeTab != .commits else { return }
        activeTab = .commits
        updateTabTitles()
        rebuildRows()
    }

    private func makeEntryRow(_ entry: FileDiffEntry) -> NSView {
        let container = DiffFileRowView(filePath: entry.relativePath)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onClick = { [weak self] path in
            self?.selectFile(path)
        }
        container.onSecondaryClick = { [weak self] path in
            self?.selectFileForContextMenu(path)
        }
        container.onDoubleClick = { [weak self] path in
            self?.openFileInDefaultApp(path)
        }
        container.onShowInFinder = { [weak self] path in
            self?.showFileInFinder(path)
        }

        // Filename — show just the last path component for brevity
        let filename = (entry.relativePath as NSString).lastPathComponent
        let nameLabel = NSTextField(labelWithString: filename)
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = colorForStatus(entry.workingStatus)
        nameLabel.lineBreakMode = .byTruncatingHead
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.toolTip = entry.relativePath
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
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsStack.leadingAnchor, constant: -6),

            statsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: 18),
        ])

        return container
    }

    private func makeCommitRow(_ commit: BranchCommit) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

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
