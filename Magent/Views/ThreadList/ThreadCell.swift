import Cocoa

final class ThreadCell: NSTableCellView {

    private var prLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var jiraImageView: NSImageView?
    private var primaryDirtyDot: NSImageView?
    private var secondaryDirtyDot: NSImageView?
    private var pinImageView: NSImageView?
    private var leadingPinImageView: NSImageView?
    private var archiveButton: NSButton?
    private var completionImageView: NSImageView?
    private var rateLimitImageView: NSImageView?
    private var busySpinner: NSProgressIndicator?
    private var trailingStackView: NSStackView?
    private var hasInstalledTextTrailingConstraint = false

    var onArchive: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NSProgressIndicator.startAnimation may silently fail when called on a
        // cell not yet in a window (e.g. during NSOutlineView.reloadData on fresh
        // launch). Re-apply the animation once the cell enters the hierarchy.
        if window != nil, let spinner = busySpinner, !spinner.isHidden {
            spinner.startAnimation(nil)
        }
    }

    /// Reparents imageView and textField into a horizontal stack.
    /// The first row can show a multi-line description; the second row shows branch/worktree.
    /// Safe to call multiple times — only runs once.
    func ensureLeadingStack() {
        guard primaryDirtyDot == nil, let iv = imageView, let tf = textField else { return }

        let primaryDot = makeDirtyDot()
        let secondaryDot = makeDirtyDot()
        primaryDirtyDot = primaryDot
        secondaryDirtyDot = secondaryDot

        let subtitle = NSTextField(labelWithString: "")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentHuggingPriority(.defaultHigh, for: .vertical)
        subtitle.isHidden = true
        subtitleLabel = subtitle

        iv.removeFromSuperview()
        tf.removeFromSuperview()

        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 16),
            iv.heightAnchor.constraint(equalToConstant: 16),
        ])

        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1

        let primaryRow = NSStackView(views: [primaryDot, tf])
        primaryRow.orientation = .horizontal
        primaryRow.alignment = .centerY
        primaryRow.spacing = 4
        primaryRow.translatesAutoresizingMaskIntoConstraints = false

        let secondaryRow = NSStackView(views: [secondaryDot, subtitle])
        secondaryRow.orientation = .horizontal
        secondaryRow.alignment = .centerY
        secondaryRow.spacing = 4
        secondaryRow.translatesAutoresizingMaskIntoConstraints = false

        let verticalStack = NSStackView(views: [primaryRow, secondaryRow])
        verticalStack.orientation = .vertical
        verticalStack.alignment = .leading
        verticalStack.spacing = 1
        verticalStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iv, verticalStack])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        var constraints = [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ThreadListViewController.sidebarHorizontalInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let trailingStack = trailingStackView {
            constraints.append(stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6))
        } else {
            constraints.append(stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ThreadListViewController.sidebarHorizontalInset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func makeDirtyDot() -> NSImageView {
        let dot = NSImageView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.isHidden = true
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
        ])
        return dot
    }

    private func ensureTrailingStack() {
        guard trailingStackView == nil else { return }
        let completionIndicatorSize: CGFloat = 10

        let prTF = NSTextField(labelWithString: "")
        prTF.translatesAutoresizingMaskIntoConstraints = false
        prTF.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        prTF.textColor = .secondaryLabelColor
        prTF.setContentHuggingPriority(.required, for: .horizontal)
        prTF.setContentCompressionResistancePriority(.required, for: .horizontal)
        prTF.isHidden = true

        let jiraIV = NSImageView()
        jiraIV.translatesAutoresizingMaskIntoConstraints = false
        jiraIV.setContentHuggingPriority(.required, for: .horizontal)
        jiraIV.isHidden = true

        let pinIV = NSImageView()
        pinIV.translatesAutoresizingMaskIntoConstraints = false
        pinIV.setContentHuggingPriority(.required, for: .horizontal)

        let completionIV = NSImageView()
        completionIV.translatesAutoresizingMaskIntoConstraints = false
        completionIV.setContentHuggingPriority(.required, for: .horizontal)

        let rateLimitIV = NSImageView()
        rateLimitIV.translatesAutoresizingMaskIntoConstraints = false
        rateLimitIV.setContentHuggingPriority(.required, for: .horizontal)

        let archiveBtn = NSButton()
        archiveBtn.translatesAutoresizingMaskIntoConstraints = false
        archiveBtn.setContentHuggingPriority(.required, for: .horizontal)
        archiveBtn.isBordered = false
        archiveBtn.image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Ready to archive")
        archiveBtn.contentTintColor = .tertiaryLabelColor
        archiveBtn.toolTip = "Work delivered — ready to archive"
        archiveBtn.target = self
        archiveBtn.action = #selector(archiveButtonClicked)
        archiveBtn.isHidden = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.isHidden = true

        let stack = NSStackView(views: [prTF, jiraIV, pinIV, archiveBtn, spinner, rateLimitIV, completionIV])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)

        // Keep markers hard-aligned to the trailing edge so additional markers grow leftward.
        // Offset chosen to preserve the previous resting position of a single completion indicator.
        let trailingAlignmentInset = ThreadListViewController.projectDisclosureTrailingInset
            + (ThreadListViewController.disclosureButtonSize / 2)
            - (completionIndicatorSize / 2)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingAlignmentInset),
            jiraIV.widthAnchor.constraint(equalToConstant: 10),
            jiraIV.heightAnchor.constraint(equalToConstant: 10),
            pinIV.widthAnchor.constraint(equalToConstant: 12),
            pinIV.heightAnchor.constraint(equalToConstant: 12),
            archiveBtn.widthAnchor.constraint(equalToConstant: 12),
            archiveBtn.heightAnchor.constraint(equalToConstant: 12),
            completionIV.widthAnchor.constraint(equalToConstant: completionIndicatorSize),
            completionIV.heightAnchor.constraint(equalToConstant: completionIndicatorSize),
            rateLimitIV.widthAnchor.constraint(equalToConstant: 10),
            rateLimitIV.heightAnchor.constraint(equalToConstant: 10),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        trailingStackView = stack
        prLabel = prTF
        jiraImageView = jiraIV
        pinImageView = pinIV
        archiveButton = archiveBtn
        completionImageView = completionIV
        rateLimitImageView = rateLimitIV
        busySpinner = spinner

        if !hasInstalledTextTrailingConstraint {
            hasInstalledTextTrailingConstraint = true
        }
    }

    private func ensureLeadingPin() {
        guard leadingPinImageView == nil, let iv = imageView else { return }
        let pin = NSImageView()
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.setContentHuggingPriority(.required, for: .horizontal)
        let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        pin.image = pinImage
        pin.contentTintColor = .controlAccentColor
        pin.isHidden = true
        addSubview(pin)
        NSLayoutConstraint.activate([
            pin.trailingAnchor.constraint(equalTo: iv.leadingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 12),
            pin.heightAnchor.constraint(equalToConstant: 12),
        ])
        leadingPinImageView = pin
    }

    func configure(with thread: MagentThread, sectionColor: NSColor?) {
        ensureTrailingStack()
        ensureLeadingStack()

        let worktreeName = (thread.worktreePath as NSString).lastPathComponent
        let branchName = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranchName = branchName.isEmpty ? thread.name : branchName
        let hasBranchWorktreeMismatch = worktreeName != resolvedBranchName

        var fullSecondaryLineParts = [resolvedBranchName]
        if hasBranchWorktreeMismatch {
            fullSecondaryLineParts.append(worktreeName)
        }
        if let pr = thread.pullRequestInfo {
            fullSecondaryLineParts.append(pr.displayLabel)
        }
        let fullSecondaryLine = fullSecondaryLineParts.joined(separator: "  ·  ")

        let trimmedDescription = thread.taskDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDescription = !(trimmedDescription?.isEmpty ?? true)

        textField?.font = thread.hasUnreadAgentCompletion
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .preferredFont(forTextStyle: .body)
        textField?.textColor = thread.jiraUnassigned ? .tertiaryLabelColor : .labelColor
        textField?.lineBreakMode = .byTruncatingTail

        if hasDescription, let description = trimmedDescription {
            textField?.stringValue = description
            textField?.maximumNumberOfLines = 2
            textField?.lineBreakMode = .byWordWrapping
            subtitleLabel?.stringValue = fullSecondaryLine
            subtitleLabel?.textColor = thread.jiraUnassigned ? .tertiaryLabelColor : .secondaryLabelColor
            subtitleLabel?.isHidden = false
            setDirtyDot(primaryDirtyDot, visible: false)
            setDirtyDot(secondaryDirtyDot, visible: thread.isDirty)
        } else if hasBranchWorktreeMismatch {
            textField?.stringValue = resolvedBranchName
            textField?.maximumNumberOfLines = 1

            var secondaryLineParts = [worktreeName]
            if let pr = thread.pullRequestInfo {
                secondaryLineParts.append(pr.displayLabel)
            }
            subtitleLabel?.stringValue = secondaryLineParts.joined(separator: "  ·  ")
            subtitleLabel?.textColor = thread.jiraUnassigned ? .tertiaryLabelColor : .secondaryLabelColor
            subtitleLabel?.isHidden = false
            setDirtyDot(primaryDirtyDot, visible: false)
            setDirtyDot(secondaryDirtyDot, visible: thread.isDirty)
        } else {
            var singleLineParts = [resolvedBranchName]
            if let pr = thread.pullRequestInfo {
                singleLineParts.append(pr.displayLabel)
            }
            textField?.stringValue = singleLineParts.joined(separator: "  ·  ")
            textField?.maximumNumberOfLines = 1
            subtitleLabel?.isHidden = true
            setDirtyDot(primaryDirtyDot, visible: thread.isDirty)
            setDirtyDot(secondaryDirtyDot, visible: false)
        }

        let detailedTooltip = buildDetailedTooltip(
            description: trimmedDescription,
            branchName: resolvedBranchName,
            worktreeName: worktreeName,
            prLabel: thread.pullRequestInfo?.displayLabel,
            statuses: statusDescriptions(for: thread)
        )
        toolTip = detailedTooltip
        imageView?.toolTip = detailedTooltip
        textField?.toolTip = detailedTooltip
        subtitleLabel?.toolTip = detailedTooltip
        primaryDirtyDot?.toolTip = detailedTooltip
        secondaryDirtyDot?.toolTip = detailedTooltip

        imageView?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imageView?.contentTintColor = thread.hasUnreadAgentCompletion
            ? NSColor.controlAccentColor
            : (sectionColor ?? NSColor(resource: .primaryBrand))

        prLabel?.stringValue = ""
        prLabel?.toolTip = nil
        prLabel?.isHidden = true

        if thread.jiraTicketKey != nil {
            jiraImageView?.image = NSImage(systemSymbolName: "ticket", accessibilityDescription: "Jira ticket")
            jiraImageView?.contentTintColor = .tertiaryLabelColor
            jiraImageView?.toolTip = thread.jiraTicketKey
            jiraImageView?.isHidden = false
        } else {
            jiraImageView?.image = nil
            jiraImageView?.toolTip = nil
            jiraImageView?.isHidden = true
        }

        // Trailing pin icon — always hidden (replaced by leading pin)
        pinImageView?.isHidden = true

        // Leading pin icon — appears to the left of the terminal icon
        ensureLeadingPin()
        leadingPinImageView?.isHidden = !thread.isPinned

        archiveButton?.isHidden = !thread.showArchiveSuggestion

        if thread.isBlockedByRateLimit {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Agent rate limited")
            rateLimitImageView?.contentTintColor = .systemRed
            rateLimitImageView?.toolTip = rateLimitTooltip(for: thread)
            rateLimitImageView?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if thread.hasWaitingForInput {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemYellow
            completionImageView?.toolTip = "Agent needs input"
            completionImageView?.isHidden = false
        } else if thread.hasAgentBusy {
            busySpinner?.isHidden = false
            busySpinner?.startAnimation(nil)
            busySpinner?.toolTip = "Agent working"
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if thread.hasUnreadAgentCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.toolTip = "Agent finished"
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        }
    }

    func configureAsMain(
        isUnreadCompletion: Bool = false,
        isBusy: Bool = false,
        isWaitingForInput: Bool = false,
        isDirty: Bool = false,
        isBlockedByRateLimit: Bool = false,
        rateLimitTooltip: String? = nil
    ) {
        textField?.stringValue = "Main"
        textField?.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnreadCompletion ? .semibold : .regular
        )
        textField?.textColor = .labelColor
        textField?.lineBreakMode = .byTruncatingTail
        textField?.maximumNumberOfLines = 1

        ensureTrailingStack()
        ensureLeadingStack()
        subtitleLabel?.isHidden = true
        pinImageView?.isHidden = true
        archiveButton?.isHidden = true
        leadingPinImageView?.isHidden = true

        imageView?.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Main thread")
        imageView?.contentTintColor = .controlAccentColor
        imageView?.isHidden = false

        setDirtyDot(primaryDirtyDot, visible: isDirty)
        setDirtyDot(secondaryDirtyDot, visible: false)

        if isBlockedByRateLimit {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = NSImage(systemSymbolName: "hourglass.circle.fill", accessibilityDescription: "Agent rate limited")
            rateLimitImageView?.contentTintColor = .systemRed
            rateLimitImageView?.toolTip = rateLimitTooltip ?? "Rate limit reached"
            rateLimitImageView?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if isWaitingForInput {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Agent needs input")
            completionImageView?.contentTintColor = .systemYellow
            completionImageView?.toolTip = "Agent needs input"
            completionImageView?.isHidden = false
        } else if isBusy {
            busySpinner?.isHidden = false
            busySpinner?.startAnimation(nil)
            busySpinner?.toolTip = "Agent working"
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if isUnreadCompletion {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Agent finished")
            completionImageView?.contentTintColor = .systemGreen
            completionImageView?.toolTip = "Agent finished"
            completionImageView?.isHidden = false
        } else {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = nil
            rateLimitImageView?.toolTip = nil
            rateLimitImageView?.isHidden = true
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        }
    }

    private func setDirtyDot(_ dot: NSImageView?, visible: Bool) {
        guard let dot else { return }
        if visible {
            dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Uncommitted changes")
            dot.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
            dot.isHidden = false
        } else {
            dot.image = nil
            dot.isHidden = true
        }
    }

    private func statusDescriptions(for thread: MagentThread) -> [String] {
        var statuses: [String] = []
        if thread.isDirty {
            statuses.append("Dirty")
        }

        if thread.isBlockedByRateLimit {
            if let detail = thread.rateLimitLiftDescription, !detail.isEmpty {
                statuses.append("Rate limited (\(detail))")
            } else {
                statuses.append("Rate limited")
            }
        } else if thread.hasWaitingForInput {
            statuses.append("Waiting for input")
        } else if thread.hasAgentBusy {
            statuses.append("Agent busy")
        } else if thread.hasUnreadAgentCompletion {
            statuses.append("Agent completed")
        }

        if thread.showArchiveSuggestion {
            statuses.append("Ready to archive")
        }

        return statuses
    }

    private func buildDetailedTooltip(
        description: String?,
        branchName: String,
        worktreeName: String,
        prLabel: String?,
        statuses: [String]
    ) -> String? {
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWorktree = worktreeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPR = prLabel?.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []

        if let trimmedDescription, !trimmedDescription.isEmpty {
            sections.append(trimmedDescription)
        }

        var detailLines: [String] = []
        if !trimmedBranch.isEmpty {
            detailLines.append("Branch: \(trimmedBranch)")
        }
        if !trimmedWorktree.isEmpty {
            detailLines.append("Worktree: \(trimmedWorktree)")
        }
        if let trimmedPR, !trimmedPR.isEmpty {
            detailLines.append("PR: \(trimmedPR)")
        }
        if !detailLines.isEmpty {
            sections.append(detailLines.joined(separator: "\n"))
        }

        if !statuses.isEmpty {
            sections.append("Status: \(statuses.joined(separator: ", "))")
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    private func rateLimitTooltip(for thread: MagentThread) -> String {
        if let detail = thread.rateLimitLiftDescription, !detail.isEmpty {
            return "Rate limit reached. \(detail)"
        }
        return "Rate limit reached"
    }

    @objc private func archiveButtonClicked() {
        onArchive?()
    }
}
