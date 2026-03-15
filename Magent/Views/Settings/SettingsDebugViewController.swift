#if DEBUG
import Cocoa
import MagentCore

final class SettingsDebugViewController: NSViewController {

    private let persistence = PersistenceService.shared

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let (onboardingCard, onboardingSection) = createSectionCard(
            title: "Onboarding",
            description: "Reset the onboarding wizard so it appears again on next launch."
        )
        stackView.addArrangedSubview(onboardingCard)

        let resetButton = NSButton(title: "Reset Onboarding State", target: self, action: #selector(resetOnboardingTapped))
        resetButton.bezelStyle = .rounded
        onboardingSection.addArrangedSubview(resetButton)

        let (appCard, appSection) = createSectionCard(
            title: "App",
            description: "Immediately terminate and relaunch the app."
        )
        stackView.addArrangedSubview(appCard)

        let relaunchButton = NSButton(title: "Relaunch App", target: self, action: #selector(relaunchTapped))
        relaunchButton.bezelStyle = .rounded
        appSection.addArrangedSubview(relaunchButton)

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    @objc private func resetOnboardingTapped() {
        var settings = persistence.loadSettings()
        settings.isConfigured = false
        try? persistence.saveSettings(settings)

        let alert = NSAlert()
        alert.messageText = "Onboarding Reset"
        alert.informativeText = "Onboarding state has been reset. Relaunch the app to run through the wizard again."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    @objc private func relaunchTapped() {
        relaunchApp()
    }

    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL.path
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && open -n '\(bundleURL)'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func createSectionCard(title: String, description: String? = nil) -> (container: NSView, content: NSStackView) {
        let container = SettingsSectionCardView()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(titleLabel)

        if let description, !description.isEmpty {
            let descriptionLabel = NSTextField(wrappingLabelWithString: description)
            descriptionLabel.font = .systemFont(ofSize: 11)
            descriptionLabel.textColor = NSColor(resource: .textSecondary)
            content.addArrangedSubview(descriptionLabel)
            content.setCustomSpacing(12, after: descriptionLabel)
            NSLayoutConstraint.activate([
                descriptionLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return (container, content)
    }
}
#endif
