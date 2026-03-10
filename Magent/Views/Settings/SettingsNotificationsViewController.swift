import Cocoa
import UserNotifications
import MagentCore

final class SettingsNotificationsViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var notificationStatusDot: NSView!
    private var notificationStatusLabel: NSTextField!
    private var showBannersCheckbox: NSButton!
    private var completionSoundCheckbox: NSButton!
    private var autoReorderOnCompletionCheckbox: NSButton!
    private var dockCompletionAttentionCheckbox: NSButton!
    private var soundPickerPopup: NSPopUpButton!
    private var soundPickerRow: NSStackView!
    private var rateLimitSystemNotificationCheckbox: NSButton!
    private var rateLimitNotifyCheckbox: NSButton!
    private var rateLimitSoundPickerPopup: NSPopUpButton!
    private var rateLimitSoundPickerRow: NSStackView!
    private var rateLimitDetectedSoundCheckbox: NSButton!
    private var rateLimitDetectedSoundPickerPopup: NSPopUpButton!
    private var rateLimitDetectedSoundPickerRow: NSStackView!
    private var appActiveObserver: NSObjectProtocol?
    private var soundPreviewPlayer: NSSound?

    // Cards for enabling/disabling based on permission
    private var completionCard: NSView!
    private var rateLimitCard: NSView!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Permission status section (no card)
        let permissionSection = NSStackView()
        permissionSection.orientation = .vertical
        permissionSection.alignment = .leading
        permissionSection.spacing = 6

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

        notificationStatusLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsStatusChecking))
        notificationStatusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(notificationStatusLabel)

        permissionSection.addArrangedSubview(statusRow)

        let openNotifSettingsButton = NSButton(
            title: String(localized: .NotificationStrings.notificationsOpenSystemSettings),
            target: self,
            action: #selector(openSystemNotificationSettings)
        )
        openNotifSettingsButton.bezelStyle = .accessoryBarAction
        openNotifSettingsButton.controlSize = .small
        openNotifSettingsButton.font = .systemFont(ofSize: 11)
        permissionSection.addArrangedSubview(openNotifSettingsButton)

        permissionSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(permissionSection)

        // --- Agent Completion card ---
        let (agentCard, agentStack) = createSectionCard(
            title: String(localized: .NotificationStrings.notificationsAgentCompletionTitle),
            description: String(localized: .NotificationStrings.notificationsAgentCompletionDescriptionSettings)
        )
        completionCard = agentCard

        showBannersCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsShowSystemBanners),
            target: self,
            action: #selector(showBannersToggled)
        )
        showBannersCheckbox.state = settings.showSystemBanners ? .on : .off
        agentStack.addArrangedSubview(showBannersCheckbox)

        completionSoundCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlaySound),
            target: self,
            action: #selector(completionSoundToggled)
        )
        completionSoundCheckbox.state = settings.playSoundForAgentCompletion ? .on : .off
        agentStack.addArrangedSubview(completionSoundCheckbox)

        soundPickerRow = NSStackView()
        soundPickerRow.orientation = .horizontal
        soundPickerRow.alignment = .centerY
        soundPickerRow.spacing = 8

        let soundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
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
        soundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        agentStack.addArrangedSubview(soundPickerRow)

        autoReorderOnCompletionCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsMoveCompletedThreadsToTop),
            target: self,
            action: #selector(autoReorderOnCompletionToggled)
        )
        autoReorderOnCompletionCheckbox.state = settings.autoReorderThreadsOnAgentCompletion ? .on : .off
        agentStack.addArrangedSubview(autoReorderOnCompletionCheckbox)

        dockCompletionAttentionCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsBounceAndBadgeDockIcon),
            target: self,
            action: #selector(dockCompletionAttentionToggled)
        )
        dockCompletionAttentionCheckbox.state = settings.showDockBadgeAndBounceForUnreadCompletions ? .on : .off
        agentStack.addArrangedSubview(dockCompletionAttentionCheckbox)

        stackView.addArrangedSubview(agentCard)

        // --- Rate Limits card ---
        let (rlCard, rlStack) = createSectionCard(
            title: String(localized: .NotificationStrings.notificationsRateLimitsTitle),
            description: String(localized: .NotificationStrings.notificationsRateLimitsDescriptionSettings)
        )
        rateLimitCard = rlCard

        rateLimitSystemNotificationCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsShowRateLimitLiftedNotification),
            target: self,
            action: #selector(rateLimitSystemNotificationToggled)
        )
        rateLimitSystemNotificationCheckbox.state = settings.showSystemNotificationOnRateLimitLifted ? .on : .off
        rlStack.addArrangedSubview(rateLimitSystemNotificationCheckbox)

        rateLimitNotifyCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlayRateLimitLiftedSound),
            target: self,
            action: #selector(rateLimitNotifyToggled)
        )
        rateLimitNotifyCheckbox.state = settings.notifyOnRateLimitLifted ? .on : .off
        rlStack.addArrangedSubview(rateLimitNotifyCheckbox)

        rateLimitSoundPickerRow = NSStackView()
        rateLimitSoundPickerRow.orientation = .horizontal
        rateLimitSoundPickerRow.alignment = .centerY
        rateLimitSoundPickerRow.spacing = 8

        let rateLimitSoundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
        rateLimitSoundLabel.font = .systemFont(ofSize: 12)
        rateLimitSoundPickerRow.addArrangedSubview(rateLimitSoundLabel)

        rateLimitSoundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        rateLimitSoundPickerPopup.controlSize = .small
        rateLimitSoundPickerPopup.font = .systemFont(ofSize: 12)
        rateLimitSoundPickerPopup.target = self
        rateLimitSoundPickerPopup.action = #selector(rateLimitSoundPickerChanged)
        populateRateLimitSoundPicker()
        rateLimitSoundPickerRow.addArrangedSubview(rateLimitSoundPickerPopup)

        rateLimitSoundPickerRow.isHidden = !settings.notifyOnRateLimitLifted
        rateLimitSoundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        rlStack.addArrangedSubview(rateLimitSoundPickerRow)

        rateLimitDetectedSoundCheckbox = NSButton(
            checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlayRateLimitDetectedSound),
            target: self,
            action: #selector(rateLimitDetectedSoundToggled)
        )
        rateLimitDetectedSoundCheckbox.state = settings.playSoundOnRateLimitDetected ? .on : .off
        rlStack.addArrangedSubview(rateLimitDetectedSoundCheckbox)

        rateLimitDetectedSoundPickerRow = NSStackView()
        rateLimitDetectedSoundPickerRow.orientation = .horizontal
        rateLimitDetectedSoundPickerRow.alignment = .centerY
        rateLimitDetectedSoundPickerRow.spacing = 8

        let rateLimitDetectedSoundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
        rateLimitDetectedSoundLabel.font = .systemFont(ofSize: 12)
        rateLimitDetectedSoundPickerRow.addArrangedSubview(rateLimitDetectedSoundLabel)

        rateLimitDetectedSoundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        rateLimitDetectedSoundPickerPopup.controlSize = .small
        rateLimitDetectedSoundPickerPopup.font = .systemFont(ofSize: 12)
        rateLimitDetectedSoundPickerPopup.target = self
        rateLimitDetectedSoundPickerPopup.action = #selector(rateLimitDetectedSoundPickerChanged)
        populateRateLimitDetectedSoundPicker()
        rateLimitDetectedSoundPickerRow.addArrangedSubview(rateLimitDetectedSoundPickerPopup)

        rateLimitDetectedSoundPickerRow.isHidden = !settings.playSoundOnRateLimitDetected
        rateLimitDetectedSoundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        rlStack.addArrangedSubview(rateLimitDetectedSoundPickerRow)

        stackView.addArrangedSubview(rlCard)

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            permissionSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            agentCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            rlCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
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
            Task { @MainActor [weak self] in
                self?.refreshNotificationPermissionStatus()
            }
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

    // MARK: - Section Card Helper

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
            let descLabel = NSTextField(wrappingLabelWithString: description)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = NSColor(resource: .textSecondary)
            content.addArrangedSubview(descLabel)
            content.setCustomSpacing(12, after: descLabel)
            NSLayoutConstraint.activate([
                descLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
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
        persistSettings()

        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    private func populateRateLimitSoundPicker() {
        rateLimitSoundPickerPopup.removeAllItems()
        let soundNames = Self.systemSoundNames()
        for name in soundNames {
            rateLimitSoundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: settings.rateLimitLiftedSoundName) {
            rateLimitSoundPickerPopup.selectItem(at: index)
        }
    }

    private func populateRateLimitDetectedSoundPicker() {
        rateLimitDetectedSoundPickerPopup.removeAllItems()
        let soundNames = Self.systemSoundNames()
        for name in soundNames {
            rateLimitDetectedSoundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: settings.rateLimitDetectedSoundName) {
            rateLimitDetectedSoundPickerPopup.selectItem(at: index)
        }
    }

    @objc private func rateLimitSoundPickerChanged() {
        guard let selectedName = rateLimitSoundPickerPopup.selectedItem?.title else { return }
        settings.rateLimitLiftedSoundName = selectedName
        persistSettings()

        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func rateLimitDetectedSoundPickerChanged() {
        guard let selectedName = rateLimitDetectedSoundPickerPopup.selectedItem?.title else { return }
        settings.rateLimitDetectedSoundName = selectedName
        persistSettings()

        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func rateLimitNotifyToggled() {
        settings.notifyOnRateLimitLifted = rateLimitNotifyCheckbox.state == .on
        rateLimitSoundPickerRow.isHidden = !settings.notifyOnRateLimitLifted
        if !settings.notifyOnRateLimitLifted {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
        persistSettings()
    }

    @objc private func rateLimitSystemNotificationToggled() {
        settings.showSystemNotificationOnRateLimitLifted = rateLimitSystemNotificationCheckbox.state == .on
        persistSettings()
    }

    @objc private func rateLimitDetectedSoundToggled() {
        settings.playSoundOnRateLimitDetected = rateLimitDetectedSoundCheckbox.state == .on
        rateLimitDetectedSoundPickerRow.isHidden = !settings.playSoundOnRateLimitDetected
        if !settings.playSoundOnRateLimitDetected {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
        persistSettings()
    }

    @objc private func completionSoundToggled() {
        settings.playSoundForAgentCompletion = completionSoundCheckbox.state == .on
        soundPickerRow.isHidden = !settings.playSoundForAgentCompletion
        if !settings.playSoundForAgentCompletion {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
        persistSettings()
    }

    @objc private func showBannersToggled() {
        settings.showSystemBanners = showBannersCheckbox.state == .on
        persistSettings()
    }

    @objc private func autoReorderOnCompletionToggled() {
        settings.autoReorderThreadsOnAgentCompletion = autoReorderOnCompletionCheckbox.state == .on
        persistSettings()
    }

    @objc private func dockCompletionAttentionToggled() {
        settings.showDockBadgeAndBounceForUnreadCompletions = dockCompletionAttentionCheckbox.state == .on
        persistSettings(refreshDockBadge: true)
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
                    ? String(localized: .NotificationStrings.notificationsStatusEnabled)
                    : String(localized: .NotificationStrings.notificationsStatusDisabled)
                self.notificationStatusLabel.textColor = authorized
                    ? .labelColor
                    : .systemRed

                let alpha: CGFloat = authorized ? 1.0 : 0.5
                self.completionCard.alphaValue = 1.0
                self.rateLimitCard.alphaValue = alpha

                self.showBannersCheckbox.isEnabled = authorized
                self.completionSoundCheckbox.isEnabled = authorized
                self.soundPickerPopup.isEnabled = authorized
                self.autoReorderOnCompletionCheckbox.isEnabled = true
                self.dockCompletionAttentionCheckbox.isEnabled = true
                self.rateLimitSystemNotificationCheckbox.isEnabled = authorized
                self.rateLimitNotifyCheckbox.isEnabled = authorized
                self.rateLimitSoundPickerPopup.isEnabled = authorized
                self.rateLimitDetectedSoundCheckbox.isEnabled = authorized && self.settings.enableRateLimitDetection
                self.rateLimitDetectedSoundPickerPopup.isEnabled = authorized && self.settings.enableRateLimitDetection
            }
        }
    }

    private func persistSettings(refreshDockBadge: Bool = false) {
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)

        guard refreshDockBadge else { return }
        Task { @MainActor in
            ThreadManager.shared.updateDockBadge()
        }
    }
}
