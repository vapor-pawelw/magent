import Cocoa
import MagentCore

private enum TerminalOverlayStyle {
    static let normalAlpha: CGFloat = 0.55
    static let hoverAlpha: CGFloat = 0.90
    static let backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
    static let contentTintColor = NSColor(white: 1, alpha: 0.85)
}

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

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = TerminalOverlayStyle.backgroundColor
        alphaValue = TerminalOverlayStyle.normalAlpha

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
            btn.contentTintColor = TerminalOverlayStyle.contentTintColor
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
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = TerminalOverlayStyle.hoverAlpha
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.animator().alphaValue = TerminalOverlayStyle.normalAlpha
        }
    }

    // MARK: - Actions

    @objc private func upTapped()       { onScrollUp?() }
    @objc private func downTapped()     { onScrollDown?() }
    @objc private func toBottomTapped() { onScrollToBottom?() }
}

/// A standalone overlay-styled pill action for jumping the terminal back to live output.
final class TerminalScrollToBottomPillButton: NSView {
    static let restingAlpha = TerminalOverlayStyle.normalAlpha

    var onTap: (() -> Void)?

    private let button = NSButton()
    private var trackingArea: NSTrackingArea?

    private static let contentInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

    override var intrinsicContentSize: NSSize {
        let buttonSize = button.intrinsicContentSize
        return NSSize(
            width: buttonSize.width + Self.contentInsets.left + Self.contentInsets.right,
            height: buttonSize.height + Self.contentInsets.top + Self.contentInsets.bottom
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(isHovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoverState(isHovered: false)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = TerminalOverlayStyle.backgroundColor
        alphaValue = Self.restingAlpha
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Scroll to bottom")?
            .withSymbolConfiguration(symbolConfig)
        button.title = "Scroll to bottom"
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = TerminalOverlayStyle.contentTintColor
        button.isBordered = false
        button.focusRingType = .none
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(handleTap)
        button.toolTip = "Scroll to live output"
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentInsets.top),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInsets.left),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInsets.right),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.contentInsets.bottom),
        ])
    }

    private func updateHoverState(isHovered: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = isHovered ? 0.15 : 0.22
            self.animator().alphaValue = isHovered ? TerminalOverlayStyle.hoverAlpha : Self.restingAlpha
        }
    }

    @objc private func handleTap() {
        onTap?()
    }
}
