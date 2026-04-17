import Cocoa
import MagentCore

private extension NSImage {
    /// Returns a copy of the template image filled with the given color.
    func tinted(with color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size)
            .fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

private final class StatusSummaryButton: NSButton {
    var contextMenuProvider: (() -> NSMenu?)?

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private enum ThreadStatusSummaryKind: String, CaseIterable {
    case busy
    case waiting
    case done
    case separateWindows
    case rateLimited
    case favorites

    func buttonTitle(for count: Int) -> String {
        switch self {
        case .busy:
            return "busy"
        case .waiting:
            return "waiting"
        case .done:
            return "done"
        case .separateWindows:
            return count == 1 ? "window" : "windows"
        case .rateLimited:
            return "rate-limited"
        case .favorites:
            return "favorites"
        }
    }

    var popoverTitle: String {
        switch self {
        case .busy:
            return "Busy Threads"
        case .waiting:
            return "Waiting For Input"
        case .done:
            return "Completed Threads"
        case .separateWindows:
            return "Threads In Separate Windows"
        case .rateLimited:
            return "Rate-Limited Threads"
        case .favorites:
            return "Favorite Threads"
        }
    }

    var symbolName: String {
        switch self {
        case .busy:
            return "circle.dotted"
        case .waiting:
            return "exclamationmark.bubble"
        case .done:
            return "checkmark.circle.fill"
        case .separateWindows:
            return "macwindow.on.rectangle"
        case .rateLimited:
            return "hourglass"
        case .favorites:
            return "heart.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .busy:
            return .systemBlue
        case .waiting:
            return .systemYellow
        case .done:
            return .systemGreen
        case .separateWindows:
            return .systemPurple
        case .rateLimited:
            return .systemRed
        case .favorites:
            return NSColor(resource: .primaryBrand)
        }
    }

    func matches(_ thread: MagentThread) -> Bool {
        switch self {
        case .busy:
            return thread.isAnyBusy
        case .waiting:
            return thread.hasWaitingForInput
        case .done:
            return thread.hasUnreadAgentCompletion
        case .separateWindows:
            return PopoutWindowManager.shared.isThreadPoppedOut(thread.id)
        case .rateLimited:
            return thread.isBlockedByRateLimit
        case .favorites:
            return thread.isFavorite
        }
    }

    var usesPersistentAddedAt: Bool {
        self == .done || self == .favorites
    }

    var showsInStatusSummaryStack: Bool {
        self != .favorites
    }
}

private struct ThreadStatusSummaryDescriptor: Equatable {
    let kind: ThreadStatusSummaryKind
    let count: Int
}

private struct ThreadStatusPopoverEntry {
    let thread: MagentThread
    let addedAt: Date
    /// For rate-limited entries: true when all markers are propagated (not directly detected).
    var isPropagatedOnly: Bool = false
}

private struct ThreadStatusPopoverRowTrailingAction {
    let symbolName: String
    let tintColor: NSColor
    let tooltip: String
}

private struct ThreadStatusPopoverFooterAction {
    let title: String
    let action: () -> Void
}

private final class ThreadStatusPopoverRowView: NSView {
    private let thread: MagentThread
    private let addedAt: Date
    private let projectName: String
    private let isPropagatedOnly: Bool
    private let onSelect: (UUID) -> Void
    private let iconTintColor: NSColor?
    private let trailingAction: ThreadStatusPopoverRowTrailingAction?
    private let onTrailingAction: ((UUID) -> Void)?
    private weak var trailingActionButton: NSButton?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateLayerColors()
        }
    }

    init(
        thread: MagentThread,
        addedAt: Date,
        projectName: String,
        isPropagatedOnly: Bool = false,
        iconTintColor: NSColor? = nil,
        trailingAction: ThreadStatusPopoverRowTrailingAction? = nil,
        onTrailingAction: ((UUID) -> Void)? = nil,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.thread = thread
        self.addedAt = addedAt
        self.projectName = projectName
        self.isPropagatedOnly = isPropagatedOnly
        self.iconTintColor = iconTintColor
        self.trailingAction = trailingAction
        self.onTrailingAction = onTrailingAction
        self.onSelect = onSelect
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let trailingActionButton {
            let buttonPoint = trailingActionButton.convert(point, from: self)
            if trailingActionButton.bounds.contains(buttonPoint) {
                return
            }
        }
        onSelect(thread.id)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        updateLayerColors()
    }

    private func setupViews() {
        wantsLayer = true
        updateLayerColors()

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: thread.threadIcon.symbolName,
            accessibilityDescription: thread.threadIcon.accessibilityDescription
        )
        iconView.contentTintColor = iconTintColor ?? NSColor(resource: .textSecondary)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleText: String
        if let description = thread.taskDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            titleText = description
        } else {
            titleText = thread.name
        }
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor(resource: .textPrimary)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        textStack.addArrangedSubview(titleLabel)

        let worktreeName = (thread.worktreePath as NSString).lastPathComponent
        let branchName = thread.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranchName = branchName.isEmpty ? thread.name : branchName
        var branchWorktreeSegments = [resolvedBranchName]
        if resolvedBranchName != worktreeName {
            branchWorktreeSegments.append(worktreeName)
        }
        let branchLabel = NSTextField(labelWithString: branchWorktreeSegments.joined(separator: " · "))
        branchLabel.font = .systemFont(ofSize: 10)
        branchLabel.textColor = NSColor(resource: .textSecondary)
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(branchLabel)

        let addedText = Self.relativeTimeString(from: addedAt)
        var metaSegments = [projectName, addedText]
        if isPropagatedOnly { metaSegments.append("propagated") }
        let metaLabel = NSTextField(labelWithString: metaSegments.joined(separator: " · "))
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = NSColor(resource: .textSecondary)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        textStack.addArrangedSubview(metaLabel)

        addSubview(iconView)
        addSubview(textStack)

        var constraints = [
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            iconView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ]

        if let trailingAction {
            let button = NSButton()
            button.isBordered = false
            button.bezelStyle = .inline
            button.image = NSImage(
                systemSymbolName: trailingAction.symbolName,
                accessibilityDescription: trailingAction.tooltip
            )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            button.contentTintColor = trailingAction.tintColor
            button.toolTip = trailingAction.tooltip
            button.target = self
            button.action = #selector(trailingActionTapped)
            button.focusRingType = .none
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            trailingActionButton = button

            constraints.append(contentsOf: [
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
                textStack.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            ])
        } else {
            constraints.append(
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
            )
        }

        NSLayoutConstraint.activate(constraints)
    }

    @objc private func trailingActionTapped() {
        onTrailingAction?(thread.id)
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 8
            layer?.backgroundColor = isHovered
                ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
                : NSColor.clear.cgColor
        }
    }

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

private final class ThreadStatusPopoverSeparatorView: NSView {
    private static let busyAnimationKey = "status-popover-busy-separator-shift"
    private let status: ThreadStatusSummaryKind
    private let lineLayer = CALayer()
    private var busyGradientLayer: CAGradientLayer?

    init(status: ThreadStatusSummaryKind) {
        self.status = status
        super.init(frame: .zero)
        wantsLayer = true
        lineLayer.cornerRadius = 0.5
        layer?.addSublayer(lineLayer)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        lineLayer.frame = bounds
        busyGradientLayer?.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        if status == .busy, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            configureBusyGradient()
            lineLayer.isHidden = true
        } else {
            busyGradientLayer?.removeFromSuperlayer()
            busyGradientLayer = nil
            lineLayer.isHidden = false
            effectiveAppearance.performAsCurrentDrawingAppearance {
                lineLayer.backgroundColor = self.resolvedStaticColor().cgColor
            }
        }
    }

    private func resolvedStaticColor() -> NSColor {
        switch status {
        case .waiting:
            return .systemOrange.withAlphaComponent(0.5)
        case .done:
            return .systemGreen.withAlphaComponent(0.5)
        case .separateWindows:
            let subtlePurple = NSColor.systemPurple.blended(withFraction: 0.35, of: .secondaryLabelColor)
                ?? NSColor.systemPurple
            return subtlePurple.withAlphaComponent(0.28)
        case .rateLimited:
            return .systemRed.withAlphaComponent(0.5)
        case .busy, .favorites:
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.08)
        }
    }

    private func configureBusyGradient() {
        let gradientLayer: CAGradientLayer
        if let existing = busyGradientLayer {
            gradientLayer = existing
        } else {
            let created = CAGradientLayer()
            created.startPoint = CGPoint(x: 0, y: 0.5)
            created.endPoint = CGPoint(x: 1, y: 0.5)
            created.cornerRadius = 0.5
            layer?.addSublayer(created)
            busyGradientLayer = created
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
            let isDark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let dimColor = isDark
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.08)
            gradientLayer.colors = [
                dimColor.cgColor,
                brightColor.withAlphaComponent(0.45).cgColor,
                brightColor.cgColor,
                brightColor.withAlphaComponent(0.45).cgColor,
                dimColor.cgColor,
            ]
        }
        gradientLayer.locations = [0.0, 0.35, 0.5, 0.65, 1.0]
        gradientLayer.frame = bounds.insetBy(dx: -bounds.width, dy: 0)

        if gradientLayer.animation(forKey: Self.busyAnimationKey) == nil {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = -bounds.width / 2
            animation.toValue = bounds.width * 1.5
            animation.duration = 2.6
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            gradientLayer.add(animation, forKey: Self.busyAnimationKey)
        }
    }
}

private final class ThreadStatusPopoverViewController: NSViewController {
    private static let popoverWidth: CGFloat = 510
    private static let contentWidth: CGFloat = popoverWidth - 16

    private let status: ThreadStatusSummaryKind
    private let onSelectThread: (UUID) -> Void
    private let trailingAction: ThreadStatusPopoverRowTrailingAction?
    private let onRowTrailingAction: ((UUID) -> Void)?
    private let onMarkAllDoneAsRead: (() -> Void)?
    private let footerAction: ThreadStatusPopoverFooterAction?
    private let limitReachedMessage: String?
    private let containerStack = NSStackView()
    private var entries: [ThreadStatusPopoverEntry]

    init(
        status: ThreadStatusSummaryKind,
        entries: [ThreadStatusPopoverEntry],
        trailingAction: ThreadStatusPopoverRowTrailingAction? = nil,
        onRowTrailingAction: ((UUID) -> Void)? = nil,
        onMarkAllDoneAsRead: (() -> Void)? = nil,
        footerAction: ThreadStatusPopoverFooterAction? = nil,
        limitReachedMessage: String? = nil,
        onSelectThread: @escaping (UUID) -> Void
    ) {
        self.status = status
        self.entries = entries
        self.trailingAction = trailingAction
        self.onRowTrailingAction = onRowTrailingAction
        self.onMarkAllDoneAsRead = onMarkAllDoneAsRead
        self.footerAction = footerAction
        self.limitReachedMessage = limitReachedMessage
        self.onSelectThread = onSelectThread
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 10))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 0
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerStack)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            containerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            containerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            containerStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            view.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
        ])

        rebuild()
    }

    func update(entries: [ThreadStatusPopoverEntry]) {
        self.entries = entries
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        containerStack.arrangedSubviews.forEach { subview in
            containerStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let headerLabel = NSTextField(labelWithString: status.popoverTitle)
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textPrimary)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: headerRow.topAnchor, constant: 2),
            headerLabel.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 4),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerRow.trailingAnchor, constant: -4),
            headerLabel.bottomAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -8),
        ])
        containerStack.addArrangedSubview(headerRow)

        let headerSeparator = ThreadStatusPopoverSeparatorView(status: status)
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addArrangedSubview(headerSeparator)
        NSLayoutConstraint.activate([
            headerSeparator.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            headerSeparator.heightAnchor.constraint(equalToConstant: 1),
            headerRow.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        if let limitReachedMessage {
            let infoRow = NSView()
            infoRow.translatesAutoresizingMaskIntoConstraints = false

            let heart = NSImageView()
            heart.translatesAutoresizingMaskIntoConstraints = false
            heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            heart.contentTintColor = NSColor(resource: .primaryBrand)

            let infoLabel = NSTextField(labelWithString: limitReachedMessage)
            infoLabel.translatesAutoresizingMaskIntoConstraints = false
            infoLabel.font = .systemFont(ofSize: 10)
            infoLabel.textColor = NSColor(resource: .textSecondary)
            infoLabel.lineBreakMode = .byWordWrapping
            infoLabel.maximumNumberOfLines = 2

            infoRow.addSubview(heart)
            infoRow.addSubview(infoLabel)
            containerStack.addArrangedSubview(infoRow)
            NSLayoutConstraint.activate([
                infoRow.widthAnchor.constraint(equalToConstant: Self.contentWidth),
                heart.leadingAnchor.constraint(equalTo: infoRow.leadingAnchor, constant: 4),
                heart.topAnchor.constraint(equalTo: infoRow.topAnchor, constant: 8),
                heart.widthAnchor.constraint(equalToConstant: 12),
                heart.heightAnchor.constraint(equalToConstant: 12),
                infoLabel.leadingAnchor.constraint(equalTo: heart.trailingAnchor, constant: 6),
                infoLabel.trailingAnchor.constraint(equalTo: infoRow.trailingAnchor, constant: -4),
                infoLabel.topAnchor.constraint(equalTo: infoRow.topAnchor, constant: 7),
                infoLabel.bottomAnchor.constraint(equalTo: infoRow.bottomAnchor, constant: -6),
            ])

            let infoSeparator = ThreadStatusPopoverSeparatorView(status: status)
            infoSeparator.translatesAutoresizingMaskIntoConstraints = false
            containerStack.addArrangedSubview(infoSeparator)
            NSLayoutConstraint.activate([
                infoSeparator.widthAnchor.constraint(equalToConstant: Self.contentWidth),
                infoSeparator.heightAnchor.constraint(equalToConstant: 1),
            ])
        }

        let settings = PersistenceService.shared.loadSettings()
        let projectsById = Dictionary(uniqueKeysWithValues: settings.projects.map { ($0.id, $0.name) })

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                let separator = ThreadStatusPopoverSeparatorView(status: status)
                separator.translatesAutoresizingMaskIntoConstraints = false
                containerStack.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalToConstant: Self.contentWidth),
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
            }

            let row = ThreadStatusPopoverRowView(
                thread: entry.thread,
                addedAt: entry.addedAt,
                projectName: projectsById[entry.thread.projectId] ?? "Unknown Project",
                isPropagatedOnly: entry.isPropagatedOnly,
                iconTintColor: sectionColor(for: entry.thread, settings: settings),
                trailingAction: trailingAction,
                onTrailingAction: onRowTrailingAction,
                onSelect: onSelectThread
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            containerStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            ])
        }

        let resolvedFooterAction: ThreadStatusPopoverFooterAction?
        if status == .done, !entries.isEmpty, onMarkAllDoneAsRead != nil {
            resolvedFooterAction = ThreadStatusPopoverFooterAction(
                title: String(localized: .ThreadStrings.threadMarkAllAsRead),
                action: { [weak self] in self?.onMarkAllDoneAsRead?() }
            )
        } else if !entries.isEmpty {
            resolvedFooterAction = footerAction
        } else {
            resolvedFooterAction = nil
        }

        if let resolvedFooterAction {
            let separator = ThreadStatusPopoverSeparatorView(status: status)
            separator.translatesAutoresizingMaskIntoConstraints = false
            containerStack.addArrangedSubview(separator)
            NSLayoutConstraint.activate([
                separator.widthAnchor.constraint(equalToConstant: Self.contentWidth),
                separator.heightAnchor.constraint(equalToConstant: 1),
            ])

            let footer = NSView()
            footer.translatesAutoresizingMaskIntoConstraints = false
            let markAllButton = NSButton(
                title: resolvedFooterAction.title,
                target: self,
                action: #selector(footerActionTapped)
            )
            markAllButton.bezelStyle = .inline
            markAllButton.isBordered = true
            markAllButton.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(markAllButton)
            containerStack.addArrangedSubview(footer)

            NSLayoutConstraint.activate([
                footer.widthAnchor.constraint(equalToConstant: Self.contentWidth),
                markAllButton.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
                markAllButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
                markAllButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -6),
            ])
        }

        view.layoutSubtreeIfNeeded()
        let height = containerStack.fittingSize.height + 16
        preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
        view.setFrameSize(NSSize(width: Self.popoverWidth, height: height))
    }

    @objc private func footerActionTapped() {
        if status == .done {
            onMarkAllDoneAsRead?()
        } else {
            footerAction?.action()
        }
    }

    private func sectionColor(for thread: MagentThread, settings: AppSettings) -> NSColor? {
        guard settings.shouldUseThreadSections(for: thread.projectId) else { return nil }
        let sections = settings.sections(for: thread.projectId)
        let effectiveSectionId = ThreadManager.shared.effectiveSectionId(for: thread, settings: settings)
        return sections.first(where: { $0.id == effectiveSectionId })?.color
    }
}

// MARK: - Session Cleanup Popover

private final class SessionCleanupPopoverViewController: NSViewController {
    private static let popoverWidth: CGFloat = 260

    private let totalSessions: Int
    private let liveSessions: Int
    private let protectedSessions: Int
    private let idleSessions: Int
    private let zombieCount: Int
    private let zombieParentPid: Int?
    private let isRecoveringTmux: Bool
    private let onCleanup: () -> Void
    private let onRestartTmux: () -> Void

    init(
        totalSessions: Int,
        liveSessions: Int,
        protectedSessions: Int,
        idleSessions: Int,
        zombieCount: Int,
        zombieParentPid: Int?,
        isRecoveringTmux: Bool,
        onCleanup: @escaping () -> Void,
        onRestartTmux: @escaping () -> Void
    ) {
        self.totalSessions = totalSessions
        self.liveSessions = liveSessions
        self.protectedSessions = protectedSessions
        self.idleSessions = idleSessions
        self.zombieCount = zombieCount
        self.zombieParentPid = zombieParentPid
        self.isRecoveringTmux = isRecoveringTmux
        self.onCleanup = onCleanup
        self.onRestartTmux = onRestartTmux
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.popoverWidth, height: 10))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // Header
        let headerLabel = NSTextField(labelWithString: "Active Sessions")
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = NSColor(resource: .textPrimary)
        stack.addArrangedSubview(headerLabel)

        // Session breakdown
        let deadCount = totalSessions - liveSessions
        let liveLabel = NSTextField(labelWithString: "\(liveSessions) live · \(deadCount) suspended · \(totalSessions) total")
        liveLabel.font = .systemFont(ofSize: 11)
        liveLabel.textColor = NSColor(resource: .textSecondary)
        stack.addArrangedSubview(liveLabel)

        if protectedSessions > 0 {
            let protectedLabel = NSTextField(labelWithString: "\(protectedSessions) protected (busy/waiting/shielded/pinned/recently active)")
            protectedLabel.font = .systemFont(ofSize: 11)
            protectedLabel.textColor = NSColor(resource: .textSecondary)
            stack.addArrangedSubview(protectedLabel)
        }

        if zombieCount > 0 || isRecoveringTmux {
            let zombieText: String
            if isRecoveringTmux {
                zombieText = "tmux recovery in progress"
            } else if let zombieParentPid {
                zombieText = "\(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es") on parent \(zombieParentPid)"
            } else {
                zombieText = "\(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es")"
            }
            let zombieLabel = NSTextField(labelWithString: zombieText)
            zombieLabel.font = .systemFont(ofSize: 11)
            zombieLabel.textColor = zombieCount >= 200 ? .systemRed : .systemOrange
            stack.addArrangedSubview(zombieLabel)
        }

        // Cleanup button
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)

        let cleanupButton = NSButton()
        cleanupButton.bezelStyle = .inline
        cleanupButton.isBordered = true
        cleanupButton.target = self
        cleanupButton.action = #selector(cleanupTapped)
        cleanupButton.translatesAutoresizingMaskIntoConstraints = false

        if idleSessions > 0 {
            cleanupButton.title = "Close \(idleSessions) idle session\(idleSessions == 1 ? "" : "s")"
            cleanupButton.isEnabled = true
        } else {
            cleanupButton.title = "All sessions are busy"
            cleanupButton.isEnabled = false
        }

        stack.addArrangedSubview(cleanupButton)

        let restartButton = NSButton()
        restartButton.bezelStyle = .inline
        restartButton.isBordered = true
        restartButton.target = self
        restartButton.action = #selector(restartTmuxTapped)
        restartButton.translatesAutoresizingMaskIntoConstraints = false
        if isRecoveringTmux {
            restartButton.title = "Restarting tmux…"
            restartButton.isEnabled = false
        } else if zombieCount > 0 {
            restartButton.title = "Restart tmux + Recover"
            restartButton.isEnabled = true
        } else {
            restartButton.title = "Restart tmux + Recover"
            restartButton.isEnabled = true
        }

        stack.addArrangedSubview(restartButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.widthAnchor.constraint(equalToConstant: Self.popoverWidth),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 24
        preferredContentSize = NSSize(width: Self.popoverWidth, height: height)
        view.setFrameSize(NSSize(width: Self.popoverWidth, height: height))
    }

    @objc private func cleanupTapped() {
        onCleanup()
    }

    @objc private func restartTmuxTapped() {
        onRestartTmux()
    }
}

/// Persistent status bar at the bottom of the main window showing aggregate thread
/// status counts, rate-limit summary, and sync info.
final class StatusBarView: NSView, NSPopoverDelegate {

    // MARK: - Constants

    static let barHeight: CGFloat = 30

    private static let horizontalPadding: CGFloat = 20

    // MARK: - Subviews

    private let threadStatusStack = NSStackView()
    private let sessionCountButton = NSButton()
    private let favoritesButton = NSButton()
    private let rateLimitLabel = NSTextField(labelWithString: "")
    private let syncStatusLabel = NSTextField(labelWithString: "")
    private let syncRefreshButton = NSButton()
    private let separator = NSBox()

    // MARK: - State

    private nonisolated(unsafe) var statusTimer: Timer?
    private var statusButtonsByKind: [ThreadStatusSummaryKind: NSButton] = [:]
    private var lastRenderedThreadSummaries: [ThreadStatusSummaryDescriptor] = []
    private var lastRenderedThreadCount: Int = -1
    private var lastRenderedFavoriteCount: Int = -1
    private var transientStatusThreadIds: [ThreadStatusSummaryKind: Set<UUID>] = [:]
    private var transientStatusAddedAt: [ThreadStatusSummaryKind: [UUID: Date]] = [:]
    private var activePopoverStatus: ThreadStatusSummaryKind?
    private var activePopover: NSPopover?
    private let doneStatusContextMenu = NSMenu(title: "Done")
    private var sessionCleanupPopover: NSPopover?
    private var lastRenderedSessionCount: Int = -1
    private var lastRenderedLiveSessionCount: Int = -1
    private var lastRenderedZombieCount: Int = -1
    private var lastRenderedTmuxRecoveryState = false

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTransientStatusTracking()
        setupViews()
        setupObservers()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        statusTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override func updateLayer() {
        super.updateLayer()
        updateLayerColors()
    }

    private func updateLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = self.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let bg: NSColor = isDark
                ? NSColor(resource: .surface)
                : NSColor(resource: .appBackground)
            layer?.backgroundColor = bg.cgColor
        }
    }

    // MARK: - Setup

    private func setupTransientStatusTracking() {
        for kind in ThreadStatusSummaryKind.allCases where !kind.usesPersistentAddedAt {
            transientStatusThreadIds[kind] = []
            transientStatusAddedAt[kind] = [:]
        }
    }

    private func setupViews() {
        wantsLayer = true
        updateLayerColors()

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        threadStatusStack.orientation = .horizontal
        threadStatusStack.alignment = .centerY
        threadStatusStack.spacing = 0
        threadStatusStack.translatesAutoresizingMaskIntoConstraints = false
        threadStatusStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        threadStatusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sessionCountButton.isBordered = false
        sessionCountButton.bezelStyle = .inline
        sessionCountButton.focusRingType = .none
        sessionCountButton.setButtonType(.momentaryChange)
        sessionCountButton.target = self
        sessionCountButton.action = #selector(sessionCountTapped)
        sessionCountButton.toolTip = "Active tmux sessions — click to manage"
        sessionCountButton.translatesAutoresizingMaskIntoConstraints = false
        updateSessionCountButton(total: 0, live: 0, zombieCount: 0, isRecoveringTmux: false)

        favoritesButton.isBordered = false
        favoritesButton.bezelStyle = .inline
        favoritesButton.focusRingType = .none
        favoritesButton.setButtonType(.momentaryChange)
        favoritesButton.target = self
        favoritesButton.action = #selector(favoritesTapped)
        favoritesButton.toolTip = "Favorite threads"
        favoritesButton.translatesAutoresizingMaskIntoConstraints = false
        favoritesButton.isHidden = true

        configureLabel(rateLimitLabel, size: 11)
        rateLimitLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        configureLabel(syncStatusLabel, size: 11)
        syncStatusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        syncRefreshButton.bezelStyle = .inline
        syncRefreshButton.isBordered = false
        syncRefreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh"
        )?.withSymbolConfiguration(symbolConfig)
        syncRefreshButton.contentTintColor = .tertiaryLabelColor
        syncRefreshButton.target = self
        syncRefreshButton.action = #selector(syncRefreshTapped)
        syncRefreshButton.toolTip = "Refresh PR and Jira statuses"
        syncRefreshButton.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [sessionCountButton, favoritesButton, threadStatusStack])
        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 12
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [rateLimitLabel, syncStatusLabel, syncRefreshButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 12
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),

            syncRefreshButton.widthAnchor.constraint(equalToConstant: 14),
            syncRefreshButton.heightAnchor.constraint(equalToConstant: 14),

            heightAnchor.constraint(equalToConstant: Self.barHeight),
        ])
    }

    private func configureLabel(_ label: NSTextField, size: CGFloat) {
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Observers

    private func setupObservers() {
        let nc = NotificationCenter.default
        let sel = #selector(handleStatusChange)

        nc.addObserver(self, selector: sel, name: .magentStatusSyncCompleted, object: nil)
        nc.addObserver(self, selector: sel, name: .magentGlobalRateLimitSummaryChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentCompletionDetected, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentRateLimitChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentBusySessionsChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentAgentWaitingForInput, object: nil)
        nc.addObserver(self, selector: sel, name: .magentThreadCreationFinished, object: nil)
        nc.addObserver(self, selector: sel, name: .magentSessionCleanupCompleted, object: nil)
        nc.addObserver(self, selector: sel, name: .magentDeadSessionsDetected, object: nil)
        nc.addObserver(self, selector: sel, name: .magentTmuxHealthChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentFavoritesChanged, object: nil)
        nc.addObserver(self, selector: sel, name: .magentThreadPoppedOut, object: nil)
        nc.addObserver(self, selector: sel, name: .magentThreadReturnedToMain, object: nil)

        statusTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    @objc private func handleStatusChange() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        updateFavoritesStatus()
        updateThreadStatus()
        updateSessionCount()
        updateRateLimitStatus()
        updateSyncStatus()
        rebuildRateLimitMenu()
        rebuildSyncMenu()
    }

    private func updateThreadStatus() {
        let threads = ThreadManager.shared.threads
        syncTransientStatusAddedAt(with: threads)

        let summaries = ThreadStatusSummaryKind.allCases
            .filter(\.showsInStatusSummaryStack)
            .compactMap { kind -> ThreadStatusSummaryDescriptor? in
            let count = threads.lazy.filter { kind.matches($0) }.count
            guard count > 0 else { return nil }
            return ThreadStatusSummaryDescriptor(kind: kind, count: count)
        }

        let shouldRebuild = summaries != lastRenderedThreadSummaries || threads.count != lastRenderedThreadCount
        let isStatusPopoverVisible = activePopover?.isShown == true
        let activeStatusStillPresent = activePopoverStatus.map { status in
            summaries.contains { $0.kind == status }
        } ?? false

        // Rebuilding the status-button stack replaces the anchor button view and
        // causes AppKit to dismiss an open popover. While any status popover is
        // visible, keep the stack stable and just refresh popover rows in place.
        if shouldRebuild, !isStatusPopoverVisible {
            rebuildThreadStatusSegments(summaries: summaries, totalCount: threads.count)
            lastRenderedThreadSummaries = summaries
            lastRenderedThreadCount = threads.count
        } else if shouldRebuild, isStatusPopoverVisible {
            refreshStatusButtonCountsInPlace(summaries: summaries)
            lastRenderedThreadSummaries = summaries
            lastRenderedThreadCount = threads.count

            // If the active status disappeared entirely (for example, "done"
            // was cleared via Mark All as Read), close the stale popover and
            // rebuild immediately so the status bar reflects the user action.
            if !activeStatusStillPresent {
                activePopover?.close()
                rebuildThreadStatusSegments(summaries: summaries, totalCount: threads.count)
            }
        }

        refreshActivePopover()
    }

    private func updateFavoritesStatus() {
        let count = ThreadManager.shared.favoriteThreadCount
        guard count != lastRenderedFavoriteCount else { return }
        lastRenderedFavoriteCount = count

        guard count > 0 else {
            favoritesButton.isHidden = true
            return
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        favoritesButton.image = NSImage(
            systemSymbolName: "heart.fill",
            accessibilityDescription: "Favorites"
        )?.withSymbolConfiguration(symbolConfig)
        favoritesButton.imagePosition = .imageLeading
        favoritesButton.imageHugsTitle = true
        favoritesButton.contentTintColor = NSColor(resource: .primaryBrand)
        favoritesButton.attributedTitle = NSAttributedString(
            string: "\(count) favorite\(count == 1 ? "" : "s")",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(resource: .primaryBrand),
            ]
        )
        favoritesButton.setAccessibilityLabel("\(count) favorite thread\(count == 1 ? "" : "s")")
        favoritesButton.toolTip = "Favorite threads"
        favoritesButton.isHidden = false
    }

    private func rebuildThreadStatusSegments(summaries: [ThreadStatusSummaryDescriptor], totalCount: Int) {
        statusButtonsByKind.removeAll()
        threadStatusStack.arrangedSubviews.forEach { subview in
            threadStatusStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        guard !summaries.isEmpty else {
            threadStatusStack.addArrangedSubview(
                makeStaticStatusLabel(
                    text: "\(totalCount) thread\(totalCount == 1 ? "" : "s")",
                    color: .tertiaryLabelColor
                )
            )
            return
        }

        for (index, summary) in summaries.enumerated() {
            if index > 0 {
                threadStatusStack.addArrangedSubview(makeSeparatorLabel())
            }
            let button = makeStatusButton(for: summary)
            statusButtonsByKind[summary.kind] = button
            threadStatusStack.addArrangedSubview(button)
        }
    }

    private func makeStatusButton(for summary: ThreadStatusSummaryDescriptor) -> NSButton {
        let button = StatusSummaryButton()
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: summary.kind.symbolName,
            accessibilityDescription: summary.kind.buttonTitle(for: summary.count)
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        )
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = summary.kind.color
        button.target = self
        button.action = #selector(threadStatusTapped(_:))
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(summary.kind.rawValue)
        configureStatusButton(button, summary: summary)
        if summary.kind == .done {
            button.contextMenuProvider = { [weak self] in
                self?.buildDoneContextMenu()
            }
        }
        return button
    }

    private func configureStatusButton(_ button: NSButton, summary: ThreadStatusSummaryDescriptor) {
        let statusTitle = summary.kind.buttonTitle(for: summary.count)
        button.attributedTitle = NSAttributedString(
            string: "\(summary.count) \(statusTitle)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: summary.kind.color,
            ]
        )
        button.setAccessibilityLabel("\(summary.count) \(statusTitle)")
    }

    private func refreshStatusButtonCountsInPlace(summaries: [ThreadStatusSummaryDescriptor]) {
        let summariesByKind = Dictionary(uniqueKeysWithValues: summaries.map { ($0.kind, $0) })
        for (kind, button) in statusButtonsByKind {
            guard let summary = summariesByKind[kind] else { continue }
            configureStatusButton(button, summary: summary)
        }
    }

    private func makeSeparatorLabel() -> NSTextField {
        makeStaticStatusLabel(text: "  ·  ", color: .tertiaryLabelColor)
    }

    private func makeStaticStatusLabel(text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    private func syncTransientStatusAddedAt(with threads: [MagentThread]) {
        let now = Date()
        for kind in ThreadStatusSummaryKind.allCases where !kind.usesPersistentAddedAt {
            let currentIds = Set(threads.filter { kind.matches($0) }.map(\.id))
            let previousIds = transientStatusThreadIds[kind] ?? []
            var addedAtById = transientStatusAddedAt[kind] ?? [:]

            for addedId in currentIds.subtracting(previousIds) {
                addedAtById[addedId] = now
            }
            for removedId in previousIds.subtracting(currentIds) {
                addedAtById.removeValue(forKey: removedId)
            }

            transientStatusThreadIds[kind] = currentIds
            transientStatusAddedAt[kind] = addedAtById
        }
    }

    private func popoverEntries(for status: ThreadStatusSummaryKind) -> [ThreadStatusPopoverEntry] {
        if status == .favorites {
            return ThreadManager.shared.favoriteThreadsChronological.map { thread in
                ThreadStatusPopoverEntry(
                    thread: thread,
                    addedAt: thread.favoritedAt ?? thread.createdAt
                )
            }
        }

        let threads = ThreadManager.shared.threads.filter { status.matches($0) }
        guard !threads.isEmpty else { return [] }

        let newestFirst: [ThreadStatusPopoverEntry]
        if status.usesPersistentAddedAt {
            newestFirst = threads.compactMap { thread in
                guard let addedAt = thread.lastAgentCompletionAt else { return nil }
                return ThreadStatusPopoverEntry(thread: thread, addedAt: addedAt)
            }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.thread.createdAt > rhs.thread.createdAt
            }
        } else {
            let addedAtById = transientStatusAddedAt[status] ?? [:]
            newestFirst = threads.map { thread in
                ThreadStatusPopoverEntry(
                    thread: thread,
                    addedAt: addedAtById[thread.id] ?? thread.createdAt,
                    isPropagatedOnly: status == .rateLimited && thread.isRateLimitPropagatedOnly
                )
            }
            .sorted { lhs, rhs in
                // For rate-limited threads, prioritize source-detected over propagated
                if status == .rateLimited {
                    if lhs.isPropagatedOnly != rhs.isPropagatedOnly { return !lhs.isPropagatedOnly }
                }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
                return lhs.thread.createdAt > rhs.thread.createdAt
            }
        }

        let displayedEntries: [ThreadStatusPopoverEntry]
        if status == .separateWindows {
            displayedEntries = newestFirst
        } else {
            displayedEntries = Array(newestFirst.prefix(3))
        }
        return Array(displayedEntries.reversed())
    }

    private func refreshActivePopover() {
        guard let status = activePopoverStatus,
              let popover = activePopover,
              popover.isShown else { return }

        let entries = popoverEntries(for: status)
        guard !entries.isEmpty else {
            popover.close()
            return
        }

        if let content = popover.contentViewController as? ThreadStatusPopoverViewController {
            content.update(entries: entries)
        }
    }

    private func updateRateLimitStatus() {
        let entries = ThreadManager.shared.globalRateLimitEntries()
        guard !entries.isEmpty else {
            rateLimitLabel.attributedStringValue = NSAttributedString()
            rateLimitLabel.stringValue = ""
            rateLimitLabel.toolTip = nil
            rateLimitLabel.isHidden = true
            return
        }

        let result = NSMutableAttributedString()
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemRed,
            .font: rateLimitLabel.font ?? NSFont.systemFont(ofSize: 11),
        ]

        result.append(NSAttributedString(string: "Rate limits: ", attributes: textAttrs))

        for (index, entry) in entries.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: textAttrs))
            }

            // Inline agent glyph
            let iconImage: NSImage? = switch entry.agent {
            case .claude, .custom: NSImage(resource: .claudeIcon)
            case .codex: NSImage(resource: .codexIcon)
            }
            if let icon = iconImage {
                let attachment = NSTextAttachment()
                let iconSize: CGFloat = 12
                icon.isTemplate = true
                let tintedIcon = icon.tinted(with: .systemRed)
                attachment.image = tintedIcon
                // Vertically center the icon relative to the text baseline
                let font = rateLimitLabel.font ?? NSFont.systemFont(ofSize: 11)
                let yOffset = (font.capHeight - iconSize) / 2
                attachment.bounds = CGRect(x: 0, y: yOffset, width: iconSize, height: iconSize)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: textAttrs))
            }

            result.append(NSAttributedString(
                string: "\(entry.agent.displayName): \(entry.countdown)",
                attributes: textAttrs
            ))
        }

        rateLimitLabel.attributedStringValue = result
        rateLimitLabel.toolTip = ThreadManager.shared.globalRateLimitSummaryText()
        rateLimitLabel.isHidden = false
    }

    private var baseSyncTooltip: String {
        let hasJira = PersistenceService.shared.loadSettings().projects.contains(where: \.jiraSyncEnabled)
        if hasJira {
            return "Periodically syncs PR status (GitHub) and Jira ticket info for all active threads. Right-click to refresh manually."
        } else {
            return "Periodically syncs PR status (GitHub) for all active threads. Right-click to refresh manually."
        }
    }

    private func syncTooltip(for threadManager: ThreadManager) -> String {
        guard threadManager.lastStatusSyncFailed,
              let failureSummary = threadManager.lastStatusSyncFailureSummary,
              !failureSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return baseSyncTooltip
        }

        return "\(baseSyncTooltip)\n\nLast failure:\n\(failureSummary)"
    }

    private func updateSyncStatus() {
        let tm = ThreadManager.shared

        guard let lastSync = tm.lastStatusSyncAt else {
            if !tm.threads.isEmpty {
                syncStatusLabel.stringValue = "Syncing…"
                syncStatusLabel.textColor = .tertiaryLabelColor
                syncStatusLabel.toolTip = syncTooltip(for: tm)
                syncRefreshButton.isHidden = true
            } else {
                syncStatusLabel.stringValue = ""
                syncStatusLabel.toolTip = nil
                syncRefreshButton.isHidden = true
            }
            return
        }

        if tm.lastStatusSyncFailed {
            syncStatusLabel.stringValue = "Sync failed \(Self.relativeTimeString(from: lastSync))"
            syncStatusLabel.textColor = .systemRed
        } else {
            syncStatusLabel.stringValue = "Synced \(Self.relativeTimeString(from: lastSync))"
            syncStatusLabel.textColor = .tertiaryLabelColor
        }
        syncStatusLabel.toolTip = syncTooltip(for: tm)
        syncRefreshButton.isHidden = false
    }

    // MARK: - Session Count

    private func updateSessionCount() {
        let tm = ThreadManager.shared
        let total = tm.totalSessionCount
        let live = tm.liveSessionCount
        let zombieCount = tm.lastTmuxZombieSummary?.zombieCount ?? 0
        let isRecoveringTmux = tm.isRestartingTmuxForRecovery
        guard total != lastRenderedSessionCount
            || live != lastRenderedLiveSessionCount
            || zombieCount != lastRenderedZombieCount
            || isRecoveringTmux != lastRenderedTmuxRecoveryState else { return }
        lastRenderedSessionCount = total
        lastRenderedLiveSessionCount = live
        lastRenderedZombieCount = zombieCount
        lastRenderedTmuxRecoveryState = isRecoveringTmux
        updateSessionCountButton(total: total, live: live, zombieCount: zombieCount, isRecoveringTmux: isRecoveringTmux)
    }

    private func updateSessionCountButton(total: Int, live: Int, zombieCount: Int, isRecoveringTmux: Bool) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        sessionCountButton.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Sessions"
        )?.withSymbolConfiguration(symbolConfig)
        sessionCountButton.imagePosition = .imageLeading
        sessionCountButton.imageHugsTitle = true
        sessionCountButton.contentTintColor = zombieCount > 0 || isRecoveringTmux ? .systemOrange : .secondaryLabelColor

        let displayText = live < total ? "\(live)/\(total)" : "\(total)"
        let zombieSuffix = zombieCount > 0 ? " · z\(zombieCount)" : ""
        sessionCountButton.attributedTitle = NSAttributedString(
            string: displayText + zombieSuffix,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: zombieCount > 0 || isRecoveringTmux ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            ]
        )
        var accessibilityLabel = "\(live) live, \(total) total sessions"
        if zombieCount > 0 {
            accessibilityLabel += ", \(zombieCount) tmux defunct processes detected"
        }
        if isRecoveringTmux {
            accessibilityLabel += ", tmux recovery in progress"
        }
        sessionCountButton.setAccessibilityLabel(accessibilityLabel)
        if isRecoveringTmux {
            sessionCountButton.toolTip = "Active tmux sessions — tmux recovery in progress"
        } else if zombieCount > 0 {
            sessionCountButton.toolTip = "Active tmux sessions — \(zombieCount) defunct tmux child process\(zombieCount == 1 ? "" : "es") detected"
        } else {
            sessionCountButton.toolTip = "Active tmux sessions — click to manage"
        }
        sessionCountButton.isHidden = total == 0 && zombieCount == 0 && !isRecoveringTmux
    }

    @objc private func sessionCountTapped() {
        if sessionCleanupPopover?.isShown == true {
            sessionCleanupPopover?.close()
            return
        }

        let tm = ThreadManager.shared
        let total = tm.totalSessionCount
        let live = tm.liveSessionCount
        let protectedCount = tm.protectedSessionCount
        let idleCount = live - protectedCount
        let zombieSummary = tm.lastTmuxZombieSummary

        let vc = SessionCleanupPopoverViewController(
            totalSessions: total,
            liveSessions: live,
            protectedSessions: protectedCount,
            idleSessions: max(0, idleCount),
            zombieCount: zombieSummary?.zombieCount ?? 0,
            zombieParentPid: zombieSummary?.parentPid,
            isRecoveringTmux: tm.isRestartingTmuxForRecovery,
            onCleanup: { [weak self] in
                self?.sessionCleanupPopover?.close()
                self?.showCleanupConfirmation()
            },
            onRestartTmux: { [weak self] in
                self?.sessionCleanupPopover?.close()
                Task {
                    await ThreadManager.shared.restartTmuxAndRecoverSessions()
                }
            }
        )

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = vc

        sessionCleanupPopover = popover
        popover.show(relativeTo: sessionCountButton.bounds, of: sessionCountButton, preferredEdge: .maxY)
    }

    private func showCleanupConfirmation() {
        let candidates = ThreadManager.shared.collectCleanupCandidates()
        guard !candidates.isEmpty else {
            BannerManager.shared.show(message: "No idle sessions to clean up.", style: .info)
            return
        }

        // Group candidates by thread.
        var threadOrder: [UUID] = []
        var threadGroups: [UUID: (name: String, isEntire: Bool, tabs: [String])] = [:]
        for c in candidates {
            if threadGroups[c.threadId] == nil {
                threadOrder.append(c.threadId)
                threadGroups[c.threadId] = (name: c.threadName, isEntire: c.isEntireThread, tabs: [])
            }
            if !c.isEntireThread {
                let tabLabel = c.tabDisplayName ?? c.sessionName
                threadGroups[c.threadId]?.tabs.append(tabLabel)
            }
        }

        // Build summary lines.
        var lines: [String] = []
        for tid in threadOrder {
            guard let group = threadGroups[tid] else { continue }
            if group.isEntire {
                lines.append("• \(group.name) (all tabs)")
            } else {
                let tabList = group.tabs.joined(separator: ", ")
                lines.append("• \(group.name): \(tabList)")
            }
        }

        let alert = NSAlert()
        alert.messageText = "Close \(candidates.count) idle session\(candidates.count == 1 ? "" : "s")?"
        alert.informativeText = "The following sessions will be killed. They will be recreated on demand when you revisit the tab. Protected (shielded/pinned) sessions are excluded.\n\nConfigure in Settings → Threads."

        // Scrollable list of sessions.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: min(CGFloat(lines.count) * 18 + 8, 200)))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.string = lines.joined(separator: "\n")
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        alert.accessoryView = scrollView
        alert.addButton(withTitle: "Close Sessions")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        Task {
            let closed = await ThreadManager.shared.cleanupIdleSessions()
            await MainActor.run {
                if closed > 0 {
                    BannerManager.shared.show(
                        message: "Closed \(closed) idle session\(closed == 1 ? "" : "s").",
                        style: .info
                    )
                }
            }
        }
    }

    // MARK: - Context Menus

    private func rebuildRateLimitMenu() {
        let menu = NSMenu(title: "Rate Limits")
        menu.autoenablesItems = false

        for agent: AgentType in [.claude, .codex] {
            if agent == .codex { menu.addItem(.separator()) }
            let hasActive = ThreadManager.shared.hasActiveRateLimit(for: agent)
            let shortName = agent == .claude ? "Claude" : "Codex"

            let liftItem = NSMenuItem(title: "Lift \(shortName) Limit Now", action: #selector(liftRateLimit(_:)), keyEquivalent: "")
            liftItem.target = self
            liftItem.representedObject = agent.rawValue
            liftItem.isEnabled = hasActive
            menu.addItem(liftItem)

            let ignoreItem = NSMenuItem(title: "Lift + Ignore Current \(shortName) Messages", action: #selector(liftAndIgnoreRateLimit(_:)), keyEquivalent: "")
            ignoreItem.target = self
            ignoreItem.representedObject = agent.rawValue
            ignoreItem.isEnabled = hasActive
            menu.addItem(ignoreItem)
        }

        rateLimitLabel.menu = menu
    }

    private func rebuildSyncMenu() {
        let menu = NSMenu(title: "Sync")
        menu.autoenablesItems = false

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(syncRefreshTapped), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        if ThreadManager.shared.lastStatusSyncFailed,
           let failureSummary = ThreadManager.shared.lastStatusSyncFailureSummary {
            let lines = failureSummary
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !lines.isEmpty {
                menu.addItem(.separator())

                let headerItem = NSMenuItem(title: "Last Failure", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                menu.addItem(headerItem)

                for line in lines.prefix(6) {
                    let lineItem = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                    lineItem.isEnabled = false
                    menu.addItem(lineItem)
                }
            }
        }

        syncStatusLabel.menu = menu
    }

    // MARK: - Actions

    @objc private func threadStatusTapped(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let status = ThreadStatusSummaryKind(rawValue: rawValue) else { return }

        if activePopoverStatus == status, activePopover?.isShown == true {
            activePopover?.close()
            return
        }

        showPopover(for: status)
    }

    @objc private func favoritesTapped() {
        if activePopoverStatus == .favorites, activePopover?.isShown == true {
            activePopover?.close()
            return
        }
        showPopover(for: .favorites)
    }

    private func showPopover(for status: ThreadStatusSummaryKind) {
        let entries = popoverEntries(for: status)
        guard !entries.isEmpty else { return }
        let anchorButton: NSButton?
        if status == .favorites {
            anchorButton = favoritesButton
        } else {
            anchorButton = statusButtonsByKind[status]
        }
        guard let anchorButton else { return }

        activePopover?.close()

        let trailingAction: ThreadStatusPopoverRowTrailingAction?
        let onRowTrailingAction: ((UUID) -> Void)?
        let onMarkAllDoneAsRead: (() -> Void)?
        let footerAction: ThreadStatusPopoverFooterAction?
        let limitReachedMessage: String?
        switch status {
        case .done:
            trailingAction = ThreadStatusPopoverRowTrailingAction(
                symbolName: "checkmark.circle",
                tintColor: .systemGreen,
                tooltip: String(localized: .ThreadStrings.threadMarkAsRead)
            )
            onRowTrailingAction = { [weak self] threadId in self?.markDoneThreadAsRead(threadId) }
            onMarkAllDoneAsRead = { [weak self] in self?.markAllCompletedThreadsAsRead(nil) }
            footerAction = nil
            limitReachedMessage = nil
        case .favorites:
            trailingAction = ThreadStatusPopoverRowTrailingAction(
                symbolName: "heart.slash.circle",
                tintColor: NSColor.systemRed.withAlphaComponent(0.9),
                tooltip: "Remove from Favorites"
            )
            onRowTrailingAction = { [weak self] threadId in self?.removeFavoriteThread(threadId) }
            onMarkAllDoneAsRead = nil
            footerAction = nil
            if ThreadManager.shared.favoriteThreadCount >= ThreadManager.maxFavoriteThreadCount {
                limitReachedMessage = "Favorites limit reached (\(ThreadManager.maxFavoriteThreadCount)/\(ThreadManager.maxFavoriteThreadCount)). Remove one to add another."
            } else {
                limitReachedMessage = nil
            }
        case .separateWindows:
            trailingAction = ThreadStatusPopoverRowTrailingAction(
                symbolName: "xmark.circle",
                tintColor: NSColor.systemPurple.withAlphaComponent(0.9),
                tooltip: "Return to Main Window"
            )
            onRowTrailingAction = { [weak self] threadId in self?.returnPoppedOutThreadToMain(threadId) }
            onMarkAllDoneAsRead = nil
            footerAction = ThreadStatusPopoverFooterAction(
                title: "Close All Windows",
                action: { [weak self] in self?.returnAllPoppedOutThreadsToMain() }
            )
            limitReachedMessage = nil
        default:
            trailingAction = nil
            onRowTrailingAction = nil
            onMarkAllDoneAsRead = nil
            footerAction = nil
            limitReachedMessage = nil
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = ThreadStatusPopoverViewController(
            status: status,
            entries: entries,
            trailingAction: trailingAction,
            onRowTrailingAction: onRowTrailingAction,
            onMarkAllDoneAsRead: onMarkAllDoneAsRead,
            footerAction: footerAction,
            limitReachedMessage: limitReachedMessage,
            onSelectThread: { [weak self] threadId in
                self?.activePopover?.close()
                let sessionName = self?.navigationSessionName(for: status, threadId: threadId)
                self?.navigateToThread(
                    threadId: threadId,
                    sessionName: sessionName,
                    centerInSidebar: self?.shouldCenterSidebarOnNavigation(for: status) ?? false
                )
            }
        )

        activePopoverStatus = status
        activePopover = popover
        popover.show(relativeTo: anchorButton.bounds, of: anchorButton, preferredEdge: .maxY)
    }

    private func shouldCenterSidebarOnNavigation(for status: ThreadStatusSummaryKind) -> Bool {
        status == .favorites || status == .separateWindows
    }

    private func navigateToThread(threadId: UUID, sessionName: String?, centerInSidebar: Bool) {
        var userInfo: [String: Any] = [
            "threadId": threadId,
            "sessionName": sessionName as Any,
            "revealSidebarIfHidden": true,
        ]
        if centerInSidebar {
            userInfo["centerInSidebar"] = true
        }
        NotificationCenter.default.post(
            name: .magentNavigateToThread,
            object: self,
            userInfo: userInfo
        )
    }

    private func removeFavoriteThread(_ threadId: UUID) {
        _ = ThreadManager.shared.toggleThreadFavorite(threadId: threadId)
        refresh()
    }

    private func returnPoppedOutThreadToMain(_ threadId: UUID) {
        PopoutWindowManager.shared.returnThreadToMain(threadId)
        refresh()
    }

    private func returnAllPoppedOutThreadsToMain() {
        PopoutWindowManager.shared.returnAllThreadsToMain()
        refresh()
    }

    private func buildDoneContextMenu() -> NSMenu? {
        let hasUnreadDone = ThreadManager.shared.threads.contains { $0.hasUnreadAgentCompletion }
        guard hasUnreadDone else { return nil }

        doneStatusContextMenu.removeAllItems()
        doneStatusContextMenu.autoenablesItems = false
        let markAllItem = NSMenuItem(
            title: String(localized: .ThreadStrings.threadMarkAllAsRead),
            action: #selector(markAllCompletedThreadsAsRead(_:)),
            keyEquivalent: ""
        )
        markAllItem.target = self
        doneStatusContextMenu.addItem(markAllItem)
        return doneStatusContextMenu
    }

    private func markDoneThreadAsRead(_ threadId: UUID) {
        ThreadManager.shared.markThreadCompletionSeen(threadId: threadId)
        refresh()
    }

    @objc private func markAllCompletedThreadsAsRead(_ sender: Any?) {
        let changed = ThreadManager.shared.markAllThreadCompletionsSeen()
        guard changed > 0 else { return }
        refresh()
    }

    private func navigationSessionName(for status: ThreadStatusSummaryKind, threadId: UUID) -> String? {
        guard let thread = ThreadManager.shared.threads.first(where: { $0.id == threadId }) else { return nil }

        let orderedTerminalSessions = thread.tmuxSessionNames + thread.agentTmuxSessions.filter { !thread.tmuxSessionNames.contains($0) }

        switch status {
        case .busy:
            return orderedTerminalSessions.first {
                thread.busySessions.contains($0) || thread.magentBusySessions.contains($0)
            }
        case .waiting:
            return orderedTerminalSessions.first {
                thread.waitingForInputSessions.contains($0)
            }
        case .done:
            return nil
        case .separateWindows:
            return nil
        case .rateLimited:
            return orderedTerminalSessions.first {
                thread.rateLimitedSessions[$0] != nil
            }
        case .favorites:
            return nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            if popover === activePopover {
                activePopover = nil
                activePopoverStatus = nil
            }
            if popover === sessionCleanupPopover {
                sessionCleanupPopover = nil
            }
        } else {
            activePopover = nil
            activePopoverStatus = nil
            sessionCleanupPopover = nil
        }
    }

    @objc private func syncRefreshTapped() {
        ThreadManager.shared.forceRefreshStatuses()
        syncStatusLabel.stringValue = "Syncing…"
        syncStatusLabel.textColor = .tertiaryLabelColor
        syncRefreshButton.isHidden = true
    }

    @objc private func liftRateLimit(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }
        Task {
            _ = await ThreadManager.shared.liftRateLimitManually(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                BannerManager.shared.show(message: "\(shortName) rate limit lifted manually.", style: .info)
                refresh()
            }
        }
    }

    @objc private func liftAndIgnoreRateLimit(_ sender: NSMenuItem) {
        guard let rawAgent = sender.representedObject as? String,
              let agent = AgentType(rawValue: rawAgent) else { return }
        Task {
            let ignoredCount = await ThreadManager.shared.liftAndIgnoreCurrentRateLimitFingerprints(for: agent)
            await MainActor.run {
                let shortName = agent == .claude ? "Claude" : "Codex"
                let message: String
                if ignoredCount > 0 {
                    message = "\(shortName) limit lifted. Ignoring \(ignoredCount) current reset window\(ignoredCount == 1 ? "" : "s")."
                } else {
                    message = "\(shortName) limit lifted. No active reset windows found to ignore."
                }
                BannerManager.shared.show(message: message, style: .info)
                refresh()
            }
        }
    }

    // MARK: - Helpers

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}
