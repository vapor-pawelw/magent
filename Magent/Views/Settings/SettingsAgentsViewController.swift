import Cocoa
import MagentCore

final class SettingsAgentsViewController: NSViewController, NSTextViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var claudeCheckbox: NSButton!
    private var codexCheckbox: NSButton!
    private var customCheckbox: NSButton!
    private var defaultAgentSection: NSStackView!
    private var defaultAgentPopup: NSPopUpButton!
    private var customAgentCard: NSView!
    private var customAgentSection: NSStackView!
    private var customAgentCommandTextView: NSTextView!
    private var skipPermissionsCheckbox: NSButton!
    private var sandboxCheckbox: NSButton!
    private var ipcInjectionCheckbox: NSButton!
    private var rememberLastTypeCheckbox: NSButton!
    private var rateLimitDetectionCheckbox: NSButton!
    private var fdaStatusLabel: NSTextField!
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

        let (selectionCard, selectionStack) = createSectionCard(
            title: String(localized: .SettingsStrings.settingsAgentsSelectionTitle),
            description: String(localized: .SettingsStrings.settingsAgentsSelectionDescription)
        )
        stackView.addArrangedSubview(selectionCard)

        let activeLabel = NSTextField(labelWithString: String(localized: .SettingsStrings.settingsAgentsActiveAgents))
        activeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        selectionStack.addArrangedSubview(activeLabel)

        claudeCheckbox = NSButton(checkboxWithTitle: AgentType.claude.displayName, target: self, action: #selector(activeAgentsChanged))
        codexCheckbox = NSButton(checkboxWithTitle: AgentType.codex.displayName, target: self, action: #selector(activeAgentsChanged))
        customCheckbox = NSButton(checkboxWithTitle: AgentType.custom.displayName, target: self, action: #selector(activeAgentsChanged))

        let active = Set(settings.availableActiveAgents)
        claudeCheckbox.state = active.contains(.claude) ? .on : .off
        codexCheckbox.state = active.contains(.codex) ? .on : .off
        customCheckbox.state = active.contains(.custom) ? .on : .off

        selectionStack.addArrangedSubview(claudeCheckbox)
        selectionStack.addArrangedSubview(codexCheckbox)
        selectionStack.addArrangedSubview(customCheckbox)
        selectionStack.setCustomSpacing(10, after: customCheckbox)

        // Default Agent
        defaultAgentSection = NSStackView()
        defaultAgentSection.orientation = .vertical
        defaultAgentSection.alignment = .leading
        defaultAgentSection.spacing = 4

        let defaultLabel = NSTextField(labelWithString: String(localized: .SettingsStrings.settingsAgentsDefaultAgent))
        defaultLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        defaultAgentSection.addArrangedSubview(defaultLabel)

        let defaultDesc = NSTextField(labelWithString: String(localized: .SettingsStrings.settingsAgentsDefaultAgentDescription))
        defaultDesc.font = .systemFont(ofSize: 11)
        defaultDesc.textColor = NSColor(resource: .textSecondary)
        defaultAgentSection.addArrangedSubview(defaultDesc)

        defaultAgentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultAgentPopup.target = self
        defaultAgentPopup.action = #selector(defaultAgentChanged)
        defaultAgentSection.addArrangedSubview(defaultAgentPopup)

        defaultAgentSection.translatesAutoresizingMaskIntoConstraints = false
        selectionStack.addArrangedSubview(defaultAgentSection)
        NSLayoutConstraint.activate([
            defaultAgentSection.widthAnchor.constraint(equalTo: selectionStack.widthAnchor),
            defaultAgentPopup.widthAnchor.constraint(equalTo: defaultAgentSection.widthAnchor),
        ])
        refreshDefaultAgentSection()

        // Remember last type selection
        rememberLastTypeCheckbox = NSButton(
            checkboxWithTitle: String(localized: .SettingsStrings.settingsAgentsRememberLastType),
            target: self,
            action: #selector(rememberLastTypeToggled)
        )
        rememberLastTypeCheckbox.state = settings.rememberLastTypeSelection ? .on : .off
        selectionStack.addArrangedSubview(rememberLastTypeCheckbox)

        let rememberLastTypeDesc = NSTextField(
            wrappingLabelWithString: String(localized: .SettingsStrings.settingsAgentsRememberLastTypeDescription)
        )
        rememberLastTypeDesc.font = .systemFont(ofSize: 11)
        rememberLastTypeDesc.textColor = NSColor(resource: .textSecondary)
        selectionStack.addArrangedSubview(rememberLastTypeDesc)
        NSLayoutConstraint.activate([
            rememberLastTypeDesc.widthAnchor.constraint(equalTo: selectionStack.widthAnchor),
        ])

        // Agent Permissions
        let (permissionsCard, permissionsSection) = createSectionCard(
            title: String(localized: .ConfigurationStrings.permissionsTitle),
            description: String(localized: .ConfigurationStrings.permissionsDescription)
        )
        stackView.addArrangedSubview(permissionsCard)

        skipPermissionsCheckbox = NSButton(
            checkboxWithTitle: String(localized: .ConfigurationStrings.permissionsSkipPrompts),
            target: self,
            action: #selector(permissionsSettingChanged)
        )
        skipPermissionsCheckbox.state = settings.agentSkipPermissions ? .on : .off
        let skipDesc = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsSkipPromptsDescription)
        )
        skipDesc.font = .systemFont(ofSize: 11)
        skipDesc.textColor = NSColor(resource: .textSecondary)
        permissionsSection.addArrangedSubview(skipPermissionsCheckbox)
        permissionsSection.addArrangedSubview(skipDesc)

        sandboxCheckbox = NSButton(
            checkboxWithTitle: String(localized: .ConfigurationStrings.permissionsEnableSandbox),
            target: self,
            action: #selector(permissionsSettingChanged)
        )
        sandboxCheckbox.state = settings.agentSandboxEnabled ? .on : .off
        let sandboxDesc = NSTextField(
            wrappingLabelWithString: String(localized: .ConfigurationStrings.permissionsEnableSandboxDescriptionSettings)
        )
        sandboxDesc.font = .systemFont(ofSize: 11)
        sandboxDesc.textColor = NSColor(resource: .textSecondary)
        permissionsSection.addArrangedSubview(sandboxCheckbox)
        permissionsSection.addArrangedSubview(sandboxDesc)

        let (behaviorCard, behaviorSection) = createSectionCard(
            title: String(localized: .SettingsStrings.settingsAgentsBehaviorTitle),
            description: String(localized: .SettingsStrings.settingsAgentsBehaviorDescription)
        )
        stackView.addArrangedSubview(behaviorCard)

        ipcInjectionCheckbox = NSButton(
            checkboxWithTitle: String(localized: .SettingsStrings.settingsAgentsInjectIPC),
            target: self,
            action: #selector(agentBehaviorSettingChanged)
        )
        ipcInjectionCheckbox.state = settings.ipcPromptInjectionEnabled ? .on : .off
        let ipcDesc = NSTextField(
            wrappingLabelWithString: String(localized: .SettingsStrings.settingsAgentsInjectIPCDescription)
        )
        ipcDesc.font = .systemFont(ofSize: 11)
        ipcDesc.textColor = NSColor(resource: .textSecondary)
        behaviorSection.addArrangedSubview(ipcInjectionCheckbox)
        behaviorSection.addArrangedSubview(ipcDesc)

        rateLimitDetectionCheckbox = NSButton(
            checkboxWithTitle: String(localized: .SettingsStrings.settingsAgentsTrackRateLimits),
            target: self,
            action: #selector(rateLimitDetectionToggled)
        )
        rateLimitDetectionCheckbox.state = settings.enableRateLimitDetection ? .on : .off
        let rateLimitDesc = NSTextField(
            wrappingLabelWithString: String(localized: .SettingsStrings.settingsAgentsTrackRateLimitsDescription)
        )
        rateLimitDesc.font = .systemFont(ofSize: 11)
        rateLimitDesc.textColor = NSColor(resource: .textSecondary)
        behaviorSection.addArrangedSubview(rateLimitDetectionCheckbox)
        behaviorSection.addArrangedSubview(rateLimitDesc)

        // Full Disk Access
        let (fdaCard, fdaSection) = createSectionCard(
            title: String(localized: .ConfigurationStrings.permissionsFullDiskAccessTitle),
            description: String(localized: .ConfigurationStrings.permissionsFullDiskAccessDescriptionLong)
        )
        stackView.addArrangedSubview(fdaCard)

        let fdaStatusRow = NSStackView()
        fdaStatusRow.orientation = .horizontal
        fdaStatusRow.alignment = .centerY
        fdaStatusRow.spacing = 8

        fdaStatusLabel = NSTextField(labelWithString: "")
        fdaStatusLabel.font = .systemFont(ofSize: 12)
        fdaStatusRow.addArrangedSubview(fdaStatusLabel)

        let fdaButton = NSButton(title: String(localized: .CommonStrings.commonOpenSystemSettings), target: self, action: #selector(openFullDiskAccessSettings))
        fdaButton.bezelStyle = .push
        fdaButton.controlSize = .small
        fdaStatusRow.addArrangedSubview(fdaButton)

        fdaSection.addArrangedSubview(fdaStatusRow)

        NSLayoutConstraint.activate([
            defaultDesc.widthAnchor.constraint(equalTo: defaultAgentSection.widthAnchor),
            skipDesc.widthAnchor.constraint(equalTo: permissionsSection.widthAnchor),
            sandboxDesc.widthAnchor.constraint(equalTo: permissionsSection.widthAnchor),
            ipcDesc.widthAnchor.constraint(equalTo: behaviorSection.widthAnchor),
            rateLimitDesc.widthAnchor.constraint(equalTo: behaviorSection.widthAnchor),
        ])

        refreshFDAStatus()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Custom Agent Command (only shown when Custom is active)
        let (customCard, customStack) = createSectionCard(
            title: String(localized: .SettingsStrings.settingsAgentsCustomAgentTitle),
            description: String(localized: .SettingsStrings.settingsAgentsCustomAgentDescription)
        )
        customAgentCard = customCard
        customAgentSection = customStack

        customAgentCommandTextView = createTextEditorSection(
            in: customStack,
            title: String(localized: .SettingsStrings.settingsAgentsCustomAgentCommandTitle),
            description: String(localized: .SettingsStrings.settingsAgentsCustomAgentCommandDescription),
            value: settings.customAgentCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        stackView.addArrangedSubview(customCard)
        customCard.isHidden = !active.contains(.custom)

        // Document view wrapper
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
            selectionCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            permissionsCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            behaviorCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            fdaCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            customCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
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

    private func createTextEditorSection(
        in stackView: NSStackView,
        title: String,
        description: String,
        value: String,
        font: NSFont
    ) -> NSTextView {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 4
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sectionStack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        sectionStack.addArrangedSubview(descLabel)
        sectionStack.setCustomSpacing(8, after: descLabel)

        let textView = NSTextView()
        textView.font = font
        textView.string = value
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let textScrollView = NonCapturingScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)
        let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
        sectionStack.addArrangedSubview(container)

        NSLayoutConstraint.activate([
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            descLabel.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }


    // MARK: - Actions

    @objc private func activeAgentsChanged() {
        var active: [AgentType] = []
        if claudeCheckbox.state == .on { active.append(.claude) }
        if codexCheckbox.state == .on { active.append(.codex) }
        if customCheckbox.state == .on { active.append(.custom) }
        settings.activeAgents = active

        if active.count <= 1 {
            settings.defaultAgentType = nil
        } else if let defaultAgent = settings.defaultAgentType, !active.contains(defaultAgent) {
            settings.defaultAgentType = active.first
        } else if settings.defaultAgentType == nil {
            settings.defaultAgentType = active.first
        }

        refreshDefaultAgentSection()
        customAgentCard.isHidden = !active.contains(.custom)
        try? persistence.saveSettings(settings)
    }

    @objc private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func appDidBecomeActive() {
        refreshFDAStatus()
    }

    private func refreshFDAStatus() {
        let granted = Self.isFullDiskAccessGranted()
        if granted {
            fdaStatusLabel.stringValue = String(localized: .ConfigurationStrings.permissionsFullDiskAccessGranted)
            fdaStatusLabel.textColor = .systemGreen
        } else {
            fdaStatusLabel.stringValue = String(localized: .ConfigurationStrings.permissionsFullDiskAccessNotGranted)
            fdaStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private static func isFullDiskAccessGranted() -> Bool {
        SystemAccessChecker.isFullDiskAccessGranted()
    }

    @objc private func permissionsSettingChanged() {
        settings.agentSkipPermissions = skipPermissionsCheckbox.state == .on
        settings.agentSandboxEnabled = sandboxCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func agentBehaviorSettingChanged() {
        settings.ipcPromptInjectionEnabled = ipcInjectionCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func rememberLastTypeToggled() {
        settings.rememberLastTypeSelection = rememberLastTypeCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func rateLimitDetectionToggled() {
        settings.enableRateLimitDetection = rateLimitDetectionCheckbox.state == .on
        try? persistence.saveSettings(settings)
        ThreadManager.shared.applyRateLimitDetectionSettingChange()
    }

    @objc private func defaultAgentChanged() {
        let active = settings.availableActiveAgents
        let index = defaultAgentPopup.indexOfSelectedItem
        guard index >= 0, index < active.count else { return }
        settings.defaultAgentType = active[index]
        try? persistence.saveSettings(settings)
    }

    private func refreshDefaultAgentSection() {
        let active = settings.availableActiveAgents
        defaultAgentPopup.removeAllItems()
        for agent in active {
            defaultAgentPopup.addItem(withTitle: agent.displayName)
        }

        defaultAgentSection.isHidden = active.count <= 1
        guard active.count > 1 else { return }

        let currentDefault = settings.defaultAgentType.flatMap { active.contains($0) ? $0 : nil } ?? active[0]
        settings.defaultAgentType = currentDefault
        if let idx = active.firstIndex(of: currentDefault) {
            defaultAgentPopup.selectItem(at: idx)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === customAgentCommandTextView {
            settings.customAgentCommand = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}
