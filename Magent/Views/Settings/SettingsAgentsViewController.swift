import Cocoa

final class SettingsAgentsViewController: NSViewController, NSTextViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var claudeCheckbox: NSButton!
    private var codexCheckbox: NSButton!
    private var customCheckbox: NSButton!
    private var defaultAgentSection: NSStackView!
    private var defaultAgentPopup: NSPopUpButton!
    private var customAgentSection: NSStackView!
    private var customAgentCommandTextView: NSTextView!
    private var skipPermissionsCheckbox: NSButton!
    private var sandboxCheckbox: NSButton!
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
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Active Agents
        let agentsSection = NSStackView()
        agentsSection.orientation = .vertical
        agentsSection.alignment = .leading
        agentsSection.spacing = 6

        let agentsLabel = NSTextField(labelWithString: "Active Agents")
        agentsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        agentsSection.addArrangedSubview(agentsLabel)

        let agentsDesc = NSTextField(
            wrappingLabelWithString: "Enable agents that can be launched in new chats. If multiple are enabled, a default can be chosen."
        )
        agentsDesc.font = .systemFont(ofSize: 11)
        agentsDesc.textColor = NSColor(resource: .textSecondary)
        agentsSection.addArrangedSubview(agentsDesc)

        claudeCheckbox = NSButton(checkboxWithTitle: AgentType.claude.displayName, target: self, action: #selector(activeAgentsChanged))
        codexCheckbox = NSButton(checkboxWithTitle: AgentType.codex.displayName, target: self, action: #selector(activeAgentsChanged))
        customCheckbox = NSButton(checkboxWithTitle: AgentType.custom.displayName, target: self, action: #selector(activeAgentsChanged))

        let active = Set(settings.availableActiveAgents)
        claudeCheckbox.state = active.contains(.claude) ? .on : .off
        codexCheckbox.state = active.contains(.codex) ? .on : .off
        customCheckbox.state = active.contains(.custom) ? .on : .off

        agentsSection.addArrangedSubview(claudeCheckbox)
        agentsSection.addArrangedSubview(codexCheckbox)
        agentsSection.addArrangedSubview(customCheckbox)

        agentsSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(agentsSection)
        NSLayoutConstraint.activate([
            agentsSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Default Agent
        defaultAgentSection = NSStackView()
        defaultAgentSection.orientation = .vertical
        defaultAgentSection.alignment = .leading
        defaultAgentSection.spacing = 4

        let defaultLabel = NSTextField(labelWithString: "Default Agent")
        defaultLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        defaultAgentSection.addArrangedSubview(defaultLabel)

        let defaultDesc = NSTextField(labelWithString: "Used when no agent is explicitly selected for a new chat.")
        defaultDesc.font = .systemFont(ofSize: 11)
        defaultDesc.textColor = NSColor(resource: .textSecondary)
        defaultAgentSection.addArrangedSubview(defaultDesc)

        defaultAgentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        defaultAgentPopup.target = self
        defaultAgentPopup.action = #selector(defaultAgentChanged)
        defaultAgentSection.addArrangedSubview(defaultAgentPopup)

        defaultAgentSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(defaultAgentSection)
        NSLayoutConstraint.activate([
            defaultAgentSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])
        refreshDefaultAgentSection()

        // Agent Permissions
        let permissionsSection = NSStackView()
        permissionsSection.orientation = .vertical
        permissionsSection.alignment = .leading
        permissionsSection.spacing = 6

        let permissionsLabel = NSTextField(labelWithString: "Agent Permissions")
        permissionsLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionsSection.addArrangedSubview(permissionsLabel)

        let permissionsDesc = NSTextField(
            wrappingLabelWithString: "Control how agents handle permissions and sandboxing. Only applies to Claude and Codex."
        )
        permissionsDesc.font = .systemFont(ofSize: 11)
        permissionsDesc.textColor = NSColor(resource: .textSecondary)
        permissionsSection.addArrangedSubview(permissionsDesc)

        skipPermissionsCheckbox = NSButton(
            checkboxWithTitle: "Skip permission prompts",
            target: self,
            action: #selector(permissionsSettingChanged)
        )
        skipPermissionsCheckbox.state = settings.agentSkipPermissions ? .on : .off
        let skipDesc = NSTextField(
            wrappingLabelWithString: "Agents run without asking for approval. Claude uses --dangerously-skip-permissions, Codex uses --yolo."
        )
        skipDesc.font = .systemFont(ofSize: 11)
        skipDesc.textColor = NSColor(resource: .textSecondary)
        permissionsSection.addArrangedSubview(skipPermissionsCheckbox)
        permissionsSection.addArrangedSubview(skipDesc)

        sandboxCheckbox = NSButton(
            checkboxWithTitle: "Enable sandbox",
            target: self,
            action: #selector(permissionsSettingChanged)
        )
        sandboxCheckbox.state = settings.agentSandboxEnabled ? .on : .off
        let sandboxDesc = NSTextField(
            wrappingLabelWithString: "Restrict agent filesystem access to the workspace. Codex uses --full-auto. Only applies to Codex (Claude sandboxes by default when permissions are not skipped)."
        )
        sandboxDesc.font = .systemFont(ofSize: 11)
        sandboxDesc.textColor = NSColor(resource: .textSecondary)
        permissionsSection.addArrangedSubview(sandboxCheckbox)
        permissionsSection.addArrangedSubview(sandboxDesc)

        permissionsSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(permissionsSection)
        NSLayoutConstraint.activate([
            permissionsSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Full Disk Access
        let fdaSection = NSStackView()
        fdaSection.orientation = .vertical
        fdaSection.alignment = .leading
        fdaSection.spacing = 6

        let fdaLabel = NSTextField(labelWithString: "Full Disk Access")
        fdaLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fdaSection.addArrangedSubview(fdaLabel)

        let fdaDesc = NSTextField(
            wrappingLabelWithString: "Grant Full Disk Access to Magent so agents can read and modify files outside the workspace (e.g. ~/.zshrc, ~/Library). Useful when agents need to inspect shell configs, install tools, or access protected directories. Without it, macOS may silently block file access."
        )
        fdaDesc.font = .systemFont(ofSize: 11)
        fdaDesc.textColor = NSColor(resource: .textSecondary)
        fdaSection.addArrangedSubview(fdaDesc)

        let fdaStatusRow = NSStackView()
        fdaStatusRow.orientation = .horizontal
        fdaStatusRow.alignment = .centerY
        fdaStatusRow.spacing = 8

        fdaStatusLabel = NSTextField(labelWithString: "")
        fdaStatusLabel.font = .systemFont(ofSize: 12)
        fdaStatusRow.addArrangedSubview(fdaStatusLabel)

        let fdaButton = NSButton(title: "Open System Settings", target: self, action: #selector(openFullDiskAccessSettings))
        fdaButton.bezelStyle = .push
        fdaButton.controlSize = .small
        fdaStatusRow.addArrangedSubview(fdaButton)

        fdaSection.addArrangedSubview(fdaStatusRow)

        fdaSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(fdaSection)
        NSLayoutConstraint.activate([
            fdaSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        refreshFDAStatus()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Custom Agent Command (only shown when Custom is active)
        customAgentSection = NSStackView()
        customAgentSection.orientation = .vertical
        customAgentSection.alignment = .leading
        customAgentSection.spacing = 4
        customAgentSection.translatesAutoresizingMaskIntoConstraints = false

        customAgentCommandTextView = createSection(
            in: customAgentSection,
            title: "Custom Agent Command",
            description: "Command used when the active agent is set to Custom.",
            value: settings.customAgentCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        stackView.addArrangedSubview(customAgentSection)
        NSLayoutConstraint.activate([
            customAgentSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])
        customAgentSection.isHidden = !active.contains(.custom)

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

    private func createSection(
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

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionStack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        sectionStack.addArrangedSubview(descLabel)

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
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
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
        customAgentSection.isHidden = !active.contains(.custom)
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
            fdaStatusLabel.stringValue = "\u{2705} Granted"
            fdaStatusLabel.textColor = .systemGreen
        } else {
            fdaStatusLabel.stringValue = "\u{274C} Not Granted"
            fdaStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private static func isFullDiskAccessGranted() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probePath = home.appendingPathComponent("Library/Containers/com.apple.stocks").path
        if (try? FileManager.default.contentsOfDirectory(atPath: probePath)) != nil {
            return true
        }
        let safariPath = home.appendingPathComponent("Library/Safari/History.db").path
        return FileManager.default.isReadableFile(atPath: safariPath)
    }

    @objc private func permissionsSettingChanged() {
        settings.agentSkipPermissions = skipPermissionsCheckbox.state == .on
        settings.agentSandboxEnabled = sandboxCheckbox.state == .on
        try? persistence.saveSettings(settings)
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
