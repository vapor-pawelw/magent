import AppKit

/// Builds an NSMenu with agent type choices (project default, each active agent, terminal).
///
/// Callers provide a `target`/`action` pair and optional extra data to merge into
/// each item's `representedObject` dictionary.
enum AgentMenuBuilder {

    /// Populates `menu` with agent items.
    ///
    /// Each item's `representedObject` is `[String: String]` with keys:
    ///   - `"mode"`: `"default"`, `"agent"`, or `"terminal"`
    ///   - `"agentRaw"`: raw value when mode is `"agent"`
    ///   - Plus any entries from `extraData`.
    static func populate(
        menu: NSMenu,
        defaultAgentName: String?,
        activeAgents: [AgentType],
        target: AnyObject,
        action: Selector,
        extraData: [String: String] = [:]
    ) {
        if let name = defaultAgentName {
            let item = NSMenuItem(
                title: "Use Project Default (\(name))",
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = extraData.merging(["mode": "default"]) { _, new in new }
            menu.addItem(item)
        }

        for agent in activeAgents {
            let item = NSMenuItem(title: agent.displayName, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = extraData.merging([
                "mode": "agent",
                "agentRaw": agent.rawValue,
            ]) { _, new in new }
            menu.addItem(item)
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let terminalItem = NSMenuItem(title: "Terminal", action: action, keyEquivalent: "")
        terminalItem.target = target
        terminalItem.representedObject = extraData.merging(["mode": "terminal"]) { _, new in new }
        menu.addItem(terminalItem)
    }

    /// Parses the selection from a menu item's `representedObject`.
    struct Selection {
        enum Mode {
            case projectDefault
            case agent(AgentType)
            case terminal
        }
        let mode: Mode
        let data: [String: String]
    }

    static func parseSelection(from sender: NSMenuItem) -> Selection? {
        guard let data = sender.representedObject as? [String: String] else { return nil }
        let mode = data["mode"] ?? "default"
        switch mode {
        case "terminal":
            return Selection(mode: .terminal, data: data)
        case "agent":
            let raw = data["agentRaw"] ?? ""
            return Selection(mode: .agent(AgentType(rawValue: raw) ?? .claude), data: data)
        default:
            return Selection(mode: .projectDefault, data: data)
        }
    }
}
