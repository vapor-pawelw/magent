import Cocoa
import MagentCore

final class TabItemView: NSView, NSMenuDelegate {

    let pinIcon: NSImageView
    let keepAliveIcon: NSImageView
    let typeIcon: NSImageView
    let busySpinner: NSProgressIndicator
    let completionDot: NSView
    let rateLimitIcon: NSImageView
    let titleLabel: NSTextField
    let closeButton: NSButton
    var isDragging = false
    private let contentStack: NSStackView

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

    var showKeepAliveIcon: Bool {
        get { !keepAliveIcon.isHidden }
        set { keepAliveIcon.isHidden = !newValue }
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

    var isRateLimitPropagated: Bool = false {
        didSet { updateIndicator() }
    }

    var rateLimitTooltip: String? {
        didSet { updateIndicator() }
    }

    var isSessionDead: Bool = false {
        didSet { updateAppearance() }
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
            if isRateLimitPropagated {
                rateLimitIcon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Rate limited (propagated)")
                rateLimitIcon.contentTintColor = .systemOrange
            } else {
                rateLimitIcon.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Rate limited")
                rateLimitIcon.contentTintColor = .systemRed
            }
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
    var onForceClose: (() -> Void)?
    var onRename: (() -> Void)?
    var onPin: (() -> Void)?
    var onKeepAlive: (() -> Void)?
    var onResumeAgentInNewTab: (() -> Void)?
    var canResumeAgentInNewTab: Bool = false
    var onContinueIn: (() -> Void)?
    var onExportContext: (() -> Void)?
    var onKillSession: (() -> Void)?
    var onCloseTabsToTheRight: (() -> Void)?
    var onCloseTabsToTheLeft: (() -> Void)?
    var availableAgentsForContinue: [AgentType] = []
    var tabIndex: Int = 0
    var totalTabCount: Int = 0

    init(title: String) {
        pinIcon = NSImageView()
        keepAliveIcon = NSImageView()
        typeIcon = NSImageView()
        busySpinner = NSProgressIndicator()
        completionDot = NSView()
        rateLimitIcon = NSImageView()
        titleLabel = NSTextField(labelWithString: title)
        closeButton = NSButton()
        contentStack = NSStackView()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // Pin icon
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinIcon.contentTintColor = NSColor(resource: .textSecondary)
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.isHidden = true
        pinIcon.setContentHuggingPriority(.required, for: .horizontal)

        // Keep alive (shield) icon
        keepAliveIcon.image = NSImage(systemSymbolName: "shield.righthalf.filled", accessibilityDescription: "Keep Alive")
        keepAliveIcon.contentTintColor = .systemCyan
        keepAliveIcon.translatesAutoresizingMaskIntoConstraints = false
        keepAliveIcon.isHidden = true
        keepAliveIcon.setContentHuggingPriority(.required, for: .horizontal)

        // Type icon (permanent icon for web tabs — Jira, PR, etc.)
        typeIcon.translatesAutoresizingMaskIntoConstraints = false
        typeIcon.isHidden = true
        typeIcon.setContentHuggingPriority(.required, for: .horizontal)
        typeIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Tab")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Layout using an internal stack
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [pinIcon, keepAliveIcon, typeIcon, completionDot, busySpinner, rateLimitIcon, titleLabel, closeButton] {
            contentStack.addArrangedSubview(view)
        }
        contentStack.orientation = .horizontal
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12),
            keepAliveIcon.widthAnchor.constraint(equalToConstant: 10),
            keepAliveIcon.heightAnchor.constraint(equalToConstant: 10),
            typeIcon.widthAnchor.constraint(equalToConstant: 14),
            typeIcon.heightAnchor.constraint(equalToConstant: 14),
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

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
            if event.modifierFlags.contains(.option) {
                onForceClose?()
            } else {
                onClose?()
            }
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

    @objc private func keepAliveTapped() {
        onKeepAlive?()
    }

    @objc private func continueInTapped() {
        onContinueIn?()
    }

    @objc private func resumeAgentInNewTabTapped() {
        onResumeAgentInNewTab?()
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

    @objc private func killSessionTapped() {
        onKillSession?()
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let deadDimAlpha: CGFloat = isSessionDead ? 0.45 : 1.0

        let titleColor: NSColor
        if isSelected {
            titleColor = NSColor(resource: .textPrimary)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        } else if isDark {
            titleColor = NSColor(resource: .textSecondary).withAlphaComponent(0.96)
            titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        } else {
            // Use system secondaryLabelColor in light mode for better contrast
            titleColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        }

        // Close/pin icon color is consistent regardless of selection state
        let secondaryColor = NSColor(resource: .textSecondary).withAlphaComponent(0.82)

        // Resolve NSColors into CGColors within the correct appearance context so
        // adaptive colors (Surface, PrimaryBrand, etc.) pick up light-mode values
        // when the window is in light mode.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if self.isSelected {
                self.layer?.backgroundColor = NSColor(resource: .primaryBrand).withAlphaComponent(0.18).cgColor
            } else {
                self.layer?.backgroundColor = NSColor(resource: .surface).withAlphaComponent(0.62).cgColor
            }
        }
        titleLabel.textColor = titleColor
        titleLabel.alphaValue = deadDimAlpha
        pinIcon.contentTintColor = secondaryColor
        pinIcon.alphaValue = deadDimAlpha
        closeButton.contentTintColor = secondaryColor
        closeButton.alphaValue = deadDimAlpha
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let pinTitle = showPinIcon ? "Unpin Tab" : "Pin Tab"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinTapped), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if onRename != nil {
            let renameItem = NSMenuItem(title: "Rename Tab...", action: #selector(renameTapped), keyEquivalent: "")
            renameItem.target = self
            menu.addItem(renameItem)
        }

        if onResumeAgentInNewTab != nil {
            let resumeItem = NSMenuItem(
                title: "Resume Agent Session in New Tab",
                action: #selector(resumeAgentInNewTabTapped),
                keyEquivalent: ""
            )
            resumeItem.target = self
            resumeItem.isEnabled = canResumeAgentInNewTab
            menu.addItem(resumeItem)
        }

        // Context transfer items
        if !availableAgentsForContinue.isEmpty || onExportContext != nil {
            menu.addItem(.separator())
        }

        if !availableAgentsForContinue.isEmpty {
            let continueItem = NSMenuItem(title: "Continue in...", action: #selector(continueInTapped), keyEquivalent: "")
            continueItem.target = self
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

        if onKeepAlive != nil {
            menu.addItem(.separator())
            let keepAliveTitle = showKeepAliveIcon ? "Remove Keep Alive" : "Keep Alive"
            let keepAliveItem = NSMenuItem(title: keepAliveTitle, action: #selector(keepAliveTapped), keyEquivalent: "")
            keepAliveItem.target = self
            menu.addItem(keepAliveItem)
        }

        // Kill tmux session (terminal tabs only, when session is alive)
        if onKillSession != nil, !isSessionDead {
            if onKeepAlive == nil {
                menu.addItem(.separator())
            }
            let killItem = NSMenuItem(title: "Kill Session", action: #selector(killSessionTapped), keyEquivalent: "")
            killItem.target = self
            menu.addItem(killItem)
        }

        // "Close this tab" — always at the bottom
        let closeThisItem = NSMenuItem(title: "Close This Tab", action: #selector(closeTapped), keyEquivalent: "")
        closeThisItem.target = self
        menu.addItem(closeThisItem)
    }
}
