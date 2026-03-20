import Cocoa
import MagentCore

final class SettingsGeneralViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var autoCheckForUpdatesCheckbox: NSButton!
    private var checkNowButton: NSButton!
    private var installUpdateButton: NSButton!
    private var updateStatusLabel: NSTextField!
    private var updateChangelogToggleButton: NSButton!
    private var updateChangelogScrollView: NSScrollView!
    private var updateChangelogTextView: NSTextView!
    private var isUpdateChangelogExpanded = false
    private var syncLocalPathsOnArchiveCheckbox: NSButton!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUpdateStateChanged),
            name: .magentUpdateStateChanged,
            object: nil
        )

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
            wrappingLabelWithString: "When enabled, Magent checks GitHub releases on app launch and shows a persistent update banner when a newer version is available. Homebrew installs are updated through brew."
        )
        updatesDesc.font = .systemFont(ofSize: 11)
        updatesDesc.textColor = NSColor(resource: .textSecondary)
        updatesSection.addArrangedSubview(updatesDesc)

        checkNowButton = NSButton(title: "Check for Updates Now", target: self, action: #selector(checkForUpdatesNowTapped))
        checkNowButton.bezelStyle = .rounded
        checkNowButton.controlSize = .small
        updatesSection.addArrangedSubview(checkNowButton)

        installUpdateButton = NSButton(title: "Update", target: self, action: #selector(updateNowTapped))
        installUpdateButton.bezelStyle = .rounded
        installUpdateButton.controlSize = .small
        installUpdateButton.isHidden = true
        updatesSection.addArrangedSubview(installUpdateButton)

        updateStatusLabel = NSTextField(wrappingLabelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = NSColor(resource: .textSecondary)
        updateStatusLabel.isHidden = true
        updatesSection.addArrangedSubview(updateStatusLabel)

        updateChangelogToggleButton = NSButton(title: "Show Changes", target: self, action: #selector(toggleUpdateChangelog))
        updateChangelogToggleButton.bezelStyle = .rounded
        updateChangelogToggleButton.controlSize = .small
        updateChangelogToggleButton.isHidden = true
        updatesSection.addArrangedSubview(updateChangelogToggleButton)

        updateChangelogTextView = NSTextView()
        updateChangelogTextView.isEditable = false
        updateChangelogTextView.isSelectable = true
        updateChangelogTextView.drawsBackground = false
        updateChangelogTextView.font = .systemFont(ofSize: 12)
        updateChangelogTextView.textColor = NSColor(resource: .textSecondary)
        updateChangelogTextView.textContainerInset = NSSize(width: 0, height: 6)
        updateChangelogTextView.isHorizontallyResizable = false
        updateChangelogTextView.isVerticallyResizable = true
        updateChangelogTextView.autoresizingMask = [.width]
        updateChangelogTextView.textContainer?.widthTracksTextView = true
        updateChangelogTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        updateChangelogScrollView = NSScrollView()
        updateChangelogScrollView.drawsBackground = false
        updateChangelogScrollView.borderType = .bezelBorder
        updateChangelogScrollView.hasVerticalScroller = true
        updateChangelogScrollView.autohidesScrollers = true
        updateChangelogScrollView.documentView = updateChangelogTextView
        updateChangelogScrollView.translatesAutoresizingMaskIntoConstraints = false
        updateChangelogScrollView.isHidden = true
        updatesSection.addArrangedSubview(updateChangelogScrollView)

        let (archiveCard, archiveSection) = createSectionCard(
            title: "Archive",
            description: "Control whether archiving writes local synced files back into the main worktree."
        )
        stackView.addArrangedSubview(archiveCard)

        syncLocalPathsOnArchiveCheckbox = NSButton(
            checkboxWithTitle: "Sync Local Sync Paths back to main worktree on archive",
            target: self,
            action: #selector(syncLocalPathsOnArchiveToggled)
        )
        syncLocalPathsOnArchiveCheckbox.state = settings.syncLocalPathsOnArchive ? .on : .off
        archiveSection.addArrangedSubview(syncLocalPathsOnArchiveCheckbox)

        let syncLocalPathsOnArchiveDesc = NSTextField(
            wrappingLabelWithString: "Disable this to keep main clean for parallel merges. You can still use `magent-cli archive-thread --skip-local-sync` per archive."
        )
        syncLocalPathsOnArchiveDesc.font = .systemFont(ofSize: 11)
        syncLocalPathsOnArchiveDesc.textColor = NSColor(resource: .textSecondary)
        archiveSection.addArrangedSubview(syncLocalPathsOnArchiveDesc)

        // --- Keyboard Shortcuts card ---
        let (keybindsCard, keybindsStack) = createSectionCard(title: "Keyboard Shortcuts")
        stackView.addArrangedSubview(keybindsCard)

        let keybindsGrid = NSGridView()
        keybindsGrid.rowSpacing = 6
        keybindsGrid.columnSpacing = 12
        keybindsGrid.translatesAutoresizingMaskIntoConstraints = false

        for action in KeyBindingAction.allCases {
            let binding = settings.keyBindings.binding(for: action)

            let nameLabel = NSTextField(labelWithString: action.displayName)
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.textColor = .labelColor

            let shortcutLabel = NSTextField(labelWithString: binding.displayString)
            shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            shortcutLabel.textColor = .secondaryLabelColor

            keybindsGrid.addRow(with: [nameLabel, shortcutLabel])
        }

        keybindsGrid.column(at: 0).xPlacement = .leading
        keybindsGrid.column(at: 1).xPlacement = .trailing

        keybindsStack.addArrangedSubview(keybindsGrid)

        // --- Environment Variables card ---
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
            archiveCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            keybindsCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            keybindsGrid.widthAnchor.constraint(equalTo: keybindsStack.widthAnchor),
            envCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            updatesDesc.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateStatusLabel.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateChangelogScrollView.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateChangelogScrollView.heightAnchor.constraint(equalToConstant: 160),
            syncLocalPathsOnArchiveDesc.widthAnchor.constraint(equalTo: archiveSection.widthAnchor),
        ])

        refreshUpdateControls()
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

    @objc private func syncLocalPathsOnArchiveToggled() {
        settings.syncLocalPathsOnArchive = syncLocalPathsOnArchiveCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func checkForUpdatesNowTapped() {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdatesManually()
        }
    }

    @objc private func updateNowTapped() {
        Task { @MainActor in
            await UpdateService.shared.installDetectedUpdateIfAvailable()
        }
    }

    @objc private func handleUpdateStateChanged() {
        refreshUpdateControls()
    }

    @objc private func toggleUpdateChangelog() {
        isUpdateChangelogExpanded.toggle()
        refreshUpdateChangelogDisclosure()
    }

    private func refreshUpdateControls() {
        guard isViewLoaded else { return }

        guard let summary = UpdateService.shared.pendingUpdateSummary else {
            installUpdateButton.isHidden = true
            updateStatusLabel.isHidden = true
            updateStatusLabel.stringValue = ""
            updateChangelogToggleButton.isHidden = true
            updateChangelogScrollView.isHidden = true
            updateChangelogTextView.string = ""
            isUpdateChangelogExpanded = false
            return
        }

        installUpdateButton.title = "Update to \(summary.availableVersion)"
        installUpdateButton.isHidden = false

        if summary.isSkipped {
            updateStatusLabel.stringValue = "New version \(summary.availableVersion) is available. This version is currently skipped for launch banners, but you can still install it here."
        } else {
            updateStatusLabel.stringValue = "New version \(summary.availableVersion) is available. You are currently on \(summary.currentVersion)."
        }
        updateStatusLabel.isHidden = false

        if let releaseNotes = summary.releaseNotes, !releaseNotes.isEmpty {
            updateChangelogTextView.string = releaseNotes
            updateChangelogToggleButton.isHidden = false
            refreshUpdateChangelogDisclosure()
        } else {
            updateChangelogToggleButton.isHidden = true
            updateChangelogScrollView.isHidden = true
            updateChangelogTextView.string = ""
            isUpdateChangelogExpanded = false
        }
    }

    private func refreshUpdateChangelogDisclosure() {
        updateChangelogToggleButton.title = isUpdateChangelogExpanded ? "Hide Changes" : "Show Changes"
        updateChangelogScrollView.isHidden = !isUpdateChangelogExpanded
    }
}
