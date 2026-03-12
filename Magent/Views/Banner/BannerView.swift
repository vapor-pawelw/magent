import Cocoa
import MagentCore

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
        switch self {
        case .info:
            return NSColor(srgbRed: 0.12, green: 0.39, blue: 0.89, alpha: 0.96)
        case .warning:
            return NSColor(srgbRed: 0.71, green: 0.46, blue: 0.09, alpha: 0.96)
        case .error:
            return NSColor(srgbRed: 0.75, green: 0.21, blue: 0.24, alpha: 0.96)
        }
    }

    var foregroundColor: NSColor {
        NSColor.white.withAlphaComponent(0.98)
    }

    var secondaryForegroundColor: NSColor {
        NSColor.white.withAlphaComponent(0.82)
    }
}

struct BannerAction {
    let title: String
    let handler: () -> Void
}

struct BannerConfig {
    let message: String
    let attributedMessage: NSAttributedString?
    let style: BannerStyle
    let duration: TimeInterval?
    let isDismissible: Bool
    let actions: [BannerAction]
    let details: String?
    let detailsCollapsedTitle: String?
    let detailsExpandedTitle: String?

    init(
        message: String = "",
        attributedMessage: NSAttributedString? = nil,
        style: BannerStyle,
        duration: TimeInterval?,
        isDismissible: Bool,
        actions: [BannerAction],
        details: String? = nil,
        detailsCollapsedTitle: String? = nil,
        detailsExpandedTitle: String? = nil
    ) {
        self.message = message
        self.attributedMessage = attributedMessage
        self.style = style
        self.duration = duration
        self.isDismissible = isDismissible
        self.actions = actions
        self.details = details
        self.detailsCollapsedTitle = detailsCollapsedTitle
        self.detailsExpandedTitle = detailsExpandedTitle
    }
}

// MARK: - BannerOverlayView

/// Transparent container that passes through mouse events unless they hit a banner child.
final class BannerOverlayView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? {
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

    private var detailsToggleButton: NSButton?
    private var detailsScrollView: NSScrollView?
    private var detailsTextView: NSTextView?
    private var isDetailsExpanded = false

    init(config: BannerConfig) {
        self.config = config
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = config.style.backgroundColor.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        self.shadow = shadow

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerRow)

        iconView.image = config.style.icon
        iconView.contentTintColor = config.style.foregroundColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(iconView)

        if let attributed = config.attributedMessage {
            messageLabel.attributedStringValue = attributed
        } else {
            messageLabel.stringValue = config.message
        }
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = config.style.foregroundColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isSelectable = true
        messageLabel.isEditable = false
        messageLabel.drawsBackground = false
        messageLabel.isBezeled = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(messageLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = config.style.secondaryForegroundColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = !config.isDismissible
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        let actionRow = buildActionRow()
        if let actionRow {
            rootStack.addArrangedSubview(actionRow)
        }

        if let detailsView = buildDetailsView() {
            rootStack.addArrangedSubview(detailsView)
        }

        if config.isDismissible {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            addGestureRecognizer(pan)
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
    }

    private func buildActionRow() -> NSView? {
        let hasDetails = !(config.details?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard !config.actions.isEmpty || hasDetails else { return nil }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        for action in config.actions {
            let button = NSButton(title: action.title, target: self, action: #selector(actionTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.tag = actionButtons.count
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(button)
            actionButtons.append(button)
        }

        if hasDetails {
            let title = config.detailsCollapsedTitle ?? "Show Details"
            let button = NSButton(title: title, target: self, action: #selector(toggleDetails))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(button)
            detailsToggleButton = button
        }

        return row
    }

    private func buildDetailsView() -> NSView? {
        guard let details = config.details?.trimmingCharacters(in: .whitespacesAndNewlines),
              !details.isEmpty else {
            return nil
        }

        let textView = NSTextView()
        textView.string = details
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = config.style.secondaryForegroundColor
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true

        detailsTextView = textView
        detailsScrollView = scrollView

        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(equalToConstant: 160),
        ])

        return scrollView
    }

    private func updateDetailsDisclosure() {
        let collapsedTitle = config.detailsCollapsedTitle ?? "Show Details"
        let expandedTitle = config.detailsExpandedTitle ?? "Hide Details"
        detailsToggleButton?.title = isDetailsExpanded ? expandedTitle : collapsedTitle
        detailsScrollView?.isHidden = !isDetailsExpanded
        onUserInteraction?()
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
        onUserInteraction?()
        config.actions[sender.tag].handler()
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    @objc private func toggleDetails() {
        isDetailsExpanded.toggle()
        updateDetailsDisclosure()
    }

    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        if gesture.state == .ended && translation.y > 0 {
            onDismiss?()
        }
    }
}
