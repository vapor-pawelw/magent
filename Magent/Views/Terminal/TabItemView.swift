import Cocoa

final class TabItemView: NSView, NSMenuDelegate {

    let pinIcon: NSImageView
    let busySpinner: NSProgressIndicator
    let completionDot: NSView
    let rateLimitIcon: NSImageView
    let titleLabel: NSTextField
    let closeButton: NSButton
    var isDragging = false

    var isSelected = false {
        didSet { updateAppearance() }
    }

    var showCloseButton: Bool {
        get { !closeButton.isHidden }
        set { closeButton.isHidden = !newValue }
    }

    var showPinIcon: Bool {
        get { !pinIcon.isHidden }
        set { pinIcon.isHidden = !newValue }
    }

    var hasUnreadCompletion: Bool = false {
        didSet { updateIndicator() }
    }

    var hasWaitingForInput: Bool = false {
        didSet { updateIndicator() }
    }

    var hasBusy: Bool = false {
        didSet { updateIndicator() }
    }

    var hasRateLimit: Bool = false {
        didSet { updateIndicator() }
    }

    var rateLimitTooltip: String? {
        didSet { updateIndicator() }
    }

    private func updateIndicator() {
        if hasWaitingForInput {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            rateLimitIcon.isHidden = true
            completionDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            completionDot.isHidden = false
        } else if hasBusy {
            completionDot.isHidden = true
            rateLimitIcon.isHidden = true
            busySpinner.isHidden = false
            busySpinner.startAnimation(nil)
        } else if hasRateLimit {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            completionDot.isHidden = true
            rateLimitIcon.toolTip = rateLimitTooltip ?? "Rate limit reached"
            rateLimitIcon.isHidden = false
        } else if hasUnreadCompletion {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            rateLimitIcon.isHidden = true
            completionDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            completionDot.isHidden = false
        } else {
            busySpinner.stopAnimation(nil)
            busySpinner.isHidden = true
            completionDot.isHidden = true
            rateLimitIcon.isHidden = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !busySpinner.isHidden {
            busySpinner.startAnimation(nil)
        }
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onPin: (() -> Void)?
    var onContinueIn: ((AgentType) -> Void)?
    var onExportContext: (() -> Void)?
    var onCloseTabsToTheRight: (() -> Void)?
    var onCloseTabsToTheLeft: (() -> Void)?
    var availableAgentsForContinue: [AgentType] = []
    var tabIndex: Int = 0
    var totalTabCount: Int = 0

    init(title: String) {
        pinIcon = NSImageView()
        busySpinner = NSProgressIndicator()
        completionDot = NSView()
        rateLimitIcon = NSImageView()
        titleLabel = NSTextField(labelWithString: title)
        closeButton = NSButton()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Pin icon
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinIcon.contentTintColor = NSColor(resource: .textSecondary)
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.isHidden = true
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)

        // Completion dot (green circle)
        completionDot.wantsLayer = true
        completionDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        completionDot.layer?.cornerRadius = 4
        completionDot.translatesAutoresizingMaskIntoConstraints = false
        completionDot.isHidden = true
        completionDot.setContentHuggingPriority(.required, for: .horizontal)
        completionDot.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Busy spinner
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isIndeterminate = true
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        busySpinner.isHidden = true
        busySpinner.setContentHuggingPriority(.required, for: .horizontal)
        busySpinner.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Rate-limit icon
        rateLimitIcon.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Rate limited")
        rateLimitIcon.contentTintColor = .systemRed
        rateLimitIcon.translatesAutoresizingMaskIntoConstraints = false
        rateLimitIcon.isHidden = true
        rateLimitIcon.setContentHuggingPriority(.required, for: .horizontal)
        rateLimitIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.isEditable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Close button — use xmark.circle.fill for visibility
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.contentTintColor = NSColor(resource: .textSecondary)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Layout using an internal stack
        let contentStack = NSStackView(views: [pinIcon, completionDot, busySpinner, rateLimitIcon, titleLabel, closeButton])
        contentStack.orientation = .horizontal
        contentStack.spacing = 4
        contentStack.alignment = .centerY
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12),
            completionDot.widthAnchor.constraint(equalToConstant: 8),
            completionDot.heightAnchor.constraint(equalToConstant: 8),
            busySpinner.widthAnchor.constraint(equalToConstant: 10),
            busySpinner.heightAnchor.constraint(equalToConstant: 10),
            rateLimitIcon.widthAnchor.constraint(equalToConstant: 10),
            rateLimitIcon.heightAnchor.constraint(equalToConstant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Right-click menu
        let tabMenu = NSMenu()
        tabMenu.delegate = self
        menu = tabMenu

        updateAppearance()
        updateIndicator()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // point is in superview coordinates
        guard frame.contains(point) else { return nil }
        let localPoint = convert(point, from: superview)
        // Let the close button handle its own clicks
        if !closeButton.isHidden {
            let closeLocal = closeButton.convert(localPoint, from: self)
            if closeButton.bounds.contains(closeLocal) {
                return closeButton
            }
        }
        // Everything else routes to self so mouseDown always fires
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle mouse button (button 2) closes the tab
        if event.buttonNumber == 2 {
            onClose?()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func renameTapped() {
        onRename?()
    }

    @objc private func pinTapped() {
        onPin?()
    }

    @objc private func continueInAgentTapped(_ sender: NSMenuItem) {
        guard let agent = sender.representedObject as? AgentType else { return }
        onContinueIn?(agent)
    }

    @objc private func exportContextTapped() {
        onExportContext?()
    }

    @objc private func closeTabsToTheRightTapped() {
        onCloseTabsToTheRight?()
    }

    @objc private func closeTabsToTheLeftTapped() {
        onCloseTabsToTheLeft?()
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected
            ? NSColor(resource: .primaryBrand).withAlphaComponent(0.2).cgColor
            : NSColor(resource: .surface).withAlphaComponent(0.5).cgColor
        titleLabel.textColor = isSelected ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pinTitle = showPinIcon ? "Unpin Tab" : "Pin Tab"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinTapped), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if onRename != nil {
            menu.addItem(.separator())
            let renameItem = NSMenuItem(title: "Rename Tab...", action: #selector(renameTapped), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
        }

        // Context transfer items
        if !availableAgentsForContinue.isEmpty || onExportContext != nil {
            menu.addItem(.separator())
        }

        if !availableAgentsForContinue.isEmpty {
            let continueItem = NSMenuItem(title: "Continue in...", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for agent in availableAgentsForContinue {
                let agentItem = NSMenuItem(
                    title: agent.displayName,
                    action: #selector(continueInAgentTapped(_:)),
                    keyEquivalent: ""
                )
                agentItem.target = self
                agentItem.representedObject = agent
                submenu.addItem(agentItem)
            }
            continueItem.submenu = submenu
            menu.addItem(continueItem)
        }

        if onExportContext != nil {
            let exportItem = NSMenuItem(
                title: "Export as Markdown...",
                action: #selector(exportContextTapped),
                keyEquivalent: ""
            )
            exportItem.target = self
            menu.addItem(exportItem)
        }

        // Close tabs section
        let hasTabsToRight = tabIndex < totalTabCount - 1
        let hasTabsToLeft = tabIndex > 0

        if hasTabsToRight || hasTabsToLeft {
            menu.addItem(.separator())

            if hasTabsToRight {
                let closeRightItem = NSMenuItem(
                    title: "Close Tabs to the Right",
                    action: #selector(closeTabsToTheRightTapped),
                    keyEquivalent: ""
                )
                closeRightItem.target = self
                if hasTabsToLeft {
                    closeRightItem.isAlternate = false
                }
                menu.addItem(closeRightItem)
            }

            if hasTabsToLeft && hasTabsToRight {
                // Option-alternate: shows "Close Tabs to the Left" when Option is held
                let closeLeftItem = NSMenuItem(
                    title: "Close Tabs to the Left",
                    action: #selector(closeTabsToTheLeftTapped),
                    keyEquivalent: ""
                )
                closeLeftItem.target = self
                closeLeftItem.isAlternate = true
                closeLeftItem.keyEquivalentModifierMask = .option
                menu.addItem(closeLeftItem)
            } else if hasTabsToLeft && !hasTabsToRight {
                let closeLeftItem = NSMenuItem(
                    title: "Close Tabs to the Left",
                    action: #selector(closeTabsToTheLeftTapped),
                    keyEquivalent: ""
                )
                closeLeftItem.target = self
                menu.addItem(closeLeftItem)
            }
        }

        // "Close this tab" — always at the bottom
        menu.addItem(.separator())
        let closeThisItem = NSMenuItem(title: "Close This Tab", action: #selector(closeTapped), keyEquivalent: "")
        closeThisItem.target = self
        menu.addItem(closeThisItem)
    }
}
