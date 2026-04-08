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

    /// Clears drafts for all modes (agent, terminal, web, and the legacy key).
    static func clearAll(for scope: AgentLaunchPromptDraftScope) {
        var drafts = persistence.loadAgentLaunchPromptDrafts()
        drafts.removeValue(forKey: scope.storageKey(mode: "agent"))
        drafts.removeValue(forKey: scope.storageKey(mode: "terminal"))
        drafts.removeValue(forKey: scope.storageKey(mode: "web"))
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
    /// Selected model id at submission time (e.g. "opus", "gpt-5.4"). Nil = agent default.
    let modelId: String?
    /// Selected reasoning level at submission time (e.g. "high", "max"). Nil = agent default.
    let reasoningLevel: String?
    /// Original picker selection (`agent rawValue`, `terminal`, or `web`) for exact recovery.
    let selectionRaw: String?

    init(
        scopeKind: ScopeKind,
        projectId: UUID?,
        threadId: UUID?,
        prompt: String,
        description: String?,
        branchName: String?,
        agentType: AgentType?,
        createdAt: Date,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        selectionRaw: String? = nil
    ) {
        self.scopeKind = scopeKind
        self.projectId = projectId
        self.threadId = threadId
        self.prompt = prompt
        self.description = description
        self.branchName = branchName
        self.agentType = agentType
        self.createdAt = createdAt
        self.modelId = modelId
        self.reasoningLevel = reasoningLevel
        self.selectionRaw = selectionRaw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scopeKind = try container.decode(ScopeKind.self, forKey: .scopeKind)
        projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        threadId = try container.decodeIfPresent(UUID.self, forKey: .threadId)
        prompt = try container.decode(String.self, forKey: .prompt)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Backwards-compatible: old temp files won't have these keys.
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        reasoningLevel = try container.decodeIfPresent(String.self, forKey: .reasoningLevel)
        selectionRaw = try container.decodeIfPresent(String.self, forKey: .selectionRaw)
    }
}

extension String {
    func magentPromptPreview(maxLength: Int, singleLine: Bool) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized: String
        if singleLine {
            normalized = trimmed.replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        } else {
            normalized = trimmed.replacingOccurrences(
                of: #"[ \t]+\n"#,
                with: "\n",
                options: .regularExpression
            )
        }

        guard normalized.count > maxLength else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return normalized[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
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
        scope: AgentLaunchPromptDraftScope,
        modelId: String? = nil,
        reasoningLevel: String? = nil,
        selectionRaw: String? = nil
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
            createdAt: Date(),
            modelId: modelId,
            reasoningLevel: reasoningLevel,
            selectionRaw: selectionRaw
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

    /// Schedules deletion of `fileURL` once a prompt-bearing `magentAgentKeysInjected`
    /// fires for `sessionName`. Falls back to deleting after 60 s in case injection
    /// never fires (e.g. session dies).
    @MainActor
    static func clearAfterInjection(fileURL: URL, sessionName: String) {
        final class Once: @unchecked Sendable { var token: NSObjectProtocol? }
        let once = Once()
        once.token = NotificationCenter.default.addObserver(
            forName: .magentAgentKeysInjected, object: nil, queue: .main
        ) { [once] notification in
            guard (notification.userInfo?["sessionName"] as? String) == sessionName else { return }
            guard (notification.userInfo?["includedInitialPrompt"] as? Bool) == true else { return }
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
    let modelId: String?
    let reasoningLevel: String?
    let selectionRaw: String?
    let isDraft: Bool
}

enum AgentLastSelectionStore {
    private static let persistence = PersistenceService.shared
    private static let globalKey = "global"

    static func lastSelection(for scope: AgentLaunchPromptDraftScope) -> String? {
        let selections = persistence.loadAgentLastSelections()
        // Try global key first, fall back to legacy per-scope key for backwards compat
        return selections[globalKey] ?? selections[scope.storageKey]
    }

    static func save(_ selectionRaw: String, for scope: AgentLaunchPromptDraftScope) {
        var selections = persistence.loadAgentLastSelections()
        selections[globalKey] = selectionRaw
        persistence.saveAgentLastSelections(selections)
    }

    // MARK: - Per-Agent Model & Reasoning

    /// Keys for per-agent model/reasoning last selections, stored alongside the type selections.
    private static func modelKey(for agentType: AgentType) -> String { "model:\(agentType.rawValue)" }
    /// Reasoning is keyed per model (agent+model), not just per agent type,
    /// because different models have different reasoning capabilities.
    private static func reasoningKey(for agentType: AgentType, modelId: String?) -> String {
        if let modelId {
            return "reasoning:\(agentType.rawValue):\(modelId)"
        }
        return "reasoning:\(agentType.rawValue)"
    }

    static func lastModel(for agentType: AgentType) -> String? {
        persistence.loadAgentLastSelections()[modelKey(for: agentType)]
    }

    static func lastReasoning(for agentType: AgentType, modelId: String?) -> String? {
        persistence.loadAgentLastSelections()[reasoningKey(for: agentType, modelId: modelId)]
    }

    static func saveModel(_ modelId: String?, for agentType: AgentType) {
        var selections = persistence.loadAgentLastSelections()
        selections[modelKey(for: agentType)] = modelId
        persistence.saveAgentLastSelections(selections)
    }

    static func saveReasoning(_ level: String?, for agentType: AgentType, modelId: String?) {
        var selections = persistence.loadAgentLastSelections()
        selections[reasoningKey(for: agentType, modelId: modelId)] = level
        persistence.saveAgentLastSelections(selections)
    }
}

struct AgentLaunchSheetConfig {
    let title: String
    let acceptButtonTitle: String
    let draftScope: AgentLaunchPromptDraftScope
    let availableAgents: [AgentType]
    let defaultAgentType: AgentType?
    /// When true, keep the picker agent-only.
    let isAgentOnly: Bool
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
    /// When false, hide the initial prompt label/input entirely.
    let showPromptInputArea: Bool
    /// When true, a "Draft" checkbox is shown (only enabled for agent mode).
    let showDraftCheckbox: Bool
    /// When non-nil, overrides the default prompt label text (e.g. "Extra context" instead of "Initial prompt").
    let promptLabelOverride: String?

    init(
        title: String,
        acceptButtonTitle: String,
        draftScope: AgentLaunchPromptDraftScope,
        availableAgents: [AgentType],
        defaultAgentType: AgentType?,
        isAgentOnly: Bool = false,
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
        defaultBranchName: String? = nil,
        showPromptInputArea: Bool = true,
        showDraftCheckbox: Bool = false,
        promptLabelOverride: String? = nil
    ) {
        self.title = title
        self.acceptButtonTitle = acceptButtonTitle
        self.draftScope = draftScope
        self.availableAgents = availableAgents
        self.defaultAgentType = defaultAgentType
        self.isAgentOnly = isAgentOnly
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
        self.showPromptInputArea = showPromptInputArea
        self.showDraftCheckbox = showDraftCheckbox
        self.promptLabelOverride = promptLabelOverride
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
    /// URL for web tab creation. Non-nil when the user selected the "Web" type.
    let initialWebURL: URL?
    /// When true, the prompt should be saved as a draft tab instead of being executed immediately.
    let isDraft: Bool
    /// Selected model id (e.g. "opus", "gpt-5.4"), nil means use agent default.
    let modelId: String?
    /// Selected reasoning level (e.g. "high", "max"), nil means use agent default.
    let reasoningLevel: String?
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
    private static let sheetContentWidth: CGFloat = 620

    private let config: AgentLaunchSheetConfig
    private let agentPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let descriptionField = NSTextField()
    private let branchField = NSTextField()
    private let baseBranchField = NSComboBox()
    private let baseBranchErrorLabel = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let draftCheckbox = NSButton(checkboxWithTitle: "Draft", target: nil, action: nil)
    private var draftCheckboxRow: NSView?
    private let rememberCheckbox = NSButton(checkboxWithTitle: "Remember type selection", target: nil, action: nil)
    private let switchToNewThreadCheckbox = NSButton(checkboxWithTitle: "Switch to new thread", target: nil, action: nil)
    private let switchToNewTabCheckbox = NSButton(checkboxWithTitle: "Switch to new tab", target: nil, action: nil)
    private let modelPicker = NSPopUpButton()
    private let reasoningPicker = NSPopUpButton()
    private var modelReasoningViews: [NSView] = []
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let acceptButton: NSButton
    private var promptScrollView: NSScrollView!
    private var promptLabel: NSTextField!
    private var promptHeightConstraint: NSLayoutConstraint?
    private var promptPlaceholderLabel: NSTextField?
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
    // When section is inlined into the project row, we track its label separately for show/hide.
    private var sectionPickerLabel: NSTextField?

    private enum PickerItem {
        case agent(AgentType, isDefault: Bool)
        case terminal
        case web

        var storageRaw: String {
            switch self {
            case .agent(let type, _): return type.rawValue
            case .terminal: return "terminal"
            case .web: return "web"
            }
        }
    }

    init(config: AgentLaunchSheetConfig) {
        self.config = config
        self.acceptButton = NSButton(title: config.acceptButtonTitle, target: nil, action: nil)
        self.currentDraftScope = config.draftScope
        self.projectPickerItems = config.availableProjects

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetContentWidth, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = config.title
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        AgentModelsService.shared.refreshIfThrottled()
        buildPickerItems()
        setupUI()
        if let prefill = config.recoveryPrefill {
            // Recovery mode: pre-select the recovered agent type, then populate fields.
            // Skip draft loading — we're restoring submitted content, not a mid-edit draft.
            applyRecoverySelection(prefill)
            syncModelReasoningToCurrentAgent()
            applyRecoveryModelReasoningSelection(prefill)
            previousMode = currentMode
            applyRecoveryPrefill(prefill)
        } else {
            applyLastSelection()
            syncModelReasoningToCurrentAgent()
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
            if self.config.showPromptInputArea {
                window.makeFirstResponder(self.promptTextView)
            } else if self.config.showTitleField {
                window.makeFirstResponder(self.titleField)
            } else {
                window.makeFirstResponder(self.agentPicker)
            }
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
        if !config.isAgentOnly {
            pickerItems.append(.terminal)
            pickerItems.append(.web)
        }

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
            case .web:
                agentPicker.addItem(withTitle: "Web")
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

    private func applyRecoverySelection(_ prefill: AgentLaunchSheetPrefill) {
        if let selectionRaw = prefill.selectionRaw,
           let index = pickerItems.firstIndex(where: { $0.storageRaw == selectionRaw }) {
            agentPicker.selectItem(withTag: index)
            return
        }

        guard let agentType = prefill.agentType,
              let index = pickerItems.firstIndex(where: {
                  if case .agent(let t, _) = $0 { return t == agentType }
                  return false
              }) else { return }
        agentPicker.selectItem(withTag: index)
    }

    private func applyRecoveryModelReasoningSelection(_ prefill: AgentLaunchSheetPrefill) {
        if let modelId = prefill.modelId,
           let matchIndex = modelPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == modelId }) {
            modelPicker.selectItem(at: matchIndex)
            if let agentType = selectedAgentTypeForModelPicker,
               let agentConfig = AgentModelsService.shared.config(for: agentType) {
                populateReasoningPicker(agentConfig: agentConfig, modelId: modelId)
            }
        }

        if let reasoningLevel = prefill.reasoningLevel,
           let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == reasoningLevel }) {
            reasoningPicker.selectItem(at: matchIndex)
        }
    }

    private func applyRecoveryPrefill(_ prefill: AgentLaunchSheetPrefill) {
        if config.showPromptInputArea {
            promptTextView.string = prefill.prompt
        }
        if config.showDescriptionAndBranchFields {
            descriptionField.stringValue = prefill.description ?? ""
            branchField.stringValue = prefill.branchName ?? ""
        }
        if config.showDraftCheckbox {
            draftCheckbox.state = prefill.isDraft && currentMode == "agent" ? .on : .off
        }
    }

    private func setupUI() {
        guard let window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView
        contentView.widthAnchor.constraint(equalToConstant: Self.sheetContentWidth).isActive = true

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
        // When a project picker is also shown, section is inlined in the same row.
        if case .newThread(let projectId) = config.draftScope {
            if projectPickerItems.count > 1, let projectRow = projectPickerRow as? NSStackView {
                let label = makeFormLabel("Section")
                sectionPickerLabel = label
                projectRow.addArrangedSubview(label)
                sectionPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
                projectRow.addArrangedSubview(sectionPicker)
            } else {
                let row = makeSectionPickerRow()
                stack.addArrangedSubview(row)
                stack.setCustomSpacing(10, after: row)
                sectionPickerRow = row
            }
            populateSectionPicker(for: projectId)
        }

        // Agent / Model / Reasoning picker row (single line)
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

        let modelLabel = makeFormLabel("Model")
        agentRow.addArrangedSubview(modelLabel)

        modelPicker.target = self
        modelPicker.action = #selector(modelPickerChanged)
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(modelPicker)

        let reasoningLabel = makeFormLabel("Reasoning")
        agentRow.addArrangedSubview(reasoningLabel)

        reasoningPicker.target = self
        reasoningPicker.action = #selector(reasoningPickerChanged)
        reasoningPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(reasoningPicker)

        modelReasoningViews = [modelLabel, modelPicker, reasoningLabel, reasoningPicker]

        stack.addArrangedSubview(agentRow)
        populateModelReasoningPickers()
        applyLastModelReasoningSelection()
        updateModelReasoningVisibility()

        let promptFont = NSFont.systemFont(ofSize: 13)
        var lastFieldView: NSView = agentRow
        if config.showPromptInputArea {
            // Prompt label
            promptLabel = makeFormLabel(promptLabelText)
            stack.addArrangedSubview(promptLabel)
            stack.setCustomSpacing(4, after: promptLabel)

            // Prompt text view
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

            // Placeholder label overlaid on the scroll view (stays fixed during horizontal scroll)
            let placeholder = NSTextField(labelWithString: "")
            placeholder.font = promptFont
            placeholder.textColor = .placeholderTextColor
            placeholder.drawsBackground = false
            placeholder.isBordered = false
            placeholder.isEditable = false
            placeholder.isSelectable = false
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            placeholder.isHidden = true
            promptScrollView.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: promptScrollView.leadingAnchor, constant: 12),
                placeholder.centerYAnchor.constraint(equalTo: promptScrollView.centerYAnchor),
            ])
            promptPlaceholderLabel = placeholder

            stack.addArrangedSubview(promptScrollView)
            lastFieldView = promptScrollView

            // Draft checkbox — right-aligned below the prompt, only visible for agent mode
            if config.showDraftCheckbox {
                draftCheckbox.state = .off
                draftCheckbox.font = .systemFont(ofSize: 11)
                draftCheckbox.contentTintColor = .controlAccentColor
                draftCheckbox.toolTip = "Save this prompt as a draft tab instead of running it immediately"
                draftCheckbox.target = self
                draftCheckbox.action = #selector(draftCheckboxChanged)

                let draftRow = NSStackView()
                draftRow.orientation = .horizontal
                draftRow.alignment = .centerY
                draftRow.translatesAutoresizingMaskIntoConstraints = false
                let draftSpacer = NSView()
                draftSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                draftSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                draftRow.addArrangedSubview(draftSpacer)
                draftRow.addArrangedSubview(draftCheckbox)

                stack.setCustomSpacing(4, after: promptScrollView)
                stack.addArrangedSubview(draftRow)
                NSLayoutConstraint.activate([draftRow.widthAnchor.constraint(equalTo: stack.widthAnchor)])
                stack.setCustomSpacing(14, after: draftRow)
                draftCheckboxRow = draftRow
                updateDraftCheckboxVisibility()
                lastFieldView = draftRow
            }
        }

        let lineHeight = promptFont.ascender + abs(promptFont.descender) + promptFont.leading
        let agentPromptHeight = max((lineHeight * 7) + 20, 130)

        // Title field (for tab title)
        var titleRow: NSStackView?
        if config.showTitleField {
            stack.setCustomSpacing(12, after: lastFieldView)

            let tr = makeTextFieldRow(label: "Title", field: titleField, placeholder: "Optional")
            stack.addArrangedSubview(tr)
            titleRow = tr

            if config.showPromptInputArea {
                promptTextView.nextKeyView = titleField
            } else {
                agentPicker.nextKeyView = titleField
            }
            lastFieldView = tr
        }

        // Description + Branch fields
        var descRow: NSStackView?
        var branchRow: NSStackView?
        var baseBranchRow: NSStackView?
        if config.showDescriptionAndBranchFields {
            stack.setCustomSpacing(12, after: lastFieldView)

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
            if config.showPromptInputArea {
                promptTextView.nextKeyView = descriptionField
            } else if config.showTitleField {
                titleField.nextKeyView = descriptionField
            } else {
                agentPicker.nextKeyView = descriptionField
            }
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
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last ?? lastFieldView)
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

        // Switch to new thread/tab checkbox
        switch config.draftScope {
        case .newThread:
            switchToNewThreadCheckbox.target = self
            switchToNewThreadCheckbox.action = #selector(switchToNewThreadCheckboxToggled)
            switchToNewThreadCheckbox.state = PersistenceService.shared.loadSettings().switchToNewlyCreatedThread ? .on : .off
            switchToNewThreadCheckbox.font = .systemFont(ofSize: 11)
            switchToNewThreadCheckbox.contentTintColor = .controlAccentColor
            stack.addArrangedSubview(switchToNewThreadCheckbox)
        case .newTab:
            switchToNewTabCheckbox.target = self
            switchToNewTabCheckbox.action = #selector(switchToNewTabCheckboxToggled)
            switchToNewTabCheckbox.state = PersistenceService.shared.loadSettings().switchToNewlyCreatedTab ? .on : .off
            switchToNewTabCheckbox.font = .systemFont(ofSize: 11)
            switchToNewTabCheckbox.contentTintColor = .controlAccentColor
            stack.addArrangedSubview(switchToNewTabCheckbox)
        }

        // Button row
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? lastFieldView)

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
            agentPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            optionalNotice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ] + (contextChip.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? [])
          + (projectPickerRow.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? [])
          + (sectionPickerRow.map { [$0.widthAnchor.constraint(equalTo: stack.widthAnchor)] } ?? []))

        if let promptLabel, let promptScrollView {
            NSLayoutConstraint.activate([
                promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
                promptScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
                {
                    let initialHeight = isSingleLinePromptMode ? singleLinePromptHeight : agentPromptHeight
                    let c = promptScrollView.heightAnchor.constraint(equalToConstant: initialHeight)
                    promptHeightConstraint = c
                    return c
                }(),
            ])
        }

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
        window.setContentSize(NSSize(width: fitting.width > 0 ? fitting.width : Self.sheetContentWidth, height: h))
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
        let hideSectionPicker = sectionPickerItems.isEmpty
        sectionPickerRow?.isHidden = hideSectionPicker
        sectionPickerLabel?.isHidden = hideSectionPicker
        sectionPicker.isHidden = hideSectionPicker

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
        if let override = config.promptLabelOverride { return override }
        switch currentMode {
        case "terminal": return "Initial command"
        case "web": return "Initial URL"
        default: return "Initial prompt"
        }
    }

    private var promptLabelPlaceholder: String? {
        switch currentMode {
        case "web": return "https://..."
        case "terminal": return "e.g. vim, htop, ssh user@host"
        default: return nil
        }
    }

    private var isSingleLinePromptMode: Bool {
        currentMode == "terminal" || currentMode == "web"
    }

    /// Height for single-line prompt fields (terminal command, web URL).
    private var singleLinePromptHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let lineHeight = font.ascender + abs(font.descender) + font.leading
        // text container inset (8 top + 8 bottom) + border padding
        return lineHeight + 20
    }

    private var currentMode: String {
        switch selectedPickerItem() {
        case .terminal?: return "terminal"
        case .web?: return "web"
        default: return "agent"
        }
    }

    private func loadDraft(mode: String) {
        guard config.showPromptInputArea || config.showDescriptionAndBranchFields else { return }
        let draft = AgentLaunchPromptDraftStore.draft(for: currentDraftScope, mode: mode)
        if config.showPromptInputArea {
            promptTextView.string = draft.prompt
        }
        if config.showDescriptionAndBranchFields && mode == "agent" {
            descriptionField.stringValue = draft.description
            branchField.stringValue = draft.branchName
        }
        if config.showDraftCheckbox {
            draftCheckbox.state = (mode == "agent" && draft.isDraft) ? .on : .off
        }
    }

    private func persistDraft(mode: String? = nil) {
        guard config.showPromptInputArea || config.showDescriptionAndBranchFields else { return }
        let mode = mode ?? currentMode
        AgentLaunchPromptDraftStore.save(
            AgentLaunchPromptDraft(
                prompt: config.showPromptInputArea ? promptTextView.string : "",
                description: mode == "agent" && config.showDescriptionAndBranchFields ? descriptionField.stringValue : "",
                branchName: mode == "agent" && config.showDescriptionAndBranchFields ? branchField.stringValue : "",
                isDraft: mode == "agent" && config.showDraftCheckbox && draftCheckbox.state == .on
            ),
            for: currentDraftScope,
            mode: mode
        )
    }

    private func applyPrefillIfNeeded() {
        guard config.showPromptInputArea else { return }
        guard currentMode != "web" else { return }
        guard promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prefill = currentMode == "terminal" ? config.terminalInjectionPrefill : config.agentContextPrefill
        if let p = prefill, !p.isEmpty {
            promptTextView.string = p
        }
    }

    func textDidChange(_ notification: Notification) {
        persistDraft()
        updatePlaceholderVisibility()
    }

    @objc private func draftCheckboxChanged() {
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
        populateModelReasoningPickers()
        applyLastModelReasoningSelection()
        updateModelReasoningVisibility()
        guard newMode != previousMode else {
            updatePromptAreaEnabled()
            resizeWindowToFitContent()
            return
        }
        // Save current text to the mode we're leaving, then load the new mode's draft
        persistDraft(mode: previousMode)
        previousMode = newMode
        loadDraft(mode: newMode)
        applyPrefillIfNeeded()
        updatePromptAreaEnabled()
        resizeWindowToFitContent()
    }

    private func selectedPickerItem() -> PickerItem? {
        guard let tag = agentPicker.selectedItem?.tag else { return nil }
        guard tag >= 0, tag < pickerItems.count else { return nil }
        return pickerItems[tag]
    }

    private func updatePromptAreaEnabled() {
        guard config.showPromptInputArea else {
            updateDraftCheckboxVisibility()
            return
        }
        // Prompt text view is always editable — for terminal it's the shell command, for agents it's the initial prompt, for web it's the URL
        promptTextView.isEditable = true
        promptTextView.alphaValue = 1.0
        promptLabel?.stringValue = promptLabelText
        updatePromptAreaStyle()
        updateDraftCheckboxVisibility()
    }

    /// Adjusts prompt area height and scroll behavior for single-line modes (terminal/web)
    /// vs multi-line agent prompt mode.
    private func updatePromptAreaStyle() {
        guard config.showPromptInputArea else { return }
        let singleLine = isSingleLinePromptMode

        // Update placeholder
        promptPlaceholderLabel?.stringValue = promptLabelPlaceholder ?? ""
        updatePlaceholderVisibility()

        if singleLine {
            promptHeightConstraint?.constant = singleLinePromptHeight
            promptScrollView?.hasVerticalScroller = false
            // Prevent wrapping so it scrolls horizontally instead
            promptTextView.textContainer?.widthTracksTextView = false
            promptTextView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            promptTextView.isHorizontallyResizable = true
            promptScrollView?.hasHorizontalScroller = false
        } else {
            let font = NSFont.systemFont(ofSize: 13)
            let lineHeight = font.ascender + abs(font.descender) + font.leading
            let agentHeight = max((lineHeight * 7) + 20, 130)
            promptHeightConstraint?.constant = agentHeight
            promptScrollView?.hasVerticalScroller = true
            promptTextView.textContainer?.widthTracksTextView = true
            promptTextView.textContainer?.containerSize = NSSize(
                width: 0,
                height: CGFloat.greatestFiniteMagnitude
            )
            promptTextView.isHorizontallyResizable = false
        }
    }

    private func updatePlaceholderVisibility() {
        let hasText = !promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPlaceholder = promptLabelPlaceholder != nil
        promptPlaceholderLabel?.isHidden = hasText || !hasPlaceholder
    }

    private func updateDraftCheckboxVisibility() {
        guard config.showDraftCheckbox else { return }
        let isAgent = currentMode == "agent"
        draftCheckboxRow?.isHidden = !isAgent
        if !isAgent {
            draftCheckbox.state = .off
        }
    }

    // MARK: - Model & Reasoning pickers

    /// Returns the currently selected agent type (non-custom), or nil for terminal/web/custom.
    private var selectedAgentTypeForModelPicker: AgentType? {
        guard let item = selectedPickerItem() else { return nil }
        if case .agent(let type, _) = item, type != .custom { return type }
        return nil
    }

    private var selectedModelId: String? {
        guard modelPicker.indexOfSelectedItem > 0 else { return nil } // index 0 = "Auto"
        return modelPicker.selectedItem?.representedObject as? String
    }

    private var selectedReasoningLevel: String? {
        guard reasoningPicker.indexOfSelectedItem > 0 else { return nil } // index 0 = "Auto"
        return reasoningPicker.selectedItem?.representedObject as? String
    }

    private func populateModelReasoningPickers() {
        modelPicker.removeAllItems()
        reasoningPicker.removeAllItems()

        guard let agentType = selectedAgentTypeForModelPicker,
              let agentConfig = AgentModelsService.shared.config(for: agentType) else {
            return
        }

        // Model picker: Default + models from manifest
        modelPicker.addItem(withTitle: "Auto")
        modelPicker.lastItem?.representedObject = nil
        for model in agentConfig.models {
            modelPicker.addItem(withTitle: model.label)
            modelPicker.lastItem?.representedObject = model.id as NSString
        }

        // Reasoning picker: populated based on current model
        populateReasoningPicker(agentConfig: agentConfig, modelId: nil)
    }

    private func populateReasoningPicker(agentConfig: AgentModelConfig, modelId: String?) {
        let previousSelection = reasoningPicker.selectedItem?.representedObject as? String
        reasoningPicker.removeAllItems()
        reasoningPicker.addItem(withTitle: "Auto")
        reasoningPicker.lastItem?.representedObject = nil
        let levels = agentConfig.effectiveReasoningLevels(for: modelId)
        for level in levels {
            reasoningPicker.addItem(withTitle: level.capitalized)
            reasoningPicker.lastItem?.representedObject = level as NSString
        }
        // Restore previous selection if still valid
        if let previousSelection {
            let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == previousSelection })
            if let matchIndex {
                reasoningPicker.selectItem(at: matchIndex)
            }
        }
    }

    private func applyLastModelReasoningSelection() {
        guard PersistenceService.shared.loadSettings().rememberLastTypeSelection else { return }
        guard let agentType = selectedAgentTypeForModelPicker else { return }

        if let lastModel = AgentLastSelectionStore.lastModel(for: agentType) {
            let matchIndex = modelPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == lastModel })
            if let matchIndex {
                modelPicker.selectItem(at: matchIndex)
                // Refresh reasoning levels for the selected model
                if let agentConfig = AgentModelsService.shared.config(for: agentType) {
                    populateReasoningPicker(agentConfig: agentConfig, modelId: lastModel)
                }
            }
        }
        let resolvedModel = selectedModelId
        if let lastReasoning = AgentLastSelectionStore.lastReasoning(for: agentType, modelId: resolvedModel) {
            let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == lastReasoning })
            if let matchIndex {
                reasoningPicker.selectItem(at: matchIndex)
            }
        }
    }

    private func updateModelReasoningVisibility() {
        let visible = selectedAgentTypeForModelPicker != nil
        for view in modelReasoningViews {
            view.isHidden = !visible
        }
    }

    /// Resync model/reasoning pickers after programmatic agent picker changes
    /// (e.g. applyLastSelection, applyRecoveryAgentSelection).
    private func syncModelReasoningToCurrentAgent() {
        populateModelReasoningPickers()
        applyLastModelReasoningSelection()
        updateModelReasoningVisibility()
    }

    @objc private func modelPickerChanged() {
        guard let agentType = selectedAgentTypeForModelPicker,
              let agentConfig = AgentModelsService.shared.config(for: agentType) else { return }
        let modelId = selectedModelId
        populateReasoningPicker(agentConfig: agentConfig, modelId: modelId)
        // Restore last reasoning selection for this specific model
        if let lastReasoning = AgentLastSelectionStore.lastReasoning(for: agentType, modelId: modelId),
           let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == lastReasoning }) {
            reasoningPicker.selectItem(at: matchIndex)
        }
        // Save immediately so fast-path picks it up
        AgentLastSelectionStore.saveModel(modelId, for: agentType)
    }

    @objc private func reasoningPickerChanged() {
        guard let agentType = selectedAgentTypeForModelPicker else { return }
        AgentLastSelectionStore.saveReasoning(selectedReasoningLevel, for: agentType, modelId: selectedModelId)
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

    @objc private func switchToNewTabCheckboxToggled() {
        var settings = PersistenceService.shared.loadSettings()
        settings.switchToNewlyCreatedTab = switchToNewTabCheckbox.state == .on
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

        // Validate base branch exists before proceeding.
        // Skip validation for empty repos (no commits) — worktree creation handles
        // the unborn-branch case and branch validation would always fail.
        if config.showDescriptionAndBranchFields, let repoPath = resolvedRepoPath() {
            let branchToValidate = rawBaseBranch.isEmpty ? resolvedDefaultBranchName() : rawBaseBranch
            acceptButton.isEnabled = false
            cancelButton.isEnabled = false
            Task { [weak self] in
                let hasCommits = await GitService.shared.repoHasCommits(repoPath: repoPath)
                let exists = hasCommits
                    ? await GitService.shared.branchExists(repoPath: repoPath, branchName: branchToValidate)
                    : true  // Empty repo — skip validation
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
        let isDraft = config.showDraftCheckbox && draftCheckbox.state == .on

        AgentLastSelectionStore.save(item.storageRaw, for: currentDraftScope)

        // Save model/reasoning selections for the current agent
        let chosenModelId = selectedModelId
        let chosenReasoningLevel = selectedReasoningLevel
        if let agentType = selectedAgentTypeForModelPicker {
            AgentLastSelectionStore.saveModel(chosenModelId, for: agentType)
            AgentLastSelectionStore.saveReasoning(chosenReasoningLevel, for: agentType, modelId: chosenModelId)
        }

        // Write crash-recovery temp file before clearing the draft, so the submitted
        // content is safe even if the app crashes during thread/tab creation.
        // Web tabs don't go through tmux injection, so skip crash-recovery for them.
        let agentType: AgentType? = {
            if case .agent(let t, _) = item { return t }
            return nil
        }()
        let pendingPromptFileURL: URL?
        if case .web = item {
            pendingPromptFileURL = nil
        } else if isDraft {
            // Drafts are persisted in the thread model, not through tmux injection —
            // skip the crash-recovery temp file so it doesn't linger as an orphan.
            pendingPromptFileURL = nil
        } else {
            pendingPromptFileURL = rawPrompt.isEmpty ? nil : PendingInitialPromptStore.save(
                prompt: rawPrompt,
                description: rawDesc.isEmpty ? nil : rawDesc,
                branchName: rawBranch.isEmpty ? nil : rawBranch,
                agentType: agentType,
                scope: currentDraftScope,
                modelId: chosenModelId,
                reasoningLevel: chosenReasoningLevel,
                selectionRaw: item.storageRaw
            )
        }

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
                selectedSectionId: selectedSectionId,
                initialWebURL: nil,
                isDraft: false,
                modelId: nil,
                reasoningLevel: nil
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
                pendingPromptFileURL: isDraft ? nil : pendingPromptFileURL,
                selectedProject: selectedProject,
                selectedSectionId: selectedSectionId,
                initialWebURL: nil,
                isDraft: isDraft,
                modelId: chosenModelId,
                reasoningLevel: chosenReasoningLevel
            ))
        case .web:
            let url = WebURLNormalizer.normalize(rawPrompt) ?? URL(string: "about:blank")!
            finish(with: AgentLaunchSheetResult(
                agentType: nil,
                useAgentCommand: false,
                prompt: nil,
                description: rawDesc.isEmpty ? nil : rawDesc,
                branchName: rawBranch.isEmpty ? nil : rawBranch,
                baseBranch: rawBaseBranch.isEmpty ? nil : rawBaseBranch,
                tabTitle: rawTitle.isEmpty ? nil : rawTitle,
                pendingPromptFileURL: nil,
                selectedProject: selectedProject,
                selectedSectionId: selectedSectionId,
                initialWebURL: url,
                isDraft: false,
                modelId: nil,
                reasoningLevel: nil
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
