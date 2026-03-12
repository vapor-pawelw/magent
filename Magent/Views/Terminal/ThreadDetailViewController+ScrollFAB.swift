import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // Minimum lines scrolled from the bottom before the FAB appears.
    // This prevents the button from flashing on minor incidental scrolls near live output.
    private static let scrollFABThreshold: UInt64 = 12
    private static let scrollFABRefreshDelayNanoseconds: UInt64 = 120_000_000
    private static let scrollOverlayDefaultBottomInset: CGFloat = 48
    private static let scrollFABFadeInDuration: TimeInterval = 0.22
    private static let scrollFABFadeOutDuration: TimeInterval = 0.18
    private static let scrollFABVerticalTravel: CGFloat = 24

    // MARK: - Setup

    // MARK: - Scroll Overlay (bottom-right draggable pill)

    func bringScrollOverlaysToFront() {
        if showTerminalScrollOverlay, scrollOverlay.superview === terminalContainer {
            terminalContainer.addSubview(scrollOverlay, positioned: .above, relativeTo: nil)
        }
        if showScrollToBottomIndicator, floatingScrollToBottomButton.superview === terminalContainer {
            terminalContainer.addSubview(floatingScrollToBottomButton, positioned: .above, relativeTo: nil)
        }
    }

    func setupScrollOverlay() {
        let overlay = scrollOverlay
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onScrollUp       = { [weak self] in self?.scrollTerminalPageUpTapped() }
        overlay.onScrollDown     = { [weak self] in self?.scrollTerminalPageDownTapped() }
        overlay.onScrollToBottom = { [weak self] in self?.scrollTerminalToBottomTapped() }

        terminalContainer.addSubview(overlay)

        let trailing = overlay.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor, constant: -16)
        let bottom   = overlay.bottomAnchor.constraint(
            equalTo: terminalContainer.bottomAnchor,
            constant: -Self.scrollOverlayDefaultBottomInset
        )
        scrollOverlayTrailingConstraint = trailing
        scrollOverlayBottomConstraint   = bottom
        NSLayoutConstraint.activate([trailing, bottom])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleScrollOverlayPan(_:)))
        overlay.addGestureRecognizer(pan)
    }

    @objc func handleScrollOverlayPan(_ gesture: NSPanGestureRecognizer) {
        guard let trailing = scrollOverlayTrailingConstraint,
              let bottom   = scrollOverlayBottomConstraint else { return }

        switch gesture.state {
        case .began:
            // Store current offsets as positive distances from the edges.
            scrollOverlayDragStartTrailing = -trailing.constant
            scrollOverlayDragStartBottom   = -bottom.constant

        case .changed:
            let t = gesture.translation(in: view)
            // Positive x → moved right → trailing offset decreases (overlay moves right).
            let newTrailing = scrollOverlayDragStartTrailing - t.x
            // Positive y → moved up (AppKit coords) → bottom offset increases.
            let newBottom   = scrollOverlayDragStartBottom + t.y

            let size = scrollOverlay.frame.size
            trailing.constant = -min(max(8, newTrailing), terminalContainer.bounds.width  - size.width  - 8)
            bottom.constant   = -min(max(8, newBottom),   terminalContainer.bounds.height - size.height - 8)

        default:
            break
        }
    }

    func setupScrollFAB() {
        let btn = floatingScrollToBottomButton
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isHidden = true
        btn.alphaValue = 0
        btn.wantsLayer = true
        btn.onTap = { [weak self] in self?.floatingScrollToBottomTapped() }

        terminalContainer.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor, constant: 18),
            btn.bottomAnchor.constraint(
                equalTo: terminalContainer.bottomAnchor,
                constant: -Self.scrollOverlayDefaultBottomInset
            ),
        ])
    }

    // MARK: - Show / Hide

    func setScrollFABVisible(_ visible: Bool) {
        guard showScrollToBottomIndicator else {
            isScrollFABVisible = false
            floatingScrollToBottomButton.layer?.removeAllAnimations()
            floatingScrollToBottomButton.alphaValue = 0
            floatingScrollToBottomButton.isHidden = true
            return
        }
        guard visible != isScrollFABVisible else { return }

        isScrollFABVisible = visible
        scrollFABAnimationGeneration &+= 1
        let animationGeneration = scrollFABAnimationGeneration
        let button = floatingScrollToBottomButton

        button.layer?.removeAllAnimations()

        if visible {
            button.alphaValue = 0
            button.isHidden = false
            setScrollFABTranslationY(-Self.scrollFABVerticalTravel)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.scrollFABFadeInDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                button.animator().alphaValue = TerminalScrollToBottomPillButton.restingAlpha
                button.layer?.transform = CATransform3DIdentity
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.scrollFABFadeOutDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                button.animator().alphaValue = 0
                button.layer?.transform = CATransform3DMakeTranslation(0, -Self.scrollFABVerticalTravel, 0)
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.scrollFABAnimationGeneration == animationGeneration, !self.isScrollFABVisible else { return }
                    self.setScrollFABTranslationY(0)
                    button.isHidden = true
                }
            })
        }
    }

    private func setScrollFABTranslationY(_ translationY: CGFloat) {
        floatingScrollToBottomButton.layer?.transform = CATransform3DMakeTranslation(0, translationY, 0)
    }

    func scheduleScrollFABVisibilityRefresh() {
        scrollFABRefreshTask?.cancel()

        guard showScrollToBottomIndicator else {
            setScrollFABVisible(false)
            return
        }

        guard let sessionName = currentSessionName() else {
            setScrollFABVisible(false)
            return
        }

        scrollFABRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.scrollFABRefreshDelayNanoseconds)
            guard !Task.isCancelled else { return }

            let linesFromBottom = await TmuxService.shared.scrollPosition(sessionName: sessionName) ?? 0
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard self.currentSessionName() == sessionName else { return }
                self.setScrollFABVisible(linesFromBottom >= Self.scrollFABThreshold)
            }
        }
    }

    // MARK: - Scrollbar Notification

    @objc func handleScrollbarUpdate(_ notification: Notification) {
        guard showScrollToBottomIndicator else {
            setScrollFABVisible(false)
            return
        }
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
        scrollFABRefreshTask?.cancel()

        // Cancel tmux copy-mode and scroll ghostty's viewport to bottom after redraw.
        scrollTerminalToBottomTapped()
        scheduleScrollFABVisibilityRefresh()
    }
}
