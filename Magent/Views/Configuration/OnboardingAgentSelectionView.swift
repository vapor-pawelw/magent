import Cocoa

final class OnboardingAgentSelectionView: NSView {

    var selectedAgents: [AgentType] {
        var agents: [AgentType] = []
        if claudeCheckbox.state == .on { agents.append(.claude) }
        if codexCheckbox.state == .on { agents.append(.codex) }
        if customCheckbox.state == .on { agents.append(.custom) }
        return agents
    }

    var defaultAgent: AgentType? {
        let agents = selectedAgents
        guard agents.count > 1 else { return nil }
        let index = defaultAgentPopup.indexOfSelectedItem
        guard index >= 0, index < agents.count else { return agents.first }
        return agents[index]
    }

    var customCommand: String {
        customCommandField.stringValue
    }

    private let claudeCheckbox = NSButton(checkboxWithTitle: AgentType.claude.displayName, target: nil, action: nil)
    private let codexCheckbox = NSButton(checkboxWithTitle: AgentType.codex.displayName, target: nil, action: nil)
    private let customCheckbox = NSButton(checkboxWithTitle: AgentType.custom.displayName, target: nil, action: nil)
    private let defaultAgentSection = NSStackView()
    private let defaultAgentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customCommandSection = NSStackView()
    private let customCommandField = NSTextField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        let titleLabel = NSTextField(labelWithString: "Active Agents")
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let descLabel = NSTextField(
            wrappingLabelWithString: "Enable agents that can be launched in new threads. If multiple are enabled, choose a default."
        )
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)

        claudeCheckbox.state = .on
        claudeCheckbox.target = self
        claudeCheckbox.action = #selector(agentToggled)

        codexCheckbox.state = .off
        codexCheckbox.target = self
        codexCheckbox.action = #selector(agentToggled)

        customCheckbox.state = .off
        customCheckbox.target = self
        customCheckbox.action = #selector(agentToggled)

        // Default agent section
        let defaultLabel = NSTextField(labelWithString: "Default Agent")
        defaultLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let defaultDesc = NSTextField(labelWithString: "Used when no agent is explicitly selected for a new thread.")
        defaultDesc.font = .systemFont(ofSize: 11)
        defaultDesc.textColor = NSColor(resource: .textSecondary)

        defaultAgentSection.orientation = .vertical
        defaultAgentSection.alignment = .leading
        defaultAgentSection.spacing = 4
        defaultAgentSection.addArrangedSubview(defaultLabel)
        defaultAgentSection.addArrangedSubview(defaultDesc)
        defaultAgentSection.addArrangedSubview(defaultAgentPopup)
        defaultAgentSection.isHidden = true

        // Custom command section
        let customLabel = NSTextField(labelWithString: "Custom Agent Command")
        customLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        customCommandField.stringValue = "claude"
        customCommandField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        customCommandField.placeholderString = "e.g. aider, goose"
        customCommandField.translatesAutoresizingMaskIntoConstraints = false

        customCommandSection.orientation = .vertical
        customCommandSection.alignment = .leading
        customCommandSection.spacing = 4
        customCommandSection.addArrangedSubview(customLabel)
        customCommandSection.addArrangedSubview(customCommandField)
        customCommandSection.isHidden = true

        let stack = NSStackView(views: [
            titleLabel, descLabel,
            claudeCheckbox, codexCheckbox, customCheckbox,
            defaultAgentSection,
            customCommandSection,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Add extra spacing before sections
        stack.setCustomSpacing(16, after: customCheckbox)
        stack.setCustomSpacing(16, after: defaultAgentSection)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            customCommandField.widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    @objc private func agentToggled() {
        let agents = selectedAgents

        // Default agent popup
        if agents.count > 1 {
            defaultAgentPopup.removeAllItems()
            for agent in agents {
                defaultAgentPopup.addItem(withTitle: agent.displayName)
            }
            defaultAgentPopup.selectItem(at: 0)
            defaultAgentSection.isHidden = false
        } else {
            defaultAgentSection.isHidden = true
        }

        // Custom command field
        customCommandSection.isHidden = !agents.contains(.custom)
    }
}
