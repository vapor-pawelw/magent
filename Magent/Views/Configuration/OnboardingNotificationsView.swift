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
        soundPickerPopup.selectedItem?.title ?? "Ping"
    }

    private let notificationStatusDot = NSView()
    private let notificationStatusLabel = NSTextField(labelWithString: "Notifications: Checking...")
    private let showBannersCheckbox = NSButton(
        checkboxWithTitle: "Show system banners",
        target: nil,
        action: nil
    )
    private let completionSoundCheckbox = NSButton(
        checkboxWithTitle: "Play sound for completion notifications",
        target: nil,
        action: nil
    )
    private let soundPickerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var soundPickerRow: NSStackView!
    private var appActiveObserver: NSObjectProtocol?
    private var soundPreviewPlayer: NSSound?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Notifications")
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let descLabel = NSTextField(
            wrappingLabelWithString: "When an agent finishes a command, Magent sends a system notification and moves the thread to the top of its section."
        )
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)

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
            title: "Open Notification Settings",
            target: self,
            action: #selector(openNotificationSettings)
        )
        openNotifButton.bezelStyle = .accessoryBarAction
        openNotifButton.controlSize = .small
        openNotifButton.font = .systemFont(ofSize: 11)

        // Behavior section
        let behaviorLabel = NSTextField(labelWithString: "Behavior")
        behaviorLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        showBannersCheckbox.state = .on

        completionSoundCheckbox.state = .on
        completionSoundCheckbox.target = self
        completionSoundCheckbox.action = #selector(completionSoundToggled)

        // Sound picker row
        soundPickerRow = NSStackView()
        soundPickerRow.orientation = .horizontal
        soundPickerRow.alignment = .centerY
        soundPickerRow.spacing = 8
        soundPickerRow.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)

        let soundLabel = NSTextField(labelWithString: "Sound:")
        soundLabel.font = .systemFont(ofSize: 12)
        soundPickerRow.addArrangedSubview(soundLabel)

        soundPickerPopup.controlSize = .small
        soundPickerPopup.font = .systemFont(ofSize: 12)
        soundPickerPopup.target = self
        soundPickerPopup.action = #selector(soundPickerChanged)
        populateSoundPicker()
        soundPickerRow.addArrangedSubview(soundPickerPopup)

        let stack = NSStackView(views: [
            titleLabel, descLabel,
            statusRow, openNotifButton,
            behaviorLabel,
            showBannersCheckbox,
            completionSoundCheckbox,
            soundPickerRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.setCustomSpacing(16, after: openNotifButton)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    private func populateSoundPicker() {
        soundPickerPopup.removeAllItems()
        let soundNames = SystemAccessChecker.systemSoundNames()
        for name in soundNames {
            soundPickerPopup.addItem(withTitle: name)
        }
        if let index = soundNames.firstIndex(of: "Ping") {
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
