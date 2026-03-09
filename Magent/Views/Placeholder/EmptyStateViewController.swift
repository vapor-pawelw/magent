import Cocoa

class EmptyStateViewController: NSViewController {

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        imageView.contentTintColor = NSColor(resource: .textSecondary)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        let titleLabel = NSTextField(labelWithString: String(localized: .AppStrings.emptyStateNoThreadSelected))
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = NSColor(resource: .textPrimary)

        let subtitleLabel = NSTextField(labelWithString: String(localized: .AppStrings.emptyStateSubtitle))
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = NSColor(resource: .textSecondary)

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
