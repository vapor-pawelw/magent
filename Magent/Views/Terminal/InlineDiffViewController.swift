import Cocoa

// MARK: - Helpers

private let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "tif",
]

private func isImageFile(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext)
}

private enum ImageDiffMode {
    case added, deleted, modified
}

private func detectImageDiffState(from chunk: String) -> ImageDiffMode {
    if chunk.contains("new file") || chunk.contains("--- /dev/null") {
        return .added
    }
    if chunk.contains("deleted file") || chunk.contains("+++ /dev/null") {
        return .deleted
    }
    return .modified
}

/// Extracts the old path from a `rename from <path>` line in a diff chunk.
private func extractRenameFrom(_ chunk: String) -> String? {
    for line in chunk.components(separatedBy: "\n") {
        if line.hasPrefix("rename from ") {
            return String(line.dropFirst("rename from ".count))
        }
    }
    return nil
}

// MARK: - Shared Diff Helpers

private let diffDefaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
private let diffHeaderFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
private let diffAddColor = NSColor(red: 0.35, green: 0.75, blue: 0.35, alpha: 1.0)
private let diffDelColor = NSColor(red: 0.9, green: 0.35, blue: 0.35, alpha: 1.0)
private let diffHunkColor = NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)
private let diffHeaderColor = NSColor(red: 0.8, green: 0.8, blue: 0.6, alpha: 1.0)
private let diffContextColor = NSColor(resource: .textSecondary)

private let statsAddColor = NSColor(red: 0.35, green: 0.65, blue: 0.35, alpha: 1.0)
private let statsDelColor = NSColor(red: 0.78, green: 0.3, blue: 0.3, alpha: 1.0)

/// Parses an array of diff lines into a colored attributed string.
private func parseDiffLines(_ lines: [String]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for line in lines {
        let attrs: [NSAttributedString.Key: Any]
        if line.hasPrefix("diff --git") {
            continue
        } else if line.hasPrefix("+++") || line.hasPrefix("---") {
            attrs = [.font: diffHeaderFont, .foregroundColor: diffHeaderColor]
        } else if line.hasPrefix("@@") {
            attrs = [.font: diffDefaultFont, .foregroundColor: diffHunkColor]
        } else if line.hasPrefix("+") {
            attrs = [
                .font: diffDefaultFont,
                .foregroundColor: diffAddColor,
                .backgroundColor: diffAddColor.withAlphaComponent(0.08),
            ]
        } else if line.hasPrefix("-") {
            attrs = [
                .font: diffDefaultFont,
                .foregroundColor: diffDelColor,
                .backgroundColor: diffDelColor.withAlphaComponent(0.08),
            ]
        } else if line.hasPrefix("new file") || line.hasPrefix("deleted file") ||
                    line.hasPrefix("index ") || line.hasPrefix("Binary") ||
                    line.hasPrefix("rename") || line.hasPrefix("similarity") {
            attrs = [.font: diffDefaultFont, .foregroundColor: diffContextColor.withAlphaComponent(0.6)]
        } else {
            attrs = [.font: diffDefaultFont, .foregroundColor: diffContextColor]
        }
        result.append(NSAttributedString(string: line + "\n", attributes: attrs))
    }
    return result
}

/// Measures the height needed to render an attributed string at a given width.
private func calculateDiffTextHeight(for attrStr: NSAttributedString, width: CGFloat = 300) -> CGFloat {
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: NSSize(width: max(width, 300), height: .greatestFiniteMagnitude))
    textContainer.lineFragmentPadding = 5
    let textStorage = NSTextStorage(attributedString: attrStr)
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
    layoutManager.ensureLayout(for: textContainer)
    let height = layoutManager.usedRect(for: textContainer).height + 8
    return max(height, 20)
}

/// Populates a horizontal stats stack with colored +N / -N labels.
private func populateStatsStack(_ stack: NSStackView, additions: Int, deletions: Int, isImage: Bool) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if isImage {
        let label = NSTextField(labelWithString: "image")
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = NSColor(resource: .textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
    } else {
        if additions > 0 {
            let label = NSTextField(labelWithString: "+\(additions)")
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = statsAddColor
            label.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(label)
        }
        if deletions > 0 {
            let label = NSTextField(labelWithString: "-\(deletions)")
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = statsDelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(label)
        }
    }
}

// MARK: - Resize Handle

fileprivate final class DiffDividerResizeHandle: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}

// MARK: - Flipped Stack Clip View

private final class FlippedDiffClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - ImageDiffContentView

private final class ImageDiffContentView: NSView {

    private let mode: ImageDiffMode
    private var beforeImageView: NSImageView?
    private var afterImageView: NSImageView?
    private var beforeLabel: NSTextField?
    private var afterLabel: NSTextField?
    private var heightConstraint: NSLayoutConstraint!

    private static let maxImageHeight: CGFloat = 300
    private static let labelHeight: CGFloat = 18
    private static let padding: CGFloat = 12

    init(mode: ImageDiffMode) {
        self.mode = mode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(resource: .textSecondary)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeImageView() -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor(resource: .textSecondary).withAlphaComponent(0.2).cgColor
        return iv
    }

    private func setupLayout() {
        let topPadding = Self.padding
        let imageTop = topPadding + Self.labelHeight + 4

        switch mode {
        case .modified:
            let bLabel = makeLabel("Before")
            let aLabel = makeLabel("After")
            let bImage = makeImageView()
            let aImage = makeImageView()

            addSubview(bLabel)
            addSubview(aLabel)
            addSubview(bImage)
            addSubview(aImage)

            // Arrow between the two images
            let arrow = NSTextField(labelWithString: "\u{2192}")
            arrow.font = .systemFont(ofSize: 16, weight: .regular)
            arrow.textColor = NSColor(resource: .textSecondary)
            arrow.alignment = .center
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrow.setContentHuggingPriority(.required, for: .horizontal)
            addSubview(arrow)

            heightConstraint = heightAnchor.constraint(equalToConstant: 200)

            NSLayoutConstraint.activate([
                heightConstraint,

                bLabel.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
                bLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
                bLabel.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -4),

                aLabel.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
                aLabel.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 4),
                aLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),

                arrow.centerYAnchor.constraint(equalTo: bImage.centerYAnchor),
                arrow.centerXAnchor.constraint(equalTo: centerXAnchor),
                arrow.widthAnchor.constraint(equalToConstant: 24),

                bImage.topAnchor.constraint(equalTo: topAnchor, constant: imageTop),
                bImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
                bImage.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -4),

                aImage.topAnchor.constraint(equalTo: topAnchor, constant: imageTop),
                aImage.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 4),
                aImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),

                bImage.heightAnchor.constraint(equalTo: aImage.heightAnchor),
            ])

            beforeImageView = bImage
            afterImageView = aImage
            beforeLabel = bLabel
            afterLabel = aLabel

        case .added:
            let label = makeLabel("New")
            let imageView = makeImageView()
            addSubview(label)
            addSubview(imageView)

            heightConstraint = heightAnchor.constraint(equalToConstant: 200)

            NSLayoutConstraint.activate([
                heightConstraint,
                label.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
                label.centerXAnchor.constraint(equalTo: centerXAnchor),

                imageView.topAnchor.constraint(equalTo: topAnchor, constant: imageTop),
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.padding),
                imageView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
            ])

            afterImageView = imageView

        case .deleted:
            let label = makeLabel("Deleted")
            let imageView = makeImageView()
            addSubview(label)
            addSubview(imageView)

            heightConstraint = heightAnchor.constraint(equalToConstant: 200)

            NSLayoutConstraint.activate([
                heightConstraint,
                label.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
                label.centerXAnchor.constraint(equalTo: centerXAnchor),

                imageView.topAnchor.constraint(equalTo: topAnchor, constant: imageTop),
                imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
                imageView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.padding),
                imageView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
            ])

            beforeImageView = imageView
        }
    }

    func setImages(before: NSImage?, after: NSImage?) {
        beforeImageView?.image = before
        afterImageView?.image = after

        let imageTop = Self.padding + Self.labelHeight + 4
        let bottomPadding = Self.padding

        // Compute the height needed based on image aspect ratios and available width
        let availableWidth: CGFloat
        switch mode {
        case .modified:
            availableWidth = max((bounds.width - Self.padding * 2 - 24) / 2, 100)
        case .added, .deleted:
            availableWidth = max(bounds.width - Self.padding * 2, 100)
        }

        var maxH: CGFloat = 60 // minimum content area
        for image in [before, after].compactMap({ $0 }) {
            let aspect = image.size.height / max(image.size.width, 1)
            let h = min(availableWidth * aspect, Self.maxImageHeight)
            maxH = max(maxH, h)
        }

        heightConstraint.constant = imageTop + maxH + bottomPadding
    }
}

// MARK: - HunkView

private final class HunkView: NSView {

    private let headerView = NSView()
    private let chevronImage = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let contentTextView = NSTextView()
    private var contentHeightConstraint: NSLayoutConstraint!
    private var expandedBottomConstraint: NSLayoutConstraint!
    private var collapsedBottomConstraint: NSLayoutConstraint!

    var isExpanded: Bool = true {
        didSet {
            contentTextView.isHidden = !isExpanded
            // Deactivate first, then activate to avoid momentary constraint conflicts
            if isExpanded {
                collapsedBottomConstraint.isActive = false
                expandedBottomConstraint.isActive = true
                contentHeightConstraint.isActive = true
            } else {
                expandedBottomConstraint.isActive = false
                contentHeightConstraint.isActive = false
                collapsedBottomConstraint.isActive = true
            }
            chevronImage.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil
            )
        }
    }

    init(headerLine: String, content: NSAttributedString) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(headerLine: headerLine, content: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(headerLine: String, content: NSAttributedString) {
        // Header bar (clickable)
        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        headerView.addGestureRecognizer(click)

        // Small chevron
        chevronImage.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevronImage.contentTintColor = diffHunkColor
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        chevronImage.symbolConfiguration = config
        chevronImage.translatesAutoresizingMaskIntoConstraints = false
        chevronImage.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(chevronImage)

        // @@ header text
        headerLabel.stringValue = headerLine
        headerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        headerLabel.textColor = diffHunkColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerLabel)

        // Content text view
        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.isRichText = true
        contentTextView.drawsBackground = false
        contentTextView.textContainerInset = NSSize(width: 8, height: 2)
        contentTextView.isVerticallyResizable = false
        contentTextView.isHorizontallyResizable = false
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.autoresizingMask = [.width]
        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentTextView)

        contentTextView.textStorage?.setAttributedString(content)

        let contentHeight = calculateDiffTextHeight(for: content)
        contentHeightConstraint = contentTextView.heightAnchor.constraint(equalToConstant: contentHeight)

        expandedBottomConstraint = contentTextView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint.isActive = false

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 20),

            chevronImage.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            chevronImage.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            chevronImage.widthAnchor.constraint(equalToConstant: 8),
            chevronImage.heightAnchor.constraint(equalToConstant: 8),

            headerLabel.leadingAnchor.constraint(equalTo: chevronImage.trailingAnchor, constant: 4),
            headerLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerView.trailingAnchor, constant: -8),

            contentTextView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentTextView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentTextView.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedBottomConstraint,
            contentHeightConstraint,
        ])
    }

    func updateContentWidth(_ width: CGFloat) {
        guard let textStorage = contentTextView.textStorage else { return }
        let attrStr = NSAttributedString(attributedString: textStorage)
        contentHeightConstraint.constant = calculateDiffTextHeight(for: attrStr, width: width - 16)
    }

    @objc private func headerClicked() {
        isExpanded.toggle()
    }
}

// MARK: - DiffSectionView

private final class DiffSectionView: NSView {

    let filePath: String
    let additions: Int
    let deletions: Int
    let isImageMode: Bool

    private let headerView = NSView()
    private let chevronImage = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsStack = NSStackView()

    // Text mode
    private let hunksStackView = NSStackView()
    private var hunkViews: [HunkView] = []
    private var preambleTextView: NSTextView?
    private var preambleHeightConstraint: NSLayoutConstraint?

    // Image mode
    private var imageContentView: ImageDiffContentView?
    private var imageHeightConstraint: NSLayoutConstraint?

    // Expand/collapse constraints
    private var expandedBottomConstraint: NSLayoutConstraint!
    private var collapsedBottomConstraint: NSLayoutConstraint!

    var isExpanded: Bool = true {
        didSet {
            if isImageMode {
                imageContentView?.isHidden = !isExpanded
            } else {
                hunksStackView.isHidden = !isExpanded
            }
            // Deactivate first, then activate to avoid momentary constraint conflicts
            if isExpanded {
                collapsedBottomConstraint.isActive = false
                expandedBottomConstraint.isActive = true
            } else {
                expandedBottomConstraint.isActive = false
                collapsedBottomConstraint.isActive = true
            }
            chevronImage.image = NSImage(
                systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: nil
            )
        }
    }

    var onToggle: (() -> Void)?

    /// Text diff init — takes raw chunk string and splits into collapsible hunks.
    init(filePath: String, rawChunk: String, additions: Int, deletions: Int) {
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.isImageMode = false
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupHeader()
        setupContent(rawChunk)
    }

    /// Image diff init
    init(filePath: String, imageDiffMode: ImageDiffMode) {
        self.filePath = filePath
        self.additions = 0
        self.deletions = 0
        self.isImageMode = true
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupHeader()
        setupImageContent(mode: imageDiffMode)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupHeader() {
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.08).cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Click gesture on header
        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        headerView.addGestureRecognizer(click)

        // Chevron
        chevronImage.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevronImage.contentTintColor = NSColor(resource: .textSecondary)
        chevronImage.translatesAutoresizingMaskIntoConstraints = false
        chevronImage.setContentHuggingPriority(.required, for: .horizontal)
        headerView.addSubview(chevronImage)

        // File path
        pathLabel.stringValue = filePath
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        pathLabel.textColor = diffHeaderColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(pathLabel)

        // Stats stack (colored +N / -N)
        statsStack.orientation = .horizontal
        statsStack.spacing = 4
        statsStack.translatesAutoresizingMaskIntoConstraints = false
        statsStack.setContentHuggingPriority(.required, for: .horizontal)
        statsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        populateStatsStack(statsStack, additions: additions, deletions: deletions, isImage: isImageMode)
        headerView.addSubview(statsStack)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 24),

            chevronImage.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 8),
            chevronImage.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            chevronImage.widthAnchor.constraint(equalToConstant: 10),
            chevronImage.heightAnchor.constraint(equalToConstant: 10),

            pathLabel.leadingAnchor.constraint(equalTo: chevronImage.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: statsStack.leadingAnchor, constant: -8),

            statsStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            statsStack.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
    }

    private func setupContent(_ rawChunk: String) {
        hunksStackView.orientation = .vertical
        hunksStackView.alignment = .leading
        hunksStackView.spacing = 0
        hunksStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hunksStackView)

        let lines = rawChunk.components(separatedBy: "\n")

        // Split into preamble + hunk groups
        var preambleLines: [String] = []
        var hunks: [(header: String, lines: [String])] = []
        var currentHunkHeader: String?
        var currentHunkLines: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git") {
                continue
            }

            if line.hasPrefix("@@") {
                // Save previous hunk if any
                if let header = currentHunkHeader {
                    hunks.append((header: header, lines: currentHunkLines))
                }
                currentHunkHeader = line
                currentHunkLines = []
            } else if currentHunkHeader != nil {
                currentHunkLines.append(line)
            } else {
                preambleLines.append(line)
            }
        }

        // Save last hunk
        if let header = currentHunkHeader {
            hunks.append((header: header, lines: currentHunkLines))
        }

        // Add preamble if non-empty
        if !preambleLines.isEmpty && !preambleLines.allSatisfy({ $0.isEmpty }) {
            let preambleAttr = parseDiffLines(preambleLines)
            let textView = NSTextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 2)
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.autoresizingMask = [.width]
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.textStorage?.setAttributedString(preambleAttr)

            let height = calculateDiffTextHeight(for: preambleAttr)
            let hc = textView.heightAnchor.constraint(equalToConstant: height)
            hc.isActive = true

            hunksStackView.addArrangedSubview(textView)
            textView.leadingAnchor.constraint(equalTo: hunksStackView.leadingAnchor).isActive = true
            textView.trailingAnchor.constraint(equalTo: hunksStackView.trailingAnchor).isActive = true

            preambleTextView = textView
            preambleHeightConstraint = hc
        }

        // Add hunk views
        for hunk in hunks {
            let hunkContent = parseDiffLines(hunk.lines)
            let hunkView = HunkView(headerLine: hunk.header, content: hunkContent)
            hunkViews.append(hunkView)
            hunksStackView.addArrangedSubview(hunkView)
            hunkView.leadingAnchor.constraint(equalTo: hunksStackView.leadingAnchor).isActive = true
            hunkView.trailingAnchor.constraint(equalTo: hunksStackView.trailingAnchor).isActive = true
        }

        expandedBottomConstraint = hunksStackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint.isActive = false

        NSLayoutConstraint.activate([
            hunksStackView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            hunksStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hunksStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedBottomConstraint,
        ])
    }

    private func setupImageContent(mode: ImageDiffMode) {
        let imageView = ImageDiffContentView(mode: mode)
        addSubview(imageView)

        let ihc = imageView.heightAnchor.constraint(equalToConstant: 200)
        imageHeightConstraint = ihc

        expandedBottomConstraint = imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint.isActive = false

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedBottomConstraint,
            ihc,
        ])

        imageContentView = imageView
    }

    func setImages(before: NSImage?, after: NSImage?) {
        imageContentView?.setImages(before: before, after: after)
        // Update the outer height constraint to match what ImageDiffContentView computed
        if let icv = imageContentView {
            icv.layoutSubtreeIfNeeded()
            imageHeightConstraint?.constant = icv.fittingSize.height
        }
    }

    func updateContentWidth(_ width: CGFloat) {
        guard !isImageMode else { return }
        // Update preamble
        if let preamble = preambleTextView,
           let constraint = preambleHeightConstraint,
           let textStorage = preamble.textStorage {
            let attrStr = NSAttributedString(attributedString: textStorage)
            constraint.constant = calculateDiffTextHeight(for: attrStr, width: width - 16)
        }
        // Update hunk views
        for hunkView in hunkViews {
            hunkView.updateContentWidth(width)
        }
    }

    @objc private func headerClicked() {
        onToggle?()
    }
}

// MARK: - InlineDiffViewController

final class InlineDiffViewController: NSViewController {

    private let scrollView = NSScrollView()
    private let sectionsStackView = NSStackView()
    private let closeButton = NSButton()
    private let expandCollapseButton = NSButton()
    private let headerLabel = NSTextField(labelWithString: "")
    private let resizeHandle = DiffDividerResizeHandle()

    // Sticky header
    private let stickyHeader = NSView()
    private let stickyChevron = NSImageView()
    private let stickyPathLabel = NSTextField(labelWithString: "")
    private let stickyStatsStack = NSStackView()
    private var stickyTopConstraint: NSLayoutConstraint!
    private weak var currentStickySection: DiffSectionView?

    private var sectionViews: [DiffSectionView] = []
    private var allExpanded = true

    private var worktreePath: String?
    private var mergeBase: String?

    var onClose: (() -> Void)?
    /// Called during drag with the delta (positive = drag up = diff taller).
    var onResizeDrag: ((_ phase: NSPanGestureRecognizer.State, _ deltaY: CGFloat) -> Void)?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("[DiffVC] viewDidLoad start")
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        NSLog("[DiffVC] calling setupUI")
        setupUI()
        NSLog("[DiffVC] viewDidLoad done")
    }

    private func setupUI() {
        NSLog("[DiffVC] setupUI: creating views")
        // Resize handle at the top (6px drag area)
        resizeHandle.wantsLayer = true
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        // Separator line inside the handle
        let separatorLine = NSView()
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.4).cgColor
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(separatorLine)

        // Header bar
        let headerBar = NSView()
        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        headerBar.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textSecondary)
        headerLabel.stringValue = "DIFF"
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        // Expand/collapse all toggle
        expandCollapseButton.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "Collapse All")
        expandCollapseButton.contentTintColor = NSColor(resource: .textSecondary)
        expandCollapseButton.bezelStyle = .inline
        expandCollapseButton.isBordered = false
        expandCollapseButton.target = self
        expandCollapseButton.action = #selector(toggleExpandCollapseAll)
        expandCollapseButton.toolTip = "Collapse All"
        expandCollapseButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(expandCollapseButton)

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Diff")
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(closeButton)

        // Sections stack view
        sectionsStackView.orientation = .vertical
        sectionsStackView.alignment = .leading
        sectionsStackView.spacing = 0
        sectionsStackView.translatesAutoresizingMaskIntoConstraints = false

        let flippedClip = FlippedDiffClipView()
        flippedClip.drawsBackground = false
        scrollView.contentView = flippedClip
        scrollView.documentView = sectionsStackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Drag-to-resize gesture on handle
        let panGesture = NSPanGestureRecognizer(target: self, action: #selector(handleResizeDrag(_:)))
        resizeHandle.addGestureRecognizer(panGesture)

        NSLog("[DiffVC] setupUI: adding subviews to hierarchy")
        // Add subviews FIRST (before any cross-view constraints)
        view.addSubview(scrollView)
        view.addSubview(stickyHeader)
        view.addSubview(headerBar)
        view.addSubview(resizeHandle)

        NSLog("[DiffVC] setupUI: setting up sticky header")
        // Setup sticky header (AFTER views are in hierarchy so constraints have common ancestor)
        setupStickyHeader()

        // Enable scroll observation for sticky header
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NSLog("[DiffVC] setupUI: activating main constraints")
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: view.topAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resizeHandle.heightAnchor.constraint(equalToConstant: 6),

            separatorLine.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor),
            separatorLine.leadingAnchor.constraint(equalTo: resizeHandle.leadingAnchor, constant: 8),
            separatorLine.trailingAnchor.constraint(equalTo: resizeHandle.trailingAnchor, constant: -8),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),

            headerBar.topAnchor.constraint(equalTo: resizeHandle.bottomAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 24),

            headerLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            headerLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            expandCollapseButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            expandCollapseButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            expandCollapseButton.widthAnchor.constraint(equalToConstant: 16),
            expandCollapseButton.heightAnchor.constraint(equalToConstant: 16),

            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            sectionsStackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            sectionsStackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            sectionsStackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        NSLog("[DiffVC] setupUI: done")
    }

    // MARK: - Sticky Header

    private func setupStickyHeader() {
        NSLog("[DiffVC] setupStickyHeader: configuring views")
        stickyHeader.wantsLayer = true
        stickyHeader.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.08).cgColor
        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.isHidden = true

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(stickyHeaderClicked))
        stickyHeader.addGestureRecognizer(click)

        // Chevron
        stickyChevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        stickyChevron.contentTintColor = NSColor(resource: .textSecondary)
        stickyChevron.translatesAutoresizingMaskIntoConstraints = false
        stickyChevron.setContentHuggingPriority(.required, for: .horizontal)
        stickyHeader.addSubview(stickyChevron)

        // File path
        stickyPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        stickyPathLabel.textColor = diffHeaderColor
        stickyPathLabel.lineBreakMode = .byTruncatingHead
        stickyPathLabel.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.addSubview(stickyPathLabel)

        // Stats
        stickyStatsStack.orientation = .horizontal
        stickyStatsStack.spacing = 4
        stickyStatsStack.translatesAutoresizingMaskIntoConstraints = false
        stickyStatsStack.setContentHuggingPriority(.required, for: .horizontal)
        stickyStatsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stickyHeader.addSubview(stickyStatsStack)

        NSLog("[DiffVC] setupStickyHeader: creating constraints (stickyHeader.superview=%@, scrollView.superview=%@)",
              String(describing: stickyHeader.superview), String(describing: scrollView.superview))
        stickyTopConstraint = stickyHeader.topAnchor.constraint(equalTo: scrollView.topAnchor)

        NSLog("[DiffVC] setupStickyHeader: activating constraints")
        NSLayoutConstraint.activate([
            stickyTopConstraint,
            stickyHeader.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stickyHeader.heightAnchor.constraint(equalToConstant: 24),

            stickyChevron.leadingAnchor.constraint(equalTo: stickyHeader.leadingAnchor, constant: 8),
            stickyChevron.centerYAnchor.constraint(equalTo: stickyHeader.centerYAnchor),
            stickyChevron.widthAnchor.constraint(equalToConstant: 10),
            stickyChevron.heightAnchor.constraint(equalToConstant: 10),

            stickyPathLabel.leadingAnchor.constraint(equalTo: stickyChevron.trailingAnchor, constant: 6),
            stickyPathLabel.centerYAnchor.constraint(equalTo: stickyHeader.centerYAnchor),
            stickyPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: stickyStatsStack.leadingAnchor, constant: -8),

            stickyStatsStack.trailingAnchor.constraint(equalTo: stickyHeader.trailingAnchor, constant: -12),
            stickyStatsStack.centerYAnchor.constraint(equalTo: stickyHeader.centerYAnchor),
        ])
    }

    @objc private func handleScrollChange() {
        let visibleY = scrollView.contentView.bounds.origin.y

        var candidateSection: DiffSectionView?
        var nextSectionHeaderY: CGFloat?

        for (i, section) in sectionViews.enumerated() {
            let frame = section.convert(section.bounds, to: sectionsStackView)
            // Section whose header top is above visibleY but whose bottom is below
            if frame.origin.y <= visibleY && frame.maxY > visibleY {
                candidateSection = section
                if i + 1 < sectionViews.count {
                    let nextFrame = sectionViews[i + 1].convert(sectionViews[i + 1].bounds, to: sectionsStackView)
                    nextSectionHeaderY = nextFrame.origin.y
                }
                break
            }
        }

        guard let section = candidateSection else {
            stickyHeader.isHidden = true
            currentStickySection = nil
            return
        }

        // Don't show sticky header if the section's own header is still visible
        let sectionFrame = section.convert(section.bounds, to: sectionsStackView)
        if sectionFrame.origin.y >= visibleY {
            stickyHeader.isHidden = true
            currentStickySection = nil
            return
        }

        // Show and update sticky header
        stickyHeader.isHidden = false
        currentStickySection = section
        stickyPathLabel.stringValue = section.filePath
        populateStatsStack(stickyStatsStack, additions: section.additions, deletions: section.deletions, isImage: section.isImageMode)
        stickyChevron.image = NSImage(
            systemSymbolName: section.isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )

        // Push-up effect: next section's header pushes sticky header up
        if let nextY = nextSectionHeaderY {
            let overlap = visibleY + 24 - nextY
            if overlap > 0 {
                stickyTopConstraint.constant = -overlap
            } else {
                stickyTopConstraint.constant = 0
            }
        } else {
            stickyTopConstraint.constant = 0
        }
    }

    @objc private func stickyHeaderClicked() {
        guard let section = currentStickySection else { return }
        // onToggle already toggles isExpanded — don't toggle it here too
        section.onToggle?()
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func toggleExpandCollapseAll() {
        if allExpanded {
            collapseAll()
        } else {
            expandAll()
        }
    }

    private func updateExpandCollapseButton() {
        if allExpanded {
            expandCollapseButton.image = NSImage(systemSymbolName: "rectangle.compress.vertical", accessibilityDescription: "Collapse All")
            expandCollapseButton.toolTip = "Collapse All"
        } else {
            expandCollapseButton.image = NSImage(systemSymbolName: "rectangle.expand.vertical", accessibilityDescription: "Expand All")
            expandCollapseButton.toolTip = "Expand All"
        }
    }

    @objc private func handleResizeDrag(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        // Negative y means drag up = diff gets taller
        onResizeDrag?(gesture.state, -translation.y)
        if gesture.state == .changed {
            gesture.setTranslation(.zero, in: view)
        }
    }

    // MARK: - Content

    func setDiffContent(_ rawDiff: String, fileCount: Int, worktreePath: String?, mergeBase: String?) {
        self.worktreePath = worktreePath
        self.mergeBase = mergeBase

        headerLabel.stringValue = "DIFF (\(fileCount) files)"

        // Clear old sections
        for sv in sectionsStackView.arrangedSubviews {
            sectionsStackView.removeArrangedSubview(sv)
            sv.removeFromSuperview()
        }
        sectionViews.removeAll()

        // Split diff into per-file chunks and create section views
        let chunks = splitDiffIntoFileChunks(rawDiff)
        for (path, chunkContent) in chunks {
            let section: DiffSectionView

            if isImageFile(path) {
                let state = detectImageDiffState(from: chunkContent)
                section = DiffSectionView(filePath: path, imageDiffMode: state)
                loadImages(for: section, path: path, chunk: chunkContent, state: state)
            } else {
                let (additions, deletions) = countStats(in: chunkContent)
                section = DiffSectionView(
                    filePath: path,
                    rawChunk: chunkContent,
                    additions: additions,
                    deletions: deletions
                )
            }

            section.onToggle = { [weak self, weak section] in
                guard let self, let section else { return }
                section.isExpanded.toggle()
                self.syncExpandCollapseState()
                self.scrollSectionIntoViewIfNeeded(section)
            }
            sectionViews.append(section)
            sectionsStackView.addArrangedSubview(section)
            section.leadingAnchor.constraint(equalTo: sectionsStackView.leadingAnchor).isActive = true
            section.trailingAnchor.constraint(equalTo: sectionsStackView.trailingAnchor).isActive = true
        }
    }

    // MARK: - Image Loading

    private func loadImages(for section: DiffSectionView, path: String, chunk: String, state: ImageDiffMode) {
        guard let worktreePath else { return }
        let mergeBase = self.mergeBase
        let beforePath = extractRenameFrom(chunk) ?? path

        Task {
            var beforeImage: NSImage?
            var afterImage: NSImage?

            // Load before image (from git ref)
            if state != .added, let ref = mergeBase {
                if let data = await GitService.shared.fileData(
                    atRef: ref,
                    relativePath: beforePath,
                    worktreePath: worktreePath
                ) {
                    beforeImage = NSImage(data: data)
                }
            }

            // Load after image (from working tree)
            if state != .deleted {
                let fileURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(path)
                if let data = try? Data(contentsOf: fileURL) {
                    afterImage = NSImage(data: data)
                }
            }

            await MainActor.run {
                section.setImages(before: beforeImage, after: afterImage)
            }
        }
    }

    func expandFile(_ relativePath: String, collapseOthers: Bool) {
        for section in sectionViews {
            if section.filePath == relativePath {
                section.isExpanded = true
            } else if collapseOthers {
                section.isExpanded = false
            }
        }
        syncExpandCollapseState()
        // Scroll to the expanded section
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let section = self.sectionViews.first(where: { $0.filePath == relativePath }) {
                self.scrollSectionIntoViewIfNeeded(section)
            }
        }
    }

    private func syncExpandCollapseState() {
        allExpanded = sectionViews.allSatisfy(\.isExpanded)
        updateExpandCollapseButton()
    }

    func expandAll() {
        // Find anchor section at top of viewport
        let visibleY = scrollView.contentView.bounds.origin.y
        var anchorSection: DiffSectionView?
        var anchorOffsetBefore: CGFloat = 0
        for section in sectionViews {
            let frame = section.convert(section.bounds, to: sectionsStackView)
            if frame.maxY > visibleY {
                anchorSection = section
                anchorOffsetBefore = frame.origin.y - visibleY
                break
            }
        }

        for section in sectionViews {
            section.isExpanded = true
        }
        allExpanded = true
        updateExpandCollapseButton()

        // Restore scroll after layout completes
        if let anchor = anchorSection {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sectionsStackView.layoutSubtreeIfNeeded()
                let newFrame = anchor.convert(anchor.bounds, to: self.sectionsStackView)
                let newScrollY = newFrame.origin.y - anchorOffsetBefore
                self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(newScrollY, 0)))
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    func collapseAll() {
        // Find anchor section at top of viewport
        let visibleY = scrollView.contentView.bounds.origin.y
        var anchorSection: DiffSectionView?
        var anchorOffsetBefore: CGFloat = 0
        for section in sectionViews {
            let frame = section.convert(section.bounds, to: sectionsStackView)
            if frame.maxY > visibleY {
                anchorSection = section
                anchorOffsetBefore = frame.origin.y - visibleY
                break
            }
        }

        for section in sectionViews {
            section.isExpanded = false
        }
        allExpanded = false
        updateExpandCollapseButton()

        // Restore scroll after layout completes
        if let anchor = anchorSection {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sectionsStackView.layoutSubtreeIfNeeded()
                let newFrame = anchor.convert(anchor.bounds, to: self.sectionsStackView)
                let newScrollY = newFrame.origin.y - anchorOffsetBefore
                self.scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(newScrollY, 0)))
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    func scrollToFile(_ relativePath: String) {
        guard let section = sectionViews.first(where: { $0.filePath == relativePath }) else { return }
        scrollSectionIntoViewIfNeeded(section)
    }

    private func scrollSectionIntoViewIfNeeded(_ section: DiffSectionView) {
        let sectionFrame = section.convert(section.bounds, to: sectionsStackView)
        scrollView.contentView.scrollToVisible(sectionFrame)
    }

    // MARK: - Diff Splitting

    private func splitDiffIntoFileChunks(_ rawDiff: String) -> [(path: String, content: String)] {
        var chunks: [(path: String, content: String)] = []
        let lines = rawDiff.components(separatedBy: "\n")

        var currentPath = ""
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git") {
                // Save previous chunk if any
                if !currentPath.isEmpty {
                    chunks.append((path: currentPath, content: currentLines.joined(separator: "\n")))
                }
                // Extract path from "diff --git a/path b/path"
                let parts = line.components(separatedBy: " b/")
                currentPath = parts.count >= 2 ? (parts.last ?? "") : ""
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        // Save last chunk
        if !currentPath.isEmpty {
            chunks.append((path: currentPath, content: currentLines.joined(separator: "\n")))
        }

        return chunks
    }

    private func countStats(in chunk: String) -> (additions: Int, deletions: Int) {
        var adds = 0
        var dels = 0
        for line in chunk.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                adds += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                dels += 1
            }
        }
        return (adds, dels)
    }
}
