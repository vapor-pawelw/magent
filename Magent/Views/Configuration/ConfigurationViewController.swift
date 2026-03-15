import Cocoa
import MagentCore

final class ConfigurationViewController: NSViewController {

    var onComplete: (() -> Void)?

    private let contentStack = NSStackView()
    private let persistence = PersistenceService.shared
    private let dependencyChecker = DependencyChecker.shared

    private var currentStep = 0
    private var settings = AppSettings()

    // Step views
    private let dependencyCheckView = DependencyCheckView()
    private let agentSelectionView = OnboardingAgentSelectionView()
    private let permissionsView = OnboardingPermissionsView()
    private let notificationsView = OnboardingNotificationsView()
    private let addProjectView = AddProjectView()

    private let backButton = NSButton(title: String(localized: .CommonStrings.commonBack), target: nil, action: nil)
    private let nextButton = NSButton(title: String(localized: .CommonStrings.commonNext), target: nil, action: nil)

    private let totalSteps = 5

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: .ConfigurationStrings.configurationWelcomeTitle)

        backButton.target = self
        backButton.action = #selector(previousStep)
        backButton.bezelStyle = .rounded

        nextButton.target = self
        nextButton.action = #selector(nextStep)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"

        setupUI()
        dependencyCheckView.onRecheck = { [weak self] in self?.checkDependencies() }
        showStep(0)
        checkDependencies()
    }

    private func setupUI() {
        contentStack.orientation = .vertical
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)

        contentStack.addArrangedSubview(dependencyCheckView)
        contentStack.addArrangedSubview(agentSelectionView)
        contentStack.addArrangedSubview(permissionsView)
        contentStack.addArrangedSubview(notificationsView)
        contentStack.addArrangedSubview(addProjectView)

        // Button bar at the bottom
        let buttonBar = NSStackView(views: [backButton, NSView(), nextButton])
        buttonBar.orientation = .horizontal
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentStack)
        view.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),

            buttonBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            buttonBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buttonBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            buttonBar.heightAnchor.constraint(equalToConstant: 30),
        ])

        addProjectView.onAddProject = { [weak self] in
            self?.showFolderPicker()
        }
    }

    private func showStep(_ step: Int) {
        currentStep = step
        dependencyCheckView.isHidden = step != 0
        agentSelectionView.isHidden = step != 1
        permissionsView.isHidden = step != 2
        notificationsView.isHidden = step != 3
        addProjectView.isHidden = step != 4

        backButton.isHidden = step == 0

        switch step {
        case 0:
            title = String(localized: .ConfigurationStrings.configurationStepCheckDependencies)
            nextButton.title = String(localized: .CommonStrings.commonNext)
        case 1:
            title = String(localized: .ConfigurationStrings.configurationStepSelectAgents)
            nextButton.title = String(localized: .CommonStrings.commonNext)
        case 2:
            title = String(localized: .ConfigurationStrings.configurationStepPermissions)
            nextButton.title = String(localized: .CommonStrings.commonNext)
        case 3:
            title = String(localized: .ConfigurationStrings.configurationStepNotifications)
            nextButton.title = String(localized: .CommonStrings.commonNext)
        case 4:
            title = String(localized: .ConfigurationStrings.configurationStepAddProject)
            nextButton.title = String(localized: .CommonStrings.commonDone)
        default:
            break
        }
    }

    @objc private func previousStep() {
        guard currentStep > 0 else { return }
        showStep(currentStep - 1)
    }

    @objc private func nextStep() {
        switch currentStep {
        case 0:
            showStep(1)
        case 1:
            if agentSelectionView.selectedAgents.isEmpty {
                showAlert(
                    title: String(localized: .ConfigurationStrings.configurationAlertNoAgentSelectedTitle),
                    message: String(localized: .ConfigurationStrings.configurationAlertNoAgentSelectedMessage)
                )
                return
            }
            showStep(2)
        case 2:
            showStep(3)
        case 3:
            showStep(4)
        case 4:
            if settings.projects.isEmpty {
                showAlert(
                    title: String(localized: .ConfigurationStrings.configurationAlertNoProjectTitle),
                    message: String(localized: .ConfigurationStrings.configurationAlertNoProjectMessage)
                )
                return
            }
            finishConfiguration()
        default:
            break
        }
    }

    private func finishConfiguration() {
        // Agents
        settings.activeAgents = agentSelectionView.selectedAgents
        settings.defaultAgentType = agentSelectionView.defaultAgent
        settings.customAgentCommand = agentSelectionView.customCommand

        // Permissions
        settings.agentSkipPermissions = permissionsView.skipPermissions
        settings.agentSandboxEnabled = permissionsView.sandboxEnabled

        // Notifications
        settings.showSystemBanners = notificationsView.showSystemBanners
        settings.playSoundForAgentCompletion = notificationsView.playSoundForCompletion
        settings.agentCompletionSoundName = notificationsView.completionSoundName
        settings.playSoundOnRateLimitDetected = notificationsView.playSoundOnRateLimitDetected
        settings.rateLimitDetectedSoundName = notificationsView.rateLimitDetectedSoundName
        settings.showSystemNotificationOnRateLimitLifted = notificationsView.showSystemNotificationOnRateLimitLifted
        settings.notifyOnRateLimitLifted = notificationsView.notifyOnRateLimitLifted
        settings.rateLimitLiftedSoundName = notificationsView.rateLimitLiftedSoundName

        settings.isConfigured = true
        try? persistence.saveSettings(settings)
        onComplete?()
        dismiss(nil)
    }

    private func checkDependencies() {
        Task {
            let statuses = await dependencyChecker.checkAll()
            dependencyCheckView.update(with: statuses)
        }
    }

    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: .ConfigurationStrings.configurationSelectRepositoryFolder)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.handleSelectedFolder(url)
        }
    }

    private func handleSelectedFolder(_ url: URL) {
        let path = url.path
        Task {
            let isRepo = await GitService.shared.isGitRepository(at: path)
            let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
            await MainActor.run {
                if isRepo {
                    let project = Project(
                        name: url.lastPathComponent,
                        repoPath: path,
                        worktreesBasePath: Project.suggestedWorktreesPath(for: path),
                        defaultBranch: defaultBranch
                    )
                    settings.projects.append(project)
                    addProjectView.addProject(project)
                } else {
                    showAlert(
                        title: String(localized: .ConfigurationStrings.configurationAlertNotGitRepositoryTitle),
                        message: String(localized: .ConfigurationStrings.configurationAlertNotGitRepositoryMessage)
                    )
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: .CommonStrings.commonOk))
        alert.runModal()
    }
}

// MARK: - Step Views

final class DependencyCheckView: NSView {

    var onRecheck: (() -> Void)?

    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = String(localized: .ConfigurationStrings.configurationCheckingDependencies)
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        let container = NSStackView(views: [titleLabel, stack])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 16
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)

        NSLayoutConstraint.activate([
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            container.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    func update(with statuses: [DependencyStatus]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = String(localized: .ConfigurationStrings.configurationDependenciesTitle)

        let anyMissing = statuses.contains { !$0.isInstalled }

        for status in statuses {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let icon = NSImageView()
            icon.image = NSImage(
                systemSymbolName: status.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                accessibilityDescription: nil
            )
            icon.contentTintColor = status.isInstalled ? .systemGreen : .systemRed
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true

            let label = NSTextField(labelWithString: "")
            label.stringValue = status.isInstalled
                ? String(localized: .ConfigurationStrings.configurationDependencyInstalled(status.name, status.path ?? String(localized: .CommonStrings.commonUnknown)))
                : String(localized: .ConfigurationStrings.configurationDependencyNotFound(status.name))
            label.font = .preferredFont(forTextStyle: .body)
            label.maximumNumberOfLines = 0

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)

            if !status.isInstalled {
                let installButton = NSButton(
                    title: String(localized: .ConfigurationStrings.configurationDependencyInstallButton),
                    target: self,
                    action: #selector(installButtonTapped(_:))
                )
                installButton.bezelStyle = .rounded
                installButton.identifier = NSUserInterfaceItemIdentifier(status.name)
                row.addArrangedSubview(installButton)
            }

            stack.addArrangedSubview(row)
        }

        if anyMissing {
            let recheckButton = NSButton(
                title: String(localized: .ConfigurationStrings.configurationRecheckDependencies),
                target: self,
                action: #selector(recheckTapped)
            )
            recheckButton.bezelStyle = .rounded
            stack.addArrangedSubview(recheckButton)
        }
    }

    @objc private func installButtonTapped(_ sender: NSButton) {
        installDependency(named: sender.identifier?.rawValue ?? "")
    }

    @objc private func recheckTapped() {
        onRecheck?()
    }

    private func installDependency(named name: String) {
        switch name {
        case "git":
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            try? process.run()
        case "tmux":
            let script = "#!/bin/bash\nbrew install tmux\nexec bash\n"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("magent-install-tmux.command")
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }
}

final class AddProjectView: NSView {

    var onAddProject: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: String(localized: .ConfigurationStrings.configurationSelectRepositoryFolderEllipsis), target: nil, action: nil)
    private let projectsStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = String(localized: .ConfigurationStrings.configurationAddProjectDescription)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.maximumNumberOfLines = 0

        let explanationLabel = NSTextField(wrappingLabelWithString: String(localized: .ConfigurationStrings.configurationWorktreeExplanation))
        explanationLabel.font = .preferredFont(forTextStyle: .body)
        explanationLabel.textColor = .secondaryLabelColor

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)

        projectsStack.orientation = .vertical
        projectsStack.spacing = 8

        let stack = NSStackView(views: [titleLabel, explanationLabel, addButton, projectsStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func addTapped() {
        onAddProject?()
    }

    func addProject(_ project: Project) {
        let label = NSTextField(labelWithString: "\(project.name) — \(project.repoPath)")
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = NSColor(resource: .textSecondary)
        projectsStack.addArrangedSubview(label)
    }
}
