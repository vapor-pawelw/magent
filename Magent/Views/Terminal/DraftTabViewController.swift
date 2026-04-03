import Cocoa
import MagentCore

/// Tracks an in-memory draft tab alongside terminal/web tabs.
struct DraftTabEntry {
    let identifier: String
    var agentType: AgentType
    var prompt: String
    var modelId: String?
    var reasoningLevel: String?
    var viewController: DraftTabViewController?
}

/// Displays a parked prompt draft — an idea saved for later execution.
/// Shows an agent picker (agents only), an editable prompt, and Discard / Proceed buttons.
final class DraftTabViewController: NSViewController, NSTextViewDelegate {

    let draftIdentifier: String
    private(set) var agentType: AgentType
    private(set) var prompt: String
    private(set) var modelId: String?
    private(set) var reasoningLevel: String?

    var onProceed: ((AgentType, String, String?, String?) -> Void)?
    var onDiscard: (() -> Void)?
    var onChanged: ((AgentType, String, String?, String?) -> Void)?

    private var scrollWidthConstraint: NSLayoutConstraint!
    private var scrollHeightConstraint: NSLayoutConstraint!

    private let agentPicker = NSPopUpButton()
    private let modelPicker = NSPopUpButton()
    private let reasoningPicker = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let discardButton = NSButton()
    private let proceedButton = NSButton()
    private var pickerAgentTypes: [AgentType] = []

    init(
        draftIdentifier: String,
        agentType: AgentType,
        prompt: String,
        modelId: String? = nil,
        reasoningLevel: String? = nil
    ) {
        self.draftIdentifier = draftIdentifier
        self.agentType = agentType
        self.prompt = prompt
        self.modelId = modelId
        self.reasoningLevel = reasoningLevel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = AppBackgroundView()
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    func updateContent(agentType: AgentType, prompt: String, modelId: String?, reasoningLevel: String?) {
        self.agentType = agentType
        self.prompt = prompt
        self.modelId = modelId
        self.reasoningLevel = reasoningLevel
        promptTextView.string = prompt
        if let idx = pickerAgentTypes.firstIndex(of: agentType) {
            agentPicker.selectItem(at: idx)
        }
        populateModelReasoningPickers()
        applyStoredOrLastModelReasoningSelection()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let viewSize = view.bounds.size
        // 64 = 32pt padding per side
        scrollWidthConstraint.constant = min(1200, viewSize.width - 64)
        // 180 = approximate height of header + subtitle + picker + label + buttons + spacing
        scrollHeightConstraint.constant = min(400, max(60, viewSize.height - 180))
    }

    // MARK: - UI Setup

    private func setupUI() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        // Container is centered and sizes to fit its content (the stack).
        // No edge-pinning — the container floats freely inside the view.
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Icon + title
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Draft")
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "Prompt Draft")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headerStack.addArrangedSubview(titleLabel)

        stack.addArrangedSubview(headerStack)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "This prompt is saved for later. Edit it anytime, then proceed when ready.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(subtitleLabel)

        // Agent/model/reasoning picker row
        let agentRow = NSStackView()
        agentRow.orientation = .horizontal
        agentRow.alignment = .centerY
        agentRow.spacing = 8

        let agentLabel = NSTextField(labelWithString: "Agent")
        agentLabel.font = .systemFont(ofSize: 12, weight: .medium)
        agentLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        agentRow.addArrangedSubview(agentLabel)

        buildAgentPicker()
        agentPicker.target = self
        agentPicker.action = #selector(agentPickerChanged)
        agentPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(agentPicker)

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        agentRow.addArrangedSubview(modelLabel)

        modelPicker.target = self
        modelPicker.action = #selector(modelPickerChanged)
        modelPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(modelPicker)

        let reasoningLabel = NSTextField(labelWithString: "Reasoning")
        reasoningLabel.font = .systemFont(ofSize: 12, weight: .medium)
        reasoningLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        agentRow.addArrangedSubview(reasoningLabel)

        reasoningPicker.target = self
        reasoningPicker.action = #selector(reasoningPickerChanged)
        reasoningPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        agentRow.addArrangedSubview(reasoningPicker)

        stack.addArrangedSubview(agentRow)

        // Prompt label
        let promptLabel = NSTextField(labelWithString: "Prompt")
        promptLabel.font = .systemFont(ofSize: 12, weight: .medium)
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
        promptTextView.string = prompt

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = promptTextView

        stack.addArrangedSubview(scrollView)

        // Button row
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        discardButton.title = "Discard Draft"
        discardButton.bezelStyle = .rounded
        discardButton.contentTintColor = .systemRed
        discardButton.target = self
        discardButton.action = #selector(discardTapped)
        buttonRow.addArrangedSubview(discardButton)

        proceedButton.title = "Start Agent"
        proceedButton.bezelStyle = .rounded
        proceedButton.contentTintColor = .controlAccentColor
        (proceedButton.cell as? NSButtonCell)?.backgroundColor = .controlAccentColor
        proceedButton.keyEquivalent = "\r"
        proceedButton.target = self
        proceedButton.action = #selector(proceedTapped)
        buttonRow.addArrangedSubview(proceedButton)

        stack.addArrangedSubview(buttonRow)

        // Text input size is computed in viewDidLayout based on available space,
        // capped at 1200pt wide x 400pt tall. These constraints are updated
        // dynamically so they never fight window resizing.
        scrollWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: 1200)
        scrollHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 400)

        NSLayoutConstraint.activate([
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            agentRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollWidthConstraint,
            scrollHeightConstraint,
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        populateModelReasoningPickers()
        applyStoredOrLastModelReasoningSelection()
    }

    private func buildAgentPicker() {
        let settings = PersistenceService.shared.loadSettings()
        pickerAgentTypes = settings.availableActiveAgents

        agentPicker.removeAllItems()
        let defaultType = settings.defaultAgentType
        for agent in pickerAgentTypes {
            let title = agent == defaultType ? "\(agent.displayName) (Default)" : agent.displayName
            agentPicker.addItem(withTitle: title)
        }

        if let idx = pickerAgentTypes.firstIndex(of: agentType) {
            agentPicker.selectItem(at: idx)
        }
    }

    private var selectedModelId: String? {
        guard modelPicker.indexOfSelectedItem > 0 else { return nil }
        return modelPicker.selectedItem?.representedObject as? String
    }

    private var selectedReasoningLevel: String? {
        guard reasoningPicker.indexOfSelectedItem > 0 else { return nil }
        return reasoningPicker.selectedItem?.representedObject as? String
    }

    private func populateModelReasoningPickers() {
        modelPicker.removeAllItems()
        reasoningPicker.removeAllItems()

        guard let agentConfig = AgentModelsService.shared.config(for: agentType) else { return }

        modelPicker.addItem(withTitle: "Auto")
        modelPicker.lastItem?.representedObject = nil
        for model in agentConfig.models {
            modelPicker.addItem(withTitle: model.label)
            modelPicker.lastItem?.representedObject = model.id as NSString
        }

        populateReasoningPicker(agentConfig: agentConfig, modelId: nil)
    }

    private func populateReasoningPicker(agentConfig: AgentModelConfig, modelId: String?) {
        let previousSelection = reasoningPicker.selectedItem?.representedObject as? String
        reasoningPicker.removeAllItems()
        reasoningPicker.addItem(withTitle: "Auto")
        reasoningPicker.lastItem?.representedObject = nil

        for level in agentConfig.effectiveReasoningLevels(for: modelId) {
            reasoningPicker.addItem(withTitle: level.capitalized)
            reasoningPicker.lastItem?.representedObject = level as NSString
        }

        if let previousSelection,
           let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == previousSelection }) {
            reasoningPicker.selectItem(at: matchIndex)
        }
    }

    private func applyStoredOrLastModelReasoningSelection() {
        guard let agentConfig = AgentModelsService.shared.config(for: agentType) else { return }

        let storedModelId = AgentModelsService.shared.validatedModelId(modelId, for: agentType)
            ?? AgentModelsService.shared.validatedModelId(AgentLastSelectionStore.lastModel(for: agentType), for: agentType)
        if let storedModelId,
           let matchIndex = modelPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == storedModelId }) {
            modelPicker.selectItem(at: matchIndex)
            populateReasoningPicker(agentConfig: agentConfig, modelId: storedModelId)
        } else {
            modelPicker.selectItem(at: 0)
            populateReasoningPicker(agentConfig: agentConfig, modelId: nil)
        }

        let storedReasoningLevel = AgentModelsService.shared.validatedReasoningLevel(reasoningLevel, for: agentType, modelId: selectedModelId)
            ?? AgentModelsService.shared.validatedReasoningLevel(
                AgentLastSelectionStore.lastReasoning(for: agentType, modelId: selectedModelId),
                for: agentType,
                modelId: selectedModelId
            )
        if let storedReasoningLevel,
           let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == storedReasoningLevel }) {
            reasoningPicker.selectItem(at: matchIndex)
        } else {
            reasoningPicker.selectItem(at: 0)
        }

        modelId = selectedModelId
        reasoningLevel = selectedReasoningLevel
    }

    private func notifyChanged() {
        onChanged?(agentType, promptTextView.string, selectedModelId, selectedReasoningLevel)
    }

    // MARK: - Actions

    @objc private func agentPickerChanged() {
        let idx = agentPicker.indexOfSelectedItem
        guard idx >= 0, idx < pickerAgentTypes.count else { return }
        agentType = pickerAgentTypes[idx]
        modelId = nil
        reasoningLevel = nil
        populateModelReasoningPickers()
        applyStoredOrLastModelReasoningSelection()
        notifyChanged()
    }

    @objc private func modelPickerChanged() {
        guard let agentConfig = AgentModelsService.shared.config(for: agentType) else { return }
        let modelId = selectedModelId
        populateReasoningPicker(agentConfig: agentConfig, modelId: modelId)
        // Restore last reasoning selection for this specific model
        if let lastReasoning = AgentLastSelectionStore.lastReasoning(for: agentType, modelId: modelId),
           let matchIndex = reasoningPicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == lastReasoning }) {
            reasoningPicker.selectItem(at: matchIndex)
        }
        self.modelId = modelId
        self.reasoningLevel = selectedReasoningLevel
        AgentLastSelectionStore.saveModel(modelId, for: agentType)
        AgentLastSelectionStore.saveReasoning(selectedReasoningLevel, for: agentType, modelId: modelId)
        notifyChanged()
    }

    @objc private func reasoningPickerChanged() {
        modelId = selectedModelId
        reasoningLevel = selectedReasoningLevel
        AgentLastSelectionStore.saveModel(modelId, for: agentType)
        AgentLastSelectionStore.saveReasoning(reasoningLevel, for: agentType, modelId: modelId)
        notifyChanged()
    }

    @objc private func discardTapped() {
        let alert = NSAlert()
        alert.messageText = "Discard Draft?"
        alert.informativeText = "This will permanently delete this draft prompt. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDiscard?()
    }

    @objc private func proceedTapped() {
        let trimmed = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        onProceed?(agentType, trimmed, selectedModelId, selectedReasoningLevel)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        prompt = promptTextView.string
        notifyChanged()
    }
}
