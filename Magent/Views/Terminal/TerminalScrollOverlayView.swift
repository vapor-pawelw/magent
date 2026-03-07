import Cocoa

/// A compact, draggable, semi-transparent floating overlay that exposes three
/// scroll controls (page-up, page-down, jump-to-bottom) for the terminal panel.
/// It sits in the bottom-right corner by default and becomes fully opaque on hover.
final class TerminalScrollOverlayView: NSView {

    var onScrollUp: (() -> Void)?
    var onScrollDown: (() -> Void)?
    var onScrollToBottom: (() -> Void)?

    var isScrollEnabled: Bool = false {
        didSet {
            upButton.isEnabled = isScrollEnabled
            downButton.isEnabled = isScrollEnabled
            toBottomButton.isEnabled = isScrollEnabled
        }
    }

    private let upButton = NSButton()
    private let downButton = NSButton()
    private let toBottomButton = NSButton()
    private var trackingArea: NSTrackingArea?

    private static let normalAlpha: CGFloat = 0.55
    private static let hoverAlpha: CGFloat = 0.90

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        alphaValue = Self.normalAlpha

        let btnSize: CGFloat = 24
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        for (btn, symbol, tip, action) in [
            (upButton,       "chevron.up",        "Scroll up one page",  #selector(upTapped)),
            (downButton,     "chevron.down",      "Scroll down one page", #selector(downTapped)),
            (toBottomButton, "arrow.down.to.line","Jump to bottom",      #selector(toBottomTapped)),
        ] as [(NSButton, String, String, Selector)] {
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(symbolConfig)
            btn.imagePosition = .imageOnly
            btn.isBordered = false
            btn.bezelStyle = .inline
            btn.contentTintColor = NSColor(white: 1, alpha: 0.85)
            btn.toolTip = tip
            btn.target = self
            btn.action = action
            btn.isEnabled = false
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: btnSize).isActive = true
            btn.heightAnchor.constraint(equalToConstant: btnSize).isActive = true
        }

        let stack = NSStackView(views: [upButton, downButton, toBottomButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = Self.hoverAlpha
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.animator().alphaValue = Self.normalAlpha
        }
    }

    // MARK: - Actions

    @objc private func upTapped()       { onScrollUp?() }
    @objc private func downTapped()     { onScrollDown?() }
    @objc private func toBottomTapped() { onScrollToBottom?() }
}
