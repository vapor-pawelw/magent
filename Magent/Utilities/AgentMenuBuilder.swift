import AppKit
import MagentCore

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
        menuTitle: String? = nil,
        defaultAgentName: String?,
        activeAgents: [AgentType],
        includeTerminal: Bool = true,
        target: AnyObject,
        action: Selector,
        extraData: [String: String] = [:]
    ) {
        if let title = menuTitle {
            let headerItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            headerItem.attributedTitle = NSAttributedString(string: title, attributes: attrs)
            menu.addItem(headerItem)
            menu.addItem(.separator())
        }

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

        if includeTerminal, !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        if includeTerminal {
            let terminalItem = NSMenuItem(title: "Terminal", action: action, keyEquivalent: "")
            terminalItem.target = target
            terminalItem.representedObject = extraData.merging(["mode": "terminal"]) { _, new in new }
            menu.addItem(terminalItem)

            let webItem = NSMenuItem(title: "Web", action: action, keyEquivalent: "")
            webItem.target = target
            webItem.representedObject = extraData.merging(["mode": "web"]) { _, new in new }
            menu.addItem(webItem)
        }
    }

    /// Parses the selection from a menu item's `representedObject`.
    struct Selection {
        enum Mode {
            case projectDefault
            case agent(AgentType)
            case terminal
            case web
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
        case "web":
            return Selection(mode: .web, data: data)
        default:
            return Selection(mode: .projectDefault, data: data)
        }
    }
}
