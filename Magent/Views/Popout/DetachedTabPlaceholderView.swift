import Cocoa

/// View shown inside `terminalContainer` when a tab is detached into a separate
/// pop-out window. Replaces the terminal view for that tab slot.
final class DetachedTabPlaceholderView: NSView {
    let sessionName: String

    var onShowWindow: (() -> Void)?
    var onReturnToTab: (() -> Void)?

    init(sessionName: String) {
        self.sessionName = sessionName
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Tab in separate window"
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .thin)
        iconView.contentTintColor = .systemPurple.withAlphaComponent(0.5)

        let titleLabel = NSTextField(labelWithString: "Tab Detached")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: "This tab is open in a separate window")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center

        let showButton = NSButton(title: "Show Window", target: self, action: #selector(showWindowTapped))
        showButton.bezelStyle = .rounded
        showButton.font = .systemFont(ofSize: 12)

        let returnButton = NSButton(title: "Return to Tab", target: self, action: #selector(returnToTabTapped))
        returnButton.bezelStyle = .rounded
        returnButton.font = .systemFont(ofSize: 12)

        let buttonStack = NSStackView(views: [showButton, returnButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(8, after: iconView)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func showWindowTapped() {
        onShowWindow?()
    }

    @objc private func returnToTabTapped() {
        onReturnToTab?()
    }
}
