import Cocoa
import UserNotifications

final class SettingsNotificationsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var notificationStatusDot: NSView!
    private var notificationStatusLabel: NSTextField!
    private var showBannersCheckbox: NSButton!
    private var completionSoundCheckbox: NSButton!
    private var soundPickerPopup: NSPopUpButton!
    private var soundPickerRow: NSStackView!
    private var appActiveObserver: NSObjectProtocol?
    private var soundPreviewPlayer: NSSound?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Description
        let notificationsDesc = NSTextField(
            wrappingLabelWithString: "When an agent finishes a command, Magent sends a system notification and moves the thread to the top of its section."
        )
        notificationsDesc.font = .systemFont(ofSize: 11)
        notificationsDesc.textColor = NSColor(resource: .textSecondary)
        notificationsDesc.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(notificationsDesc)
        NSLayoutConstraint.activate([
            notificationsDesc.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Permission status section
        let permissionSection = NSStackView()
        permissionSection.orientation = .vertical
        permissionSection.alignment = .leading
        permissionSection.spacing = 6

        let permissionLabel = NSTextField(labelWithString: "Permission Status")
        permissionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionSection.addArrangedSubview(permissionLabel)

        // Permission status row
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        notificationStatusDot = NSView()
        notificationStatusDot.wantsLayer = true
        notificationStatusDot.layer?.cornerRadius = 5
        notificationStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notificationStatusDot.widthAnchor.constraint(equalToConstant: 10),
            notificationStatusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        statusRow.addArrangedSubview(notificationStatusDot)

        notificationStatusLabel = NSTextField(labelWithString: "Notifications: Checking...")
        notificationStatusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(notificationStatusLabel)

        permissionSection.addArrangedSubview(statusRow)

        // Open Notification Settings button
        let openNotifSettingsButton = NSButton(
            title: "Open Notification Settings",
            target: self,
            action: #selector(openSystemNotificationSettings)
        )
        openNotifSettingsButton.bezelStyle = .accessoryBarAction
        openNotifSettingsButton.controlSize = .small
        openNotifSettingsButton.font = .systemFont(ofSize: 11)
        permissionSection.addArrangedSubview(openNotifSettingsButton)

        permissionSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(permissionSection)
        NSLayoutConstraint.activate([
            permissionSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Behavior section
        let behaviorSection = NSStackView()
        behaviorSection.orientation = .vertical
        behaviorSection.alignment = .leading
        behaviorSection.spacing = 6

        let behaviorLabel = NSTextField(labelWithString: "Behavior")
        behaviorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        behaviorSection.addArrangedSubview(behaviorLabel)

        // Show system banners checkbox
        showBannersCheckbox = NSButton(
            checkboxWithTitle: "Show system banners",
            target: self,
            action: #selector(showBannersToggled)
        )
        showBannersCheckbox.state = settings.showSystemBanners ? .on : .off
        behaviorSection.addArrangedSubview(showBannersCheckbox)

        completionSoundCheckbox = NSButton(
            checkboxWithTitle: "Play sound for completion notifications",
            target: self,
            action: #selector(completionSoundToggled)
        )
        completionSoundCheckbox.state = settings.playSoundForAgentCompletion ? .on : .off
        behaviorSection.addArrangedSubview(completionSoundCheckbox)

        // Sound picker row
        soundPickerRow = NSStackView()
        soundPickerRow.orientation = .horizontal
        soundPickerRow.alignment = .centerY
        soundPickerRow.spacing = 8

        let soundLabel = NSTextField(labelWithString: "Sound:")
        soundLabel.font = .systemFont(ofSize: 12)
        soundPickerRow.addArrangedSubview(soundLabel)

        soundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        soundPickerPopup.controlSize = .small
        soundPickerPopup.font = .systemFont(ofSize: 12)
        soundPickerPopup.target = self
        soundPickerPopup.action = #selector(soundPickerChanged)
        populateSoundPicker()
        soundPickerRow.addArrangedSubview(soundPickerPopup)

        soundPickerRow.isHidden = !settings.playSoundForAgentCompletion
        // Indent to align with checkbox label
        soundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        behaviorSection.addArrangedSubview(soundPickerRow)

        behaviorSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(behaviorSection)
        NSLayoutConstraint.activate([
            behaviorSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshNotificationPermissionStatus()
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotificationPermissionStatus()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        soundPreviewPlayer?.stop()
        soundPreviewPlayer = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
        appActiveObserver = nil
    }

    // MARK: - Actions

    private func populateSoundPicker() {
        soundPickerPopup.removeAllItems()
        let soundNames = Self.systemSoundNames()
        for name in soundNames {
            soundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: settings.agentCompletionSoundName) {
            soundPickerPopup.selectItem(at: index)
        }
    }

    static func systemSoundNames() -> [String] {
        SystemAccessChecker.systemSoundNames()
    }

    @objc private func soundPickerChanged() {
        guard let selectedName = soundPickerPopup.selectedItem?.title else { return }
        settings.agentCompletionSoundName = selectedName
        try? persistence.saveSettings(settings)

        // Stop any currently playing preview
        soundPreviewPlayer?.stop()
        // Play the selected sound as preview
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func completionSoundToggled() {
        settings.playSoundForAgentCompletion = completionSoundCheckbox.state == .on
        soundPickerRow.isHidden = !settings.playSoundForAgentCompletion
        if !settings.playSoundForAgentCompletion {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
        try? persistence.saveSettings(settings)
    }

    @objc private func showBannersToggled() {
        settings.showSystemBanners = showBannersCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func openSystemNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshNotificationPermissionStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] notifSettings in
            let authorized = notifSettings.authorizationStatus == .authorized
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatusDot.layer?.backgroundColor = authorized
                    ? NSColor.systemGreen.cgColor
                    : NSColor.systemRed.cgColor
                self.notificationStatusLabel.stringValue = authorized
                    ? "Notifications: Enabled"
                    : "Notifications: Disabled \u{2014} enable in System Settings"
                self.notificationStatusLabel.textColor = authorized
                    ? .labelColor
                    : .systemRed

                self.showBannersCheckbox.isEnabled = authorized
                self.completionSoundCheckbox.isEnabled = authorized
                self.soundPickerPopup.isEnabled = authorized
                self.showBannersCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.completionSoundCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.soundPickerRow.alphaValue = authorized ? 1.0 : 0.5
            }
        }
    }
}
