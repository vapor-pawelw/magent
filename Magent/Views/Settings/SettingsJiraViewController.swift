import Cocoa

final class SettingsJiraViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private let jira = JiraService.shared
    private var settings: AppSettings!

    private var acliStatusLabel: NSTextField!
    private var authStatusLabel: NSTextField!
    private var authDetailLabel: NSTextField!
    private var loginButton: NSButton!
    private var refreshButton: NSButton!
    private var siteURLField: NSTextField!

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
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Title
        let title = NSTextField(labelWithString: "Jira Integration")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)

        // acli CLI section
        let acliHeader = NSTextField(labelWithString: "acli CLI")
        acliHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(acliHeader)

        acliStatusLabel = NSTextField(labelWithString: "Checking...")
        acliStatusLabel.font = .systemFont(ofSize: 12)
        acliStatusLabel.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(acliStatusLabel)

        // Separator
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep1)

        // Authentication section
        let authHeader = NSTextField(labelWithString: "Authentication")
        authHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(authHeader)

        authStatusLabel = NSTextField(labelWithString: "Checking...")
        authStatusLabel.font = .systemFont(ofSize: 12)
        authStatusLabel.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(authStatusLabel)

        authDetailLabel = NSTextField(labelWithString: "")
        authDetailLabel.font = .systemFont(ofSize: 11)
        authDetailLabel.textColor = NSColor(resource: .textSecondary)
        authDetailLabel.isHidden = true
        stack.addArrangedSubview(authDetailLabel)

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

        stack.addArrangedSubview(buttonRow)

        // Separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep2)

        // Site URL
        let siteHeader = NSTextField(labelWithString: "Jira Site URL")
        siteHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(siteHeader)

        let siteDesc = NSTextField(wrappingLabelWithString: "Auto-detected from auth. Override if needed.")
        siteDesc.font = .systemFont(ofSize: 11)
        siteDesc.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(siteDesc)

        siteURLField = NSTextField(string: settings.jiraSiteURL)
        siteURLField.font = .systemFont(ofSize: 13)
        siteURLField.placeholderString = "e.g. mycompany.atlassian.net"
        siteURLField.translatesAutoresizingMaskIntoConstraints = false
        siteURLField.target = self
        siteURLField.action = #selector(siteURLChanged)
        stack.addArrangedSubview(siteURLField)

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

            sep1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            sep2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            siteURLField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    // MARK: - Status Refresh

    private func refreshStatus() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let installed = await jira.isAcliInstalled()
            if installed {
                acliStatusLabel.stringValue = "acli installed at /opt/homebrew/bin/acli"
                acliStatusLabel.textColor = .systemGreen
            } else {
                acliStatusLabel.stringValue = "Not found. Install: brew install acli"
                acliStatusLabel.textColor = .systemRed
                authStatusLabel.stringValue = "acli not installed"
                authStatusLabel.textColor = .systemRed
                loginButton.isEnabled = false
                return
            }

            let status = await jira.checkAuthStatus()
            if status.isAuthenticated {
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
