import Cocoa
import MagentCore

final class ThreadCell: NSTableCellView {

    // MARK: - SF Symbol Cache

    /// Caches SF Symbol NSImages to avoid repeated allocation during cell reconfiguration.
    /// Keyed by symbol name. Thread-safe via main-thread-only access (NSTableCellView).
    private static var symbolImageCache: [String: NSImage] = [:]

    static func cachedSymbolImage(_ name: String) -> NSImage? {
        if let cached = symbolImageCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        symbolImageCache[name] = image
        return image
    }

    /// Returns the Jira brand icon if available in the asset catalog, otherwise the "ticket" SF Symbol.
    static func jiraMarkerImage() -> NSImage? {
        if let cached = symbolImageCache["_jiraMarker"] { return cached }
        let image: NSImage?
        if let jiraIcon = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (jiraIcon.copy() as? NSImage) ?? jiraIcon
            sized.size = NSSize(width: jiraMarkerWidth, height: jiraMarkerWidth)
            sized.isTemplate = false
            image = sized
        } else {
            image = cachedSymbolImage("ticket")
        }
        if let image { symbolImageCache["_jiraMarker"] = image }
        return image
    }

    // MARK: - Constants

    private static let leadingIconSize: CGFloat = 16
    private static let dirtyDotSize: CGFloat = 7
    private static let jiraMarkerWidth: CGFloat = 10
    private static let pinMarkerWidth: CGFloat = 12
    private static let archiveMarkerWidth: CGFloat = 12
    private static let statusMarkerSlotWidth: CGFloat = 14
    private static let trailingMarkerSpacing: CGFloat = 4
    private static let primarySecondaryRowSpacing: CGFloat = 1
    private static let contentVerticalInset: CGFloat = 9

    private var prLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var jiraTicketLabel: NSTextField?
    private var jiraStatusBadge: StatusBadgeView?
    private var prDotSeparator: NSTextField?
    private var prNumberLabel: NSTextField?
    private var prStatusBadge: StatusBadgeView?
    private var jiraImageView: NSImageView?
    private var primaryDirtyDot: NSImageView?
    private var secondaryDirtyDot: NSImageView?
    private var pinImageView: NSImageView?
    private(set) var archiveButton: NSButton?
    private var completionImageView: NSImageView?
    private var rateLimitImageView: NSImageView?
    private var busySpinner: NSProgressIndicator?
    private var trailingStackView: NSStackView?
    private weak var leadingTextStackView: NSStackView?
    private weak var secondaryRowStack: NSStackView?
    private weak var prRowStack: NSStackView?
    private var leadingStackConstraint: NSLayoutConstraint?
    private var mainAccentBar: NSView?
    private var signEmojiLabel: NSTextField?
    private var hasInstalledTextTrailingConstraint = false
    private var isConfiguredAsMain = false
    private var showsRenamePulse = false

    private static let renamePulseAnimationKey = "rename-label-pulse"

    var onArchive: (() -> Void)?

    private static func descriptionFont() -> NSFont {
        .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    }

    private static func metadataFont() -> NSFont {
        .systemFont(ofSize: 10)
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func uniformSidebarRowHeight(maxDescriptionLines: Int) -> CGFloat {
        let clampedDescriptionLines = max(1, maxDescriptionLines)
        let titleBlockHeight = (lineHeight(for: descriptionFont()) * CGFloat(clampedDescriptionLines))
            + (lineHeight(for: metadataFont()) * 2)
            + primarySecondaryRowSpacing
        let contentHeight = max(
            leadingIconSize,
            dirtyDotSize,
            statusMarkerSlotWidth,
            titleBlockHeight
        )
        return ceil(contentHeight + (contentVerticalInset * 2))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateMainTextColorForSelection()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NSProgressIndicator.startAnimation may silently fail when called on a
        // cell not yet in a window (e.g. during NSOutlineView.reloadData on fresh
        // launch). Re-apply the animation once the cell enters the hierarchy.
        if window != nil, let spinner = busySpinner, !spinner.isHidden {
            spinner.startAnimation(nil)
        }
        if window != nil, showsRenamePulse {
            applyRenamePulse(true)
        }
    }

    /// Reparents imageView and textField into a horizontal stack.
    /// The first row shows the description/name; the second row shows branch/worktree metadata.
    /// Safe to call multiple times — only runs once.
    func ensureLeadingStack() {
        guard primaryDirtyDot == nil, let iv = imageView, let tf = textField else { return }

        let primaryDot = makeDirtyDot()
        let secondaryDot = makeDirtyDot()
        primaryDirtyDot = primaryDot
        secondaryDirtyDot = secondaryDot

        let subtitle = NSTextField(labelWithString: "")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = Self.metadataFont()
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentHuggingPriority(.defaultHigh, for: .vertical)
        subtitle.isHidden = true
        subtitleLabel = subtitle

        let jiraTicketTF = NSTextField(labelWithString: "")
        jiraTicketTF.translatesAutoresizingMaskIntoConstraints = false
        jiraTicketTF.font = Self.metadataFont()
        jiraTicketTF.textColor = .controlAccentColor
        jiraTicketTF.lineBreakMode = .byClipping
        jiraTicketTF.maximumNumberOfLines = 1
        jiraTicketTF.setContentHuggingPriority(.required, for: .horizontal)
        jiraTicketTF.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        jiraTicketTF.isHidden = true
        jiraTicketLabel = jiraTicketTF

        let jiraBadge = StatusBadgeView()
        jiraBadge.isHidden = true
        jiraStatusBadge = jiraBadge

        let dotSep = NSTextField(labelWithString: " · ")
        dotSep.translatesAutoresizingMaskIntoConstraints = false
        dotSep.font = Self.metadataFont()
        dotSep.textColor = .controlAccentColor
        dotSep.setContentHuggingPriority(.required, for: .horizontal)
        dotSep.setContentCompressionResistancePriority(.required, for: .horizontal)
        dotSep.isHidden = true
        prDotSeparator = dotSep

        let prNumTF = NSTextField(labelWithString: "")
        prNumTF.translatesAutoresizingMaskIntoConstraints = false
        prNumTF.font = Self.metadataFont()
        prNumTF.textColor = .controlAccentColor
        prNumTF.lineBreakMode = .byClipping
        prNumTF.maximumNumberOfLines = 1
        prNumTF.setContentHuggingPriority(.required, for: .horizontal)
        prNumTF.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        prNumTF.isHidden = true
        prNumberLabel = prNumTF

        let prBadge = StatusBadgeView()
        prBadge.isHidden = true
        prStatusBadge = prBadge

        iv.removeFromSuperview()
        tf.removeFromSuperview()

        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: Self.leadingIconSize),
            iv.heightAnchor.constraint(equalToConstant: Self.leadingIconSize),
        ])

        tf.wantsLayer = true
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

        // PR row: badge-aware composition. Individual labels + badges for Jira and PR.
        let prRow = NSStackView(views: [jiraTicketTF, jiraBadge, dotSep, prNumTF, prBadge])
        prRow.orientation = .horizontal
        prRow.alignment = .centerY
        prRow.spacing = 3
        prRow.detachesHiddenViews = true
        prRow.translatesAutoresizingMaskIntoConstraints = false

        let verticalStack = NSStackView(views: [primaryRow, secondaryRow, prRow])
        verticalStack.orientation = .vertical
        verticalStack.alignment = .leading
        verticalStack.spacing = Self.primarySecondaryRowSpacing
        verticalStack.detachesHiddenViews = true
        verticalStack.translatesAutoresizingMaskIntoConstraints = false
        verticalStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        verticalStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryRowStack = secondaryRow
        prRowStack = prRow
        leadingTextStackView = verticalStack

        let stack = NSStackView(views: [iv, verticalStack])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let emojiLabel = NSTextField(labelWithString: "")
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = .systemFont(ofSize: 9)
        emojiLabel.alignment = .center
        emojiLabel.isHidden = true
        addSubview(emojiLabel)
        signEmojiLabel = emojiLabel
        NSLayoutConstraint.activate([
            emojiLabel.trailingAnchor.constraint(equalTo: iv.leadingAnchor, constant: 1),
            emojiLabel.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
        ])

        let leadingConstraint = stack.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: ThreadListViewController.sidebarHorizontalInset
        )
        leadingStackConstraint = leadingConstraint

        var constraints = [
            leadingConstraint,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let trailingStack = trailingStackView {
            constraints.append(stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6))
        } else {
            constraints.append(stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ThreadListViewController.sidebarTrailingInset))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func ensureMainAccentBar() {
        guard mainAccentBar == nil, let leadingTextStackView else { return }

        let accentBar = NSView()
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        accentBar.isHidden = true
        addSubview(accentBar)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ThreadListViewController.sidebarRowLeadingInset
                    - ThreadListViewController.outlineIndentationPerLevel
            ),
            accentBar.centerYAnchor.constraint(equalTo: leadingTextStackView.centerYAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            accentBar.heightAnchor.constraint(equalTo: leadingTextStackView.heightAnchor),
        ])

        mainAccentBar = accentBar
    }

    private func setLeadingOffset(_ offset: CGFloat) {
        leadingStackConstraint?.constant = ThreadListViewController.sidebarHorizontalInset + offset
    }

    private func makeDirtyDot() -> NSImageView {
        let dot = NSImageView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.setContentCompressionResistancePriority(.required, for: .horizontal)
        dot.isHidden = true
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dirtyDotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dirtyDotSize),
        ])
        return dot
    }

    private func setSidebarHiddenAppearance(_ isHiddenInSidebar: Bool) {
        alphaValue = isHiddenInSidebar ? 0.5 : 1.0
    }

    private func applyRenamePulse(_ active: Bool) {
        guard let tf = textField else { return }
        tf.layer?.removeAnimation(forKey: Self.renamePulseAnimationKey)
        if active {
            tf.textColor = .controlAccentColor
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                  window != nil else {
                tf.layer?.opacity = 1.0
                return
            }
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.3
            anim.autoreverses = true
            anim.duration = 1.2
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tf.layer?.add(anim, forKey: Self.renamePulseAnimationKey)
        } else {
            tf.layer?.opacity = 1.0
        }
    }

    private func ensureTrailingStack() {
        guard trailingStackView == nil else { return }
        let completionIndicatorSize: CGFloat = Self.statusMarkerSlotWidth - 4

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
        completionIV.isHidden = true

        let rateLimitIV = NSImageView()
        rateLimitIV.translatesAutoresizingMaskIntoConstraints = false
        rateLimitIV.setContentHuggingPriority(.required, for: .horizontal)
        rateLimitIV.isHidden = true

        let archiveBtn = NSButton()
        archiveBtn.translatesAutoresizingMaskIntoConstraints = false
        archiveBtn.setContentHuggingPriority(.required, for: .horizontal)
        archiveBtn.isBordered = false
        archiveBtn.image = Self.cachedSymbolImage("archivebox.fill")
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

        // All trailing markers live directly in this stack. detachesHiddenViews = true means
        // hidden items take no space, so multiple icons (e.g. archive + completion) can appear
        // side-by-side without a fixed-size slot container.
        let stack = NSStackView(views: [prTF, jiraIV, archiveBtn, spinner, rateLimitIV, completionIV, pinIV])
        stack.orientation = .horizontal
        stack.spacing = Self.trailingMarkerSpacing
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)

        // Keep markers hard-aligned to the trailing edge so additional markers grow leftward.
        let trailingAlignmentInset = ThreadListViewController.sidebarTrailingInset

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingAlignmentInset),
            jiraIV.widthAnchor.constraint(equalToConstant: Self.jiraMarkerWidth),
            jiraIV.heightAnchor.constraint(equalToConstant: Self.jiraMarkerWidth),
            pinIV.widthAnchor.constraint(equalToConstant: Self.pinMarkerWidth),
            pinIV.heightAnchor.constraint(equalToConstant: Self.pinMarkerWidth),
            archiveBtn.widthAnchor.constraint(equalToConstant: Self.archiveMarkerWidth),
            archiveBtn.heightAnchor.constraint(equalToConstant: Self.archiveMarkerWidth),
            spinner.widthAnchor.constraint(equalToConstant: Self.statusMarkerSlotWidth),
            spinner.heightAnchor.constraint(equalToConstant: Self.statusMarkerSlotWidth),
            rateLimitIV.widthAnchor.constraint(equalToConstant: Self.jiraMarkerWidth),
            rateLimitIV.heightAnchor.constraint(equalToConstant: Self.jiraMarkerWidth),
            completionIV.widthAnchor.constraint(equalToConstant: completionIndicatorSize),
            completionIV.heightAnchor.constraint(equalToConstant: completionIndicatorSize),
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

    func configure(
        with thread: MagentThread,
        sectionColor: NSColor?,
        leadingOffset: CGFloat = 0,
        maxDescriptionLines: Int = 2,
        isAutoRenaming: Bool = false
    ) {
        isConfiguredAsMain = false
        ensureTrailingStack()
        ensureLeadingStack()
        ensureMainAccentBar()
        setLeadingOffset(leadingOffset)
        setSidebarHiddenAppearance(thread.isSidebarHidden)
        mainAccentBar?.isHidden = true

        let worktreeName = (thread.worktreePath as NSString).lastPathComponent
        let branchName = (thread.actualBranch ?? thread.branchName).trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranchName = branchName.isEmpty ? thread.name : branchName
        let hasBranchWorktreeMismatch = worktreeName != resolvedBranchName

        // Secondary line 1: branch + worktree (no PR).
        var branchWorktreeParts = [resolvedBranchName]
        if hasBranchWorktreeMismatch {
            branchWorktreeParts.append(worktreeName)
        }
        let branchWorktreeLine = branchWorktreeParts.joined(separator: "  ·  ")

        let trimmedDescription = thread.taskDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDescription = !(trimmedDescription?.isEmpty ?? true)
        let clampedDescriptionLines = max(1, maxDescriptionLines)

        if hasDescription {
            // Keep description wrapping stable across selection/unread state changes.
            textField?.font = Self.descriptionFont()
        } else {
            textField?.font = thread.hasUnreadAgentCompletion
                ? Self.descriptionFont()
                : .preferredFont(forTextStyle: .body)
        }
        let showsJiraState = AppFeatures.jiraSyncEnabled
        textField?.textColor = showsJiraState && thread.jiraUnassigned ? .tertiaryLabelColor : .labelColor
        textField?.lineBreakMode = .byTruncatingTail

        if hasDescription, let description = trimmedDescription {
            // With description: primary = description, secondary = branch · worktree.
            textField?.stringValue = description
            textField?.maximumNumberOfLines = clampedDescriptionLines
            textField?.lineBreakMode = clampedDescriptionLines > 1 ? .byWordWrapping : .byTruncatingTail
            subtitleLabel?.stringValue = branchWorktreeLine
            subtitleLabel?.textColor = showsJiraState && thread.jiraUnassigned ? .tertiaryLabelColor : .secondaryLabelColor
            subtitleLabel?.isHidden = false
            setDirtyDot(primaryDirtyDot, visible: false)
            setDirtyDot(secondaryDirtyDot, visible: thread.isDirty)
        } else {
            // Without description: primary = branch, secondary = worktree only (if different).
            textField?.stringValue = resolvedBranchName
            textField?.maximumNumberOfLines = 1
            if hasBranchWorktreeMismatch {
                subtitleLabel?.stringValue = worktreeName
                subtitleLabel?.textColor = .secondaryLabelColor
                subtitleLabel?.isHidden = false
            } else {
                subtitleLabel?.stringValue = ""
                subtitleLabel?.isHidden = true
            }
            setDirtyDot(primaryDirtyDot, visible: thread.isDirty)
            setDirtyDot(secondaryDirtyDot, visible: false)
        }

        // Secondary line 2 (PR/ticket row): ticket key with status badge, PR number with status badge.
        let cellSettings = PersistenceService.shared.loadSettings()
        let jiraEnabled = cellSettings.jiraIntegrationEnabled && cellSettings.jiraTicketDetectionEnabled
        let ticketKey = jiraEnabled ? thread.effectiveJiraTicketKey : nil
        let badgeFontSize: CGFloat = 8
        let showJiraBadges = cellSettings.showJiraStatusBadges
        let showPRBadges = cellSettings.showPRStatusBadges

        let hasTicket = ticketKey != nil
        let hasPR = thread.pullRequestInfo != nil

        if let ticketKey {
            jiraTicketLabel?.stringValue = ticketKey
            jiraTicketLabel?.isHidden = false
            if showJiraBadges, let verified = thread.verifiedJiraTicket, !verified.status.isEmpty {
                jiraStatusBadge?.configure(
                    text: verified.status,
                    style: StatusBadgeView.jiraStyle(forCategoryKey: verified.statusCategoryKey),
                    fontSize: badgeFontSize
                )
                jiraStatusBadge?.isHidden = false
            } else {
                jiraStatusBadge?.isHidden = true
            }
        } else {
            jiraTicketLabel?.stringValue = ""
            jiraTicketLabel?.isHidden = true
            jiraStatusBadge?.isHidden = true
        }

        prDotSeparator?.isHidden = !(hasTicket && hasPR)

        if let pr = thread.pullRequestInfo {
            prNumberLabel?.stringValue = pr.displayLabel
            prNumberLabel?.isHidden = false
            if showPRBadges {
                prStatusBadge?.configure(
                    text: pr.statusText,
                    style: StatusBadgeView.prStyle(for: pr),
                    fontSize: badgeFontSize
                )
                prStatusBadge?.isHidden = false
            } else {
                prStatusBadge?.isHidden = true
            }
        } else {
            prNumberLabel?.stringValue = ""
            prNumberLabel?.isHidden = true
            prStatusBadge?.isHidden = true
        }

        let detailedTooltip = buildDetailedTooltip(
            description: trimmedDescription,
            branchName: resolvedBranchName,
            worktreeName: worktreeName,
            prLabel: thread.pullRequestInfo.map { "\($0.displayLabel) (\($0.statusText))" },
            statuses: statusDescriptions(for: thread)
        )
        toolTip = detailedTooltip
        imageView?.toolTip = detailedTooltip
        textField?.toolTip = detailedTooltip
        subtitleLabel?.toolTip = detailedTooltip
        primaryDirtyDot?.toolTip = detailedTooltip
        secondaryDirtyDot?.toolTip = detailedTooltip

        imageView?.image = Self.cachedSymbolImage(thread.threadIcon.symbolName)
            ?? Self.cachedSymbolImage("terminal")
        imageView?.contentTintColor = thread.hasUnreadAgentCompletion
            ? NSColor.controlAccentColor
            : (sectionColor ?? NSColor(resource: .primaryBrand))

        if let emoji = thread.signEmoji {
            signEmojiLabel?.stringValue = emoji
            signEmojiLabel?.isHidden = false
        } else {
            signEmojiLabel?.stringValue = ""
            signEmojiLabel?.isHidden = true
        }

        prLabel?.stringValue = ""
        prLabel?.toolTip = nil
        prLabel?.isHidden = true

        jiraImageView?.image = nil
        jiraImageView?.toolTip = nil
        jiraImageView?.isHidden = true

        if thread.isPinned {
            pinImageView?.image = Self.cachedSymbolImage("pin.fill")
            pinImageView?.contentTintColor = .controlAccentColor
            pinImageView?.isHidden = false
        } else {
            pinImageView?.image = nil
            pinImageView?.isHidden = true
        }

        archiveButton?.isHidden = !thread.showArchiveSuggestion

        if thread.isRateLimitExpiredAndResumable {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = Self.cachedSymbolImage("arrow.clockwise.circle.fill")
            rateLimitImageView?.contentTintColor = .systemGreen
            rateLimitImageView?.toolTip = "Rate limit lifted — ready to resume"
            rateLimitImageView?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if thread.isBlockedByRateLimit {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = Self.cachedSymbolImage("hourglass.circle.fill")
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
            completionImageView?.image = Self.cachedSymbolImage("exclamationmark.circle.fill")
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
            completionImageView?.image = Self.cachedSymbolImage("circle.fill")
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

        syncRowVisibility()
        showsRenamePulse = isAutoRenaming
        applyRenamePulse(isAutoRenaming)
    }

    func configureAsMain(
        isUnreadCompletion: Bool = false,
        isBusy: Bool = false,
        isWaitingForInput: Bool = false,
        isDirty: Bool = false,
        isBlockedByRateLimit: Bool = false,
        isRateLimitExpiredAndResumable: Bool = false,
        rateLimitTooltip: String? = nil,
        currentBranch: String? = nil,
        leadingOffset: CGFloat = 0
    ) {
        isConfiguredAsMain = true
        ensureTrailingStack()
        ensureLeadingStack()
        ensureMainAccentBar()
        setLeadingOffset(leadingOffset)
        setSidebarHiddenAppearance(false)
        mainAccentBar?.isHidden = false

        textField?.stringValue = "Main worktree"
        textField?.font = .systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isUnreadCompletion ? .bold : .semibold
        )
        updateMainTextColorForSelection()
        textField?.lineBreakMode = .byTruncatingTail
        textField?.maximumNumberOfLines = 1

        pinImageView?.isHidden = true
        archiveButton?.isHidden = true

        let resolvedBranch = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedBranch, !resolvedBranch.isEmpty {
            subtitleLabel?.stringValue = resolvedBranch
            subtitleLabel?.textColor = .secondaryLabelColor
            subtitleLabel?.isHidden = false
        } else {
            subtitleLabel?.stringValue = ""
            subtitleLabel?.isHidden = true
        }

        imageView?.image = nil
        imageView?.isHidden = true

        signEmojiLabel?.isHidden = true

        setDirtyDot(primaryDirtyDot, visible: false)
        setDirtyDot(secondaryDirtyDot, visible: isDirty)

        let detailedTooltip = buildDetailedTooltip(
            description: "Main worktree",
            branchName: (resolvedBranch?.isEmpty == false ? resolvedBranch : nil) ?? "Unknown branch",
            worktreeName: "Main worktree",
            prLabel: nil,
            statuses: mainStatusDescriptions(
                isDirty: isDirty,
                isRateLimitExpiredAndResumable: isRateLimitExpiredAndResumable,
                rateLimitTooltip: rateLimitTooltip,
                isBlockedByRateLimit: isBlockedByRateLimit,
                isWaitingForInput: isWaitingForInput,
                isBusy: isBusy,
                isUnreadCompletion: isUnreadCompletion
            )
        )
        toolTip = detailedTooltip
        imageView?.toolTip = detailedTooltip
        textField?.toolTip = detailedTooltip
        subtitleLabel?.toolTip = detailedTooltip
        primaryDirtyDot?.toolTip = detailedTooltip
        secondaryDirtyDot?.toolTip = detailedTooltip

        if isRateLimitExpiredAndResumable {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = Self.cachedSymbolImage("arrow.clockwise.circle.fill")
            rateLimitImageView?.contentTintColor = .systemGreen
            rateLimitImageView?.toolTip = "Rate limit lifted — ready to resume"
            rateLimitImageView?.isHidden = false
            completionImageView?.image = nil
            completionImageView?.toolTip = nil
            completionImageView?.isHidden = true
        } else if isBlockedByRateLimit {
            busySpinner?.stopAnimation(nil)
            busySpinner?.isHidden = true
            busySpinner?.toolTip = nil
            rateLimitImageView?.image = Self.cachedSymbolImage("hourglass.circle.fill")
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
            completionImageView?.image = Self.cachedSymbolImage("exclamationmark.circle.fill")
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
            completionImageView?.image = Self.cachedSymbolImage("circle.fill")
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

        syncRowVisibility()
    }

    private func syncRowVisibility() {
        let subtitleVisible = !(subtitleLabel?.isHidden ?? true)
        let secondaryDotVisible = !(secondaryDirtyDot?.isHidden ?? true)
        secondaryRowStack?.isHidden = !subtitleVisible && !secondaryDotVisible

        let hasJira = !(jiraTicketLabel?.isHidden ?? true)
        let hasPR = !(prNumberLabel?.isHidden ?? true)
        prRowStack?.isHidden = !hasJira && !hasPR
    }

    private func setDirtyDot(_ dot: NSImageView?, visible: Bool) {
        guard let dot else { return }
        if visible {
            dot.image = Self.cachedSymbolImage("circle.fill")
            dot.contentTintColor = NSColor.systemOrange.withAlphaComponent(0.7)
            dot.isHidden = false
        } else {
            dot.image = nil
            dot.isHidden = true
        }
    }

    private func updateMainTextColorForSelection() {
        guard isConfiguredAsMain else { return }
        textField?.textColor = backgroundStyle == .emphasized ? .white : .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMainTextColorForSelection()
    }

    private func statusDescriptions(for thread: MagentThread) -> [String] {
        var statuses: [String] = []
        if thread.isDirty {
            statuses.append("Dirty")
        }

        if thread.isSidebarHidden {
            statuses.append("Hidden")
        }

        if thread.isRateLimitExpiredAndResumable {
            statuses.append("Ready to resume")
        } else if thread.isBlockedByRateLimit {
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

    private func mainStatusDescriptions(
        isDirty: Bool,
        isRateLimitExpiredAndResumable: Bool,
        rateLimitTooltip: String?,
        isBlockedByRateLimit: Bool,
        isWaitingForInput: Bool,
        isBusy: Bool,
        isUnreadCompletion: Bool
    ) -> [String] {
        var statuses: [String] = []
        if isDirty {
            statuses.append("Dirty")
        }

        if isRateLimitExpiredAndResumable {
            statuses.append("Ready to resume")
        } else if isBlockedByRateLimit {
            let rateLimitDetail = rateLimitTooltip?
                .replacingOccurrences(of: "Rate limit reached. ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let rateLimitDetail, !rateLimitDetail.isEmpty, rateLimitDetail != "Rate limit reached" {
                statuses.append("Rate limited (\(rateLimitDetail))")
            } else {
                statuses.append("Rate limited")
            }
        } else if isWaitingForInput {
            statuses.append("Waiting for input")
        } else if isBusy {
            statuses.append("Agent busy")
        } else if isUnreadCompletion {
            statuses.append("Agent completed")
        }

        return statuses
    }

    @objc private func archiveButtonClicked() {
        onArchive?()
    }
}
