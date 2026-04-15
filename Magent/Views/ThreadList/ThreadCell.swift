import Cocoa
import MagentCore

/// A pill-shaped container for the priority dots label. Paints a
/// `windowBackgroundColor` background (matching the sidebar area behind the
/// row capsules) and wears the same 1pt border + 5/2 padding + cornerRadius 7
/// as `TopBorderBadge` so it visually sits next to the duration badge as a
/// matching sibling.
private final class PriorityCapsuleView: NSView {
    let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        tf.backgroundColor = .clear
        tf.isBordered = false
        tf.isEditable = false
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        tf.setContentHuggingPriority(.required, for: .horizontal)
        tf.setContentCompressionResistancePriority(.required, for: .horizontal)
        return tf
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        // Match TopBorderBadge: 5pt horizontal, 2pt vertical inner padding.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Matches the border-color logic of `TopBorderBadge.updateColors(...)` so
    /// selection, waiting, and completion highlights stay in sync with the
    /// adjacent duration badge. NSColor dynamic resolution runs inside the
    /// drawing appearance block per the CALayer convention in AGENTS.md.
    func updateColors(isRowSelected: Bool, hasCompletionHighlight: Bool, hasWaitingHighlight: Bool, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            let borderColor: CGColor
            if isRowSelected {
                borderColor = NSColor.controlAccentColor.cgColor
            } else if hasWaitingHighlight {
                borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
            } else if hasCompletionHighlight {
                borderColor = NSColor.systemGreen.withAlphaComponent(0.5).cgColor
            } else {
                borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            }
            self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            self.layer?.borderColor = borderColor
            self.layer?.borderWidth = 1
        }
    }
}

/// A small pill badge that sits on the top border of the capsule row.
/// Hosts either a text label or an icon image view (or both).
private final class TopBorderBadge: NSView {
    /// When true, the badge renders as a bare icon (no pill background/border,
    /// larger icon size). Use for icon-only badges like pin or rate-limit.
    let isBareIcon: Bool

    let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        tf.lineBreakMode = .byClipping
        tf.maximumNumberOfLines = 1
        tf.setContentHuggingPriority(.required, for: .horizontal)
        tf.setContentCompressionResistancePriority(.required, for: .horizontal)
        tf.backgroundColor = .clear
        tf.isBordered = false
        tf.isEditable = false
        return tf
    }()

    let iconView: NSImageView = {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.setContentCompressionResistancePriority(.required, for: .horizontal)
        iv.isHidden = true
        return iv
    }()

    private let cornerDot: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.isHidden = true
        return view
    }()

    private let contentStack: NSStackView

    init(bareIcon: Bool = false) {
        self.isBareIcon = bareIcon
        contentStack = NSStackView(views: [])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 3
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(label)
        addSubview(contentStack)
        addSubview(cornerDot)

        if bareIcon {
            // Bare icon: larger icon with circular background when selected.
            let iconSize: CGFloat = 13
            let padding: CGFloat = 3
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: iconSize),
                iconView.heightAnchor.constraint(equalToConstant: iconSize),
                contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
                contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
                cornerDot.widthAnchor.constraint(equalToConstant: 2),
                cornerDot.heightAnchor.constraint(equalToConstant: 2),
                cornerDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                cornerDot.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            ])
        } else {
            layer?.cornerRadius = 7
            layer?.borderWidth = 1
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 8),
                iconView.heightAnchor.constraint(equalToConstant: 8),
                contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
                contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                cornerDot.widthAnchor.constraint(equalToConstant: 2),
                cornerDot.heightAnchor.constraint(equalToConstant: 2),
                cornerDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
                cornerDot.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if isBareIcon {
            layer?.cornerRadius = bounds.height / 2
        }
    }

    func updateColors(isRowSelected: Bool, hasCompletionHighlight: Bool, hasWaitingHighlight: Bool = false, appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            // Border color mirrors the capsule row border.
            let borderColor: CGColor
            if isRowSelected {
                borderColor = NSColor.controlAccentColor.cgColor
            } else if hasWaitingHighlight {
                borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
            } else if hasCompletionHighlight {
                borderColor = NSColor.systemGreen.withAlphaComponent(0.5).cgColor
            } else {
                borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            }

            if self.isBareIcon {
                self.layer?.cornerRadius = self.bounds.height / 2
                self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                self.layer?.borderColor = borderColor
                self.layer?.borderWidth = 1
            } else {
                self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                self.layer?.borderColor = borderColor
                self.layer?.borderWidth = 1
            }
            self.label.textColor = NSColor.secondaryLabelColor
            self.cornerDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            self.cornerDot.layer?.cornerRadius = 1
        }
    }

    func setCornerDotVisible(_ isVisible: Bool) {
        cornerDot.isHidden = !isVisible
    }
}

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

    /// Returns a larger Jira brand icon for the top-border badge. Cached separately
    /// from `jiraMarkerImage()` so the inline 10pt marker instance isn't resized.
    static func jiraBadgeIconImage() -> NSImage? {
        if let cached = symbolImageCache["_jiraBadge"] { return cached }
        let image: NSImage?
        if let jiraIcon = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (jiraIcon.copy() as? NSImage) ?? jiraIcon
            sized.size = NSSize(width: jiraBadgeIconSize, height: jiraBadgeIconSize)
            sized.isTemplate = false
            image = sized
        } else {
            image = cachedSymbolImage("ticket")
        }
        if let image { symbolImageCache["_jiraBadge"] = image }
        return image
    }

    // MARK: - Constants

    private static let leadingIconSize: CGFloat = 16
    private static let dirtyDotSize: CGFloat = 7
    private static let jiraMarkerWidth: CGFloat = 10
    private static let jiraBadgeIconSize: CGFloat = 13
    private static let pinMarkerWidth: CGFloat = 12
    private static let archiveMarkerWidth: CGFloat = 12
    private static let trailingMarkerSpacing: CGFloat = 4
    private static let primarySecondaryRowSpacing: CGFloat = 1
    /// Total vertical padding from row/cell edge to content (capsule inset + border + content padding).
    private static let contentVerticalInset: CGFloat =
        AlwaysEmphasizedRowView.capsuleVerticalInset
        + AlwaysEmphasizedRowView.capsuleBorderInset
        + AlwaysEmphasizedRowView.capsuleContentVPadding

    private var subtitleLabel: NSTextField?
    private var jiraTicketLabel: NSTextField?
    private var jiraStatusBadge: StatusBadgeView?
    private var prDotSeparator: NSTextField?
    private var prNumberLabel: NSTextField?
    private var prStatusBadge: StatusBadgeView?
    private var primaryDirtyDot: NSImageView?
    private var secondaryDirtyDot: NSImageView?
    private var popoutImageView: NSImageView?
    private var pinImageView: NSImageView?
    private(set) var archiveButton: NSButton?
    private var trailingStackView: NSStackView?
    private weak var leadingTextStackView: NSStackView?
    private weak var secondaryRowStack: NSStackView?
    private weak var prRowStack: NSStackView?
    private var leadingStackConstraint: NSLayoutConstraint?
    private var mainAccentBar: NSView?
    private var durationLabel: NSTextField?
    private var durationTimer: Timer?
    private var currentDurationSince: Date?
    /// 5-dot priority capsule rendered at the bottom border, immediately left of the duration badge.
    /// Hidden (detached from the stack) when the thread has no priority set.
    private var priorityCapsule: PriorityCapsuleView?
    private var topBorderBadgeStack: NSStackView?
    private var claudeRateLimitBadge: TopBorderBadge?
    private var codexRateLimitBadge: TopBorderBadge?
    private var keepAliveBadge: TopBorderBadge?
    private var favoriteBadge: TopBorderBadge?
    private var pinnedBadge: TopBorderBadge?
    private var jiraSyncBadge: TopBorderBadge?
    private var hasInstalledTextTrailingConstraint = false
    private var isConfiguredAsMain = false
    private var showsRenamePulse = false
    private var hasUnreadCompletion = false
    private var hasWaitingForInput = false
    private var hasAllDead = false
    private var configuredSectionColor: NSColor?

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

    static func uniformSidebarRowHeight(maxDescriptionLines: Int, narrowThreads: Bool = false) -> CGFloat {
        sidebarRowHeight(descriptionLines: max(1, maxDescriptionLines), hasSubtitle: true, hasPRRow: true, narrowThreads: narrowThreads)
    }

    /// Estimate how many lines the description text will occupy given available width.
    static func estimatedDescriptionLineCount(text: String, maxLines: Int, availableWidth: CGFloat) -> Int {
        let font = descriptionFont()
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let lines = max(1, Int(ceil(textWidth / max(1, availableWidth))))
        return min(lines, max(1, maxLines))
    }

    /// Minimum content height: description lines (based on narrow setting) + 2 metadata labels.
    static func minimumContentHeight(narrowThreads: Bool) -> CGFloat {
        let descLines = narrowThreads ? 1 : 2
        let minBlock = lineHeight(for: descriptionFont()) * CGFloat(descLines)
            + (lineHeight(for: metadataFont()) * 2)
            + primarySecondaryRowSpacing
        return max(leadingIconSize, minBlock)
    }

    /// Compute row height based on actual visible content lines.
    static func sidebarRowHeight(
        descriptionLines: Int,
        hasSubtitle: Bool,
        hasPRRow: Bool,
        narrowThreads: Bool = false
    ) -> CGFloat {
        let descHeight = lineHeight(for: descriptionFont()) * CGFloat(max(1, descriptionLines))
        var titleBlockHeight = descHeight
        if hasSubtitle {
            titleBlockHeight += lineHeight(for: metadataFont()) + primarySecondaryRowSpacing
        }
        if hasPRRow {
            titleBlockHeight += lineHeight(for: metadataFont()) + primarySecondaryRowSpacing
        }
        let contentHeight = max(leadingIconSize, titleBlockHeight, minimumContentHeight(narrowThreads: narrowThreads))
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
            updateTopBorderBadgeColors()
            updateLeadingIconTint()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

        // Position the accent bar where the icon sits in non-main threads:
        // same horizontal inset, centered vertically with the text stack.
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ThreadListViewController.sidebarHorizontalInset
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

    private func setDimmedAppearance(isHidden: Bool, isArchiving: Bool) {
        let dimmed = isHidden || isArchiving
        let contentAlpha: CGFloat = dimmed ? 0.5 : 1.0
        // Dim content subviews individually so that border badges keep full
        // opacity and don't visually bleed through the capsule border.
        for sub in subviews where sub !== topBorderBadgeStack && sub !== bottomBorderBadgeStack {
            sub.alphaValue = contentAlpha
        }
        topBorderBadgeStack?.alphaValue = 1.0
        bottomBorderBadgeStack?.alphaValue = 1.0
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

        let popoutIV = NSImageView()
        popoutIV.translatesAutoresizingMaskIntoConstraints = false
        popoutIV.setContentHuggingPriority(.required, for: .horizontal)
        popoutIV.setContentCompressionResistancePriority(.required, for: .horizontal)
        popoutIV.image = Self.cachedSymbolImage("macwindow.on.rectangle")
        popoutIV.contentTintColor = .systemPurple
        popoutIV.toolTip = "Open in separate window"
        popoutIV.isHidden = true

        let pinIV = NSImageView()
        pinIV.translatesAutoresizingMaskIntoConstraints = false
        pinIV.setContentHuggingPriority(.required, for: .horizontal)

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

        let stack = NSStackView(views: [archiveBtn, popoutIV, pinIV])
        stack.orientation = .horizontal
        stack.spacing = Self.trailingMarkerSpacing
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)

        let trailingAlignmentInset = AlwaysEmphasizedRowView.capsuleTrailingInset + AlwaysEmphasizedRowView.capsuleContentHPadding

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailingAlignmentInset),
            popoutIV.widthAnchor.constraint(equalToConstant: 15),
            popoutIV.heightAnchor.constraint(equalToConstant: 15),
            pinIV.widthAnchor.constraint(equalToConstant: Self.pinMarkerWidth),
            pinIV.heightAnchor.constraint(equalToConstant: Self.pinMarkerWidth),
            archiveBtn.widthAnchor.constraint(equalToConstant: Self.archiveMarkerWidth),
            archiveBtn.heightAnchor.constraint(equalToConstant: Self.archiveMarkerWidth),
        ])
        trailingStackView = stack
        popoutImageView = popoutIV
        pinImageView = pinIV
        archiveButton = archiveBtn

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
        setDimmedAppearance(isHidden: thread.isSidebarHidden, isArchiving: thread.isArchiving)
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
        let deadSessions = thread.hasAllSessionsDead
        if showsJiraState && thread.jiraUnassigned {
            textField?.textColor = .tertiaryLabelColor
        } else {
            textField?.textColor = deadSessions ? .secondaryLabelColor : .labelColor
        }
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
        let ticketKey = jiraEnabled ? thread.effectiveJiraTicketKey(settings: cellSettings) : nil
        let badgeFontSize: CGFloat = 8
        let showJiraBadges = cellSettings.showJiraStatusBadges
        let showPRBadges = cellSettings.showPRStatusBadges

        let hasTicket = ticketKey != nil
        let hasPR = thread.pullRequestInfo != nil

        if let ticketKey {
            jiraTicketLabel?.stringValue = ticketKey
            jiraTicketLabel?.isHidden = false
            jiraTicketLabel?.toolTip = "Jira ticket: \(ticketKey)"
            if showJiraBadges, let verified = thread.verifiedJiraTicket, !verified.status.isEmpty {
                jiraStatusBadge?.configure(
                    text: verified.status,
                    style: StatusBadgeView.jiraStyle(forCategoryKey: verified.statusCategoryKey),
                    fontSize: badgeFontSize
                )
                jiraStatusBadge?.isHidden = false
                jiraStatusBadge?.toolTip = "Jira status: \(verified.status)"
            } else {
                jiraStatusBadge?.isHidden = true
                jiraStatusBadge?.toolTip = nil
            }
        } else {
            jiraTicketLabel?.stringValue = ""
            jiraTicketLabel?.isHidden = true
            jiraTicketLabel?.toolTip = nil
            jiraStatusBadge?.isHidden = true
            jiraStatusBadge?.toolTip = nil
        }

        prDotSeparator?.isHidden = !(hasTicket && hasPR)

        if let pr = thread.pullRequestInfo {
            prNumberLabel?.stringValue = pr.displayLabel
            prNumberLabel?.isHidden = false
            prNumberLabel?.toolTip = "Pull request: \(pr.displayLabel)"
            if showPRBadges {
                prStatusBadge?.configure(
                    text: pr.statusText,
                    style: StatusBadgeView.prStyle(for: pr),
                    fontSize: badgeFontSize
                )
                prStatusBadge?.isHidden = false
                prStatusBadge?.toolTip = "PR status: \(pr.statusText)"
            } else {
                prStatusBadge?.isHidden = true
                prStatusBadge?.toolTip = nil
            }
        } else {
            prNumberLabel?.stringValue = ""
            prNumberLabel?.isHidden = true
            prNumberLabel?.toolTip = nil
            prStatusBadge?.isHidden = true
            prStatusBadge?.toolTip = nil
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
        hasUnreadCompletion = thread.hasUnreadAgentCompletion
        hasWaitingForInput = thread.hasWaitingForInput
        hasAllDead = thread.hasAllSessionsDead
        configuredSectionColor = sectionColor
        updateLeadingIconTint()


        if thread.isFavorite {
            ensureFavoriteBadge()
            favoriteBadge?.isHidden = false
            favoriteBadge?.toolTip = "Favorite thread"
        } else {
            favoriteBadge?.isHidden = true
            favoriteBadge?.toolTip = nil
        }

        if thread.isPinned {
            ensurePinnedBadge()
            pinnedBadge?.isHidden = false
            pinnedBadge?.toolTip = "Pinned thread"
            pinImageView?.isHidden = true
        } else {
            pinnedBadge?.isHidden = true
            pinnedBadge?.toolTip = nil
            pinImageView?.isHidden = true
        }

        if thread.syncWithJira {
            ensureJiraSyncBadge()
            jiraSyncBadge?.isHidden = false
            jiraSyncBadge?.toolTip = "Auto-syncing description and priority from Jira"
        } else {
            jiraSyncBadge?.isHidden = true
            jiraSyncBadge?.toolTip = nil
        }
        updateTopBorderBadgeOrder()

        // Show shield when thread has Keep Alive, but hide it when pinned threads
        // are already implicitly protected via the protectPinnedFromEviction setting.
        let showKeepAliveShield = thread.isKeepAlive
            && !(cellSettings.protectPinnedFromEviction && thread.isPinned)
        if showKeepAliveShield {
            ensureKeepAliveBadge()
            keepAliveBadge?.toolTip = "Keep Alive — protected from idle eviction"
            keepAliveBadge?.isHidden = false
            if thread.isPinned { ensurePinnedBadge() }
        } else {
            keepAliveBadge?.isHidden = true
            keepAliveBadge?.toolTip = nil
        }

        let isPopout = PopoutWindowManager.shared.isThreadPoppedOut(thread.id)
        popoutImageView?.isHidden = !isPopout

        archiveButton?.isHidden = !thread.showArchiveSuggestion

        // Rate limit shown as top-border badge with agent glyph.
        configureRateLimitBadge(
            isExpiredAndResumable: thread.isRateLimitExpiredAndResumable,
            isBlocked: thread.isBlockedByRateLimit,
            isPropagatedOnly: thread.isRateLimitPropagatedOnly,
            tooltip: rateLimitTooltip(for: thread),
            rateLimitedAgentTypes: thread.rateLimitedAgentTypes,
            directlyRateLimitedAgentTypes: thread.directlyRateLimitedAgentTypes
        )

        configureDuration(since: cellSettings.showBusyStateDuration ? thread.busyStateSince : nil)
        configurePriority(thread.priority)

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
        isRateLimitPropagatedOnly: Bool = false,
        rateLimitTooltip: String? = nil,
        rateLimitedAgentTypes: Set<AgentType> = [],
        directlyRateLimitedAgentTypes: Set<AgentType> = [],
        currentBranch: String? = nil,
        busyStateSince: Date? = nil,
        leadingOffset: CGFloat = 0
    ) {
        isConfiguredAsMain = true
        ensureTrailingStack()
        ensureLeadingStack()
        ensureMainAccentBar()
        setLeadingOffset(leadingOffset)
        setDimmedAppearance(isHidden: false, isArchiving: false)
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
        popoutImageView?.isHidden = true
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

        // Rate limit shown as top-border badge with agent glyph (same as non-main threads).
        configureRateLimitBadge(
            isExpiredAndResumable: isRateLimitExpiredAndResumable,
            isBlocked: isBlockedByRateLimit,
            isPropagatedOnly: isRateLimitPropagatedOnly,
            tooltip: rateLimitTooltip,
            rateLimitedAgentTypes: rateLimitedAgentTypes,
            directlyRateLimitedAgentTypes: directlyRateLimitedAgentTypes
        )

        let showDuration = PersistenceService.shared.loadSettings().showBusyStateDuration
        configureDuration(since: showDuration ? busyStateSince : nil)
        // The main worktree row doesn't carry a priority.
        configurePriority(nil)

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

    // MARK: - Rate limit badge (top border)

    /// Shows/hides rate limit badges on the top border, one per rate-limited agent type.
    private func configureRateLimitBadge(
        isExpiredAndResumable: Bool,
        isBlocked: Bool,
        isPropagatedOnly: Bool,
        tooltip: String?,
        rateLimitedAgentTypes: Set<AgentType> = [],
        directlyRateLimitedAgentTypes: Set<AgentType> = []
    ) {
        let showBadge = isExpiredAndResumable || isBlocked
        guard showBadge else {
            claudeRateLimitBadge?.isHidden = true
            claudeRateLimitBadge?.setCornerDotVisible(false)
            codexRateLimitBadge?.isHidden = true
            codexRateLimitBadge?.setCornerDotVisible(false)
            return
        }

        // When we know the agent types, show one badge per agent.
        // Fall back to showing a single Claude badge when agent type is unknown.
        let agentsToShow: [AgentType] = rateLimitedAgentTypes.isEmpty
            ? [.claude]
            : AgentType.allCases.filter { rateLimitedAgentTypes.contains($0) && $0 != .custom }

        for agent in [AgentType.claude, .codex] {
            let badge = ensureRateLimitBadge(for: agent)
            guard agentsToShow.contains(agent) else {
                badge.isHidden = true
                badge.setCornerDotVisible(false)
                continue
            }

            badge.label.isHidden = true
            badge.iconView.isHidden = false
            badge.iconView.image = Self.agentIconImage(for: agent)

            if isExpiredAndResumable {
                badge.iconView.contentTintColor = .systemGreen
                badge.toolTip = "\(agent.displayName) rate limit lifted — ready to resume"
            } else {
                badge.iconView.contentTintColor = .systemRed
                badge.toolTip = tooltip.map { "\(agent.displayName): \($0)" }
                    ?? "\(agent.displayName) rate limit reached"
            }
            badge.isHidden = false
            badge.setCornerDotVisible(directlyRateLimitedAgentTypes.contains(agent))
        }
        updateTopBorderBadgeColors()
    }

    // MARK: - Busy-state duration label

    private static func durationFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    }

    private var durationBadge: TopBorderBadge?
    /// Holds `[priorityLabel, durationBadge]` anchored to the bottom-border line.
    /// `detachesHiddenViews = true` so either can collapse independently and the
    /// surviving one slides to the trailing edge without a phantom gap.
    private weak var bottomBorderBadgeStack: NSStackView?

    private func ensureTopBorderBadgeStack() {
        guard topBorderBadgeStack == nil else { return }
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        addSubview(stack)

        let capsuleTopY = AlwaysEmphasizedRowView.capsuleVerticalInset
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: topAnchor, constant: capsuleTopY),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -(AlwaysEmphasizedRowView.capsuleTrailingInset + AlwaysEmphasizedRowView.capsuleContentHPadding)
            ),
        ])
        topBorderBadgeStack = stack
    }

    @discardableResult
    private func ensureRateLimitBadge(for agent: AgentType) -> TopBorderBadge {
        switch agent {
        case .claude:
            if let existing = claudeRateLimitBadge { return existing }
        case .codex:
            if let existing = codexRateLimitBadge { return existing }
        case .custom:
            if let existing = claudeRateLimitBadge { return existing }
        }

        ensureTopBorderBadgeStack()
        let badge = TopBorderBadge(bareIcon: true)
        badge.label.isHidden = true
        badge.isHidden = true
        topBorderBadgeStack?.insertArrangedSubview(badge, at: 0)

        switch agent {
        case .claude, .custom:
            claudeRateLimitBadge = badge
        case .codex:
            codexRateLimitBadge = badge
        }
        return badge
    }

    private static func agentIconImage(for agent: AgentType) -> NSImage? {
        switch agent {
        case .claude, .custom:
            return NSImage(resource: .claudeIcon)
        case .codex:
            return NSImage(resource: .codexIcon)
        }
    }

    private func ensureDurationLabel() {
        guard durationLabel == nil else { return }

        let badge = TopBorderBadge()
        badge.iconView.isHidden = true
        badge.isHidden = true

        // Priority dots: wrapped in a pill-shaped container with a
        // `windowBackgroundColor` fill (matches the sidebar area behind the
        // row capsules), 2pt inner padding on all edges.
        let capsule = PriorityCapsuleView()
        capsule.label.font = Self.priorityDotsFont()
        capsule.isHidden = true

        let stack = NSStackView(views: [capsule, badge])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        // Critical: hidden views must collapse so priority can sit flush against
        // the trailing edge when the duration badge is hidden (and vice versa).
        stack.detachesHiddenViews = true
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(stack)

        let capsuleBottomY = AlwaysEmphasizedRowView.capsuleVerticalInset
        let trailingInset = AlwaysEmphasizedRowView.capsuleTrailingInset + AlwaysEmphasizedRowView.capsuleContentHPadding
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -capsuleBottomY),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -trailingInset
            ),
        ])

        bottomBorderBadgeStack = stack
        durationBadge = badge
        durationLabel = badge.label
        priorityCapsule = capsule

        updateTopBorderBadgeColors()
    }

    private static func priorityDotsFont() -> NSFont {
        // Monospaced so the dot string always occupies the same width regardless of level.
        .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    }

    /// Maps 1–5 priority to a calm tint (blue → green → yellow → orange → red).
    /// Alpha values are tuned to match the existing duration-label palette.
    private static func priorityTintColor(forLevel level: Int) -> NSColor {
        switch level {
        case 1: return NSColor.systemBlue.withAlphaComponent(0.75)
        case 2: return NSColor.systemGreen.withAlphaComponent(0.8)
        case 3: return NSColor.systemYellow.withAlphaComponent(0.8)
        case 4: return NSColor.systemOrange.withAlphaComponent(0.8)
        default: return NSColor.systemRed.withAlphaComponent(0.75)
        }
    }

    /// Builds the 5-character cumulative dot string for a given priority level.
    /// ●○○○○, ●●○○○, ●●●○○, ●●●●○, ●●●●●. Empty string for `nil`/out-of-range.
    private static func priorityDotsString(forLevel level: Int) -> String {
        let filled = max(0, min(5, level))
        return String(repeating: "●", count: filled) + String(repeating: "○", count: 5 - filled)
    }

    private static func priorityLabel(forLevel level: Int) -> String {
        switch level {
        case 1: return "Lowest"
        case 2: return "Low"
        case 3: return "Medium"
        case 4: return "High"
        default: return "Highest"
        }
    }

    private func configurePriority(_ priority: Int?) {
        ensureDurationLabel()
        guard let capsule = priorityCapsule else { return }
        guard let priority, (1...5).contains(priority) else {
            capsule.label.stringValue = ""
            capsule.isHidden = true
            capsule.toolTip = nil
            return
        }
        capsule.label.stringValue = Self.priorityDotsString(forLevel: priority)
        capsule.label.textColor = Self.priorityTintColor(forLevel: priority)
        capsule.isHidden = false
        capsule.toolTip = "Priority \(priority): \(Self.priorityLabel(forLevel: priority))"
        capsule.needsDisplay = true
    }

    private func ensureKeepAliveBadge() {
        guard keepAliveBadge == nil else { return }
        ensureTopBorderBadgeStack()
        let badge = TopBorderBadge(bareIcon: true)
        badge.label.isHidden = true
        badge.iconView.image = Self.cachedSymbolImage("shield.righthalf.filled")
        badge.iconView.contentTintColor = .systemCyan
        badge.iconView.isHidden = false
        badge.isHidden = true
        topBorderBadgeStack?.addArrangedSubview(badge)
        keepAliveBadge = badge
    }

    private func ensureFavoriteBadge() {
        ensureTopBorderBadgeStack()
        if favoriteBadge == nil {
            let badge = TopBorderBadge(bareIcon: true)
            badge.label.isHidden = true
            badge.iconView.image = Self.cachedSymbolImage("heart.fill")
            badge.iconView.contentTintColor = NSColor(resource: .primaryBrand)
            badge.iconView.isHidden = false
            badge.isHidden = true
            favoriteBadge = badge
        }
        if let badge = favoriteBadge, badge.superview !== topBorderBadgeStack {
            topBorderBadgeStack?.addArrangedSubview(badge)
        }
    }

    private func ensurePinnedBadge() {
        ensureTopBorderBadgeStack()
        if pinnedBadge == nil {
            let badge = TopBorderBadge(bareIcon: true)
            badge.label.isHidden = true
            badge.iconView.image = Self.cachedSymbolImage("pin.fill")
            badge.iconView.contentTintColor = NSColor(resource: .primaryBrand)
            badge.iconView.isHidden = false
            badge.isHidden = true
            pinnedBadge = badge
        }
        if let badge = pinnedBadge, badge.superview !== topBorderBadgeStack {
            topBorderBadgeStack?.addArrangedSubview(badge)
        }
    }

    private func ensureJiraSyncBadge() {
        ensureTopBorderBadgeStack()
        if jiraSyncBadge == nil {
            let badge = TopBorderBadge(bareIcon: true)
            badge.label.isHidden = true
            badge.iconView.image = Self.jiraBadgeIconImage()
            // Brand asset — do NOT set contentTintColor or the colored mark
            // would render as a monochrome silhouette.
            badge.iconView.contentTintColor = nil
            badge.iconView.isHidden = false
            badge.isHidden = true
            jiraSyncBadge = badge
        }
        if let badge = jiraSyncBadge, badge.superview !== topBorderBadgeStack {
            topBorderBadgeStack?.addArrangedSubview(badge)
        }
    }

    private func updateTopBorderBadgeOrder() {
        guard let stack = topBorderBadgeStack else { return }

        let trailingBadges = [favoriteBadge, pinnedBadge, jiraSyncBadge].compactMap { badge -> TopBorderBadge? in
            guard let badge, badge.superview === stack else { return nil }
            return badge
        }
        guard !trailingBadges.isEmpty else { return }

        for badge in trailingBadges {
            stack.removeArrangedSubview(badge)
            badge.removeFromSuperview()
        }
        for badge in trailingBadges {
            stack.addArrangedSubview(badge)
        }
    }

    private func updateTopBorderBadgeColors() {
        let rowSelected = (superview as? NSTableRowView)?.isSelected ?? false
        let completion = hasUnreadCompletion && !rowSelected
        let waiting = hasWaitingForInput && !hasUnreadCompletion && !rowSelected
        durationBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        // Re-apply elapsed-time tint after updateColors resets label to secondaryLabelColor.
        if let since = currentDurationSince {
            let elapsed = max(0, Int(Date().timeIntervalSince(since)))
            durationLabel?.textColor = Self.durationLabelColor(elapsed: elapsed)
        }
        claudeRateLimitBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        codexRateLimitBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        keepAliveBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        favoriteBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        pinnedBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        jiraSyncBadge?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        priorityCapsule?.updateColors(isRowSelected: rowSelected, hasCompletionHighlight: completion, hasWaitingHighlight: waiting, appearance: effectiveAppearance)
        // Pin/favorite icons: primary brand by default, white when selected.
        if let favorite = favoriteBadge {
            favorite.iconView.contentTintColor = rowSelected ? .white : NSColor(resource: .primaryBrand)
        }
        if let pin = pinnedBadge {
            pin.iconView.contentTintColor = rowSelected ? .white : NSColor(resource: .textSecondary)
        }
        if let popout = popoutImageView {
            popout.contentTintColor = .systemPurple
        }
    }


    private func configureDuration(since: Date?) {
        ensureDurationLabel()
        currentDurationSince = since
        if let since {
            refreshDurationText(since: since)
            durationLabel?.isHidden = false
            durationBadge?.isHidden = false
            durationBadge?.toolTip = "Busy duration"
            startDurationTimer()
        } else {
            durationLabel?.stringValue = ""
            durationLabel?.isHidden = true
            durationBadge?.isHidden = true
            durationBadge?.toolTip = nil
            stopDurationTimer()
        }
    }

    private func refreshDurationText(since: Date) {
        let elapsed = max(0, Int(Date().timeIntervalSince(since)))
        let text: String
        if elapsed < 60 {
            text = "<1m"
        } else if elapsed < 3600 {
            text = "\(elapsed / 60)m"
        } else if elapsed < 86400 {
            text = "\(elapsed / 3600)h"
        } else {
            text = "\(elapsed / 86400)d"
        }
        durationLabel?.stringValue = text
        durationLabel?.textColor = Self.durationLabelColor(elapsed: elapsed)
        durationBadge?.toolTip = "Busy for \(text)"
    }

    /// Returns a subtle tint for the duration label based on elapsed seconds.
    /// Light blue → light green → green → yellow → orange → red as activity ages.
    private static func durationLabelColor(elapsed: Int) -> NSColor {
        if elapsed < 900 {           // < 15 min — light blue
            return NSColor.systemCyan.withAlphaComponent(0.7)
        } else if elapsed < 7200 {   // < 2 hrs — light green
            return NSColor.systemMint.withAlphaComponent(0.75)
        } else if elapsed < 28800 {  // < 8 hrs — green
            return NSColor.systemGreen.withAlphaComponent(0.7)
        } else if elapsed < 86400 {  // < 1 day — yellow
            return NSColor.systemYellow.withAlphaComponent(0.65)
        } else if elapsed < 259200 { // < 3 days — orange
            return NSColor.systemOrange.withAlphaComponent(0.65)
        } else {                     // ≥ 3 days — red
            return NSColor.systemRed.withAlphaComponent(0.6)
        }
    }

    private func startDurationTimer() {
        guard durationTimer == nil else { return }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self, let since = self.currentDurationSince else { return }
            self.refreshDurationText(since: since)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    override func removeFromSuperview() {
        stopDurationTimer()
        super.removeFromSuperview()
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

    private func updateLeadingIconTint() {
        guard !isConfiguredAsMain else { return }
        if hasAllDead {
            imageView?.contentTintColor = .tertiaryLabelColor
        } else {
            let isRowSelected = (superview as? NSTableRowView)?.isSelected ?? false
            if isRowSelected {
                imageView?.contentTintColor = .controlAccentColor
            } else if hasWaitingForInput {
                imageView?.contentTintColor = .systemOrange
            } else if hasUnreadCompletion {
                imageView?.contentTintColor = .systemGreen
            } else {
                imageView?.contentTintColor = configuredSectionColor ?? NSColor(resource: .primaryBrand)
            }
        }
    }

    private func updateMainTextColorForSelection() {
        let isEmphasized = backgroundStyle == .emphasized
        if isConfiguredAsMain {
            textField?.textColor = isEmphasized ? .white : .labelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMainTextColorForSelection()
        updateTopBorderBadgeColors()
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
        } else if thread.isAnyBusy {
            statuses.append(thread.hasMagentBusy && !thread.hasAgentBusy ? "Setting up" : "Agent busy")
        } else if thread.hasUnreadAgentCompletion {
            statuses.append("Agent completed")
        }

        if thread.isKeepAlive {
            statuses.append("Keep Alive")
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
