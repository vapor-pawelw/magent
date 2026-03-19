import Cocoa
import MagentCore

enum AgentLaunchPromptDraftScope: Equatable {
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
}

/// All fields the user filled in before submitting the launch sheet.
/// Persisted to `/tmp` as JSON so a crash between submission and tmux injection
/// doesn't silently lose the user's work.
struct PendingInitialPrompt: Codable {
    enum ScopeKind: String, Codable {
        case newThread
        case newTab
    }
    let scopeKind: ScopeKind
    /// Set for `newThread` — identifies which project to open the sheet on.
    let projectId: UUID?
    /// Set for `newTab` — identifies which thread the tab was being added to.
    let threadId: UUID?
    let prompt: String
    let description: String?
    let branchName: String?
    let agentType: AgentType?
    let createdAt: Date
}

/// Manages crash-recovery temp files for submitted (but not yet injected) initial prompts.
///
/// When the user accepts the launch sheet, their prompt is written to a unique JSON file
/// under `/tmp` before the draft in persistent storage is cleared. The file survives app
/// crashes and is only removed once the tmux keys have been confirmed as injected. This
/// lets users immediately re-open the sheet without seeing stale text while still
/// protecting against losing a long prompt if something goes wrong mid-creation.
/// On the next launch, `loadAll()` finds leftover files and surfaces them for recovery.
enum PendingInitialPromptStore {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Writes all submitted fields to a unique temp file and returns its URL.
    /// Returns `nil` if the write fails (non-fatal — the in-memory result still carries the data).
    static func save(
        prompt: String,
        description: String?,
        branchName: String?,
        agentType: AgentType?,
        scope: AgentLaunchPromptDraftScope
    ) -> URL? {
        let scopeKind: PendingInitialPrompt.ScopeKind
        let projectId: UUID?
        let threadId: UUID?
        switch scope {
        case .newThread(let pid): scopeKind = .newThread; projectId = pid; threadId = nil
        case .newTab(let tid):   scopeKind = .newTab;    projectId = nil; threadId = tid
        }
        let record = PendingInitialPrompt(
            scopeKind: scopeKind,
            projectId: projectId,
            threadId: threadId,
            prompt: prompt,
            description: description.flatMap { $0.isEmpty ? nil : $0 },
            branchName: branchName.flatMap { $0.isEmpty ? nil : $0 },
            agentType: agentType,
            createdAt: Date()
        )
        let url = URL(fileURLWithPath: "/tmp/magent-pending-prompt-\(UUID().uuidString).json")
        guard let data = try? encoder.encode(record) else { return nil }
        try? data.write(to: url)
        return url
    }

    /// Returns all leftover pending-prompt files from `/tmp`, sorted oldest first.
    static func loadAll() -> [(url: URL, prompt: PendingInitialPrompt)] {
        let tmpDir = URL(fileURLWithPath: "/tmp")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("magent-pending-prompt-") && $0.pathExtension == "json" }
            .compactMap { url -> (URL, PendingInitialPrompt)? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(PendingInitialPrompt.self, from: data)
                else { return nil }
                return (url, record)
            }
            .sorted { $0.1.createdAt < $1.1.createdAt }
    }

    /// Schedules deletion of `fileURL` once `magentAgentKeysInjected` fires for `sessionName`.
    /// Falls back to deleting after 60 s in case injection never fires (e.g. session dies).
    @MainActor
    static func clearAfterInjection(fileURL: URL, sessionName: String) {
        final class Once: @unchecked Sendable { var token: NSObjectProtocol? }
        let once = Once()
        once.token = NotificationCenter.default.addObserver(
            forName: .magentAgentKeysInjected, object: nil, queue: .main
        ) { [once] notification in
            guard (notification.userInfo?["sessionName"] as? String) == sessionName else { return }
            try? FileManager.default.removeItem(at: fileURL)
            if let t = once.token { NotificationCenter.default.removeObserver(t) }
            once.token = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [once] in
            guard let t = once.token else { return }
            try? FileManager.default.removeItem(at: fileURL)
            NotificationCenter.default.removeObserver(t)
            once.token = nil
        }
    }
}

/// Prefill values applied to the launch sheet when opening it to recover a crashed submission.
struct AgentLaunchSheetPrefill {
    let prompt: String
    let description: String?
    let branchName: String?
    let agentType: AgentType?
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
    /// Ignored when `availableProjects` has more than one entry (picker is shown instead).
    let subtitle: String?
    /// When more than one project is provided, a project picker is shown instead of the static subtitle chip.
    let availableProjects: [Project]
    /// When true, Description and Branch text fields are shown below the prompt.
    let showDescriptionAndBranchFields: Bool
    /// When true, a Title text field is shown below the prompt (used for tab title).
    let showTitleField: Bool
    /// When non-nil, a subtle auto-generate hint is shown near the description/branch fields.
    let autoGenerateHint: String?
    /// When Terminal is selected and the prompt field is empty, prefill with this value.
    let terminalInjectionPrefill: String?
    /// When an Agent is selected and the prompt field is empty, prefill with this value.
    let agentContextPrefill: String?
    /// When non-nil, the sheet opens pre-populated with recovered content instead of the saved draft.
    let recoveryPrefill: AgentLaunchSheetPrefill?
    /// Per-project visible sections — when non-empty, a Section picker is shown for `newThread` scope.
    let sectionsByProjectId: [UUID: [ThreadSection]]
    /// Per-project default section ID — used to pre-select the section picker.
    let defaultSectionIdByProjectId: [UUID: UUID]
    /// When non-nil, a "Base branch" combo box is shown below Branch and pre-populated with this value.
    let baseBranchPrefill: String?
    /// Repo path used to populate the base branch combo box with existing branches.
    let baseBranchRepoPath: String?
    /// The project's default branch name (e.g. "main"). Used as placeholder and for validation fallback.
    let defaultBranchName: String?

    init(
        title: String,
        acceptButtonTitle: String,
        draftScope: AgentLaunchPromptDraftScope,
        availableAgents: [AgentType],
        defaultAgentType: AgentType?,
        subtitle: String?,
        availableProjects: [Project] = [],
        showDescriptionAndBranchFields: Bool,
        showTitleField: Bool = false,
        autoGenerateHint: String?,
        terminalInjectionPrefill: String?,
        agentContextPrefill: String?,
        recoveryPrefill: AgentLaunchSheetPrefill? = nil,
        sectionsByProjectId: [UUID: [ThreadSection]] = [:],
        defaultSectionIdByProjectId: [UUID: UUID] = [:],
        baseBranchPrefill: String? = nil,
        baseBranchRepoPath: String? = nil,
        defaultBranchName: String? = nil
    ) {
        self.title = title
        self.acceptButtonTitle = acceptButtonTitle
        self.draftScope = draftScope
        self.availableAgents = availableAgents
        self.defaultAgentType = defaultAgentType
        self.subtitle = subtitle
        self.availableProjects = availableProjects
        self.showDescriptionAndBranchFields = showDescriptionAndBranchFields
        self.showTitleField = showTitleField
        self.autoGenerateHint = autoGenerateHint
        self.terminalInjectionPrefill = terminalInjectionPrefill
        self.agentContextPrefill = agentContextPrefill
        self.recoveryPrefill = recoveryPrefill
        self.sectionsByProjectId = sectionsByProjectId
        self.defaultSectionIdByProjectId = defaultSectionIdByProjectId
        self.baseBranchPrefill = baseBranchPrefill
        self.baseBranchRepoPath = baseBranchRepoPath
        self.defaultBranchName = defaultBranchName
    }
}

struct AgentLaunchSheetResult {
    let agentType: AgentType?
    let useAgentCommand: Bool
    let prompt: String?
    let description: String?
    let branchName: String?
    /// Base branch for the new worktree. Non-nil when the user entered/kept a value in the Base branch field.
    let baseBranch: String?
    /// Custom tab title entered by the user. Non-nil only when `showTitleField` was true and the user typed a value.
    let tabTitle: String?
    /// Temp file holding the submitted prompt for crash recovery.
    /// Exists only when `prompt` is non-nil; deleted once injection is confirmed.
    let pendingPromptFileURL: URL?
    /// The project selected by the user. Non-nil when the project picker was shown.
    let selectedProject: Project?
    /// The section selected by the user. Non-nil when the section picker was shown.
    let selectedSectionId: UUID?
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

final class AgentLaunchPromptSheetController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSComboBoxDelegate {
    private static var activeControllers: [ObjectIdentifier: AgentLaunchPromptSheetController] = [:]
    private static let formLabelWidth: CGFloat = 80
    private static let formLabelColumnWidth: CGFloat = formLabelWidth + 8 // label + row spacing

    private let config: AgentLaunchSheetConfig
    private let agentPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let descriptionField = NSTextField()
    private let branchField = NSTextField()
    private let baseBranchField = NSComboBox()
    private let baseBranchHintLabel = NSTextField(labelWithString: "")
    private let baseBranchErrorLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let rememberCheckbox = NSButton(checkboxWithTitle: "Remember type selection", target: nil, action: nil)
    private let switchToNewThreadCheckbox = NSButton(checkboxWithTitle: "Switch to new thread", target: nil, action: nil)
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

    // Project picker — present when config.availableProjects has more than one entry.
    private var projectPickerItems: [Project] = []
    private var projectPicker: NSPopUpButton?
    /// Draft scope that tracks the currently selected project; starts as config.draftScope.
    private var currentDraftScope: AgentLaunchPromptDraftScope

    // Section picker — present when the current project has sections enabled.
    private let sectionPicker = NSPopUpButton()
    private var sectionPickerItems: [ThreadSection] = []
    private var sectionPickerRow: NSView?

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
        self.currentDraftScope = config.draftScope
        self.projectPickerItems = config.availableProjects

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
        if let prefill = config.recoveryPrefill {
            // Recovery mode: pre-select the recovered agent type, then populate fields.
            // Skip draft loading — we're restoring submitted content, not a mid-edit draft.
            applyRecoveryAgentSelection(prefill)
            previousMode = currentMode
            applyRecoveryPrefill(prefill)
        } else {
            applyLastSelection()
            // Sync previousMode to the restored selection before loading draft
            previousMode = currentMode
            loadDraft(mode: currentMode)
            applyPrefillIfNeeded()
        }
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
                agentPicker.lastItem?.tag = i
            case .terminal:
                if i > 0 {
                    agentPicker.menu?.addItem(.separator())
                }
                agentPicker.addItem(withTitle: "Terminal")
                agentPicker.lastItem?.tag = i
            }
        }

        agentPicker.selectItem(at: 0)
    }

    private func applyLastSelection() {
        guard PersistenceService.shared.loadSettings().rememberLastTypeSelection else { return }
        guard let raw = AgentLastSelectionStore.lastSelection(for: config.draftScope),
              let index = pickerItems.firstIndex(where: { $0.storageRaw == raw }) else {
            return
        }
        agentPicker.selectItem(withTag: index)
    }

    private func applyRecoveryAgentSelection(_ prefill: AgentLaunchSheetPrefill) {
        guard let agentType = prefill.agentType,
              let index = pickerItems.firstIndex(where: {
                  if case .agent(let t, _) = $0 { return t == agentType }
                  return false
              }) else { return }
        agentPicker.selectItem(withTag: index)
    }

    private func applyRecoveryPrefill(_ prefill: AgentLaunchSheetPrefill) {
        promptTextView.string = prefill.prompt
        if config.showDescriptionAndBranchFields {
            descriptionField.stringValue = prefill.description ?? ""
            branchField.stringValue = prefill.branchName ?? ""
        }
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

        // Large title
        let titleLabel = NSTextField(labelWithString: config.title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.setCustomSpacing(8, after: titleLabel)

        // Project picker (multiple projects) or subtitle chip (e.g. thread context for new tab).
        var contextChip: NSView?
        var projectPickerRow: NSView?
        if projectPickerItems.count > 1, case .newThread = config.draftScope {
            let row = makeProjectPickerRow()
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(10, after: row)
            projectPickerRow = row
        } else if let subtitle = config.subtitle {
            let chip = makeContextChip(subtitle)
            stack.addArrangedSubview(chip)
            stack.setCustomSpacing(10, after: chip)
            contextChip = chip
        }

        // Section picker — shown for newThread when the project has sections enabled.
        if case .newThread(let projectId) = config.draftScope {
            let row = makeSectionPickerRow()
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(10, after: row)
            sectionPickerRow = row
            populateSectionPicker(for: projectId)
        }

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
        promptTextView.allowsUndo = true
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

        // Title field (for tab title)
        var titleRow: NSStackView?
        if config.showTitleField {
            stack.setCustomSpacing(12, after: promptScrollView)

            let tr = makeTextFieldRow(label: "Title", field: titleField, placeholder: "Optional")
            stack.addArrangedSubview(tr)
            titleRow = tr

            promptTextView.nextKeyView = titleField
        }

        // Description + Branch fields
        var descRow: NSStackView?
        var branchRow: NSStackView?
        var baseBranchRow: NSStackView?
        if config.showDescriptionAndBranchFields {
            stack.setCustomSpacing(12, after: promptScrollView)

            let dr = makeTextFieldRow(label: "Description", field: descriptionField, placeholder: "Optional")
            stack.addArrangedSubview(dr)
            descRow = dr

            let br = makeTextFieldRow(label: "Branch", field: branchField, placeholder: "Optional")
            stack.addArrangedSubview(br)
            branchRow = br

            let defaultBranchPlaceholder = resolvedDefaultBranchName()
            let bbr = makeComboBoxRow(
                label: "Base branch",
                comboBox: baseBranchField,
                placeholder: defaultBranchPlaceholder
            )
            stack.addArrangedSubview(bbr)
            baseBranchRow = bbr
            baseBranchField.delegate = self

            // Hint label
            baseBranchHintLabel.stringValue = "Uses default branch (\(defaultBranchPlaceholder)) if empty."
            baseBranchHintLabel.font = .systemFont(ofSize: 11)
            baseBranchHintLabel.textColor = NSColor(resource: .textSecondary)
            baseBranchHintLabel.translatesAutoresizingMaskIntoConstraints = false
            let hintRow = NSStackView()
            hintRow.orientation = .horizontal
            hintRow.spacing = 0
            hintRow.translatesAutoresizingMaskIntoConstraints = false
            let hintSpacer = NSView()
            hintSpacer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([hintSpacer.widthAnchor.constraint(equalToConstant: Self.formLabelColumnWidth)])
            hintRow.addArrangedSubview(hintSpacer)
            hintRow.addArrangedSubview(baseBranchHintLabel)
            stack.addArrangedSubview(hintRow)

            // Error label (hidden by default)
            baseBranchErrorLabel.font = .systemFont(ofSize: 11, weight: .medium)
            baseBranchErrorLabel.textColor = .systemRed
            baseBranchErrorLabel.isHidden = true
            baseBranchErrorLabel.translatesAutoresizingMaskIntoConstraints = false
            let errorRow = NSStackView()
            errorRow.orientation = .horizontal
            errorRow.spacing = 0
            errorRow.translatesAutoresizingMaskIntoConstraints = false
            let errorSpacer = NSView()
            errorSpacer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([errorSpacer.widthAnchor.constraint(equalToConstant: Self.formLabelColumnWidth)])
            errorRow.addArrangedSubview(errorSpacer)
            errorRow.addArrangedSubview(baseBranchErrorLabel)
            stack.addArrangedSubview(errorRow)

            if let prefill = config.baseBranchPrefill, !prefill.isEmpty {
                baseBranchField.stringValue = prefill
            }
            loadBaseBranchItems()

            // Tab order: prompt → description → branch → base branch → (wraps back via window key loop)
            promptTextView.nextKeyView = descriptionField
            descriptionField.nextKeyView = branchField
            branchField.nextKeyView = baseBranchField

            // Auto-generate hint
            if let hint = config.autoGenerateHint {
                let hintLabel = NSTextField(wrappingLabelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 11)
                hintLabel.textColor = NSColor(resource: .textSecondary)
                stack.addArrangedSubview(hintLabel)
                NSLayoutConstraint.activate([hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
            }
        }

        // "All fields optional" prominent notice — placed just above the checkboxes.
        let optionalNotice = makeNoticeBox(
            icon: "info.circle.fill",
            text: "All fields are optional — you can start the session and add them later.",
            color: .systemBlue
        )
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last ?? promptScrollView)
        stack.addArrangedSubview(optionalNotice)
        stack.setCustomSpacing(10, after: optionalNotice)

        // Remember type selection checkbox
        rememberCheckbox.target = self
        rememberCheckbox.action = #selector(rememberCheckboxToggled)
        rememberCheckbox.state = PersistenceService.shared.loadSettings().rememberLastTypeSelection ? .on : .off
        rememberCheckbox.font = .systemFont(ofSize: 11)
        rememberCheckbox.contentTintColor = .controlAccentColor
        stack.addArrangedSubview(rememberCheckbox)
        stack.setCustomSpacing(4, after: rememberCheckbox)

        // Switch to new thread checkbox — only relevant when creating a new thread, not a tab
        if case .newThread = config.draftScope {
            switchToNewThreadCheckbox.target = self
            switchToNewThreadCheckbox.action = #selector(switchToNewThreadCheckboxToggled)
            switchToNewThreadCheckbox.state = PersistenceService.shared.loadSettings().switchToNewlyCreatedThread ? .on : .off
            switchToNewThreadCheckbox.font = .systemFont(ofSize: 11)
            switchToNewThreadCheckbox.contentTintColor = .controlAccentColor
            stack.addArrangedSubview(switchToNewThreadCheckbox)
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

            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rememberCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptScrollView.heightAnchor.constraint(equalToConstant: promptHeight),
            optionalNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + (contextChip.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? [])
          + (projectPickerRow.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? [])
          + (sectionPickerRow.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? []))

        if let titleRow {
            NSLayoutConstraint.activate([
                titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        if let descRow, let branchRow, let baseBranchRow {
            NSLayoutConstraint.activate([
                descRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
                branchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
                baseBranchRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    private func makeComboBoxRow(label labelText: String, comboBox: NSComboBox, placeholder: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeFormLabel(labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: Self.formLabelWidth)])
        row.addArrangedSubview(label)

        comboBox.placeholderString = placeholder
        comboBox.font = .systemFont(ofSize: 13)
        comboBox.completes = true
        comboBox.numberOfVisibleItems = 12
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        comboBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        comboBox.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(comboBox)

        return row
    }

    /// Returns the effective default branch name for the current project context, falling back to "main".
    private func resolvedDefaultBranchName() -> String {
        // If a project picker is visible and a project is selected, use that project's default branch.
        if let picker = projectPicker {
            let idx = picker.indexOfSelectedItem
            if idx >= 0, idx < projectPickerItems.count {
                let branch = projectPickerItems[idx].defaultBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return branch.isEmpty ? "main" : branch
            }
        }
        let branch = config.defaultBranchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return branch.isEmpty ? "main" : branch
    }

    private func loadBaseBranchItems() {
        guard let repoPath = config.baseBranchRepoPath else { return }
        populateBaseBranchComboBox(repoPath: repoPath)
    }

    private func reloadBaseBranches(for project: Project) {
        guard config.showDescriptionAndBranchFields else { return }
        baseBranchField.stringValue = ""
        let defaultBranch = resolvedDefaultBranchName()
        baseBranchField.placeholderString = defaultBranch
        baseBranchHintLabel.stringValue = "Uses default branch (\(defaultBranch)) if empty."
        clearBaseBranchError()
        populateBaseBranchComboBox(repoPath: project.repoPath)
    }

    private func populateBaseBranchComboBox(repoPath: String) {
        Task {
            let branches = await GitService.shared.listBranchesByDate(repoPath: repoPath)
            await MainActor.run {
                baseBranchField.removeAllItems()
                let defaultBranch = resolvedDefaultBranchName()
                var items: [String] = []
                if !defaultBranch.isEmpty {
                    items.append(defaultBranch)
                }
                for branch in branches where branch != defaultBranch {
                    items.append(branch)
                }
                baseBranchField.addItems(withObjectValues: items)
            }
        }
    }

    private func makeTextFieldRow(label labelText: String, field: NSTextField, placeholder: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeFormLabel(labelText)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: Self.formLabelWidth)])
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

    private func makeProjectPickerRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeFormLabel("Project")
        row.addArrangedSubview(label)

        let picker = NSPopUpButton()
        for (i, project) in projectPickerItems.enumerated() {
            picker.addItem(withTitle: project.name)
            picker.lastItem?.tag = i
        }
        if case .newThread(let projectId) = config.draftScope,
           let idx = projectPickerItems.firstIndex(where: { $0.id == projectId }) {
            picker.selectItem(at: idx)
        }
        picker.target = self
        picker.action = #selector(projectPickerChanged)
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(picker)

        self.projectPicker = picker
        return row
    }

    @objc private func projectPickerChanged() {
        guard let picker = projectPicker else { return }
        let idx = picker.indexOfSelectedItem
        guard idx >= 0, idx < projectPickerItems.count else { return }
        let newProject = projectPickerItems[idx]
        let newScope = AgentLaunchPromptDraftScope.newThread(projectId: newProject.id)
        guard case .newThread(let oldId) = currentDraftScope, oldId != newProject.id else { return }

        // Just update the scope — no save, no load.
        // Drafts are saved only when the user actually types (textDidChange), so switching
        // projects neither persists the current content to the old project nor overwrites
        // the prompt with the new project's saved draft. Whatever is in the field stays.
        currentDraftScope = newScope
        populateSectionPicker(for: newProject.id)
        reloadBaseBranches(for: newProject)
        resizeWindowToFitContent()
    }

    private func makeSectionPickerRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = makeFormLabel("Section")
        row.addArrangedSubview(label)

        sectionPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(sectionPicker)

        return row
    }

    private func populateSectionPicker(for projectId: UUID) {
        sectionPicker.removeAllItems()
        sectionPickerItems = config.sectionsByProjectId[projectId] ?? []
        sectionPickerRow?.isHidden = sectionPickerItems.isEmpty

        for (i, section) in sectionPickerItems.enumerated() {
            sectionPicker.addItem(withTitle: section.name)
            sectionPicker.lastItem?.tag = i
            sectionPicker.lastItem?.image = colorDotImage(color: section.color, size: 10)
        }

        let defaultId = config.defaultSectionIdByProjectId[projectId]
        if let defaultId, let idx = sectionPickerItems.firstIndex(where: { $0.id == defaultId }) {
            sectionPicker.selectItem(at: idx)
        }
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
        let draft = AgentLaunchPromptDraftStore.draft(for: currentDraftScope, mode: mode)
        promptTextView.string = draft.prompt
        if config.showDescriptionAndBranchFields && mode == "agent" {
            descriptionField.stringValue = draft.description
            branchField.stringValue = draft.branchName
        }
    }

    private func persistDraft(mode: String? = nil) {
        let mode = mode ?? currentMode
        AgentLaunchPromptDraftStore.save(
            AgentLaunchPromptDraft(
                prompt: promptTextView.string,
                description: mode == "agent" && config.showDescriptionAndBranchFields ? descriptionField.stringValue : "",
                branchName: mode == "agent" && config.showDescriptionAndBranchFields ? branchField.stringValue : ""
            ),
            for: currentDraftScope,
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

    // MARK: - NSComboBoxDelegate

    func comboBoxSelectionDidChange(_ notification: Notification) {
        clearBaseBranchError()
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSComboBox) === baseBranchField {
            clearBaseBranchError()
        }
    }

    private func clearBaseBranchError() {
        guard !baseBranchErrorLabel.isHidden else { return }
        baseBranchErrorLabel.isHidden = true
        baseBranchErrorLabel.stringValue = ""
        resizeWindowToFitContent()
    }

    // MARK: - Agent picker

    @objc private func agentPickerChanged() {
        let newMode = currentMode
        guard newMode != previousMode else {
            updatePromptAreaEnabled()
            return
        }
        // Save current text to the mode we're leaving, then load the new mode's draft
        persistDraft(mode: previousMode)
        previousMode = newMode
        loadDraft(mode: newMode)
        applyPrefillIfNeeded()
        updatePromptAreaEnabled()
    }

    private func selectedPickerItem() -> PickerItem? {
        guard let tag = agentPicker.selectedItem?.tag else { return nil }
        guard tag >= 0, tag < pickerItems.count else { return nil }
        return pickerItems[tag]
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
            baseBranchField.isEnabled = !isTerminal
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
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            window?.selectNextKeyView(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            window?.selectPreviousKeyView(nil)
            return true
        }
        if commandSelector == Selector(("undo:")) {
            promptTextView.undoManager?.undo()
            return true
        }
        if commandSelector == Selector(("redo:")) {
            promptTextView.undoManager?.redo()
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func rememberCheckboxToggled() {
        var settings = PersistenceService.shared.loadSettings()
        settings.rememberLastTypeSelection = rememberCheckbox.state == .on
        try? PersistenceService.shared.saveSettings(settings)
    }

    @objc private func switchToNewThreadCheckboxToggled() {
        var settings = PersistenceService.shared.loadSettings()
        settings.switchToNewlyCreatedThread = switchToNewThreadCheckbox.state == .on
        try? PersistenceService.shared.saveSettings(settings)
    }

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
        let rawBaseBranch = config.showDescriptionAndBranchFields
            ? baseBranchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let rawTitle = config.showTitleField
            ? titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        // Validate base branch exists before proceeding
        if config.showDescriptionAndBranchFields, let repoPath = resolvedRepoPath() {
            let branchToValidate = rawBaseBranch.isEmpty ? resolvedDefaultBranchName() : rawBaseBranch
            acceptButton.isEnabled = false
            cancelButton.isEnabled = false
            Task { [weak self] in
                let exists = await GitService.shared.branchExists(repoPath: repoPath, branchName: branchToValidate)
                await MainActor.run {
                    guard let self else { return }
                    self.acceptButton.isEnabled = true
                    self.cancelButton.isEnabled = true
                    if exists {
                        self.performAccept(item: item, rawPrompt: rawPrompt, rawDesc: rawDesc, rawBranch: rawBranch, rawBaseBranch: rawBaseBranch, rawTitle: rawTitle)
                    } else {
                        self.baseBranchErrorLabel.stringValue = "Branch \"\(branchToValidate)\" does not exist."
                        self.baseBranchErrorLabel.isHidden = false
                        self.resizeWindowToFitContent()
                    }
                }
            }
            return
        }

        performAccept(item: item, rawPrompt: rawPrompt, rawDesc: rawDesc, rawBranch: rawBranch, rawBaseBranch: rawBaseBranch, rawTitle: rawTitle)
    }

    /// Returns the repo path for the currently selected project context.
    private func resolvedRepoPath() -> String? {
        if let picker = projectPicker {
            let idx = picker.indexOfSelectedItem
            if idx >= 0, idx < projectPickerItems.count {
                return projectPickerItems[idx].repoPath
            }
        }
        return config.baseBranchRepoPath
    }

    private func performAccept(item: PickerItem, rawPrompt: String, rawDesc: String, rawBranch: String, rawBaseBranch: String, rawTitle: String) {
        AgentLastSelectionStore.save(item.storageRaw, for: currentDraftScope)

        // Write crash-recovery temp file before clearing the draft, so the submitted
        // content is safe even if the app crashes during thread/tab creation.
        let agentType: AgentType? = {
            if case .agent(let t, _) = item { return t }
            return nil
        }()
        let pendingPromptFileURL = rawPrompt.isEmpty ? nil : PendingInitialPromptStore.save(
            prompt: rawPrompt,
            description: rawDesc.isEmpty ? nil : rawDesc,
            branchName: rawBranch.isEmpty ? nil : rawBranch,
            agentType: agentType,
            scope: currentDraftScope
        )

        // Clear draft immediately — the modal is now clean if the user opens it again
        // while the thread/tab is still being created in the background.
        // Also clear the original scope in case the project picker changed it mid-edit,
        // so the original project's draft doesn't show stale submitted text.
        AgentLaunchPromptDraftStore.clearAll(for: currentDraftScope)
        if currentDraftScope != config.draftScope {
            AgentLaunchPromptDraftStore.clearAll(for: config.draftScope)
        }

        let selectedProject: Project? = {
            guard let picker = projectPicker else { return nil }
            let idx = picker.indexOfSelectedItem
            guard idx >= 0, idx < projectPickerItems.count else { return nil }
            return projectPickerItems[idx]
        }()

        let selectedSectionId: UUID? = {
            guard !sectionPickerItems.isEmpty else { return nil }
            let tag = sectionPicker.selectedItem?.tag ?? 0
            guard tag >= 0, tag < sectionPickerItems.count else { return nil }
            return sectionPickerItems[tag].id
        }()

        switch item {
        case .terminal:
            finish(with: AgentLaunchSheetResult(
                agentType: nil,
                useAgentCommand: false,
                prompt: rawPrompt.isEmpty ? nil : rawPrompt,
                description: nil,
                branchName: nil,
                baseBranch: rawBaseBranch.isEmpty ? nil : rawBaseBranch,
                tabTitle: rawTitle.isEmpty ? nil : rawTitle,
                pendingPromptFileURL: pendingPromptFileURL,
                selectedProject: selectedProject,
                selectedSectionId: selectedSectionId
            ))
        case .agent(let type, _):
            finish(with: AgentLaunchSheetResult(
                agentType: type,
                useAgentCommand: true,
                prompt: rawPrompt.isEmpty ? nil : rawPrompt,
                description: rawDesc.isEmpty ? nil : rawDesc,
                branchName: rawBranch.isEmpty ? nil : rawBranch,
                baseBranch: rawBaseBranch.isEmpty ? nil : rawBaseBranch,
                tabTitle: rawTitle.isEmpty ? nil : rawTitle,
                pendingPromptFileURL: pendingPromptFileURL,
                selectedProject: selectedProject,
                selectedSectionId: selectedSectionId
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
