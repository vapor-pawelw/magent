import Cocoa

final class ChangelogWindowController: NSWindowController {

    private enum ContentMode: Equatable {
        case full
        case currentVersion(version: String)
    }

    private struct ContentModel {
        let title: String
        let subtitle: String?
        let bodyMarkdown: String
    }

    private struct VersionSection {
        let heading: String
        let bodyMarkdown: String
    }

    private static var shared: ChangelogWindowController?
    private let contentMode: ContentMode

    static func showChangelog() {
        _ = show(contentMode: .full, requireContent: false)
    }

    @discardableResult
    static func showCurrentVersionChangelog(version: String) -> Bool {
        show(contentMode: .currentVersion(version: version), requireContent: true)
    }

    @discardableResult
    private static func show(contentMode: ContentMode, requireContent: Bool) -> Bool {
        if let existing = shared {
            if existing.contentMode == contentMode {
                existing.window?.makeKeyAndOrderFront(nil)
                return true
            }
            existing.close()
        }

        guard let model = contentModel(for: contentMode) else {
            return !requireContent
        }

        let controller = ChangelogWindowController(contentMode: contentMode, model: model)
        shared = controller
        controller.showWindow(nil)
        return true
    }

    private init(contentMode: ContentMode, model: ContentModel) {
        self.contentMode = contentMode

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 420)

        super.init(window: window)

        let titleLabel = NSTextField(labelWithString: model.title)
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: model.subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = model.subtitle?.isEmpty ?? true

        let divider = NSBox()
        divider.boxType = .separator

        let contentView = NSView()
        window.contentView = contentView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        if let textStorage = textView.textStorage {
            textStorage.setAttributedString(Self.attributedReleaseNotes(from: model.bodyMarkdown))
        } else {
            textView.string = model.bodyMarkdown
        }

        scrollView.documentView = textView
        let stackView = NSStackView(views: [titleLabel, subtitleLabel, divider, scrollView])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            scrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func close() {
        super.close()
        Self.shared = nil
    }

    private static func contentModel(for contentMode: ContentMode) -> ContentModel? {
        guard let changelog = loadBundleFile("CHANGELOG.md") else {
            guard case .full = contentMode else { return nil }
            return ContentModel(
                title: "Changelog",
                subtitle: nil,
                bodyMarkdown: "Changelog not available."
            )
        }

        switch contentMode {
        case .full:
            return ContentModel(
                title: "Changelog",
                subtitle: "Bundled release history",
                bodyMarkdown: changelog
            )
        case .currentVersion(let version):
            guard let section = extractVersionSection(from: changelog, targetVersion: version) else {
                return nil
            }
            let subtitle: String
            if let releaseDate = releaseDate(fromHeading: section.heading) {
                subtitle = "What's new in mAgent \(version) • Released \(releaseDate)"
            } else {
                subtitle = "What's new in mAgent \(version)"
            }
            return ContentModel(
                title: "What's New",
                subtitle: subtitle,
                bodyMarkdown: section.bodyMarkdown
            )
        }
    }

    private static func extractVersionSection(from changelog: String, targetVersion: String) -> VersionSection? {
        let lines = changelog.components(separatedBy: .newlines)
        guard let normalizedTarget = normalizedVersion(targetVersion) else { return nil }

        var sectionStartIndex: Int?
        var sectionHeading: String?

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("## ") else { continue }

            let heading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard let headingVersion = versionFromHeading(heading),
                  let normalizedHeadingVersion = normalizedVersion(headingVersion) else {
                continue
            }

            if normalizedHeadingVersion == normalizedTarget {
                sectionStartIndex = index
                sectionHeading = heading
                break
            }
        }

        guard let start = sectionStartIndex, let heading = sectionHeading else {
            return nil
        }

        var end = lines.count
        var index = start + 1
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                end = index
                break
            }
            index += 1
        }

        let body = lines[(start + 1)..<end]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !body.isEmpty else { return nil }
        return VersionSection(heading: heading, bodyMarkdown: body)
    }

    private static func versionFromHeading(_ heading: String) -> String? {
        let token = heading.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).first.map(String.init)
        guard var token else { return nil }
        if token.hasPrefix("v") || token.hasPrefix("V") {
            token.removeFirst()
        }
        return token
    }

    private static func releaseDate(fromHeading heading: String) -> String? {
        let parts = heading.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let datePart = parts[1].trimmingCharacters(in: .whitespaces)
        return datePart.isEmpty ? nil : datePart
    }

    private static func normalizedVersion(_ raw: String) -> String? {
        let parts = raw
            .split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        guard let major = Int(parts[0]) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else { return nil }
        return "\(major).\(minor).\(patch)"
    }

    private static func attributedReleaseNotes(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let brandColor = NSColor(resource: .primaryBrand)
        let separatorColor = brandColor.withAlphaComponent(0.45)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let sectionParagraph = NSMutableParagraphStyle()
        sectionParagraph.paragraphSpacingBefore = 14
        sectionParagraph.paragraphSpacing = 2
        let sectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: sectionParagraph,
        ]
        let subSectionParagraph = NSMutableParagraphStyle()
        subSectionParagraph.paragraphSpacingBefore = 6
        subSectionParagraph.paragraphSpacing = 2
        let subSectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: brandColor,
            .kern: 0.6,
            .paragraphStyle: subSectionParagraph,
        ]
        let bulletParagraph = NSMutableParagraphStyle()
        bulletParagraph.headIndent = 14
        bulletParagraph.firstLineHeadIndent = 0
        bulletParagraph.paragraphSpacing = 2
        let bulletAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bulletParagraph,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        func appendSectionSeparator() {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = HorizontalRuleAttachmentCell(color: separatorColor, height: 1)
            let separatorParagraph = NSMutableParagraphStyle()
            separatorParagraph.paragraphSpacingBefore = 0
            separatorParagraph.paragraphSpacing = 6
            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttributes([.paragraphStyle: separatorParagraph], range: NSRange(location: 0, length: attachmentString.length))
            result.append(attachmentString)
            append("\n", attributes: [.paragraphStyle: separatorParagraph])
        }

        let normalized = mergeDuplicateDomains(in: markdown)

        var previousLineWasEmpty = true
        for rawLine in normalized.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !previousLineWasEmpty {
                    append("\n", attributes: bodyAttributes)
                }
                previousLineWasEmpty = true
                continue
            }

            if trimmed.hasPrefix("## ") {
                if !previousLineWasEmpty { append("\n", attributes: bodyAttributes) }
                append("\(String(trimmed.dropFirst(3)))\n", attributes: titleAttributes)
            } else if trimmed.hasPrefix("### ") {
                if !previousLineWasEmpty { append("\n", attributes: bodyAttributes) }
                append("\(String(trimmed.dropFirst(4)))\n", attributes: sectionAttributes)
                appendSectionSeparator()
            } else if trimmed.hasPrefix("#### ") {
                append("\(String(trimmed.dropFirst(5)).uppercased())\n", attributes: subSectionAttributes)
            } else if trimmed.hasPrefix("##### ") {
                append("\(String(trimmed.dropFirst(6)).uppercased())\n", attributes: subSectionAttributes)
            } else if trimmed.hasPrefix("- ") {
                append("•  \(String(trimmed.dropFirst(2)))\n", attributes: bulletAttributes)
            } else {
                append("\(trimmed)\n", attributes: bodyAttributes)
            }

            previousLineWasEmpty = false
        }

        return result
    }

    /// Collapses duplicate `### Domain` headings within the same release into a single
    /// section, ordering subsections as Features → Bug Fixes → Performance → others.
    /// This keeps rendering tidy even when a hand-edited CHANGELOG accidentally splits
    /// the same domain across multiple groups.
    private static func mergeDuplicateDomains(in markdown: String) -> String {
        struct Domain {
            var name: String
            var subsectionOrder: [String] = []
            var subsections: [String: [String]] = [:]
            var preamble: [String] = []
        }

        let lines = markdown.components(separatedBy: .newlines)
        var leading: [String] = []
        var domainOrder: [String] = []
        var domains: [String: Domain] = [:]
        var currentDomain: String?
        var currentSubsection: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("### ") {
                let name = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                currentDomain = name
                currentSubsection = nil
                if domains[name] == nil {
                    domains[name] = Domain(name: name)
                    domainOrder.append(name)
                }
                continue
            }

            if trimmed.hasPrefix("#### "), let domain = currentDomain {
                let name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                currentSubsection = name
                if domains[domain]?.subsections[name] == nil {
                    domains[domain]?.subsections[name] = []
                    domains[domain]?.subsectionOrder.append(name)
                }
                continue
            }

            guard let domain = currentDomain else {
                leading.append(line)
                continue
            }

            if trimmed.isEmpty { continue }

            if let subsection = currentSubsection {
                domains[domain]?.subsections[subsection]?.append(line)
            } else {
                domains[domain]?.preamble.append(line)
            }
        }

        // No `### Domain` headings at all — return original markdown untouched.
        if domainOrder.isEmpty { return markdown }

        let preferredSubsectionOrder = ["Features", "Bug Fixes", "Performance"]
        var output: [String] = leading

        if !leading.isEmpty, !(leading.last?.isEmpty ?? true) {
            output.append("")
        }

        for domainName in domainOrder {
            guard let domain = domains[domainName] else { continue }
            output.append("### \(domainName)")

            if !domain.preamble.isEmpty {
                output.append("")
                output.append(contentsOf: domain.preamble)
            }

            var ordered: [String] = []
            for preferred in preferredSubsectionOrder where domain.subsections[preferred] != nil {
                ordered.append(preferred)
            }
            for sub in domain.subsectionOrder where !ordered.contains(sub) {
                ordered.append(sub)
            }

            for sub in ordered {
                output.append("")
                output.append("#### \(sub)")
                if let bullets = domain.subsections[sub] {
                    output.append(contentsOf: bullets)
                }
            }
            output.append("")
        }

        return output.joined(separator: "\n")
    }

    private static func loadBundleFile(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Inline NSTextAttachment cell that draws a thin horizontal bar spanning the
/// available line fragment width. Used as a separator under each release-section
/// heading in the "What's New" / Changelog window.
private final class HorizontalRuleAttachmentCell: NSTextAttachmentCell {
    private let ruleColor: NSColor
    private let ruleHeight: CGFloat

    init(color: NSColor, height: CGFloat) {
        self.ruleColor = color
        self.ruleHeight = height
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    nonisolated override func cellSize() -> NSSize {
        // Provide a fallback size; actual width is taken from the line fragment in cellFrame.
        NSSize(width: 10_000, height: ruleHeight + 6)
    }

    nonisolated override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(x: 0, y: 0, width: lineFrag.width, height: ruleHeight + 6)
    }

    nonisolated override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // Text drawing already runs inside the host view's appearance context, so
        // dynamic asset colors resolve correctly without touching `controlView.window`
        // (which would force this method onto the main actor).
        let lineRect = NSRect(
            x: cellFrame.minX,
            y: cellFrame.midY - (ruleHeight / 2),
            width: cellFrame.width,
            height: ruleHeight
        )
        ruleColor.setFill()
        lineRect.fill()
    }
}
