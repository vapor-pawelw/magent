import Cocoa
import UserNotifications

final class OnboardingNotificationsView: NSView {

    var showSystemBanners: Bool {
        showBannersCheckbox.state == .on
    }

    var playSoundForCompletion: Bool {
        completionSoundCheckbox.state == .on
    }

    var completionSoundName: String {
        soundPickerPopup.selectedItem?.title ?? String(localized: .CommonStrings.soundPing)
    }

    var showSystemNotificationOnRateLimitLifted: Bool {
        rateLimitSystemNotificationCheckbox.state == .on
    }

    var notifyOnRateLimitLifted: Bool {
        rateLimitNotifyCheckbox.state == .on
    }

    var rateLimitLiftedSoundName: String {
        rateLimitSoundPickerPopup.selectedItem?.title ?? String(localized: .CommonStrings.soundGlass)
    }

    var playSoundOnRateLimitDetected: Bool {
        rateLimitDetectedSoundCheckbox.state == .on
    }

    var rateLimitDetectedSoundName: String {
        rateLimitDetectedSoundPickerPopup.selectedItem?.title ?? String(localized: .CommonStrings.soundSosumi)
    }

    private let notificationStatusDot = NSView()
    private let notificationStatusLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsStatusChecking))
    private let showBannersCheckbox = NSButton(
        checkboxWithTitle: String(localized: .NotificationStrings.notificationsShowSystemBanners),
        target: nil,
        action: nil
    )
    private let completionSoundCheckbox = NSButton(
        checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlaySound),
        target: nil,
        action: nil
    )
    private let soundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var soundPickerRow: NSStackView!
    private let rateLimitSystemNotificationCheckbox = NSButton(
        checkboxWithTitle: String(localized: .NotificationStrings.notificationsShowRateLimitLiftedNotification),
        target: nil,
        action: nil
    )
    private let rateLimitNotifyCheckbox = NSButton(
        checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlayRateLimitLiftedSound),
        target: nil,
        action: nil
    )
    private let rateLimitSoundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rateLimitSoundPickerRow: NSStackView!
    private let rateLimitDetectedSoundCheckbox = NSButton(
        checkboxWithTitle: String(localized: .NotificationStrings.notificationsPlayRateLimitDetectedSound),
        target: nil,
        action: nil
    )
    private let rateLimitDetectedSoundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rateLimitDetectedSoundPickerRow: NSStackView!
    private var appActiveObserver: NSObjectProtocol?
    private var soundPreviewPlayer: NSSound?

    override var isHidden: Bool {
        didSet {
            if !isHidden { refreshNotificationStatus() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: String(localized: .ConfigurationStrings.configurationStepNotifications))
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        // Permission status row
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        notificationStatusDot.wantsLayer = true
        notificationStatusDot.layer?.cornerRadius = 5
        notificationStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            notificationStatusDot.widthAnchor.constraint(equalToConstant: 10),
            notificationStatusDot.heightAnchor.constraint(equalToConstant: 10),
        ])
        statusRow.addArrangedSubview(notificationStatusDot)

        notificationStatusLabel.font = .systemFont(ofSize: 12)
        statusRow.addArrangedSubview(notificationStatusLabel)

        let openNotifButton = NSButton(
            title: String(localized: .NotificationStrings.notificationsOpenSystemSettings),
            target: self,
            action: #selector(openNotificationSettings)
        )
        openNotifButton.bezelStyle = .accessoryBarAction
        openNotifButton.controlSize = .small
        openNotifButton.font = .systemFont(ofSize: 11)

        // --- Agent Completion card ---
        let (completionCard, completionStack) = createSectionCard(
            title: String(localized: .NotificationStrings.notificationsAgentCompletionTitle),
            description: String(localized: .NotificationStrings.notificationsAgentCompletionDescriptionOnboarding)
        )

        showBannersCheckbox.state = .on
        completionStack.addArrangedSubview(showBannersCheckbox)

        completionSoundCheckbox.state = .on
        completionSoundCheckbox.target = self
        completionSoundCheckbox.action = #selector(completionSoundToggled)
        completionStack.addArrangedSubview(completionSoundCheckbox)

        soundPickerRow = NSStackView()
        soundPickerRow.orientation = .horizontal
        soundPickerRow.alignment = .centerY
        soundPickerRow.spacing = 8
        soundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let soundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
        soundLabel.font = .systemFont(ofSize: 12)
        soundPickerRow.addArrangedSubview(soundLabel)

        soundPickerPopup.controlSize = .small
        soundPickerPopup.font = .systemFont(ofSize: 12)
        soundPickerPopup.target = self
        soundPickerPopup.action = #selector(soundPickerChanged)
        populateSoundPicker()
        soundPickerRow.addArrangedSubview(soundPickerPopup)
        completionStack.addArrangedSubview(soundPickerRow)

        // --- Rate Limits card ---
        let (rlCard, rlStack) = createSectionCard(
            title: String(localized: .NotificationStrings.notificationsRateLimitsTitle),
            description: String(localized: .NotificationStrings.notificationsRateLimitsDescriptionOnboarding)
        )

        rateLimitSystemNotificationCheckbox.state = .on
        rlStack.addArrangedSubview(rateLimitSystemNotificationCheckbox)

        rateLimitNotifyCheckbox.state = .on
        rateLimitNotifyCheckbox.target = self
        rateLimitNotifyCheckbox.action = #selector(rateLimitNotifyToggled)
        rlStack.addArrangedSubview(rateLimitNotifyCheckbox)

        rateLimitSoundPickerRow = NSStackView()
        rateLimitSoundPickerRow.orientation = .horizontal
        rateLimitSoundPickerRow.alignment = .centerY
        rateLimitSoundPickerRow.spacing = 8
        rateLimitSoundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let rateLimitSoundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
        rateLimitSoundLabel.font = .systemFont(ofSize: 12)
        rateLimitSoundPickerRow.addArrangedSubview(rateLimitSoundLabel)

        rateLimitSoundPickerPopup.controlSize = .small
        rateLimitSoundPickerPopup.font = .systemFont(ofSize: 12)
        rateLimitSoundPickerPopup.target = self
        rateLimitSoundPickerPopup.action = #selector(rateLimitSoundPickerChanged)
        populateRateLimitSoundPicker()
        rateLimitSoundPickerRow.addArrangedSubview(rateLimitSoundPickerPopup)
        rlStack.addArrangedSubview(rateLimitSoundPickerRow)

        rateLimitDetectedSoundCheckbox.state = .on
        rateLimitDetectedSoundCheckbox.target = self
        rateLimitDetectedSoundCheckbox.action = #selector(rateLimitDetectedSoundToggled)
        rlStack.addArrangedSubview(rateLimitDetectedSoundCheckbox)

        rateLimitDetectedSoundPickerRow = NSStackView()
        rateLimitDetectedSoundPickerRow.orientation = .horizontal
        rateLimitDetectedSoundPickerRow.alignment = .centerY
        rateLimitDetectedSoundPickerRow.spacing = 8
        rateLimitDetectedSoundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let rateLimitDetectedSoundLabel = NSTextField(labelWithString: String(localized: .NotificationStrings.notificationsSoundLabel))
        rateLimitDetectedSoundLabel.font = .systemFont(ofSize: 12)
        rateLimitDetectedSoundPickerRow.addArrangedSubview(rateLimitDetectedSoundLabel)

        rateLimitDetectedSoundPickerPopup.controlSize = .small
        rateLimitDetectedSoundPickerPopup.font = .systemFont(ofSize: 12)
        rateLimitDetectedSoundPickerPopup.target = self
        rateLimitDetectedSoundPickerPopup.action = #selector(rateLimitDetectedSoundPickerChanged)
        populateRateLimitDetectedSoundPicker()
        rateLimitDetectedSoundPickerRow.addArrangedSubview(rateLimitDetectedSoundPickerPopup)
        rlStack.addArrangedSubview(rateLimitDetectedSoundPickerRow)

        let stack = NSStackView(views: [
            titleLabel,
            statusRow, openNotifButton,
            completionCard,
            rlCard,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.setCustomSpacing(16, after: openNotifButton)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            completionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rlCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        refreshNotificationStatus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            appActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isHidden else { return }
                self.refreshNotificationStatus()
            }
        } else if let observer = appActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            appActiveObserver = nil
        }
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

    // MARK: - Sound Pickers

    private func populateSoundPicker() {
        soundPickerPopup.removeAllItems()
        let soundNames = SystemAccessChecker.systemSoundNames()
        for name in soundNames {
            soundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: String(localized: .CommonStrings.soundPing)) {
            soundPickerPopup.selectItem(at: index)
        }
    }

    private func refreshNotificationStatus() {
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

                self.showBannersCheckbox.isEnabled = authorized
                self.completionSoundCheckbox.isEnabled = authorized
                self.soundPickerPopup.isEnabled = authorized
                self.rateLimitSystemNotificationCheckbox.isEnabled = authorized
                self.rateLimitNotifyCheckbox.isEnabled = authorized
                self.rateLimitSoundPickerPopup.isEnabled = authorized
                self.rateLimitDetectedSoundCheckbox.isEnabled = authorized
                self.rateLimitDetectedSoundPickerPopup.isEnabled = authorized
                self.showBannersCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.completionSoundCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.soundPickerRow.alphaValue = authorized ? 1.0 : 0.5
                self.rateLimitSystemNotificationCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.rateLimitNotifyCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.rateLimitSoundPickerRow.alphaValue = authorized ? 1.0 : 0.5
                self.rateLimitDetectedSoundCheckbox.alphaValue = authorized ? 1.0 : 0.5
                self.rateLimitDetectedSoundPickerRow.alphaValue = authorized ? 1.0 : 0.5
            }
        }
    }

    private func populateRateLimitSoundPicker() {
        rateLimitSoundPickerPopup.removeAllItems()
        let soundNames = SystemAccessChecker.systemSoundNames()
        for name in soundNames {
            rateLimitSoundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: "Glass") {
            rateLimitSoundPickerPopup.selectItem(at: index)
        }
    }

    private func populateRateLimitDetectedSoundPicker() {
        rateLimitDetectedSoundPickerPopup.removeAllItems()
        let soundNames = SystemAccessChecker.systemSoundNames()
        for name in soundNames {
            rateLimitDetectedSoundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: "Sosumi") {
            rateLimitDetectedSoundPickerPopup.selectItem(at: index)
        }
    }

    @objc private func rateLimitNotifyToggled() {
        rateLimitSoundPickerRow.isHidden = rateLimitNotifyCheckbox.state != .on
        if rateLimitNotifyCheckbox.state != .on {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
    }

    @objc private func rateLimitSoundPickerChanged() {
        guard let selectedName = rateLimitSoundPickerPopup.selectedItem?.title else { return }
        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func rateLimitDetectedSoundToggled() {
        rateLimitDetectedSoundPickerRow.isHidden = rateLimitDetectedSoundCheckbox.state != .on
        if rateLimitDetectedSoundCheckbox.state != .on {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
    }

    @objc private func rateLimitDetectedSoundPickerChanged() {
        guard let selectedName = rateLimitDetectedSoundPickerPopup.selectedItem?.title else { return }
        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func completionSoundToggled() {
        soundPickerRow.isHidden = completionSoundCheckbox.state != .on
        if completionSoundCheckbox.state != .on {
            soundPreviewPlayer?.stop()
            soundPreviewPlayer = nil
        }
    }

    @objc private func soundPickerChanged() {
        guard let selectedName = soundPickerPopup.selectedItem?.title else { return }
        soundPreviewPlayer?.stop()
        if let sound = NSSound(named: NSSound.Name(selectedName)) {
            soundPreviewPlayer = sound
            sound.play()
        }
    }

    @objc private func openNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
    }
}
