import Cocoa

final class ChangelogWindowController: NSWindowController {

    private static var shared: ChangelogWindowController?

    static func showChangelog() {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = ChangelogWindowController()
        shared = controller
        controller.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changelog"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)

        super.init(window: window)

        let contentView = NSView()
        window.contentView = contentView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let commitHash = Self.loadBundleFile("BUILD_COMMIT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildInfo = Self.buildInfoString(buildNumber: buildNumber, commitHash: commitHash)

        if let buildInfo {
            let headerLabel = NSTextField(labelWithString: buildInfo)
            headerLabel.translatesAutoresizingMaskIntoConstraints = false
            headerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            headerLabel.textColor = .secondaryLabelColor
            contentView.addSubview(headerLabel)

            NSLayoutConstraint.activate([
                headerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
                headerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),

                scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
                scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        if let changelog = Self.loadBundleFile("CHANGELOG.md") {
            textView.string = changelog
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        } else {
            textView.string = "Changelog not available."
            textView.font = .systemFont(ofSize: 13)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func close() {
        super.close()
        Self.shared = nil
    }

    private static func buildInfoString(buildNumber: String?, commitHash: String?) -> String? {
        let hasCommit = commitHash != nil && commitHash != "unknown" && commitHash?.isEmpty == false
        switch (buildNumber, hasCommit) {
        case (let bn?, true):
            return "Build number: \(bn) (\(commitHash!))"
        case (let bn?, false):
            return "Build number: \(bn)"
        default:
            return nil
        }
    }

    private static func loadBundleFile(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
