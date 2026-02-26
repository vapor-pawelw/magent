import Cocoa

final class ConfigurationViewController: NSViewController {

    var onComplete: (() -> Void)?

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let persistence = PersistenceService.shared
    private let dependencyChecker = DependencyChecker.shared

    private var currentStep = 0
    private var settings = AppSettings()

    // Step views
    private let dependencyCheckView = DependencyCheckView()
    private let addProjectView = AddProjectView()
    private let agentConfigView = AgentConfigView()

    private let nextButton = NSButton(title: "Next", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Welcome to Magent"

        nextButton.target = self
        nextButton.action = #selector(nextStep)
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"

        setupUI()
        showStep(0)
        checkDependencies()
    }

    private func setupUI() {
        contentStack.orientation = .vertical
        contentStack.spacing = 24
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        contentStack.addArrangedSubview(dependencyCheckView)
        contentStack.addArrangedSubview(addProjectView)
        contentStack.addArrangedSubview(agentConfigView)

        // Button bar at the bottom
        let buttonBar = NSStackView(views: [NSView(), nextButton])
        buttonBar.orientation = .horizontal
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentStack)
        view.addSubview(buttonBar)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        addProjectView.isHidden = step != 1
        agentConfigView.isHidden = step != 2

        switch step {
        case 0:
            title = "Check Dependencies"
            nextButton.title = "Next"
        case 1:
            title = "Add Project"
            nextButton.title = "Next"
        case 2:
            title = "Configure Agent"
            nextButton.title = "Done"
        default:
            break
        }
    }

    @objc private func nextStep() {
        switch currentStep {
        case 0:
            showStep(1)
        case 1:
            if settings.projects.isEmpty {
                showAlert(title: "No Project", message: "Please add at least one git repository.")
                return
            }
            showStep(2)
        case 2:
            finishConfiguration()
        default:
            break
        }
    }

    private func finishConfiguration() {
        settings.customAgentCommand = agentConfigView.agentCommand
        settings.activeAgents = [.claude]
        settings.defaultAgentType = nil
        settings.isConfigured = true
        try? persistence.saveSettings(settings)
        onComplete?()
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
        panel.message = "Select a git repository folder"

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
                    showAlert(title: "Not a Git Repository", message: "The selected folder is not a git repository.")
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Step Views

final class DependencyCheckView: NSView {

    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = "Checking required dependencies..."
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(stack)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(with statuses: [DependencyStatus]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = "Dependencies"

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
                ? "\(status.name) — installed at \(status.path ?? "unknown")"
                : "\(status.name) — not found. \(status.installHint)"
            label.font = .preferredFont(forTextStyle: .body)
            label.maximumNumberOfLines = 0

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }
    }
}

final class AddProjectView: NSView {

    var onAddProject: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "Select Repository Folder...", target: nil, action: nil)
    private let projectsStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = "Add a git repository to manage worktrees for."
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.maximumNumberOfLines = 0

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)

        projectsStack.orientation = .vertical
        projectsStack.spacing = 8

        let stack = NSStackView(views: [titleLabel, addButton, projectsStack])
        stack.orientation = .vertical
        stack.alignment = .leading
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

final class AgentConfigView: NSView {

    var agentCommand: String {
        textField.stringValue
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let textField = NSTextField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        titleLabel.stringValue = "Agent command to run in new threads:"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.maximumNumberOfLines = 0

        textField.stringValue = "claude"
        textField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textField.placeholderString = "claude"

        let stack = NSStackView(views: [titleLabel, textField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textField.widthAnchor.constraint(equalToConstant: 300),
        ])
    }
}
