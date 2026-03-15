import Cocoa
import MagentCore

enum AgentLaunchPromptDraftScope {
    case newThread(projectId: UUID)
    case newTab(threadId: UUID)

    var storageKey: String {
        switch self {
        case .newThread(let projectId):
            return "new-thread:\(projectId.uuidString)"
        case .newTab(let threadId):
            return "new-tab:\(threadId.uuidString)"
        }
    }

    func storageKey(mode: String) -> String { "\(storageKey):\(mode)" }
}

enum AgentLaunchPromptDraftStore {
    private static let persistence = PersistenceService.shared

    /// Load draft for a specific input mode ("agent" or "terminal").
    /// Falls back to the legacy mode-less key for agent drafts (backwards compat).
    static func draft(for scope: AgentLaunchPromptDraftScope, mode: String) -> AgentLaunchPromptDraft {
        let all = persistence.loadAgentLaunchPromptDrafts()
        return all[scope.storageKey(mode: mode)]
            ?? (mode == "agent" ? all[scope.storageKey] : nil)
            ?? AgentLaunchPromptDraft()
    }

    static func save(_ draft: AgentLaunchPromptDraft, for scope: AgentLaunchPromptDraftScope, mode: String) {
        var drafts = persistence.loadAgentLaunchPromptDrafts()
        drafts[scope.storageKey(mode: mode)] = draft
        persistence.saveAgentLaunchPromptDrafts(drafts)
    }

    /// Clears drafts for all modes (agent, terminal, and the legacy key).
    static func clearAll(for scope: AgentLaunchPromptDraftScope) {
        var drafts = persistence.loadAgentLaunchPromptDrafts()
        drafts.removeValue(forKey: scope.storageKey(mode: "agent"))
        drafts.removeValue(forKey: scope.storageKey(mode: "terminal"))
        drafts.removeValue(forKey: scope.storageKey)
        persistence.saveAgentLaunchPromptDrafts(drafts)
    }

    /// Schedules a `clearAll` that fires once `magentAgentKeysInjected` fires for `sessionName`.
    /// Falls back to clearing after 60 s in case injection never fires (e.g. session dies).
    @MainActor
    static func clearAllAfterInjection(for scope: AgentLaunchPromptDraftScope, sessionName: String) {
        final class Once: @unchecked Sendable { var token: NSObjectProtocol? }
        let once = Once()
        once.token = NotificationCenter.default.addObserver(
            forName: .magentAgentKeysInjected, object: nil, queue: .main
        ) { [once] notification in
            guard (notification.userInfo?["sessionName"] as? String) == sessionName else { return }
            AgentLaunchPromptDraftStore.clearAll(for: scope)
            if let t = once.token { NotificationCenter.default.removeObserver(t) }
            once.token = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [once] in
            guard let t = once.token else { return }
            AgentLaunchPromptDraftStore.clearAll(for: scope)
            NotificationCenter.default.removeObserver(t)
            once.token = nil
        }
    }
}

enum AgentLastSelectionStore {
    private static let persistence = PersistenceService.shared

    static func lastSelection(for scope: AgentLaunchPromptDraftScope) -> String? {
        persistence.loadAgentLastSelections()[scope.storageKey]
    }

    static func save(_ selectionRaw: String, for scope: AgentLaunchPromptDraftScope) {
        var selections = persistence.loadAgentLastSelections()
        selections[scope.storageKey] = selectionRaw
        persistence.saveAgentLastSelections(selections)
    }
}

struct AgentLaunchSheetConfig {
    let title: String
    let acceptButtonTitle: String
    let draftScope: AgentLaunchPromptDraftScope
    let availableAgents: [AgentType]
    let defaultAgentType: AgentType?
    /// Secondary label shown below the window title (e.g. "Project: MyProject").
    let subtitle: String?
    /// When true, Description and Branch text fields are shown below the prompt.
    let showDescriptionAndBranchFields: Bool
    /// When non-nil, a subtle auto-generate hint is shown near the description/branch fields.
    let autoGenerateHint: String?
    /// When Terminal is selected and the prompt field is empty, prefill with this value.
    let terminalInjectionPrefill: String?
    /// When an Agent is selected and the prompt field is empty, prefill with this value.
    let agentContextPrefill: String?
}

struct AgentLaunchSheetResult {
    let agentType: AgentType?
    let useAgentCommand: Bool
    let prompt: String?
    let description: String?
    let branchName: String?
}

/// A rounded chip view that shows accent-tinted background, adapting correctly to light/dark mode.
private final class ContextChipView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        }
        layer?.cornerRadius = 6
    }
}

final class AgentLaunchPromptSheetController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private static var activeControllers: [ObjectIdentifier: AgentLaunchPromptSheetController] = [:]

    private let config: AgentLaunchSheetConfig
    private let agentPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let descriptionField = NSTextField()
    private let branchField = NSTextField()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let acceptButton: NSButton
    private var promptScrollView: NSScrollView!
    private var promptLabel: NSTextField!
    private var completion: ((AgentLaunchSheetResult?) -> Void)?
    private var didFinish = false

    /// Maps NSPopUpButton item indices (excluding separators) to picker modes.
    private var pickerItems: [PickerItem] = []
    /// Tracks the mode we were in before the last picker change, so we save to the right draft on switch.
    private var previousMode: String = "agent"

    private enum PickerItem {
        case agent(AgentType, isDefault: Bool)
        case terminal

        var storageRaw: String {
            switch self {
            case .agent(let type, _): return type.rawValue
            case .terminal: return "terminal"
            }
        }
    }

    init(config: AgentLaunchSheetConfig) {
        self.config = config
        self.acceptButton = NSButton(title: config.acceptButtonTitle, target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = config.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildPickerItems()
        setupUI()
        applyLastSelection()
        // Sync previousMode to the restored selection before loading draft
        previousMode = currentMode
        loadDraft(mode: currentMode)
        applyPrefillIfNeeded()
        updatePromptAreaEnabled()
        resizeWindowToFitContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(for parentWindow: NSWindow, completion: @escaping (AgentLaunchSheetResult?) -> Void) {
        self.completion = completion
        guard let window else {
            completion(nil)
            return
        }

        let identifier = ObjectIdentifier(self)
        Self.activeControllers[identifier] = self
        parentWindow.beginSheet(window) { _ in
            Self.activeControllers.removeValue(forKey: identifier)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.promptTextView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !didFinish {
            finish(with: nil)
        }
    }

    // MARK: - Setup

    private func buildPickerItems() {
        var agents = config.availableAgents
        if let defaultAgent = config.defaultAgentType, let idx = agents.firstIndex(of: defaultAgent) {
            agents.remove(at: idx)
            agents.insert(defaultAgent, at: 0)
        }

        for agent in agents {
            pickerItems.append(.agent(agent, isDefault: agent == config.defaultAgentType))
        }
        pickerItems.append(.terminal)

        for (i, item) in pickerItems.enumerated() {
            switch item {
            case .agent(let type, let isDefault):
                let title = isDefault ? "\(type.displayName) (Default)" : type.displayName
                agentPicker.addItem(withTitle: title)
            case .terminal:
                if i > 0 {
                    agentPicker.menu?.addItem(.separator())
                }
                agentPicker.addItem(withTitle: "Terminal")
            }
        }

        agentPicker.selectItem(at: 0)
    }

    private func applyLastSelection() {
        guard let raw = AgentLastSelectionStore.lastSelection(for: config.draftScope),
              let index = pickerItems.firstIndex(where: { $0.storageRaw == raw }) else {
            return
        }
        agentPicker.selectItem(at: index)
    }

    private func setupUI() {
        guard let window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView
        contentView.widthAnchor.constraint(equalToConstant: 540).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        // Subtitle (project context) — shown as a prominent context chip
        var contextChip: NSView?
        if let subtitle = config.subtitle {
            let chip = makeContextChip(subtitle)
            stack.addArrangedSubview(chip)
            stack.setCustomSpacing(10, after: chip)
            contextChip = chip
        }

        // "All fields optional" prominent notice
        let optionalNotice = makeNoticeBox(
            icon: "info.circle.fill",
            text: "All fields are optional — you can start the session and add them later.",
            color: .systemBlue
        )
        stack.addArrangedSubview(optionalNotice)
        stack.setCustomSpacing(12, after: optionalNotice)

        // Agent picker row
        let agentRow = NSStackView()
        agentRow.orientation = .horizontal
        agentRow.alignment = .centerY
        agentRow.spacing = 8

        let agentLabel = makeFormLabel("Type")
        agentRow.addArrangedSubview(agentLabel)

        agentPicker.target = self
        agentPicker.action = #selector(agentPickerChanged)
        agentPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(agentPicker)
        stack.addArrangedSubview(agentRow)

        // Prompt label
        promptLabel = makeFormLabel(promptLabelText)
        stack.addArrangedSubview(promptLabel)
        stack.setCustomSpacing(4, after: promptLabel)

        // Prompt text view
        let promptFont = NSFont.systemFont(ofSize: 13)
        promptTextView.isRichText = false
        promptTextView.font = promptFont
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isAutomaticTextReplacementEnabled = false
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.textContainerInset = NSSize(width: 8, height: 8)
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        promptTextView.delegate = self

        promptScrollView = NonCapturingScrollView()
        promptScrollView.translatesAutoresizingMaskIntoConstraints = false
        promptScrollView.drawsBackground = false
        promptScrollView.borderType = .bezelBorder
        promptScrollView.hasVerticalScroller = true
        promptScrollView.autohidesScrollers = true
        promptScrollView.documentView = promptTextView
        stack.addArrangedSubview(promptScrollView)

        let lineHeight = promptFont.ascender + abs(promptFont.descender) + promptFont.leading
        let promptHeight = max((lineHeight * 7) + 20, 130)

        // Description + Branch fields
        var descRow: NSStackView?
        var branchRow: NSStackView?
        if config.showDescriptionAndBranchFields {
            stack.setCustomSpacing(12, after: promptScrollView)

            let dr = makeTextFieldRow(label: "Description", field: descriptionField, placeholder: "Optional")
            stack.addArrangedSubview(dr)
            descRow = dr

            let br = makeTextFieldRow(label: "Branch", field: branchField, placeholder: "Optional")
            stack.addArrangedSubview(br)
            branchRow = br

            // Tab order between the two fields
            descriptionField.nextKeyView = branchField

            // Auto-generate hint
            if let hint = config.autoGenerateHint {
                let hintLabel = NSTextField(wrappingLabelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 11)
                hintLabel.textColor = NSColor(resource: .textSecondary)
                stack.addArrangedSubview(hintLabel)
                NSLayoutConstraint.activate([hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            }
        }

        // Button row
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? promptScrollView)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        buttonRow.addArrangedSubview(cancelButton)

        acceptButton.target = self
        acceptButton.action = #selector(acceptTapped)
        acceptButton.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(acceptButton)
        stack.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            agentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScrollView.heightAnchor.constraint(equalToConstant: promptHeight),
            optionalNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + (contextChip.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? []))

        if let descRow, let branchRow {
            NSLayoutConstraint.activate([
                descRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
                branchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
    }

    private func resizeWindowToFitContent() {
        guard let window, let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fitting = contentView.fittingSize
        let h = max(fitting.height, 200)
        window.setContentSize(NSSize(width: fitting.width > 0 ? fitting.width : 540, height: h))
    }

    // MARK: - Helpers

    private func makeFormLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return label
    }

    private func makeTextFieldRow(label labelText: String, field: NSTextField, placeholder: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeFormLabel(labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: 80)])
        row.addArrangedSubview(label)

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(field)

        return row
    }

    /// Renders a compact chip showing project/thread context (e.g. "Project: MyProject").
    private func makeContextChip(_ text: String) -> NSView {
        // Split on first ": " so we can bold the label part and use accent color for the value.
        let parts = text.split(separator: ":", maxSplits: 1).map { String($0) }
        let labelPart = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespaces) + ":" : nil
        let valuePart = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : text

        // Determine icon from label
        let iconName: String
        switch labelPart?.lowercased().replacingOccurrences(of: ":", with: "") {
        case "project": iconName = "folder.fill"
        case "thread": iconName = "terminal.fill"
        default: iconName = "tag.fill"
        }

        let container = ContextChipView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = iconView.image?.withSymbolConfiguration(symbolConfig)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Build attributed string: "Project: " in medium accent + "MyProject" in semibold primary
        let attrStr = NSMutableAttributedString()
        if let lbl = labelPart {
            attrStr.append(NSAttributedString(
                string: lbl + " ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        attrStr.append(NSAttributedString(
            string: valuePart,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        ))

        let textField = NSTextField(labelWithAttributedString: attrStr)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        container.addSubview(iconView)
        container.addSubview(textField)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func makeNoticeBox(icon symbolName: String, text: String, color: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        container.layer?.cornerRadius = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = color
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .regular)
        label.textColor = color
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
        ])

        return container
    }

    // MARK: - Draft

    private var promptLabelText: String {
        currentMode == "terminal" ? "Initial command" : "Initial prompt"
    }

    private var currentMode: String {
        if case .terminal? = selectedPickerItem() { return "terminal" }
        return "agent"
    }

    private func loadDraft(mode: String) {
        let draft = AgentLaunchPromptDraftStore.draft(for: config.draftScope, mode: mode)
        promptTextView.string = draft.prompt
        if config.showDescriptionAndBranchFields && mode == "agent" {
            descriptionField.stringValue = draft.description
            branchField.stringValue = draft.branchName
        }
    }

    private func persistDraft() {
        let mode = currentMode
        AgentLaunchPromptDraftStore.save(
            AgentLaunchPromptDraft(
                prompt: promptTextView.string,
                description: mode == "agent" && config.showDescriptionAndBranchFields ? descriptionField.stringValue : "",
                branchName: mode == "agent" && config.showDescriptionAndBranchFields ? branchField.stringValue : ""
            ),
            for: config.draftScope,
            mode: mode
        )
    }

    private func applyPrefillIfNeeded() {
        guard promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prefill = currentMode == "terminal" ? config.terminalInjectionPrefill : config.agentContextPrefill
        if let p = prefill, !p.isEmpty {
            promptTextView.string = p
        }
    }

    func textDidChange(_ notification: Notification) {
        persistDraft()
    }

    // MARK: - Agent picker

    @objc private func agentPickerChanged() {
        let newMode = currentMode
        guard newMode != previousMode else {
            updatePromptAreaEnabled()
            return
        }
        // Save current text to the mode we're leaving, then load the new mode's draft
        persistDraft()
        previousMode = newMode
        loadDraft(mode: newMode)
        applyPrefillIfNeeded()
        updatePromptAreaEnabled()
    }

    private func selectedPickerItem() -> PickerItem? {
        let index = agentPicker.indexOfSelectedItem
        guard index >= 0, index < pickerItems.count else { return nil }
        return pickerItems[index]
    }

    private func updatePromptAreaEnabled() {
        let isTerminal: Bool
        if case .terminal = selectedPickerItem() {
            isTerminal = true
        } else {
            isTerminal = false
        }
        // Prompt text view is always editable — for terminal it's the shell command, for agents it's the initial prompt
        promptTextView.isEditable = true
        promptTextView.alphaValue = 1.0
        promptLabel?.stringValue = promptLabelText
        if config.showDescriptionAndBranchFields {
            descriptionField.isEnabled = !isTerminal
            branchField.isEnabled = !isTerminal
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Shift+Return inserts a newline; plain Return submits.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                return false
            }
            acceptTapped()
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func acceptTapped() {
        guard let item = selectedPickerItem() else { return }

        let rawPrompt = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDesc = config.showDescriptionAndBranchFields
            ? descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let rawBranch = config.showDescriptionAndBranchFields
            ? branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        AgentLastSelectionStore.save(item.storageRaw, for: config.draftScope)

        switch item {
        case .terminal:
            finish(with: AgentLaunchSheetResult(
                agentType: nil,
                useAgentCommand: false,
                prompt: rawPrompt.isEmpty ? nil : rawPrompt,
                description: nil,
                branchName: nil
            ))
        case .agent(let type, _):
            finish(with: AgentLaunchSheetResult(
                agentType: type,
                useAgentCommand: true,
                prompt: rawPrompt.isEmpty ? nil : rawPrompt,
                description: rawDesc.isEmpty ? nil : rawDesc,
                branchName: rawBranch.isEmpty ? nil : rawBranch
            ))
        }
    }

    private func finish(with result: AgentLaunchSheetResult?) {
        guard !didFinish else { return }
        didFinish = true

        if let parentWindow = window?.sheetParent, let window {
            parentWindow.endSheet(window)
        } else {
            close()
        }

        completion?(result)
        completion = nil
    }
}
