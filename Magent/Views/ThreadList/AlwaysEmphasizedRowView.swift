import Cocoa

final class AlwaysEmphasizedRowView: NSTableRowView {
    var showsCompletionHighlight = false {
        didSet { needsDisplay = true }
    }
    var showsSubtleBottomSeparator = false {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if showsCompletionHighlight, !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }

        if showsSubtleBottomSeparator {
            let separatorY = isFlipped ? (bounds.maxY - 1) : bounds.minY
            let separatorRect = NSRect(
                x: bounds.minX + 8,
                y: separatorY,
                width: max(0, bounds.width - 16),
                height: 1
            )
            NSColor.separatorColor.withAlphaComponent(0.24).setFill()
            NSBezierPath(rect: separatorRect).fill()
        }
    }
}

final class ProjectHeaderRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class SidebarSpacerRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
    }
}

final class SidebarSpacerCellView: NSTableCellView {
    private let dividerView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.wantsLayer = true
        addSubview(dividerView)

        NSLayoutConstraint.activate([
            dividerView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ThreadListViewController.projectSpacerDividerLeadingInset
            ),
            dividerView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ThreadListViewController.projectSpacerDividerTrailingInset
            ),
            dividerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: ThreadListViewController.projectSpacerDividerHeight),
        ])
        updateDividerColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDividerColor()
    }

    private func updateDividerColor() {
        dividerView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
    }
}
