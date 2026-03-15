import Cocoa
import MagentCore

/// Popover that shows the list of files changed in a specific commit or in the working tree.
final class CommitFilesPopoverViewController: NSViewController {

    private let titleText: String
    private let worktreePath: String
    private let commitHash: String?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let loadingLabel = NSTextField(labelWithString: "Loading…")

    init(title: String, worktreePath: String, commitHash: String?) {
        self.titleText = title
        self.worktreePath = worktreePath
        self.commitHash = commitHash
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Stack view for file rows
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Loading state
        loadingLabel.font = .systemFont(ofSize: 11)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(loadingLabel)

        // Scroll view
        let flippedClip = FlippedClipViewForPopover()
        flippedClip.drawsBackground = false
        scrollView.contentView = flippedClip
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),

            container.widthAnchor.constraint(equalToConstant: 280),
            container.heightAnchor.constraint(equalToConstant: 220),
        ])

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadEntries()
    }

    private func loadEntries() {
        let hash = commitHash
        let path = worktreePath
        Task {
            let entries: [FileDiffEntry]
            if let hash {
                entries = await GitService.shared.commitDiffStats(worktreePath: path, commitHash: hash)
            } else {
                entries = await GitService.shared.workingTreeDiffStats(worktreePath: path)
            }
            await MainActor.run {
                self.showEntries(entries)
            }
        }
    }

    private func showEntries(_ entries: [FileDiffEntry]) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if entries.isEmpty {
            let label = NSTextField(labelWithString: commitHash == nil ? "No uncommitted changes" : "No files changed")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 12).isActive = true
            label.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -12).isActive = true
            return
        }

        for entry in entries {
            let row = makeRow(for: entry)
            stackView.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
        }
    }

    private func makeRow(for entry: FileDiffEntry) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = colorForStatus(entry.workingStatus).cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let name = NSTextField(labelWithString: entry.relativePath)
        name.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 1
        name.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(dot)
        container.addSubview(name)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            name.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            container.heightAnchor.constraint(equalToConstant: 18),
        ])

        return container
    }

    private func colorForStatus(_ status: FileWorkingStatus) -> NSColor {
        switch status {
        case .staged:    return NSColor(red: 0.35, green: 0.65, blue: 0.35, alpha: 1.0)
        case .unstaged:  return NSColor(red: 0.78, green: 0.3, blue: 0.3, alpha: 1.0)
        case .untracked: return NSColor(red: 0.76, green: 0.65, blue: 0.42, alpha: 1.0)
        case .committed: return .secondaryLabelColor
        }
    }
}

private final class FlippedClipViewForPopover: NSClipView {
    override var isFlipped: Bool { true }
}
