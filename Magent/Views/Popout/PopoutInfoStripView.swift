import Cocoa
import MagentCore

/// Thin info bar (48pt) displayed at the top of pop-out windows.
/// Shows thread identity, branch, status, and optional tab name.
final class PopoutInfoStripView: NSView {
    private static let busySeparatorAnimationKey = "popout-info-strip-busy-separator-shift"
    private let threadIconView = NSImageView()
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let dirtyDot = NSView()
    private let jiraLabel = NSTextField(labelWithString: "")
    private let prLabel = NSTextField(labelWithString: "")
    private let trailingAccessoryStack = NSStackView()
    private let stateIndicator = NSImageView()
    private let keepAliveIndicator = NSImageView()
    private let favoriteIndicator = NSImageView()
    private let pinnedIndicator = NSImageView()
    private let busySpinner = NSProgressIndicator()
    private let bottomBorder = NSView()
    private var busyBorderGradientLayer: CAGradientLayer?
    private var currentThreadId: UUID?
    private var currentSessionName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true

        // Thread icon
        threadIconView.translatesAutoresizingMaskIntoConstraints = false
        threadIconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(threadIconView)

        // Description label (line 1)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 1
        addSubview(descriptionLabel)

        // Branch label (line 2)
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.font = .systemFont(ofSize: 11)
        branchLabel.lineBreakMode = .byTruncatingHead
        branchLabel.maximumNumberOfLines = 1
        addSubview(branchLabel)

        // Dirty dot
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3.5
        dirtyDot.isHidden = true
        addSubview(dirtyDot)

        // Jira label (line 2)
        jiraLabel.translatesAutoresizingMaskIntoConstraints = false
        jiraLabel.font = .systemFont(ofSize: 10)
        jiraLabel.isHidden = true
        addSubview(jiraLabel)

        // PR label (line 2)
        prLabel.translatesAutoresizingMaskIntoConstraints = false
        prLabel.font = .systemFont(ofSize: 10)
        prLabel.isHidden = true
        addSubview(prLabel)

        // Busy spinner
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isIndeterminate = true
        busySpinner.isHidden = true

        trailingAccessoryStack.orientation = .horizontal
        trailingAccessoryStack.alignment = .centerY
        trailingAccessoryStack.spacing = 6
        trailingAccessoryStack.detachesHiddenViews = true
        trailingAccessoryStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingAccessoryStack)

        for indicator in [stateIndicator, keepAliveIndicator, favoriteIndicator, pinnedIndicator] {
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.imageScaling = .scaleProportionallyUpOrDown
            indicator.isHidden = true
            trailingAccessoryStack.addArrangedSubview(indicator)
        }
        trailingAccessoryStack.addArrangedSubview(busySpinner)

        keepAliveIndicator.image = NSImage(systemSymbolName: "shield.righthalf.filled", accessibilityDescription: "Keep Alive")
        favoriteIndicator.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite")
        pinnedIndicator.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        keepAliveIndicator.toolTip = "Keep Alive — protected from idle eviction"
        favoriteIndicator.toolTip = "Favorite thread"
        pinnedIndicator.toolTip = "Pinned thread"

        // Bottom border
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBorder.wantsLayer = true
        addSubview(bottomBorder)

        NSLayoutConstraint.activate([
            // Line 1
            threadIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            threadIconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            threadIconView.widthAnchor.constraint(equalToConstant: 16),
            threadIconView.heightAnchor.constraint(equalToConstant: 16),

            descriptionLabel.leadingAnchor.constraint(equalTo: threadIconView.trailingAnchor, constant: 6),
            descriptionLabel.centerYAnchor.constraint(equalTo: threadIconView.centerYAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAccessoryStack.leadingAnchor, constant: -8),

            trailingAccessoryStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingAccessoryStack.centerYAnchor.constraint(equalTo: threadIconView.centerYAnchor),

            stateIndicator.widthAnchor.constraint(equalToConstant: 14),
            stateIndicator.heightAnchor.constraint(equalToConstant: 14),
            keepAliveIndicator.widthAnchor.constraint(equalToConstant: 12),
            keepAliveIndicator.heightAnchor.constraint(equalToConstant: 12),
            favoriteIndicator.widthAnchor.constraint(equalToConstant: 12),
            favoriteIndicator.heightAnchor.constraint(equalToConstant: 12),
            pinnedIndicator.widthAnchor.constraint(equalToConstant: 12),
            pinnedIndicator.heightAnchor.constraint(equalToConstant: 12),
            busySpinner.widthAnchor.constraint(equalToConstant: 14),
            busySpinner.heightAnchor.constraint(equalToConstant: 14),

            // Line 2
            branchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            branchLabel.topAnchor.constraint(equalTo: threadIconView.bottomAnchor, constant: 2),
            branchLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            dirtyDot.leadingAnchor.constraint(equalTo: branchLabel.trailingAnchor, constant: 4),
            dirtyDot.centerYAnchor.constraint(equalTo: branchLabel.centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 7),
            dirtyDot.heightAnchor.constraint(equalToConstant: 7),

            // Bottom border
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor(resource: .surface).withAlphaComponent(0.85).cgColor
            self.dirtyDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            self.descriptionLabel.textColor = NSColor(resource: .textPrimary)
            self.branchLabel.textColor = NSColor(resource: .textSecondary)
            self.jiraLabel.textColor = .controlAccentColor
            self.prLabel.textColor = .controlAccentColor
            self.keepAliveIndicator.contentTintColor = .systemCyan
            self.favoriteIndicator.contentTintColor = NSColor(resource: .primaryBrand)
            self.pinnedIndicator.contentTintColor = NSColor(resource: .textSecondary)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let currentThreadId else { return }

        var userInfo: [String: Any] = [
            "threadId": currentThreadId,
            "centerInSidebar": true,
        ]
        if let currentSessionName {
            userInfo["sessionName"] = currentSessionName
        }
        NotificationCenter.default.post(
            name: .magentNavigateToThread,
            object: self,
            userInfo: userInfo
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        busyBorderGradientLayer?.frame = bottomBorder.bounds.insetBy(dx: -bottomBorder.bounds.width, dy: 0)
    }

    // MARK: - Refresh

    func refresh(from thread: MagentThread) {
        currentThreadId = thread.id
        currentSessionName = nil
        threadIconView.image = NSImage(systemSymbolName: thread.threadIcon.symbolName, accessibilityDescription: nil)

        descriptionLabel.stringValue = thread.taskDescription ?? thread.name
        branchLabel.stringValue = thread.currentBranch
        dirtyDot.isHidden = !thread.isDirty

        // Jira
        if let ticket = thread.jiraTicketKey {
            jiraLabel.stringValue = ticket
            jiraLabel.isHidden = false
        } else {
            jiraLabel.isHidden = true
        }

        // PR
        if let prInfo = thread.pullRequestInfo {
            prLabel.stringValue = "#\(prInfo.number)"
            prLabel.isHidden = false
        } else {
            prLabel.isHidden = true
        }

        updateTrailingIndicators(thread: thread)
        updateThreadIconTint(thread: thread)
        updateStatusIndicator(thread: thread)
        updateBottomBorder(thread: thread)
    }

    func configureForTab(thread: MagentThread, sessionName: String) {
        currentThreadId = thread.id
        currentSessionName = sessionName
        let tabIndex = thread.tmuxSessionNames.firstIndex(of: sessionName).map { $0 + 1 } ?? 1
        let threadName = thread.taskDescription ?? thread.name
        descriptionLabel.stringValue = "\(threadName) — Tab \(tabIndex)"
        branchLabel.stringValue = thread.currentBranch
        dirtyDot.isHidden = !thread.isDirty
        threadIconView.image = NSImage(systemSymbolName: thread.threadIcon.symbolName, accessibilityDescription: nil)

        // PR info for tab popout
        if let prInfo = thread.pullRequestInfo {
            prLabel.stringValue = "#\(prInfo.number)"
            prLabel.isHidden = false
        } else {
            prLabel.isHidden = true
        }

        updateTrailingIndicators(thread: thread)
        updateThreadIconTint(thread: thread)
        updateStatusIndicator(thread: thread)
        updateBottomBorder(thread: thread)
    }

    private func updateTrailingIndicators(thread: MagentThread) {
        keepAliveIndicator.isHidden = !thread.isKeepAlive
        favoriteIndicator.isHidden = !thread.isFavorite
        pinnedIndicator.isHidden = !thread.isPinned
    }

    private func updateThreadIconTint(thread: MagentThread) {
        threadIconView.contentTintColor = sectionColor(for: thread) ?? .secondaryLabelColor
    }

    private func updateStatusIndicator(thread: MagentThread) {
        if thread.isAnyBusy {
            stateIndicator.isHidden = true
            busySpinner.isHidden = false
            busySpinner.startAnimation(nil)
        } else if thread.isBlockedByRateLimit {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            stateIndicator.isHidden = false
            if thread.isRateLimitPropagatedOnly {
                stateIndicator.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Rate limited (propagated)")
                stateIndicator.contentTintColor = .systemOrange
            } else {
                stateIndicator.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Rate limited")
                stateIndicator.contentTintColor = .systemRed
            }
        } else if thread.hasWaitingForInput {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            stateIndicator.isHidden = false
            stateIndicator.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Waiting for input")
            stateIndicator.contentTintColor = .systemYellow
        } else {
            busySpinner.isHidden = true
            busySpinner.stopAnimation(nil)
            stateIndicator.isHidden = true
        }
    }

    private func updateBottomBorder(thread: MagentThread) {
        if thread.isAnyBusy, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            startBusyBorderGradient()
            return
        }

        stopBusyBorderGradient()

        let borderColor: NSColor
        if thread.isBlockedByRateLimit {
            borderColor = thread.isRateLimitPropagatedOnly
                ? .systemOrange.withAlphaComponent(0.5)
                : .systemRed.withAlphaComponent(0.5)
        } else if thread.hasWaitingForInput {
            borderColor = .systemOrange.withAlphaComponent(0.5)
        } else if thread.hasUnreadAgentCompletion {
            borderColor = .systemGreen.withAlphaComponent(0.5)
        } else {
            borderColor = .controlAccentColor
        }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.bottomBorder.layer?.backgroundColor = borderColor.cgColor
        }
    }

    private func startBusyBorderGradient() {
        let gradientLayer: CAGradientLayer
        if let existing = busyBorderGradientLayer {
            gradientLayer = existing
        } else {
            let created = CAGradientLayer()
            created.startPoint = CGPoint(x: 0, y: 0.5)
            created.endPoint = CGPoint(x: 1, y: 0.5)
            bottomBorder.layer?.backgroundColor = NSColor.clear.cgColor
            bottomBorder.layer?.addSublayer(created)
            busyBorderGradientLayer = created
            gradientLayer = created
        }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accentColor = NSColor.controlAccentColor
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            accentColor.usingColorSpace(.sRGB)?.getHue(
                &hue,
                saturation: &saturation,
                brightness: &brightness,
                alpha: &alpha
            )
            let brightColor = NSColor(
                hue: hue,
                saturation: max(saturation * 0.7, 0.3),
                brightness: min(brightness * 1.1, 1.0),
                alpha: 0.8
            )
            let dimColor = NSColor.white.withAlphaComponent(0.12)
            gradientLayer.colors = [
                dimColor.cgColor,
                brightColor.withAlphaComponent(0.45).cgColor,
                brightColor.cgColor,
                brightColor.withAlphaComponent(0.45).cgColor,
                dimColor.cgColor,
            ]
        }

        gradientLayer.locations = [0.0, 0.35, 0.5, 0.65, 1.0]
        gradientLayer.frame = bottomBorder.bounds.insetBy(dx: -bottomBorder.bounds.width, dy: 0)

        if gradientLayer.animation(forKey: Self.busySeparatorAnimationKey) == nil {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = -bottomBorder.bounds.width / 2
            animation.toValue = bottomBorder.bounds.width * 1.5
            animation.duration = 2.6
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            gradientLayer.add(animation, forKey: Self.busySeparatorAnimationKey)
        }
    }

    private func stopBusyBorderGradient() {
        busyBorderGradientLayer?.removeAllAnimations()
        busyBorderGradientLayer?.removeFromSuperlayer()
        busyBorderGradientLayer = nil
    }

    private func sectionColor(for thread: MagentThread) -> NSColor? {
        let settings = PersistenceService.shared.loadSettings()
        guard settings.shouldUseThreadSections(for: thread.projectId) else { return nil }
        let sections = settings.sections(for: thread.projectId)
        let effectiveSectionId = ThreadManager.shared.effectiveSectionId(for: thread, settings: settings)
        return sections.first(where: { $0.id == effectiveSectionId })?.color
    }
}
