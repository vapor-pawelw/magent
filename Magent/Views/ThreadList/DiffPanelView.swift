import Cocoa

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
    var onDoubleClick: ((String) -> Void)?

    init(filePath: String) {
        self.filePath = filePath
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(filePath)
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class DiffPanelView: NSView {

    private let handleView = DiffPanelResizeHandle()
    private let separatorView = NSView()
    private let headerButton = NSButton()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let branchInfoLabel = NSTextField(labelWithString: "")

    private var entries: [FileDiffEntry] = []

    private var heightConstraint: NSLayoutConstraint!
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

        // Header — clickable to open full diff viewer
        headerButton.title = "CHANGES"
        headerButton.font = .systemFont(ofSize: 11, weight: .semibold)
        headerButton.contentTintColor = NSColor(resource: .textSecondary)
        headerButton.isBordered = false
        headerButton.alignment = .left
        headerButton.target = self
        headerButton.action = #selector(headerTapped)
        headerButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerButton)

        // Stack view for file entries
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

            headerButton.topAnchor.constraint(equalTo: handleView.bottomAnchor, constant: 4),
            headerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerButton.bottomAnchor, constant: 4),
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
            UserDefaults.standard.set(heightConstraint.constant, forKey: Self.heightKey)
        } else {
            super.mouseUp(with: event)
        }
    }

    func update(with newEntries: [FileDiffEntry], branchName: String? = nil, baseBranch: String? = nil) {
        entries = newEntries

        // Remove old rows
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if entries.isEmpty {
            headerButton.title = "CHANGES"
            branchInfoLabel.isHidden = true
            isHidden = true
            return
        }

        isHidden = false
        headerButton.title = "CHANGES (\(entries.count))"

        for entry in entries {
            let row = makeEntryRow(entry)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }

        // Branch info
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
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headerButton.title = "CHANGES"
        branchInfoLabel.isHidden = true
        isHidden = true
    }

    @objc private func headerTapped() {
        guard !entries.isEmpty else { return }
        NotificationCenter.default.post(
            name: .magentShowDiffViewer,
            object: nil,
            userInfo: nil
        )
    }

    private func makeEntryRow(_ entry: FileDiffEntry) -> NSView {
        let container = DiffFileRowView(filePath: entry.relativePath)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onDoubleClick = { [weak self] path in
            guard self != nil else { return }
            NotificationCenter.default.post(
                name: .magentShowDiffViewer,
                object: nil,
                userInfo: ["filePath": path]
            )
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
}
