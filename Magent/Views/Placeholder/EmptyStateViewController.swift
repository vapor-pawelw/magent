import Cocoa

class EmptyStateViewController: NSViewController {

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        let titleLabel = NSTextField(labelWithString: "No Thread Selected")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .secondaryLabelColor

        let subtitleLabel = NSTextField(labelWithString: "Create a new thread or select one from the sidebar")
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [imageView, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
