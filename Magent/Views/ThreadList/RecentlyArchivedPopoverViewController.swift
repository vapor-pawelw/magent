import Cocoa
import MagentCore

final class RecentlyArchivedPopoverViewController: NSViewController {
    private static let recentArchivedThreadLimit = 10
    private static let popoverWidth: CGFloat = 360
    private static let rowHorizontalPadding: CGFloat = 12

    private var scrollView: NSScrollView!
    private var contentStack: NSStackView!
    private var threadRowsById: [UUID: MagentThread] = [:]

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 200))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(archivedThreadsDidChange),
            name: .magentArchivedThreadsDidChange,
            object: nil
        )

        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func archivedThreadsDidChange() {
        refresh()
    }

    func refresh() {
        guard isViewLoaded, contentStack != nil else { return }

        contentStack.arrangedSubviews.forEach { subview in
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let persistence = PersistenceService.shared
        let settings = persistence.loadSettings()
        let projectsById = Dictionary(uniqueKeysWithValues: settings.projects.map { ($0.id, $0.name) })
        let archivedThreads = persistence.loadThreads()
            .filter { $0.isArchived && !$0.isMain }
            .sorted { lhs, rhs in
                let lhsDate = lhs.archivedAt ?? .distantPast
                let rhsDate = rhs.archivedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.createdAt > rhs.createdAt
            }

        threadRowsById = Dictionary(uniqueKeysWithValues: archivedThreads.map { ($0.id, $0) })

        let recentThreads = Array(archivedThreads.prefix(Self.recentArchivedThreadLimit))

        // Header
        let headerLabel = NSTextField(labelWithString: "Recently Archived")
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textPrimary)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerRow.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            headerLabel.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 10),
            headerLabel.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -8),
            headerLabel.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: Self.rowHorizontalPadding),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerRow.trailingAnchor, constant: -Self.rowHorizontalPadding),
        ])
        contentStack.addArrangedSubview(headerRow)

        let headerSep = NSBox()
        headerSep.boxType = .separator
        headerSep.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(headerSep)
        NSLayoutConstraint.activate([
            headerSep.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        guard !recentThreads.isEmpty else {
            let emptyRow = NSView()
            emptyRow.translatesAutoresizingMaskIntoConstraints = false
            let emptyLabel = NSTextField(wrappingLabelWithString: "No recently archived threads.")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = NSColor(resource: .textSecondary)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            emptyRow.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.topAnchor.constraint(equalTo: emptyRow.topAnchor, constant: 10),
                emptyLabel.bottomAnchor.constraint(equalTo: emptyRow.bottomAnchor, constant: -10),
                emptyLabel.leadingAnchor.constraint(equalTo: emptyRow.leadingAnchor, constant: Self.rowHorizontalPadding),
                emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyRow.trailingAnchor, constant: -Self.rowHorizontalPadding),
                emptyRow.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            ])
            contentStack.addArrangedSubview(emptyRow)
            updatePopoverHeight()
            return
        }

        for (index, thread) in recentThreads.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                contentStack.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
                ])
            }
            let row = makeThreadRow(
                thread: thread,
                projectName: projectsById[thread.projectId] ?? "Unknown"
            )
            contentStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            ])
        }

        updatePopoverHeight()
    }

    private func makeThreadRow(thread: MagentThread, projectName: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        )
        iconView.contentTintColor = NSColor(resource: .textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleText: String
        if let description = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            titleText = description
        } else {
            titleText = thread.name
        }
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(resource: .textPrimary)
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLabel)

        var metaSegments = [projectName]
        if let archivedAt = thread.archivedAt {
            metaSegments.append(archivedAt.formatted(date: .abbreviated, time: .omitted))
        }
        let metaLabel = NSTextField(labelWithString: metaSegments.joined(separator: " · "))
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = NSColor(resource: .textSecondary)
        textStack.addArrangedSubview(metaLabel)

        let restoreButton = NSButton(title: "Restore", target: self, action: #selector(restoreButtonTapped(_:)))
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.identifier = NSUserInterfaceItemIdentifier(thread.id.uuidString)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.setContentHuggingPriority(.required, for: .horizontal)
        restoreButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(iconView)
        row.addSubview(textStack)
        row.addSubview(restoreButton)

        let pad = Self.rowHorizontalPadding
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -8),

            restoreButton.leadingAnchor.constraint(equalTo: textStack.trailingAnchor, constant: 8),
            restoreButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -pad),
            restoreButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        return row
    }

    @objc private func restoreButtonTapped(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let threadId = UUID(uuidString: rawValue),
              let thread = threadRowsById[threadId] else { return }

        sender.isEnabled = false
        Task { [weak self] in
            let restored = await ThreadManager.shared.restoreArchivedThreadFromUserAction(
                id: thread.id,
                threadName: thread.name
            )
            await MainActor.run {
                if restored {
                    self?.refresh()
                } else {
                    sender.isEnabled = true
                }
            }
        }
    }

    private func updatePopoverHeight() {
        view.layoutSubtreeIfNeeded()
        let naturalHeight = contentStack.fittingSize.height
        let maxHeight: CGFloat = 480
        let targetHeight = min(max(naturalHeight, 80), maxHeight)
        view.setFrameSize(NSSize(width: Self.popoverWidth, height: targetHeight))
        preferredContentSize = NSSize(width: Self.popoverWidth, height: targetHeight)
    }
}
