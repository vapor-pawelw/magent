import Cocoa

final class OnboardingPermissionsView: NSView {

    var skipPermissions: Bool {
        skipPermissionsCheckbox.state == .on
    }

    var sandboxEnabled: Bool {
        sandboxCheckbox.state == .on
    }

    private let skipPermissionsCheckbox = NSButton(
        checkboxWithTitle: "Skip permission prompts",
        target: nil,
        action: nil
    )
    private let sandboxCheckbox = NSButton(
        checkboxWithTitle: "Enable sandbox",
        target: nil,
        action: nil
    )
    private let fdaStatusLabel = NSTextField(labelWithString: "")
    private var appActiveObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Agent Permissions")
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let descLabel = NSTextField(
            wrappingLabelWithString: "Control how agents handle permissions and sandboxing. Only applies to Claude and Codex."
        )
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)

        skipPermissionsCheckbox.state = .on
        let skipDesc = NSTextField(
            wrappingLabelWithString: "Agents run without asking for approval. Claude uses --dangerously-skip-permissions, Codex uses --yolo."
        )
        skipDesc.font = .systemFont(ofSize: 11)
        skipDesc.textColor = NSColor(resource: .textSecondary)

        sandboxCheckbox.state = .off
        let sandboxDesc = NSTextField(
            wrappingLabelWithString: "Restrict agent filesystem access to the workspace. Codex uses --full-auto."
        )
        sandboxDesc.font = .systemFont(ofSize: 11)
        sandboxDesc.textColor = NSColor(resource: .textSecondary)

        // FDA section
        let fdaLabel = NSTextField(labelWithString: "Full Disk Access")
        fdaLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let fdaDesc = NSTextField(
            wrappingLabelWithString: "Grant Full Disk Access so agents can read and modify files outside the workspace (e.g. ~/.zshrc, ~/Library)."
        )
        fdaDesc.font = .systemFont(ofSize: 11)
        fdaDesc.textColor = NSColor(resource: .textSecondary)

        let fdaStatusRow = NSStackView()
        fdaStatusRow.orientation = .horizontal
        fdaStatusRow.alignment = .centerY
        fdaStatusRow.spacing = 8

        fdaStatusLabel.font = .systemFont(ofSize: 12)
        fdaStatusRow.addArrangedSubview(fdaStatusLabel)

        let fdaButton = NSButton(title: "Open System Settings", target: self, action: #selector(openFDASettings))
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
            fdaStatusLabel.stringValue = "\u{2705} Granted"
            fdaStatusLabel.textColor = .systemGreen
        } else {
            fdaStatusLabel.stringValue = "\u{274C} Not Granted"
            fdaStatusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
