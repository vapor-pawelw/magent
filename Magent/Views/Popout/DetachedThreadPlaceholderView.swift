import Cocoa
import MagentCore

/// Shown in the main window's content area when a popped-out thread is selected
/// in the sidebar. The thread IS the active thread (diff panel works), but its
/// terminals live in the pop-out window.
final class DetachedThreadPlaceholderView: NSViewController {
    private let thread: MagentThread

    var onShowWindow: (() -> Void)?
    var onReturnToMain: (() -> Void)?

    init(thread: MagentThread) {
        self.thread = thread
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: "Thread in separate window"
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        iconView.contentTintColor = .systemPurple.withAlphaComponent(0.5)

        let titleLabel = NSTextField(labelWithString: "Thread Open in Separate Window")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = NSColor(resource: .textPrimary)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(labelWithString: thread.taskDescription ?? thread.name)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = NSColor(resource: .textSecondary)
        subtitleLabel.alignment = .center

        let showButton = NSButton(title: "Show Window", target: self, action: #selector(showWindowTapped))
        showButton.bezelStyle = .rounded
        showButton.font = .systemFont(ofSize: 13)

        let returnButton = NSButton(title: "Return to Main Window", target: self, action: #selector(returnToMainTapped))
        returnButton.bezelStyle = .rounded
        returnButton.font = .systemFont(ofSize: 13)

        let buttonStack = NSStackView(views: [showButton, returnButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(16, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func showWindowTapped() {
        onShowWindow?()
    }

    @objc private func returnToMainTapped() {
        onReturnToMain?()
    }
}
