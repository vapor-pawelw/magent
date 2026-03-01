import Cocoa

final class BranchMismatchView: NSView, NSGestureRecognizerDelegate {

    var onSwitchBranch: (() -> Void)?

    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let switchButton = NSButton()
    private let detailContainer = NSView()
    private let currentLabel = NSTextField(wrappingLabelWithString: "")
    private let expectedLabel = NSTextField(wrappingLabelWithString: "")
    private let detailExplanation = NSTextField(wrappingLabelWithString: "")
    private var collapsedHeightConstraint: NSLayoutConstraint!
    private var expandedBottomConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?

    private var isExpanded = false
    private var storedActual: String = ""
    private var storedExpected: String = ""

    private static let collapsedHeight: CGFloat = 32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.12).cgColor

        // Click gesture on collapsed header to expand/collapse
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleExpanded))
        click.delegate = self
        addGestureRecognizer(click)

        // Warning icon
        iconView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Branch mismatch warning"
        )
        iconView.contentTintColor = .systemYellow
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(iconView)

        // Message — short label
        messageLabel.font = .systemFont(ofSize: 11, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        // Switch button
        switchButton.title = "Switch"
        switchButton.bezelStyle = .rounded
        switchButton.controlSize = .mini
        switchButton.font = .systemFont(ofSize: 11, weight: .medium)
        switchButton.target = self
        switchButton.action = #selector(switchTapped)
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(switchButton)

        // Detail container — shown when expanded
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.isHidden = true
        addSubview(detailContainer)

        // Current branch row — wrapping, bold branch name
        configureDetailLabel(currentLabel)
        detailContainer.addSubview(currentLabel)

        // Expected branch row — wrapping, bold branch name
        configureDetailLabel(expectedLabel)
        detailContainer.addSubview(expectedLabel)

        // Explanation — wrapping
        detailExplanation.font = .systemFont(ofSize: 11)
        detailExplanation.textColor = .secondaryLabelColor
        detailExplanation.maximumNumberOfLines = 0
        detailExplanation.lineBreakMode = .byWordWrapping
        detailExplanation.translatesAutoresizingMaskIntoConstraints = false
        detailExplanation.setContentCompressionResistancePriority(.required, for: .vertical)
        detailExplanation.setContentHuggingPriority(.required, for: .vertical)
        detailContainer.addSubview(detailExplanation)

        // Collapsed: fixed height. Expanded: detail container drives the bottom.
        collapsedHeightConstraint = heightAnchor.constraint(equalToConstant: 0)
        expandedBottomConstraint = detailContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        expandedBottomConstraint.isActive = false

        NSLayoutConstraint.activate([
            collapsedHeightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            messageLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            messageLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: switchButton.leadingAnchor, constant: -6),

            switchButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            switchButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            detailContainer.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            detailContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            detailContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            currentLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            currentLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            currentLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            expectedLabel.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 3),
            expectedLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            expectedLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),

            detailExplanation.topAnchor.constraint(equalTo: expectedLabel.bottomAnchor, constant: 6),
            detailExplanation.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailExplanation.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailExplanation.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])

        isHidden = true
    }

    private func configureDetailLabel(_ label: NSTextField) {
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
    }

    private func attributedBranchString(prefix: String, branch: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let branchAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        result.append(NSAttributedString(string: prefix, attributes: prefixAttrs))
        result.append(NSAttributedString(string: branch, attributes: branchAttrs))
        return result
    }

    // MARK: - Hover tooltip

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHidden, !storedActual.isEmpty else { return }
        toolTip = "On \(storedActual), should be \(storedExpected)"
    }

    override func mouseExited(with event: NSEvent) {
        toolTip = nil
    }

    // MARK: - Public API

    func update(actualBranch: String, expectedBranch: String, hasMismatch: Bool) {
        guard hasMismatch else {
            clear()
            return
        }

        storedActual = actualBranch
        storedExpected = expectedBranch

        messageLabel.stringValue = "Branch changed"

        currentLabel.attributedStringValue = attributedBranchString(prefix: "now: ", branch: actualBranch)
        expectedLabel.attributedStringValue = attributedBranchString(prefix: "expected: ", branch: expectedBranch)
        detailExplanation.stringValue = "The working branch diverged from the thread's branch. Click Switch to restore it."

        switchButton.toolTip = "Checkout \(expectedBranch)"

        applyExpandedState(animated: false)
        isHidden = false
    }

    func clear() {
        storedActual = ""
        storedExpected = ""
        messageLabel.stringValue = ""
        toolTip = nil
        switchButton.toolTip = nil
        isExpanded = false
        detailContainer.isHidden = true
        collapsedHeightConstraint.isActive = true
        expandedBottomConstraint.isActive = false
        collapsedHeightConstraint.constant = 0
        isHidden = true
    }

    // MARK: - Actions

    @objc private func toggleExpanded() {
        guard !isHidden else { return }
        isExpanded.toggle()
        applyExpandedState(animated: true)
    }

    private func applyExpandedState(animated: Bool) {
        let apply = {
            if self.isExpanded {
                self.detailContainer.isHidden = false
                self.collapsedHeightConstraint.isActive = false
                self.expandedBottomConstraint.isActive = true
            } else {
                self.collapsedHeightConstraint.constant = Self.collapsedHeight
                self.collapsedHeightConstraint.isActive = true
                self.expandedBottomConstraint.isActive = false
                self.detailContainer.isHidden = true
            }
            self.superview?.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        return !switchButton.frame.contains(location)
    }

    @objc private func switchTapped() {
        onSwitchBranch?()
    }
}
