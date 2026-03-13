import Cocoa
import MagentCore

private enum TerminalOverlayStyle {
    static let normalAlpha: CGFloat = 0.55
    static let hoverAlpha: CGFloat = 0.90
    static let opaqueAlpha: CGFloat = 1.0

    static func backgroundColor(for appearance: NSAppearance) -> NSColor {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.94)
        }
        return NSColor.white.withAlphaComponent(0.94)
    }

    static func borderColor(for appearance: NSAppearance) -> NSColor {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.12)
        }
        return NSColor.black.withAlphaComponent(0.10)
    }

    static func contentTintColor(for appearance: NSAppearance) -> NSColor {
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.88)
        }
        return NSColor.black.withAlphaComponent(0.72)
    }
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
    private let buttonStack = NSStackView()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        alphaValue = TerminalOverlayStyle.normalAlpha
        layer?.borderWidth = 1

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
            btn.toolTip = tip
            btn.target = self
            btn.action = action
            btn.isEnabled = false
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: btnSize).isActive = true
            btn.heightAnchor.constraint(equalToConstant: btnSize).isActive = true
        }

        buttonStack.orientation = .horizontal
        buttonStack.spacing = 2
        buttonStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(upButton)
        buttonStack.addArrangedSubview(downButton)
        buttonStack.addArrangedSubview(toBottomButton)
        addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: topAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        updateAppearance()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = TerminalOverlayStyle.backgroundColor(for: effectiveAppearance).cgColor
            layer?.borderColor = TerminalOverlayStyle.borderColor(for: effectiveAppearance).cgColor
            let contentTint = TerminalOverlayStyle.contentTintColor(for: effectiveAppearance)
            upButton.contentTintColor = contentTint
            downButton.contentTintColor = contentTint
            toBottomButton.contentTintColor = contentTint
        }
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

    // MARK: - Mouse event absorption
    //
    // Override mouse events to prevent them from propagating to the Ghostty
    // terminal surface below. Without this, clicks in the padding areas between
    // buttons fall through the responder chain and trigger text selection in
    // the terminal. The buttons themselves absorb their own events; we only
    // need to handle the gaps/insets of the container view.

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    // MARK: - Actions

    @objc private func upTapped()       { onScrollUp?() }
    @objc private func downTapped()     { onScrollDown?() }
    @objc private func toBottomTapped() { onScrollToBottom?() }
}

/// A standalone overlay-styled pill action for jumping the terminal back to live output.
final class TerminalScrollToBottomPillButton: NSView {
    static let restingAlpha = TerminalOverlayStyle.opaqueAlpha

    var onTap: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Scroll to bottom")
    private let contentStack = NSStackView()

    private static let contentInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    private static let contentSpacing: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        let contentSize = contentStack.fittingSize
        return NSSize(
            width: contentSize.width + Self.contentInsets.left + Self.contentInsets.right,
            height: contentSize.height + Self.contentInsets.top + Self.contentInsets.bottom
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

    private func setup() {
        wantsLayer = true
        alphaValue = Self.restingAlpha
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        layer?.borderWidth = 1

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Scroll to bottom")?
            .withSymbolConfiguration(symbolConfig)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = Self.contentSpacing
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleLabel)

        toolTip = "Scroll to live output"

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentInsets.top),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInsets.left),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInsets.right),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.contentInsets.bottom),
        ])

        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = TerminalOverlayStyle.backgroundColor(for: effectiveAppearance).cgColor
            layer?.borderColor = TerminalOverlayStyle.borderColor(for: effectiveAppearance).cgColor
            let contentTint = TerminalOverlayStyle.contentTintColor(for: effectiveAppearance)
            iconView.contentTintColor = contentTint
            titleLabel.textColor = contentTint
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        handleTap()
    }

    @objc private func handleTap() {
        onTap?()
    }

    override func accessibilityPerformPress() -> Bool {
        handleTap()
        return true
    }
}
