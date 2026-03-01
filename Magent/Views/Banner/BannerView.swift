import Cocoa

// MARK: - Banner Types

enum BannerStyle {
    case info
    case warning
    case error

    var icon: NSImage? {
        let name: String
        switch self {
        case .info: name = "info.circle.fill"
        case .warning: name = "exclamationmark.triangle.fill"
        case .error: name = "xmark.octagon.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    var tintColor: NSColor {
        switch self {
        case .info: return .systemBlue
        case .warning: return .systemYellow
        case .error: return .systemRed
        }
    }

    var backgroundColor: NSColor {
        tintColor.withAlphaComponent(0.15)
    }
}

struct BannerAction {
    let title: String
    let handler: () -> Void
}

struct BannerConfig {
    let message: String
    let style: BannerStyle
    let duration: TimeInterval?
    let isDismissible: Bool
    let actions: [BannerAction]
}

// MARK: - BannerOverlayView

/// Transparent container that passes through mouse events unless they hit a banner child.
final class BannerOverlayView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in our superview's coordinate system.
        // Since the overlay is pinned to (0,0) of its superview, this equals
        // our own coordinate system — which is what subview.hitTest() expects
        // (point in the subview's superview coords, i.e. our coords).
        for subview in subviews {
            if let hit = subview.hitTest(point) {
                return hit
            }
        }
        return nil
    }
}

// MARK: - BannerView

final class BannerView: NSView {

    private let config: BannerConfig
    var onDismiss: (() -> Void)?
    /// Called when the user interacts with the banner (hover, click) to delay auto-dismiss.
    var onUserInteraction: (() -> Void)?

    private let iconView = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()
    private var actionButtons: [NSButton] = []
    private var trackingArea: NSTrackingArea?

    init(config: BannerConfig) {
        self.config = config
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = config.style.backgroundColor.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        self.shadow = shadow

        // Icon
        iconView.image = config.style.icon
        iconView.contentTintColor = config.style.tintColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Message — selectable, multi-line
        messageLabel.stringValue = config.message
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = NSColor(resource: .textPrimary)
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isSelectable = true
        messageLabel.isEditable = false
        messageLabel.drawsBackground = false
        messageLabel.isBezeled = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        messageLabel.setContentHuggingPriority(.required, for: .vertical)
        addSubview(messageLabel)

        // Action buttons
        for action in config.actions {
            let button = NSButton(title: action.title, target: self, action: #selector(actionTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.tag = actionButtons.count
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            actionButtons.append(button)
        }

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !config.isDismissible
        addSubview(closeButton)

        // Swipe-up gesture to dismiss (only when dismissible)
        if config.isDismissible {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            addGestureRecognizer(pan)
        }

        setupConstraints()
    }

    private func setupConstraints() {
        translatesAutoresizingMaskIntoConstraints = false

        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ]

        // Chain: message -> action buttons -> close button
        var previousTrailing = closeButton.leadingAnchor
        for button in actionButtons.reversed() {
            constraints.append(button.trailingAnchor.constraint(equalTo: previousTrailing, constant: -6))
            constraints.append(button.topAnchor.constraint(equalTo: topAnchor, constant: 8))
            previousTrailing = button.leadingAnchor
        }
        constraints.append(messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousTrailing, constant: -8))

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Mouse tracking for hover delay

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onUserInteraction?()
    }

    override func mouseDown(with event: NSEvent) {
        onUserInteraction?()
        super.mouseDown(with: event)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard sender.tag < config.actions.count else { return }
        config.actions[sender.tag].handler()
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        if gesture.state == .ended && translation.y > 0 {
            // Swiped up (in flipped coordinates, y>0 is up in non-flipped; but in AppKit y increases upward)
            // We want swipe-up: translation.y > 0 means upward in standard AppKit coords
            onDismiss?()
        }
    }
}
