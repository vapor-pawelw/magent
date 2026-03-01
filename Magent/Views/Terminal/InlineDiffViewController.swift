import Cocoa

// MARK: - Resize Handle

fileprivate final class DiffDividerResizeHandle: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}

// MARK: - InlineDiffViewController

final class InlineDiffViewController: NSViewController {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let closeButton = NSButton()
    private let headerLabel = NSTextField(labelWithString: "")
    private let resizeHandle = DiffDividerResizeHandle()

    /// File paths in the order they appear in the diff, used for scroll-to-file.
    private var fileRanges: [(path: String, range: NSRange)] = []

    var onClose: (() -> Void)?
    /// Called during drag with the delta (positive = drag up = diff taller).
    var onResizeDrag: ((_ phase: NSPanGestureRecognizer.State, _ deltaY: CGFloat) -> Void)?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
        setupUI()
    }

    private func setupUI() {
        // Resize handle at the top (6px drag area)
        resizeHandle.wantsLayer = true
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resizeHandle)

        // Separator line inside the handle
        let separatorLine = NSView()
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.4).cgColor
        separatorLine.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.addSubview(separatorLine)

        // Header bar
        let headerBar = NSView()
        headerBar.wantsLayer = true
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerBar)

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textSecondary)
        headerLabel.stringValue = "DIFF"
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerLabel)

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Diff")
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(closeButton)

        // Scroll view + text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(resource: .appBackground)
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Drag-to-resize gesture on handle
        let panGesture = NSPanGestureRecognizer(target: self, action: #selector(handleResizeDrag(_:)))
        resizeHandle.addGestureRecognizer(panGesture)

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

            scrollView.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        onClose?()
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

    func setDiffContent(_ rawDiff: String, fileCount: Int) {
        headerLabel.stringValue = "DIFF (\(fileCount) files)"
        let attributed = parseDiff(rawDiff)
        textView.textStorage?.setAttributedString(attributed)
        fileRanges = buildFileRanges(from: rawDiff, in: attributed)
    }

    func scrollToFile(_ relativePath: String) {
        guard let entry = fileRanges.first(where: { $0.path == relativePath }) else { return }
        textView.scrollRangeToVisible(entry.range)
        // Highlight briefly
        textView.setSelectedRange(NSRange(location: entry.range.location, length: 0))
        textView.scrollRangeToVisible(entry.range)
    }

    // MARK: - Diff Parsing

    private func parseDiff(_ raw: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = raw.components(separatedBy: "\n")

        let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        let addColor = NSColor(red: 0.35, green: 0.75, blue: 0.35, alpha: 1.0)
        let delColor = NSColor(red: 0.9, green: 0.35, blue: 0.35, alpha: 1.0)
        let hunkColor = NSColor(red: 0.45, green: 0.65, blue: 0.85, alpha: 1.0)
        let headerColor = NSColor(red: 0.8, green: 0.8, blue: 0.6, alpha: 1.0)
        let contextColor = NSColor(resource: .textSecondary)

        for line in lines {
            let attrs: [NSAttributedString.Key: Any]

            if line.hasPrefix("diff --git") {
                // File header — bold, distinct color, with a blank line before for separation
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: defaultFont]))
                }
                attrs = [.font: headerFont, .foregroundColor: headerColor]
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                attrs = [.font: headerFont, .foregroundColor: headerColor]
            } else if line.hasPrefix("@@") {
                attrs = [.font: defaultFont, .foregroundColor: hunkColor]
            } else if line.hasPrefix("+") {
                attrs = [
                    .font: defaultFont,
                    .foregroundColor: addColor,
                    .backgroundColor: addColor.withAlphaComponent(0.08),
                ]
            } else if line.hasPrefix("-") {
                attrs = [
                    .font: defaultFont,
                    .foregroundColor: delColor,
                    .backgroundColor: delColor.withAlphaComponent(0.08),
                ]
            } else if line.hasPrefix("new file") || line.hasPrefix("deleted file") ||
                        line.hasPrefix("index ") || line.hasPrefix("Binary") ||
                        line.hasPrefix("rename") || line.hasPrefix("similarity") {
                attrs = [.font: defaultFont, .foregroundColor: contextColor.withAlphaComponent(0.6)]
            } else {
                attrs = [.font: defaultFont, .foregroundColor: contextColor]
            }

            result.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }

        return result
    }

    private func buildFileRanges(from raw: String, in attributed: NSAttributedString) -> [(path: String, range: NSRange)] {
        var ranges: [(path: String, range: NSRange)] = []
        let attrString = attributed.string
        let lines = raw.components(separatedBy: "\n")

        // We need to find "diff --git a/... b/..." lines and their character offsets in the attributed string
        var searchStart = attrString.startIndex
        for line in lines {
            guard line.hasPrefix("diff --git") else { continue }

            // Extract file path from "diff --git a/path b/path"
            let parts = line.components(separatedBy: " b/")
            guard parts.count >= 2 else { continue }
            let path = parts.last ?? ""

            // Find this line in the attributed string
            if let range = attrString.range(of: line, range: searchStart..<attrString.endIndex) {
                let nsRange = NSRange(range, in: attrString)
                ranges.append((path: path, range: nsRange))
                searchStart = range.upperBound
            }
        }

        return ranges
    }
}
