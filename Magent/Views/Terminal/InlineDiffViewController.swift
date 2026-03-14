import Cocoa
import MagentCore

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

private func decodeQuotedGitPath(_ rawPath: String) -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return trimmed }

    let body = trimmed.dropFirst().dropLast()
    var result = ""
    var index = body.startIndex

    while index < body.endIndex {
        let char = body[index]
        guard char == "\\" else {
            result.append(char)
            index = body.index(after: index)
            continue
        }

        let escapeIndex = body.index(after: index)
        guard escapeIndex < body.endIndex else {
            result.append("\\")
            break
        }

        let escape = body[escapeIndex]
        switch escape {
        case "\\":
            result.append("\\")
        case "\"":
            result.append("\"")
        case "t":
            result.append("\t")
        case "n":
            result.append("\n")
        case "r":
            result.append("\r")
        case "0"..."7":
            var octal = String(escape)
            var octalIndex = body.index(after: escapeIndex)
            while octalIndex < body.endIndex, octal.count < 3 {
                let digit = body[octalIndex]
                guard ("0"..."7").contains(digit) else { break }
                octal.append(digit)
                octalIndex = body.index(after: octalIndex)
            }
            if let scalar = UInt8(octal, radix: 8) {
                result.append(Character(UnicodeScalar(scalar)))
            }
            index = octalIndex
            continue
        default:
            result.append(escape)
        }

        index = body.index(after: escapeIndex)
    }

    return result
}

private func normalizedGitPatchPath(_ rawPath: String, preferredPrefix: Character? = nil) -> String? {
    let decoded = decodeQuotedGitPath(rawPath)
    guard !decoded.isEmpty, decoded != "/dev/null" else { return nil }

    if let preferredPrefix, decoded.hasPrefix("\(preferredPrefix)/") {
        return String(decoded.dropFirst(2))
    }
    if decoded.hasPrefix("a/") || decoded.hasPrefix("b/") {
        return String(decoded.dropFirst(2))
    }
    return decoded
}

private func parseGitDiffHeaderPaths(_ line: String) -> (oldPath: String?, newPath: String?) {
    guard line.hasPrefix("diff --git ") else { return (nil, nil) }
    let remainder = line.dropFirst("diff --git ".count)
    var index = remainder.startIndex

    func consumePathToken() -> Substring? {
        while index < remainder.endIndex, remainder[index] == " " {
            index = remainder.index(after: index)
        }
        guard index < remainder.endIndex else { return nil }

        let start = index
        if remainder[index] == "\"" {
            index = remainder.index(after: index)
            while index < remainder.endIndex {
                if remainder[index] == "\"" {
                    let backslashCount = remainder[..<index].reversed().prefix { $0 == "\\" }.count
                    if backslashCount.isMultiple(of: 2) {
                        let token = remainder[start...index]
                        index = remainder.index(after: index)
                        return token
                    }
                }
                index = remainder.index(after: index)
            }
            return remainder[start..<remainder.endIndex]
        }

        while index < remainder.endIndex, remainder[index] != " " {
            index = remainder.index(after: index)
        }
        return remainder[start..<index]
    }

    let oldToken = consumePathToken().map(String.init)
    let newToken = consumePathToken().map(String.init)
    return (
        oldPath: oldToken.flatMap { normalizedGitPatchPath($0, preferredPrefix: "a") },
        newPath: newToken.flatMap { normalizedGitPatchPath($0, preferredPrefix: "b") }
    )
}

private func pathForDiffChunk(_ chunk: String) -> String? {
    var deletedPath: String?

    for line in chunk.components(separatedBy: "\n") {
        if line.hasPrefix("rename to ") {
            return normalizedGitPatchPath(String(line.dropFirst("rename to ".count)))
        }
        if line.hasPrefix("+++ ") {
            if let path = normalizedGitPatchPath(String(line.dropFirst(4)), preferredPrefix: "b") {
                return path
            }
        }
        if line.hasPrefix("--- "), deletedPath == nil {
            deletedPath = normalizedGitPatchPath(String(line.dropFirst(4)), preferredPrefix: "a")
        }
        if line.hasPrefix("diff --git ") {
            let headerPaths = parseGitDiffHeaderPaths(line)
            deletedPath = deletedPath ?? headerPaths.oldPath
            if let newPath = headerPaths.newPath, chunk.contains("Binary files") {
                return newPath
            }
        }
    }

    return deletedPath
}

/// Extracts the old path from a `rename from <path>` line in a diff chunk.
private func extractRenameFrom(_ chunk: String) -> String? {
    for line in chunk.components(separatedBy: "\n") {
        if line.hasPrefix("rename from ") {
            return normalizedGitPatchPath(String(line.dropFirst("rename from ".count)))
        }
    }
    return nil
}

/// Parses a `@@ -oldStart,oldCount +newStart,newCount @@` header into its components.
private func parseHunkHeader(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
    let pattern = #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
        return nil
    }
    let ns = header as NSString
    let oldStart = Int(ns.substring(with: match.range(at: 1))) ?? 0
    let oldCount = match.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: match.range(at: 2))) ?? 1) : 1
    let newStart = Int(ns.substring(with: match.range(at: 3))) ?? 0
    let newCount = match.range(at: 4).location != NSNotFound ? (Int(ns.substring(with: match.range(at: 4))) ?? 1) : 1
    return (oldStart, oldCount, newStart, newCount)
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

private final class DiffTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command, event.charactersIgnoringModifiers == "c" else {
            return super.performKeyEquivalent(with: event)
        }
        guard selectedRange().length > 0 else {
            return super.performKeyEquivalent(with: event)
        }
        copy(nil)
        return true
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else {
            super.copy(sender)
            return
        }
        let selectedString = (string as NSString).substring(with: selection)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedString, forType: .string)
    }
}

/// Parses an array of diff lines into a colored attributed string.
private func parseDiffLines(_ lines: [String]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for line in lines {
        let attrs: [NSAttributedString.Key: Any]
        if line.hasPrefix("diff --git") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("@@") {
            continue // Skip metadata headers; render only actual code/context lines.
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

private final class ClickableDiffImageView: NSImageView {
    var onLeftClick: (() -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onLeftClick?()
    }
}

// MARK: - ImageDiffContentView

private final class ImageDiffContentView: NSView {

    private let mode: ImageDiffMode
    private var beforeImageView: ClickableDiffImageView?
    private var afterImageView: ClickableDiffImageView?
    private var beforeLabel: NSTextField?
    private var afterLabel: NSTextField?
    private var heightConstraint: NSLayoutConstraint!
    private var beforeImageHeightConstraint: NSLayoutConstraint?
    private var afterImageHeightConstraint: NSLayoutConstraint?
    var onImageClick: ((NSImageView, NSImage) -> Void)?

    private static let maxImageHeight: CGFloat = 420
    private static let maxViewportHeightFraction: CGFloat = 0.55
    private static let minimumPlaceholderHeight: CGFloat = 60
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

    private func makeImageView() -> ClickableDiffImageView {
        let iv = ClickableDiffImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.borderWidth = 1
        iv.layer?.borderColor = NSColor(resource: .textSecondary).withAlphaComponent(0.2).cgColor
        iv.toolTip = "Click to enlarge"
        iv.onLeftClick = { [weak self, weak iv] in
            guard let self, let iv, let image = iv.image else { return }
            self.onImageClick?(iv, image)
        }
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
            let beforeHeight = bImage.heightAnchor.constraint(equalToConstant: Self.minimumPlaceholderHeight)
            let afterHeight = aImage.heightAnchor.constraint(equalToConstant: Self.minimumPlaceholderHeight)
            beforeImageHeightConstraint = beforeHeight
            afterImageHeightConstraint = afterHeight

            NSLayoutConstraint.activate([
                heightConstraint,
                beforeHeight,
                afterHeight,

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
            let imageHeight = imageView.heightAnchor.constraint(equalToConstant: Self.minimumPlaceholderHeight)
            afterImageHeightConstraint = imageHeight

            NSLayoutConstraint.activate([
                heightConstraint,
                imageHeight,
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
            let imageHeight = imageView.heightAnchor.constraint(equalToConstant: Self.minimumPlaceholderHeight)
            beforeImageHeightConstraint = imageHeight

            NSLayoutConstraint.activate([
                heightConstraint,
                imageHeight,
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
        updateContentWidth(bounds.width)
    }

    func updateContentWidth(_ width: CGFloat) {
        let imageTop = Self.padding + Self.labelHeight + 4
        let bottomPadding = Self.padding

        let contentWidth = max(width, Self.padding * 2 + 100)
        let viewportHeight = max(enclosingScrollView?.contentSize.height ?? 0, Self.minimumPlaceholderHeight)
        let maxRenderedHeight = min(
            Self.maxImageHeight,
            max(Self.minimumPlaceholderHeight, viewportHeight * Self.maxViewportHeightFraction)
        )

        func renderedHeight(for image: NSImage?, availableWidth: CGFloat) -> CGFloat {
            guard let image else { return Self.minimumPlaceholderHeight }
            let aspect = image.size.height / max(image.size.width, 1)
            let widthFitHeight = availableWidth * aspect
            // With scaleProportionallyUpOrDown (aspect-fit), the image always scales to fill
            // the frame proportionally — no need to cap at intrinsic size.
            return max(min(widthFitHeight, maxRenderedHeight), Self.minimumPlaceholderHeight)
        }

        switch mode {
        case .modified:
            let availableWidth = max((contentWidth - Self.padding * 2 - 24) / 2, 100)
            let maxH = max(
                renderedHeight(for: beforeImageView?.image, availableWidth: availableWidth),
                renderedHeight(for: afterImageView?.image, availableWidth: availableWidth)
            )
            beforeImageHeightConstraint?.constant = maxH
            afterImageHeightConstraint?.constant = maxH
            heightConstraint.constant = imageTop + maxH + bottomPadding
        case .added:
            let availableWidth = max(contentWidth - Self.padding * 2, 100)
            let imageHeight = renderedHeight(for: afterImageView?.image, availableWidth: availableWidth)
            afterImageHeightConstraint?.constant = imageHeight
            heightConstraint.constant = imageTop + imageHeight + bottomPadding
        case .deleted:
            let availableWidth = max(contentWidth - Self.padding * 2, 100)
            let imageHeight = renderedHeight(for: beforeImageView?.image, availableWidth: availableWidth)
            beforeImageHeightConstraint?.constant = imageHeight
            heightConstraint.constant = imageTop + imageHeight + bottomPadding
        }
    }
}

// MARK: - HunkView

/// Displays a single diff hunk content block.
/// Always visible (no expand/collapse).
private final class HunkView: NSView {

    private let contentTextView = DiffTextView()
    private var contentHeightConstraint: NSLayoutConstraint!

    init(content: NSAttributedString) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup(content: content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup(content: NSAttributedString) {
        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.isRichText = true
        contentTextView.drawsBackground = false
        contentTextView.textContainerInset = NSSize(width: 8, height: 0)
        contentTextView.isVerticallyResizable = false
        contentTextView.isHorizontallyResizable = false
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.autoresizingMask = [.width]
        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentTextView)

        contentTextView.textStorage?.setAttributedString(content)

        let contentHeight = calculateDiffTextHeight(for: content)
        contentHeightConstraint = contentTextView.heightAnchor.constraint(equalToConstant: contentHeight)

        NSLayoutConstraint.activate([
            contentTextView.topAnchor.constraint(equalTo: topAnchor),
            contentTextView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentTextView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentTextView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentHeightConstraint,
        ])
    }

    func updateContentWidth(_ width: CGFloat) {
        guard let textStorage = contentTextView.textStorage else { return }
        let attrStr = NSAttributedString(attributedString: textStorage)
        contentHeightConstraint.constant = calculateDiffTextHeight(for: attrStr, width: width - 16)
    }
}

// MARK: - ContextGapView

/// Displays a clickable "Show N hidden lines" indicator between diff hunks.
/// When expanded, shows the hidden context lines from the working tree file.
private final class ContextGapView: NSView {

    let gapStartLine: Int // 1-based inclusive (new-file line number)
    let gapEndLine: Int   // 1-based inclusive

    private let expandButton = NSButton()
    private var contentTextView: NSTextView?
    private var heightConstraint: NSLayoutConstraint!
    private(set) var isExpanded = false

    var onRequestExpand: (() -> Void)?

    init(gapStartLine: Int, gapEndLine: Int) {
        self.gapStartLine = gapStartLine
        self.gapEndLine = gapEndLine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        let lineCount = gapEndLine - gapStartLine + 1

        expandButton.title = " Show \(lineCount) hidden line\(lineCount == 1 ? "" : "s")"
        expandButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        expandButton.imagePosition = .imageLeading
        expandButton.bezelStyle = .inline
        expandButton.isBordered = false
        expandButton.contentTintColor = diffHunkColor.withAlphaComponent(0.7)
        expandButton.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        expandButton.target = self
        expandButton.action = #selector(expandClicked)
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expandButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 22)

        NSLayoutConstraint.activate([
            heightConstraint,
            expandButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func expandClicked() {
        onRequestExpand?()
    }

    func showExpandedContent(_ lines: [String]) {
        guard !isExpanded else { return }
        isExpanded = true
        expandButton.isHidden = true

        let textView = DiffTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 0)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        // Render lines as context (space-prefixed, dimmed)
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: diffDefaultFont,
            .foregroundColor: diffContextColor,
        ]
        for line in lines {
            result.append(NSAttributedString(string: " " + line + "\n", attributes: attrs))
        }
        textView.textStorage?.setAttributedString(result)

        let height = calculateDiffTextHeight(for: result, width: max(bounds.width - 16, 300))
        heightConstraint.constant = height

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        contentTextView = textView
    }

    func updateContentWidth(_ width: CGFloat) {
        guard isExpanded, let textView = contentTextView, let textStorage = textView.textStorage else { return }
        let attrStr = NSAttributedString(attributedString: textStorage)
        heightConstraint.constant = calculateDiffTextHeight(for: attrStr, width: width - 16)
    }
}

// MARK: - DiffSectionView

private final class DiffSectionView: NSView {

    let filePath: String
    let additions: Int
    let deletions: Int
    let isImageMode: Bool
    let renamedFrom: String?
    private(set) var worktreePath: String?

    /// Display path: shows "old → new" for renames, otherwise just the path.
    var displayPath: String {
        if let oldPath = renamedFrom {
            return "\(oldPath) → \(filePath)"
        }
        return filePath
    }

    private let headerView = NSView()
    private let chevronImage = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statsStack = NSStackView()

    // Text mode
    private let hunksStackView = NSStackView()
    private var hunkViews: [HunkView] = []
    private var gapViews: [ContextGapView] = []
    private var preambleTextView: NSTextView?
    private var preambleHeightConstraint: NSLayoutConstraint?

    // Image mode
    private var imageContentView: ImageDiffContentView?
    var onImageClick: ((NSImageView, NSImage) -> Void)? {
        didSet {
            imageContentView?.onImageClick = onImageClick
        }
    }

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

    /// Text diff init — takes raw chunk string and splits into hunks with context gap indicators.
    init(filePath: String, rawChunk: String, additions: Int, deletions: Int, worktreePath: String?) {
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.isImageMode = false
        self.worktreePath = worktreePath
        self.renamedFrom = extractRenameFrom(rawChunk)
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
        self.worktreePath = nil
        self.renamedFrom = nil
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

        // File path (shows rename if applicable)
        pathLabel.stringValue = displayPath
        pathLabel.toolTip = displayPath
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

        // Filter out --- and +++ file header lines from preamble (shown in section header instead)
        preambleLines = preambleLines.filter { !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") }

        // Add preamble if non-empty (metadata like "new file", "deleted file", etc.)
        if !preambleLines.isEmpty && !preambleLines.allSatisfy({ $0.isEmpty }) {
            let preambleAttr = parseDiffLines(preambleLines)
            if preambleAttr.length > 0 {
                let textView = DiffTextView()
                textView.isEditable = false
                textView.isSelectable = true
                textView.isRichText = true
                textView.drawsBackground = false
                textView.textContainerInset = NSSize(width: 8, height: 0)
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
        }

        // Parse hunk headers for line numbers (used for context gap calculation)
        let parsedHeaders = hunks.map { parseHunkHeader($0.header) }

        // Add hunks with context gap indicators between them
        for (index, hunk) in hunks.enumerated() {
            // Insert context gap before this hunk (between previous hunk's end and this hunk's start)
            if let parsed = parsedHeaders[index] {
                let gapStart: Int
                if index == 0 {
                    // Gap before first hunk: lines 1 to (newStart - 1)
                    gapStart = 1
                } else if let prevParsed = parsedHeaders[index - 1] {
                    // Gap between previous hunk end and this hunk start
                    gapStart = prevParsed.newStart + prevParsed.newCount
                } else {
                    gapStart = parsed.newStart
                }
                let gapEnd = parsed.newStart - 1

                if gapEnd >= gapStart {
                    let gapView = ContextGapView(gapStartLine: gapStart, gapEndLine: gapEnd)
                    gapView.onRequestExpand = { [weak self, weak gapView] in
                        guard let self, let gapView else { return }
                        self.loadContextForGap(gapView)
                    }
                    gapViews.append(gapView)
                    hunksStackView.addArrangedSubview(gapView)
                    gapView.leadingAnchor.constraint(equalTo: hunksStackView.leadingAnchor).isActive = true
                    gapView.trailingAnchor.constraint(equalTo: hunksStackView.trailingAnchor).isActive = true
                }
            }

            // Render only actual diff lines (skip the @@ metadata header line).
            let hunkContent = parseDiffLines(hunk.lines)
            let hunkView = HunkView(content: hunkContent)
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

    /// Loads context lines from the working tree file and expands the given gap view.
    private func loadContextForGap(_ gapView: ContextGapView) {
        guard let worktreePath else { return }
        let fullPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(filePath).path
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { return }
        let allLines = content.components(separatedBy: "\n")
        let startIdx = max(gapView.gapStartLine - 1, 0) // 0-based
        let endIdx = min(gapView.gapEndLine, allLines.count) // exclusive
        guard startIdx < endIdx else { return }
        let contextLines = Array(allLines[startIdx..<endIdx])
        gapView.showExpandedContent(contextLines)
    }

    private func setupImageContent(mode: ImageDiffMode) {
        let imageView = ImageDiffContentView(mode: mode)
        imageView.onImageClick = onImageClick
        addSubview(imageView)

        // ImageDiffContentView manages its own height via its internal heightConstraint.
        // Do NOT add an external height constraint here — that would conflict.
        expandedBottomConstraint = imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        collapsedBottomConstraint.isActive = false

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandedBottomConstraint,
        ])

        imageContentView = imageView
    }

    func setImages(before: NSImage?, after: NSImage?) {
        imageContentView?.setImages(before: before, after: after)
    }

    func updateContentWidth(_ width: CGFloat) {
        if isImageMode {
            imageContentView?.updateContentWidth(width)
            return
        }
        // Update gap views
        for gapView in gapViews {
            gapView.updateContentWidth(width)
        }
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
    private let stickyPinnedTopConstant: CGFloat = 24
    private var stickyTopConstraint: NSLayoutConstraint!
    private weak var currentStickySection: DiffSectionView?
    private var lastMeasuredContentWidth: CGFloat = 0

    private var sectionViews: [DiffSectionView] = []
    private var allExpanded = true

    private var worktreePath: String?
    private var mergeBase: String?

    var onClose: (() -> Void)?
    var onImageClick: ((_ imageView: NSImageView, _ image: NSImage) -> Void)?
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

    override func viewDidLayout() {
        super.viewDidLayout()

        // Recalculate text heights at the actual scroll viewport width to avoid oversized blank gaps.
        let contentWidth = scrollView.contentSize.width
        if contentWidth > 0, abs(contentWidth - lastMeasuredContentWidth) > 0.5 {
            lastMeasuredContentWidth = contentWidth
            for section in sectionViews {
                section.updateContentWidth(contentWidth)
            }
        }
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

            scrollView.topAnchor.constraint(equalTo: stickyHeader.bottomAnchor),
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
        // Opaque background so content doesn't bleed through
        stickyHeader.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        stickyHeader.layer?.zPosition = 10
        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.isHidden = true

        // Bottom separator line
        let stickyBottomLine = NSView()
        stickyBottomLine.wantsLayer = true
        stickyBottomLine.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.25).cgColor
        stickyBottomLine.translatesAutoresizingMaskIntoConstraints = false
        stickyHeader.addSubview(stickyBottomLine)

        // Click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(stickyHeaderClicked))
        stickyHeader.addGestureRecognizer(click)

        // Keep reserved leading spacing for alignment with section rows, but render no icon.
        stickyChevron.image = nil
        stickyChevron.isHidden = false
        stickyChevron.translatesAutoresizingMaskIntoConstraints = false
        stickyChevron.setContentHuggingPriority(.required, for: .horizontal)
        stickyHeader.addSubview(stickyChevron)

        // File path
        stickyPathLabel.font = .systemFont(ofSize: 11, weight: .bold)
        stickyPathLabel.textColor = diffHunkColor
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
        // Keep sticky header fixed directly under the DIFF header bar.
        stickyTopConstraint = stickyHeader.topAnchor.constraint(equalTo: resizeHandle.bottomAnchor, constant: stickyPinnedTopConstant)

        NSLog("[DiffVC] setupStickyHeader: activating constraints")
        NSLayoutConstraint.activate([
            stickyTopConstraint,
            stickyHeader.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stickyHeader.heightAnchor.constraint(equalToConstant: 24),

            stickyBottomLine.bottomAnchor.constraint(equalTo: stickyHeader.bottomAnchor),
            stickyBottomLine.leadingAnchor.constraint(equalTo: stickyHeader.leadingAnchor),
            stickyBottomLine.trailingAnchor.constraint(equalTo: stickyHeader.trailingAnchor),
            stickyBottomLine.heightAnchor.constraint(equalToConstant: 1),

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
        guard !sectionViews.isEmpty else {
            showStickyPlaceholder("No files changed")
            stickyTopConstraint.constant = stickyPinnedTopConstant
            return
        }

        // Keep layout up-to-date so section frames/hit-tests are accurate after expand/collapse.
        sectionsStackView.layoutSubtreeIfNeeded()

        // Probe the top visible content line inside the scroll viewport.
        // Use section-local coordinate conversion to avoid document/flip coordinate mismatches.
        let clipBounds = scrollView.contentView.bounds
        let probeInClip = NSPoint(x: max(clipBounds.minX + 12, 12), y: clipBounds.minY + 1)

        var candidateSection: DiffSectionView?

        for section in sectionViews {
            let probeInSection = section.convert(probeInClip, from: scrollView.contentView)
            if section.bounds.contains(probeInSection) {
                candidateSection = section
                break
            }
        }

        // Fallback: keep header stable even on boundary pixels.
        if candidateSection == nil {
            candidateSection = currentStickySection ?? sectionViews.first
        }

        guard let section = candidateSection else { return }

        // Always keep sticky header pinned right under DIFF header.
        stickyHeader.isHidden = false
        stickyTopConstraint.constant = stickyPinnedTopConstant
        applyStickyHeader(section)
    }

    private func applyStickyHeader(_ section: DiffSectionView) {
        currentStickySection = section
        stickyPathLabel.stringValue = section.displayPath
        stickyPathLabel.toolTip = section.displayPath
        populateStatsStack(stickyStatsStack, additions: section.additions, deletions: section.deletions, isImage: section.isImageMode)
    }

    private func showStickyPlaceholder(_ text: String) {
        currentStickySection = nil
        stickyHeader.isHidden = false
        stickyPathLabel.stringValue = text
        stickyPathLabel.toolTip = text
        populateStatsStack(stickyStatsStack, additions: 0, deletions: 0, isImage: false)
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
        // Positive y = drag up = diff gets taller (AppKit origin is bottom-left)
        onResizeDrag?(gesture.state, translation.y)
        if gesture.state == .changed {
            gesture.setTranslation(.zero, in: view)
        }
    }

    // MARK: - Content

    func setDiffContent(_ rawDiff: String, fileCount: Int, worktreePath: String?, mergeBase: String?) {
        self.worktreePath = worktreePath
        self.mergeBase = mergeBase
        lastMeasuredContentWidth = 0

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
                section.onImageClick = { [weak self] imageView, image in
                    self?.onImageClick?(imageView, image)
                }
                loadImages(for: section, path: path, chunk: chunkContent, state: state)
            } else {
                let (additions, deletions) = countStats(in: chunkContent)
                section = DiffSectionView(
                    filePath: path,
                    rawChunk: chunkContent,
                    additions: additions,
                    deletions: deletions,
                    worktreePath: worktreePath
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

        // Initialize sticky header immediately so it remains visible/pinned even before first scroll event.
        if let firstSection = sectionViews.first {
            stickyHeader.isHidden = false
            stickyTopConstraint.constant = stickyPinnedTopConstant
            applyStickyHeader(firstSection)
        } else {
            showStickyPlaceholder("No files changed")
        }

        // Ensure sticky header and measured text heights are correct after content replacement.
        view.needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.handleScrollChange()
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
        let requestedPath = normalizedSelectionPath(relativePath)
        var matchedSection: DiffSectionView?

        for section in sectionViews {
            if section.filePath == requestedPath {
                section.isExpanded = true
                matchedSection = section
            } else if collapseOthers {
                section.isExpanded = false
            }
        }
        syncExpandCollapseState()
        // Force layout before scrolling: section frames may be stale (fresh creation)
        // or pending (constraint change from isExpanded toggle). Without this,
        // section.convert(bounds, to: sectionsStackView) returns wrong/zero rects.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let section = matchedSection {
                self.view.layoutSubtreeIfNeeded()
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
        let requestedPath = normalizedSelectionPath(relativePath)
        guard let section = sectionViews.first(where: { $0.filePath == requestedPath }) else { return }
        scrollSectionIntoViewIfNeeded(section)
    }

    private func normalizedSelectionPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Accept rename paths from git numstat (for example: "src/{old => new}.swift")
        // and map them to the "new/current" path used by diff chunk headers.
        if let openBrace = trimmed.firstIndex(of: "{"),
           let closeBrace = trimmed.lastIndex(of: "}"),
           openBrace < closeBrace {
            let insideStart = trimmed.index(after: openBrace)
            let inside = String(trimmed[insideStart..<closeBrace])
            if let arrow = inside.range(of: " => ") {
                let prefix = String(trimmed[..<openBrace])
                let suffixStart = trimmed.index(after: closeBrace)
                let suffix = String(trimmed[suffixStart...])
                let newSegment = String(inside[arrow.upperBound...])
                return prefix + newSegment + suffix
            }
        }

        if let range = trimmed.range(of: " => ") {
            return String(trimmed[range.upperBound...])
        }
        return trimmed
    }

    private func scrollSectionIntoViewIfNeeded(_ section: DiffSectionView) {
        let sectionFrame = section.convert(section.bounds, to: sectionsStackView)
        sectionsStackView.scrollToVisible(sectionFrame)
    }

    // MARK: - Diff Splitting

    private func splitDiffIntoFileChunks(_ rawDiff: String) -> [(path: String, content: String)] {
        var chunks: [(path: String, content: String)] = []
        let lines = rawDiff.components(separatedBy: "\n")

        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git") {
                // Save previous chunk if any
                if !currentLines.isEmpty {
                    let content = currentLines.joined(separator: "\n")
                    if let path = pathForDiffChunk(content) {
                        chunks.append((path: path, content: content))
                    }
                }
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        // Save last chunk
        if !currentLines.isEmpty {
            let content = currentLines.joined(separator: "\n")
            if let path = pathForDiffChunk(content) {
                chunks.append((path: path, content: content))
            }
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
