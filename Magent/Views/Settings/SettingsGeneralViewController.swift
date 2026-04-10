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
    private var externalLinkPreferencePopup: NSPopUpButton!
    private var createBackupButton: NSButton!
    private var restoreFromBackupButton: NSButton!
    private var lastBackupLabel: NSTextField!
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackupSnapshotsChanged),
            name: .magentBackupSnapshotsDidChange,
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

        let (linksCard, linksSection) = createSectionCard(
            title: "Links",
            description: "Choose where Magent opens web targets like PRs, Jira pages, and other in-app web destinations by default."
        )
        stackView.addArrangedSubview(linksCard)

        externalLinkPreferencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        externalLinkPreferencePopup.controlSize = .small
        externalLinkPreferencePopup.font = .systemFont(ofSize: 12)
        externalLinkPreferencePopup.addItems(withTitles: ExternalLinkOpenPreference.allCases.map(\.displayName))
        if let index = ExternalLinkOpenPreference.allCases.firstIndex(of: settings.externalLinkOpenPreference) {
            externalLinkPreferencePopup.selectItem(at: index)
        }
        externalLinkPreferencePopup.target = self
        externalLinkPreferencePopup.action = #selector(externalLinkPreferenceChanged)
        linksSection.addArrangedSubview(
            labeledPopupRow(label: "Open web links in", popup: externalLinkPreferencePopup)
        )

        let linksDesc = NSTextField(
            wrappingLabelWithString: "Primary clicks follow this preference. Option-click on Magent toolbar link buttons opens the opposite destination as a quick override."
        )
        linksDesc.font = .systemFont(ofSize: 11)
        linksDesc.textColor = NSColor(resource: .textSecondary)
        linksSection.addArrangedSubview(linksDesc)

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

        // --- Data Backup card (last-resort restore) ---
        let (backupCard, backupSection) = createSectionCard(
            title: "Data Backup",
            description: "Magent automatically snapshots critical data (threads, settings, drafts) every 30 minutes. You can also create a snapshot manually or restore from a previous snapshot."
        )
        stackView.addArrangedSubview(backupCard)

        createBackupButton = NSButton(
            title: "Back Up Now",
            target: self,
            action: #selector(createBackupNowTapped)
        )
        createBackupButton.bezelStyle = .rounded
        createBackupButton.controlSize = .small
        backupSection.addArrangedSubview(createBackupButton)

        restoreFromBackupButton = NSButton(
            title: "Restore from Backup\u{2026}",
            target: self,
            action: #selector(restoreFromBackupTapped)
        )
        restoreFromBackupButton.bezelStyle = .rounded
        restoreFromBackupButton.controlSize = .small
        backupSection.addArrangedSubview(restoreFromBackupButton)

        lastBackupLabel = NSTextField(wrappingLabelWithString: "")
        lastBackupLabel.font = .systemFont(ofSize: 11)
        lastBackupLabel.textColor = NSColor(resource: .textSecondary)
        backupSection.addArrangedSubview(lastBackupLabel)

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
            linksCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            archiveCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            keybindsCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            keybindsGrid.widthAnchor.constraint(equalTo: keybindsStack.widthAnchor),
            envCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            backupCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            updatesDesc.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateStatusLabel.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateChangelogScrollView.widthAnchor.constraint(equalTo: updatesSection.widthAnchor),
            updateChangelogScrollView.heightAnchor.constraint(equalToConstant: 160),
            linksDesc.widthAnchor.constraint(equalTo: linksSection.widthAnchor),
            syncLocalPathsOnArchiveDesc.widthAnchor.constraint(equalTo: archiveSection.widthAnchor),
            lastBackupLabel.widthAnchor.constraint(equalTo: backupSection.widthAnchor),
        ])

        refreshUpdateControls()
        refreshBackupControls()
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

    private func labeledPopupRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .medium)

        let row = NSStackView(views: [labelField, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    @objc private func autoCheckForUpdatesToggled() {
        settings = persistence.loadSettings()
        settings.autoCheckForUpdates = autoCheckForUpdatesCheckbox.state == .on
        try? persistence.saveSettings(settings)
        UpdateService.shared.handleAutoCheckSettingChanged()
    }

    @objc private func syncLocalPathsOnArchiveToggled() {
        settings = persistence.loadSettings()
        settings.syncLocalPathsOnArchive = syncLocalPathsOnArchiveCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func externalLinkPreferenceChanged() {
        let index = externalLinkPreferencePopup.indexOfSelectedItem
        guard ExternalLinkOpenPreference.allCases.indices.contains(index) else { return }
        settings = persistence.loadSettings()
        settings.externalLinkOpenPreference = ExternalLinkOpenPreference.allCases[index]
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)
    }

    @objc private func checkForUpdatesNowTapped() {
        Task { @MainActor in
            await UpdateService.shared.checkForUpdatesManually()
        }
    }

    @objc private func updateNowTapped() {
        Task { @MainActor in
            guard !UpdateService.shared.isUpdateDownloadInProgress,
                  !UpdateService.shared.isUpdateInstallInProgress else { return }
            if UpdateService.shared.isUpdateReadyToInstall {
                await UpdateService.shared.installPreparedUpdate()
            } else {
                await UpdateService.shared.installDetectedUpdateIfAvailable()
            }
        }
    }

    @objc private func handleUpdateStateChanged() {
        refreshUpdateControls()
    }

    @objc private func handleBackupSnapshotsChanged() {
        refreshBackupControls()
    }

    @objc private func toggleUpdateChangelog() {
        isUpdateChangelogExpanded.toggle()
        refreshUpdateChangelogDisclosure()
    }

    @objc private func createBackupNowTapped() {
        let copiedCount = BackupService.shared.createSnapshot()
        let message: String
        let style: BannerStyle

        if copiedCount > 0 {
            message = copiedCount == 1 ? "Created a manual backup snapshot with 1 file." : "Created a manual backup snapshot with \(copiedCount) files."
            style = .info
        } else {
            message = "No current data files were available to back up."
            style = .warning
        }

        BannerManager.shared.show(message: message, style: style, duration: 4.0)
        refreshBackupControls()
    }

    private func refreshUpdateControls() {
        guard isViewLoaded else { return }

        guard let summary = UpdateService.shared.pendingUpdateSummary else {
            installUpdateButton.isHidden = true
            installUpdateButton.isEnabled = true
            updateStatusLabel.isHidden = true
            updateStatusLabel.stringValue = ""
            updateChangelogToggleButton.isHidden = true
            updateChangelogScrollView.isHidden = true
            updateChangelogTextView.string = ""
            isUpdateChangelogExpanded = false
            return
        }

        if UpdateService.shared.isUpdateReadyToInstall {
            installUpdateButton.title = "Install & Relaunch"
            installUpdateButton.isEnabled = true
        } else if UpdateService.shared.isUpdateDownloadInProgress {
            installUpdateButton.title = "Downloading..."
            installUpdateButton.isEnabled = false
        } else if UpdateService.shared.isUpdateInstallInProgress {
            installUpdateButton.title = "Installing..."
            installUpdateButton.isEnabled = false
        } else {
            installUpdateButton.title = "Download"
            installUpdateButton.isEnabled = true
        }
        installUpdateButton.isHidden = false

        if UpdateService.shared.isUpdateDownloadInProgress {
            if UpdateService.shared.isUpdatePreparing {
                updateStatusLabel.stringValue = "Preparing Magent \(summary.availableVersion) for installation..."
            } else if let percent = UpdateService.shared.updateDownloadProgressPercent {
                updateStatusLabel.stringValue = "Downloading Magent \(summary.availableVersion)... \(percent)%"
            } else {
                updateStatusLabel.stringValue = "Downloading Magent \(summary.availableVersion)..."
            }
        } else if summary.isSkipped {
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

    private func refreshBackupControls() {
        guard isViewLoaded else { return }

        guard let snapshot = BackupService.shared.latestSnapshot() else {
            lastBackupLabel.stringValue = "No backups have been created yet."
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let ageString = backupAgeString(for: snapshot.date)
        lastBackupLabel.stringValue = "Last backup: \(dateFormatter.string(from: snapshot.date)) (\(ageString))"
    }

    private func backupAgeString(for date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 3600 {
            let minutes = max(1, Int(age / 60))
            return "\(minutes) min ago"
        } else if age < 24 * 3600 {
            let hours = Int(age / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(age / (24 * 3600))
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }

    // MARK: - Backup Restore

    @objc private func restoreFromBackupTapped() {
        let snapshots = BackupService.shared.listSnapshots()
        guard !snapshots.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Backups Available"
            alert.informativeText = "No backup snapshots were found. Snapshots are created automatically every 30 minutes while Magent is running, and you can create one immediately with Back Up Now."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore from Backup"
        alert.informativeText = "Select a snapshot to restore. A safety backup of your current data will be created first, so you can undo this if needed.\n\nMagent will relaunch after restoring."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 24), pullsDown: false)
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for snapshot in snapshots {
            let age = now.timeIntervalSince(snapshot.date)
            let ageString: String
            if age < 3600 {
                ageString = "\(Int(age / 60)) min ago"
            } else if age < 24 * 3600 {
                let hours = Int(age / 3600)
                ageString = "\(hours) hour\(hours == 1 ? "" : "s") ago"
            } else {
                let days = Int(age / (24 * 3600))
                ageString = "\(days) day\(days == 1 ? "" : "s") ago"
            }

            let fileList = snapshot.files.joined(separator: ", ")
            let labelPrefix = snapshot.isSafetySnapshot ? "Safety backup" : "Snapshot"
            let title = "\(labelPrefix): \(dateFormatter.string(from: snapshot.date)) (\(ageString)) - \(fileList)"
            popup.addItem(withTitle: title)
        }

        alert.accessoryView = popup

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let selectedIndex = popup.indexOfSelectedItem
        guard selectedIndex >= 0, selectedIndex < snapshots.count else { return }
        let selected = snapshots[selectedIndex]

        // Confirm once more
        let confirm = NSAlert()
        confirm.messageText = "Are you sure?"
        confirm.informativeText = "This will replace your current threads, settings, and drafts with the snapshot from \(dateFormatter.string(from: selected.date)). A safety backup will be created first."
        confirm.alertStyle = .critical
        confirm.addButton(withTitle: "Restore and Relaunch")
        confirm.addButton(withTitle: "Cancel")

        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try performRestoreAndRelaunch(using: selected)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Restore Failed"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .critical
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    private func performRestoreAndRelaunch(using snapshot: BackupService.Snapshot) throws {
        let restorableFiles = PersistenceService.restorableCriticalFileNames
        ThreadManager.shared.stopSessionMonitor()
        UpdateService.shared.stopPeriodicUpdateChecks()
        BackupService.shared.stopPeriodicSnapshots()
        persistence.cancelPendingThreadSave()
        persistence.blockWrites(for: restorableFiles)

        do {
            try BackupService.shared.restoreSnapshot(snapshot)
            relaunchApp()
        } catch {
            persistence.unblockWrites(for: restorableFiles)
            BackupService.shared.startPeriodicSnapshots()
            UpdateService.shared.startPeriodicUpdateChecks()
            ThreadManager.shared.startSessionMonitor()
            throw error
        }
    }

    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
