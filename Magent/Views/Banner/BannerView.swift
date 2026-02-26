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
        for subview in subviews {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted) {
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

    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var actionButtons: [NSButton] = []

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

        // Message
        messageLabel.stringValue = config.message
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = NSColor(resource: .textPrimary)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            heightAnchor.constraint(equalToConstant: 40),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ]

        // Chain: message -> action buttons -> close button
        var previousTrailing = closeButton.leadingAnchor
        for button in actionButtons.reversed() {
            constraints.append(button.trailingAnchor.constraint(equalTo: previousTrailing, constant: -6))
            constraints.append(button.centerYAnchor.constraint(equalTo: centerYAnchor))
            previousTrailing = button.leadingAnchor
        }
        constraints.append(messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousTrailing, constant: -8))

        NSLayoutConstraint.activate(constraints)
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
