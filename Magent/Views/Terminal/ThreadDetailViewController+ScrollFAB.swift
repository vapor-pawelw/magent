import Cocoa

extension ThreadDetailViewController {

    // Minimum lines scrolled from the bottom before the FAB appears.
    // This prevents the button from flashing on minor incidental scrolls.
    private static let scrollFABThreshold: UInt64 = 3

    // MARK: - Setup

    func setupScrollFAB() {
        let btn = floatingScrollToBottomButton
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        btn.alphaValue = 0
        btn.bezelStyle = .texturedRounded
        btn.title = " Scroll to bottom"
        btn.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleProportionallyDown
        btn.font = .systemFont(ofSize: 12)
        btn.target = self
        btn.action = #selector(floatingScrollToBottomTapped)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        btn.wantsLayer = true
        btn.shadow = shadow

        // Add to the root view (not terminalContainer) so it floats above Metal surfaces.
        view.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 16),
            btn.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Show / Hide

    func setScrollFABVisible(_ visible: Bool) {
        if visible && floatingScrollToBottomButton.isHidden {
            floatingScrollToBottomButton.alphaValue = 0
            floatingScrollToBottomButton.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                self.floatingScrollToBottomButton.animator().alphaValue = 1
            }
        } else if !visible && !floatingScrollToBottomButton.isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.floatingScrollToBottomButton.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    self?.floatingScrollToBottomButton.isHidden = true
                }
            })
        }
    }

    // MARK: - Scrollbar Notification

    @objc func handleScrollbarUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let surfaceAddr = userInfo["surfaceAddr"] as? Int,
              let total = userInfo["total"] as? UInt64,
              let offset = userInfo["offset"] as? UInt64,
              let len = userInfo["len"] as? UInt64 else { return }

        // Only react to updates from the currently visible terminal.
        guard currentTabIndex < terminalViews.count,
              let surface = terminalViews[currentTabIndex].surface,
              Int(bitPattern: surface) == surfaceAddr else { return }

        let linesFromBottom = (total > offset + len) ? (total - offset - len) : 0
        setScrollFABVisible(linesFromBottom >= Self.scrollFABThreshold)
    }

    // MARK: - Action

    @objc func floatingScrollToBottomTapped() {
        // Hide immediately for instant feedback.
        setScrollFABVisible(false)

        // Scroll ghostty's own scrollback to the bottom.
        if currentTabIndex < terminalViews.count {
            terminalViews[currentTabIndex].bindingAction("scroll_to_bottom")
        }

        // Also cancel tmux copy-mode in case page-up toolbar buttons were used.
        scrollTerminalToBottomTapped()
    }
}
