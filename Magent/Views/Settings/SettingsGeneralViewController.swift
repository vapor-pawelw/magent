import Cocoa
import MagentCore

final class SettingsGeneralViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var autoCheckForUpdatesCheckbox: NSButton!
    private var showScrollToBottomIndicatorCheckbox: NSButton!
    private var showScrollOverlayCheckbox: NSButton!
    private var showPromptTOCCheckbox: NSButton!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        contentScrollView = NSScrollView()
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let (updatesCard, updatesSection) = createSectionCard(title: "Updates")
        stackView.addArrangedSubview(updatesCard)

        autoCheckForUpdatesCheckbox = NSButton(
            checkboxWithTitle: "Automatically check for updates on launch",
            target: self,
            action: #selector(autoCheckForUpdatesToggled)
        )
        autoCheckForUpdatesCheckbox.state = settings.autoCheckForUpdates ? .on : .off
        updatesSection.addArrangedSubview(autoCheckForUpdatesCheckbox)

        let updatesDesc = NSTextField(
            wrappingLabelWithString: "When enabled, Magent checks GitHub releases on app launch and installs newer versions automatically. Homebrew installs are updated through brew."
        )
        updatesDesc.font = .systemFont(ofSize: 11)
        updatesDesc.textColor = NSColor(resource: .textSecondary)
        updatesSection.addArrangedSubview(updatesDesc)

        let checkNowButton = NSButton(title: "Check for Updates Now", target: self, action: #selector(checkForUpdatesNowTapped))
        checkNowButton.bezelStyle = .rounded
        checkNowButton.controlSize = .small
        updatesSection.addArrangedSubview(checkNowButton)

        let (terminalOverlaysCard, terminalOverlaysSection) = createSectionCard(
            title: "Terminal Overlays",
            description: "Control always-on terminal helpers."
        )
        stackView.addArrangedSubview(terminalOverlaysCard)

        showScrollToBottomIndicatorCheckbox = NSButton(
            checkboxWithTitle: "Show scroll-to-bottom indicator",
            target: self,
            action: #selector(showScrollToBottomIndicatorToggled)
        )
        showScrollToBottomIndicatorCheckbox.state = settings.showScrollToBottomIndicator ? .on : .off
        terminalOverlaysSection.addArrangedSubview(showScrollToBottomIndicatorCheckbox)

        let showScrollToBottomIndicatorDesc = NSTextField(
            wrappingLabelWithString: "Shows the floating `Scroll to bottom` pill when you are away from live output."
        )
        showScrollToBottomIndicatorDesc.font = .systemFont(ofSize: 11)
        showScrollToBottomIndicatorDesc.textColor = NSColor(resource: .textSecondary)
        terminalOverlaysSection.addArrangedSubview(showScrollToBottomIndicatorDesc)

        showScrollOverlayCheckbox = NSButton(
            checkboxWithTitle: "Show terminal scroll overlay controls",
            target: self,
            action: #selector(showScrollOverlayToggled)
        )
        showScrollOverlayCheckbox.state = settings.showTerminalScrollOverlay ? .on : .off
        terminalOverlaysSection.addArrangedSubview(showScrollOverlayCheckbox)

        let showScrollOverlayDesc = NSTextField(
            wrappingLabelWithString: "Shows the bottom-right page up/down/jump overlay."
        )
        showScrollOverlayDesc.font = .systemFont(ofSize: 11)
        showScrollOverlayDesc.textColor = NSColor(resource: .textSecondary)
        terminalOverlaysSection.addArrangedSubview(showScrollOverlayDesc)

        showPromptTOCCheckbox = NSButton(
            checkboxWithTitle: "Show prompt Table of Contents overlay",
            target: self,
            action: #selector(showPromptTOCToggled)
        )
        showPromptTOCCheckbox.state = settings.showPromptTOCOverlay ? .on : .off
        terminalOverlaysSection.addArrangedSubview(showPromptTOCCheckbox)

        let showPromptTOCDesc = NSTextField(
            wrappingLabelWithString: "When disabled, TOC stays hidden and the top-right TOC toggle is removed."
        )
        showPromptTOCDesc.font = .systemFont(ofSize: 11)
        showPromptTOCDesc.textColor = NSColor(resource: .textSecondary)
        terminalOverlaysSection.addArrangedSubview(showPromptTOCDesc)

        let envVars: [(String, String)] = [
            ("$MAGENT_WORKTREE_PATH", "Absolute path to the thread's git worktree directory"),
            ("$MAGENT_PROJECT_PATH", "Absolute path to the original git repository"),
            ("$MAGENT_WORKTREE_NAME", "Name of the current thread"),
            ("$MAGENT_PROJECT_NAME", "Name of the project (also usable in Worktrees Path)"),
        ]

        let (envCard, envStack) = createSectionCard(
            title: "Environment Variables",
            description: "Available in injection commands:"
        )
        stackView.addArrangedSubview(envCard)

        for (name, desc) in envVars {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
            row.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            nameLabel.textColor = .systemGreen

            let descLabel = NSTextField(wrappingLabelWithString: desc)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = NSColor(resource: .textSecondary)

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(descLabel)
            envStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: envStack.widthAnchor),
                descLabel.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -8),
            ])
        }

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        contentScrollView.documentView = documentView

        view.addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            contentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),
            updatesCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            terminalOverlaysCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            envCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            updatesDesc.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didInitialScrollToTop {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialScrollToTop, view.window != nil {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    private func scrollToTop() {
        guard let clipView = contentScrollView?.contentView as NSClipView? else { return }
        clipView.scroll(to: NSPoint(x: 0, y: 0))
        contentScrollView.reflectScrolledClipView(clipView)
    }

    private func saveSettingsAndNotify() {
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)
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

    @objc private func autoCheckForUpdatesToggled() {
        settings.autoCheckForUpdates = autoCheckForUpdatesCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func showScrollToBottomIndicatorToggled() {
        settings.showScrollToBottomIndicator = showScrollToBottomIndicatorCheckbox.state == .on
        saveSettingsAndNotify()
    }

    @objc private func showScrollOverlayToggled() {
        settings.showTerminalScrollOverlay = showScrollOverlayCheckbox.state == .on
        saveSettingsAndNotify()
    }

    @objc private func showPromptTOCToggled() {
        settings.showPromptTOCOverlay = showPromptTOCCheckbox.state == .on
        saveSettingsAndNotify()
    }

    @objc private func checkForUpdatesNowTapped() {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdatesManually()
        }
    }
}
