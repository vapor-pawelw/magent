import Cocoa

final class OnboardingPermissionsView: NSView {

    var skipPermissions: Bool {
        skipPermissionsCheckbox.state == .on
    }

    var sandboxEnabled: Bool {
        sandboxCheckbox.state == .on
    }

    private let skipPermissionsCheckbox = NSButton(
        checkboxWithTitle: String(localized: .ConfigurationStrings.permissionsSkipPrompts),
        target: nil,
        action: nil
    )
    private let sandboxCheckbox = NSButton(
        checkboxWithTitle: String(localized: .ConfigurationStrings.permissionsEnableSandbox),
        target: nil,
        action: nil
    )
    private let fdaStatusLabel = NSTextField(labelWithString: "")
    private var appActiveObserver: NSObjectProtocol?

    override var isHidden: Bool {
        didSet {
            if !isHidden { refreshFDAStatus() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: String(localized: .ConfigurationStrings.permissionsTitle))
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let descLabel = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsDescription)
        )
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)

        skipPermissionsCheckbox.state = .on
        let skipDesc = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsSkipPromptsDescription)
        )
        skipDesc.font = .systemFont(ofSize: 11)
        skipDesc.textColor = NSColor(resource: .textSecondary)

        sandboxCheckbox.state = .off
        let sandboxDesc = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsEnableSandboxDescriptionOnboarding)
        )
        sandboxDesc.font = .systemFont(ofSize: 11)
        sandboxDesc.textColor = NSColor(resource: .textSecondary)

        // FDA section
        let fdaLabel = NSTextField(labelWithString: String(localized: .ConfigurationStrings.permissionsFullDiskAccessTitle))
        fdaLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let fdaDesc = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsFullDiskAccessDescriptionShort)
        )
        fdaDesc.font = .systemFont(ofSize: 11)
        fdaDesc.textColor = NSColor(resource: .textSecondary)

        let fdaStatusRow = NSStackView()
        fdaStatusRow.orientation = .horizontal
        fdaStatusRow.alignment = .centerY
        fdaStatusRow.spacing = 8

        fdaStatusLabel.font = .systemFont(ofSize: 12)
        fdaStatusRow.addArrangedSubview(fdaStatusLabel)

        let fdaButton = NSButton(title: String(localized: .CommonStrings.commonOpenSystemSettings), target: self, action: #selector(openFDASettings))
        fdaButton.bezelStyle = .push
        fdaButton.controlSize = .small
        fdaStatusRow.addArrangedSubview(fdaButton)

        let stack = NSStackView(views: [
            titleLabel, descLabel,
            skipPermissionsCheckbox, skipDesc,
            sandboxCheckbox, sandboxDesc,
            fdaLabel, fdaDesc, fdaStatusRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.setCustomSpacing(16, after: sandboxDesc)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshFDAStatus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            appActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isHidden else { return }
                self.refreshFDAStatus()
            }
        } else if let observer = appActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            appActiveObserver = nil
        }
    }

    private func refreshFDAStatus() {
        let granted = SystemAccessChecker.isFullDiskAccessGranted()
        if granted {
            fdaStatusLabel.stringValue = String(localized: .ConfigurationStrings.permissionsFullDiskAccessGranted)
            fdaStatusLabel.textColor = .systemGreen
        } else {
            fdaStatusLabel.stringValue = String(localized: .ConfigurationStrings.permissionsFullDiskAccessNotGranted)
            fdaStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
