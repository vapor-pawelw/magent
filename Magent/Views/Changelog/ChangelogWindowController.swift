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

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let sectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let subSectionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bulletAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]

        func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }

        var previousLineWasEmpty = true
        for rawLine in markdown.components(separatedBy: .newlines) {
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
            } else if trimmed.hasPrefix("#### ") {
                append("\(String(trimmed.dropFirst(5)))\n", attributes: subSectionAttributes)
            } else if trimmed.hasPrefix("##### ") {
                append("\(String(trimmed.dropFirst(6)))\n", attributes: subSectionAttributes)
            } else if trimmed.hasPrefix("- ") {
                append("• \(String(trimmed.dropFirst(2)))\n", attributes: bulletAttributes)
            } else {
                append("\(trimmed)\n", attributes: bodyAttributes)
            }

            previousLineWasEmpty = false
        }

        return result
    }

    private static func loadBundleFile(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
