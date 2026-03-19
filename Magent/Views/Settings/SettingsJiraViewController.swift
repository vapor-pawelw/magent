import Cocoa
import MagentCore

final class SettingsJiraViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private let jira = JiraService.shared
    private var settings: AppSettings!

    private var integrationCheckbox: NSButton!
    private var integrationDisabledLabel: NSTextField!
    private var acliStatusLabel: NSTextField!
    private var authStatusLabel: NSTextField!
    private var authDetailLabel: NSTextField!
    private var loginButton: NSButton!
    private var refreshButton: NSButton!
    private var siteURLField: NSTextField!
    private var ticketDetectionCheckbox: NSButton!

    // Views that should be hidden when integration is off
    private var integrationDependentViews: [NSView] = []
    private var isAcliConnected = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()
        setupUI()
        refreshStatus()
    }

    private func setupUI() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let infoLabel = NSTextField(
            wrappingLabelWithString: "Configure acli authentication and Jira site URL. Ticket keys detected in branch names link directly to Jira."
        )
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(infoLabel)
        NSLayoutConstraint.activate([
            infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // MARK: - Jira Integration Toggle
        let (integrationCard, integrationStack) = createSectionCard(
            title: "Jira Integration",
            description: "Master switch for all Jira features — ticket detection, status badges, and Jira links."
        )
        stack.addArrangedSubview(integrationCard)

        integrationCheckbox = NSButton(
            checkboxWithTitle: "Enable Jira integration",
            target: self,
            action: #selector(integrationToggled)
        )
        integrationCheckbox.state = settings.jiraIntegrationEnabled ? .on : .off
        integrationStack.addArrangedSubview(integrationCheckbox)

        integrationDisabledLabel = NSTextField(
            wrappingLabelWithString: "Jira integration requires acli to be installed and authenticated. Install with: brew install acli"
        )
        integrationDisabledLabel.font = .systemFont(ofSize: 11)
        integrationDisabledLabel.textColor = .systemOrange
        integrationDisabledLabel.isHidden = true
        integrationStack.addArrangedSubview(integrationDisabledLabel)

        let (statusCard, statusStack) = createSectionCard(
            title: "Connection & Authentication",
            description: "Use acli for Jira auth and connectivity checks."
        )
        stack.addArrangedSubview(statusCard)

        let acliHeader = NSTextField(labelWithString: "acli CLI")
        acliHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        statusStack.addArrangedSubview(acliHeader)

        acliStatusLabel = NSTextField(labelWithString: "Checking...")
        acliStatusLabel.font = .systemFont(ofSize: 12)
        acliStatusLabel.textColor = NSColor(resource: .textSecondary)
        statusStack.addArrangedSubview(acliStatusLabel)
        statusStack.setCustomSpacing(10, after: acliStatusLabel)

        let authHeader = NSTextField(labelWithString: "Authentication")
        authHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        statusStack.addArrangedSubview(authHeader)

        authStatusLabel = NSTextField(labelWithString: "Checking...")
        authStatusLabel.font = .systemFont(ofSize: 12)
        authStatusLabel.textColor = NSColor(resource: .textSecondary)
        statusStack.addArrangedSubview(authStatusLabel)

        authDetailLabel = NSTextField(labelWithString: "")
        authDetailLabel.font = .systemFont(ofSize: 11)
        authDetailLabel.textColor = NSColor(resource: .textSecondary)
        authDetailLabel.isHidden = true
        statusStack.addArrangedSubview(authDetailLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        loginButton = NSButton(title: "Open acli Login Page", target: self, action: #selector(loginTapped))
        loginButton.bezelStyle = .rounded
        loginButton.controlSize = .regular
        buttonRow.addArrangedSubview(loginButton)

        refreshButton = NSButton(title: "Refresh Status", target: self, action: #selector(refreshTapped))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .regular
        buttonRow.addArrangedSubview(refreshButton)

        statusStack.addArrangedSubview(buttonRow)

        let (siteCard, siteStack) = createSectionCard(
            title: "Jira Site URL",
            description: "Auto-detected from auth. Override if needed."
        )
        stack.addArrangedSubview(siteCard)

        siteURLField = NSTextField(string: settings.jiraSiteURL)
        siteURLField.font = .systemFont(ofSize: 13)
        siteURLField.placeholderString = "e.g. mycompany.atlassian.net"
        siteURLField.translatesAutoresizingMaskIntoConstraints = false
        siteURLField.target = self
        siteURLField.action = #selector(siteURLChanged)
        siteStack.addArrangedSubview(siteURLField)

        let (detectionCard, detectionStack) = createSectionCard(
            title: "Ticket Detection",
            description: "Automatically detect Jira ticket keys in branch names and show links to open them in Jira."
        )
        stack.addArrangedSubview(detectionCard)

        ticketDetectionCheckbox = NSButton(
            checkboxWithTitle: "Detect Jira tickets from branch names",
            target: self,
            action: #selector(ticketDetectionToggled)
        )
        ticketDetectionCheckbox.state = settings.jiraTicketDetectionEnabled ? .on : .off
        detectionStack.addArrangedSubview(ticketDetectionCheckbox)

        // Track views that depend on integration being enabled
        integrationDependentViews = [statusCard, siteCard, detectionCard]

        // Document view
        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.documentView = documentView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            integrationCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            integrationDisabledLabel.widthAnchor.constraint(equalTo: integrationStack.widthAnchor),
            statusCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            siteCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            detectionCard.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            siteURLField.widthAnchor.constraint(equalTo: siteStack.widthAnchor),
            authDetailLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor),
        ])
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

    // MARK: - Status Refresh

    private func refreshStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let installed = await jira.isAcliInstalled()
            var authenticated = false

            if installed {
                acliStatusLabel.stringValue = "acli installed at /opt/homebrew/bin/acli"
                acliStatusLabel.textColor = .systemGreen
                loginButton.isEnabled = true
            } else {
                acliStatusLabel.stringValue = "Not found. Install: brew install acli"
                acliStatusLabel.textColor = .systemRed
                authStatusLabel.stringValue = "acli not installed"
                authStatusLabel.textColor = .systemRed
                loginButton.isEnabled = false
            }

            if installed {
                let status = await jira.checkAuthStatus()
                if status.isAuthenticated {
                    authenticated = true
                    authStatusLabel.stringValue = "Authenticated" + (status.email.map { " as \($0)" } ?? "")
                    authStatusLabel.textColor = .systemGreen
                    if let site = status.siteURL {
                        authDetailLabel.stringValue = "Site: \(site)"
                        authDetailLabel.isHidden = false
                        // Auto-populate site URL if empty
                        if settings.jiraSiteURL.isEmpty {
                            settings.jiraSiteURL = site
                            siteURLField.stringValue = site
                            try? persistence.saveSettings(settings)
                        }
                    }
                } else {
                    authStatusLabel.stringValue = "Not authenticated"
                    authStatusLabel.textColor = .systemOrange
                    authDetailLabel.stringValue = status.errorMessage ?? ""
                    authDetailLabel.isHidden = (status.errorMessage ?? "").isEmpty
                }
            }

            isAcliConnected = installed && authenticated
            updateIntegrationState()

            if settings.jiraIntegrationEnabled && isAcliConnected {
                ThreadManager.shared.enableAndRefreshJiraDetection()
            }
        }
    }

    private func updateIntegrationState() {
        let canEnable = isAcliConnected

        // Disable checkbox if acli is not connected
        integrationCheckbox.isEnabled = canEnable
        if !canEnable {
            integrationCheckbox.state = .off
            integrationDisabledLabel.isHidden = false
        } else {
            integrationCheckbox.state = settings.jiraIntegrationEnabled ? .on : .off
            integrationDisabledLabel.isHidden = true
        }

        let integrationOn = canEnable && settings.jiraIntegrationEnabled
        for v in integrationDependentViews {
            v.isHidden = !integrationOn
        }

        ticketDetectionCheckbox.isEnabled = integrationOn
        ticketDetectionCheckbox.state = (integrationOn && settings.jiraTicketDetectionEnabled) ? .on : .off
    }

    // MARK: - Actions

    @objc private func loginTapped() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            loginButton.isEnabled = false
            loginButton.title = "Opening browser..."
            await jira.openLoginPage()
            loginButton.isEnabled = true
            loginButton.title = "Open acli Login Page"
            refreshStatus()
        }
    }

    @objc private func refreshTapped() {
        refreshStatus()
    }

    @objc private func integrationToggled() {
        let enabled = integrationCheckbox.state == .on
        settings.jiraIntegrationEnabled = enabled
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)
        updateIntegrationState()

        if enabled {
            ThreadManager.shared.enableAndRefreshJiraDetection()
        } else {
            ThreadManager.shared.clearAllJiraDetectionState()
        }
    }

    @objc private func ticketDetectionToggled() {
        let enabled = ticketDetectionCheckbox.state == .on
        settings.jiraTicketDetectionEnabled = enabled
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)

        if enabled {
            ThreadManager.shared.enableAndRefreshJiraDetection()
        } else {
            ThreadManager.shared.clearAllJiraDetectionState()
        }
    }

    @objc private func siteURLChanged() {
        let value = siteURLField.stringValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        settings.jiraSiteURL = value
        siteURLField.stringValue = value
        try? persistence.saveSettings(settings)
    }
}
