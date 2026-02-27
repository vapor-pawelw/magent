import Cocoa

final class DiffPanelView: NSView {

    private let separatorView = NSView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private var entries: [FileDiffEntry] = []

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

        // Separator
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor(resource: .textSecondary).withAlphaComponent(0.4).cgColor
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)

        // Header
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textSecondary)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        // Stack view for file entries
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            separatorView.topAnchor.constraint(equalTo: topAnchor),
            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            separatorView.heightAnchor.constraint(equalToConstant: 1),

            headerLabel.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        clear()
    }

    func update(with newEntries: [FileDiffEntry]) {
        entries = newEntries

        // Remove old rows
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if entries.isEmpty {
            headerLabel.stringValue = "CHANGES"
            isHidden = true
            return
        }

        isHidden = false
        headerLabel.stringValue = "CHANGES (\(entries.count))"

        for entry in entries {
            let row = makeEntryRow(entry)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    func clear() {
        entries = []
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        headerLabel.stringValue = "CHANGES"
        isHidden = true
    }

    private func makeEntryRow(_ entry: FileDiffEntry) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

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
