import Cocoa
import MagentCore

private final class ArchivingRowOverlayView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        }
    }
}

final class AlwaysEmphasizedRowView: NSTableRowView {
    private static let busyOpacitySweepAnimationKey = "busy-row-opacity-sweep"
    private static let busyBorderRotationAnimationKey = "busy-border-rotation"
    private static let busyMaskOverscanLeft: CGFloat = 96
    private static let busyMaskOverscanRight: CGFloat = 48
    static let capsuleLeadingInset: CGFloat = 12
    static let capsuleTrailingInset: CGFloat = 12
    static let capsuleVerticalInset: CGFloat = 8
    static let capsuleBorderWidth: CGFloat = 2
    /// Half the border width — the inset from capsule rect to the border's inner edge.
    static let capsuleBorderInset: CGFloat = capsuleBorderWidth / 2
    private static let capsuleCornerRadius: CGFloat = 8
    /// Horizontal content padding from capsule inner edge (inside the border).
    static let capsuleContentHPadding: CGFloat = 12
    /// Vertical content padding from capsule inner edge (inside the border).
    static let capsuleContentVPadding: CGFloat = 12
    private var busyOpacityMaskLayer: CAGradientLayer?
    private weak var maskedContentView: NSView?
    private var archivingOverlay: ArchivingRowOverlayView?
    private var signEmojiLabel: NSTextField?
    private var signEmojiTintColor: NSColor?
    /// Container layer for the rotating conic gradient border.
    private var busyBorderContainer: CALayer?

    /// Class-level store of animation start times keyed by an opaque phase key
    /// (typically the thread UUID). When a row view is recreated (e.g. structural
    /// reload), the new instance picks up the stored start time so the rotation
    /// resumes at the correct phase instead of jumping to 0.
    private static var sharedBorderAnimationStartTimes: [AnyHashable: CFTimeInterval] = [:]

    /// Opaque key that ties this row's border animation to the class-level phase
    /// store. Set from the data source (typically the thread ID) so the animation
    /// survives row view recreation.
    var busyBorderPhaseKey: AnyHashable? {
        didSet {
            guard busyBorderPhaseKey != oldValue else { return }
            // If we already have a running animation, migrate its start time
            // to the new key (or drop it if the key was cleared).
            if let oldKey = oldValue, busyBorderContainer != nil {
                let startTime = Self.sharedBorderAnimationStartTimes.removeValue(forKey: oldKey)
                if let newKey = busyBorderPhaseKey, let startTime {
                    Self.sharedBorderAnimationStartTimes[newKey] = startTime
                }
            }
        }
    }

    /// Resolved animation start time — prefers the shared store, falls back to 0.
    private var busyBorderAnimationStartTime: CFTimeInterval {
        get {
            guard let key = busyBorderPhaseKey else { return 0 }
            return Self.sharedBorderAnimationStartTimes[key] ?? 0
        }
        set {
            guard let key = busyBorderPhaseKey else { return }
            if newValue == 0 {
                Self.sharedBorderAnimationStartTimes.removeValue(forKey: key)
            } else {
                Self.sharedBorderAnimationStartTimes[key] = newValue
            }
        }
    }

    var showsCompletionHighlight = false {
        didSet { needsDisplay = true }
    }
    var showsWaitingHighlight = false {
        didSet { needsDisplay = true }
    }
    var showsSubtleBottomSeparator = false {
        didSet { needsDisplay = true }
    }
    var showsBusyShimmer = false {
        didSet {
            guard showsBusyShimmer != oldValue else { return }
            updateBusyShimmerAnimation()
        }
    }
    var showsArchivingOverlay = false {
        didSet { updateArchivingOverlay() }
    }

    /// The inset rect used for the capsule border/background.
    private var capsuleRect: NSRect {
        NSRect(
            x: bounds.minX + Self.capsuleLeadingInset,
            y: bounds.minY + Self.capsuleVerticalInset,
            width: bounds.width - Self.capsuleLeadingInset - Self.capsuleTrailingInset,
            height: bounds.height - Self.capsuleVerticalInset * 2
        )
    }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        focusRingType = .none
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    // With selectionHighlightStyle = .none, AppKit no longer triggers redraws
    // or backgroundStyle changes on child views automatically. Force both so
    // drawBackground renders our capsule and cells update their tints.
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            // Push backgroundStyle to child cell views so they can react to
            // selection changes (icon tint, badge colors, text color).
            let style: NSView.BackgroundStyle = isSelected ? .emphasized : .normal
            for case let cell as NSTableCellView in subviews {
                cell.backgroundStyle = style
            }
            updateSignEmojiSelectionColor()
            updateBusyBorderSelectionColors()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBusyShimmerAnimation()
        if window != nil, let spinner = archivingOverlay?.subviews.compactMap({ $0 as? NSStackView }).first?
            .views.first(where: { $0 is NSProgressIndicator }) as? NSProgressIndicator {
            spinner.startAnimation(nil)
        }
    }

    override func layout() {
        super.layout()
        if let busyOpacityMaskLayer,
           let maskedContentView,
           let contentLayer = maskedContentView.layer {
            busyOpacityMaskLayer.frame = busyMaskFrame(for: contentLayer.bounds)
        }
        layoutBusyBorderLayers()
    }

    private func drawCapsuleBorderAndFill(color: NSColor, fillOpacity: CGFloat = 0.1, borderOpacity: CGFloat = 1.0) {
        let fillPath = NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: Self.capsuleCornerRadius,
            yRadius: Self.capsuleCornerRadius
        )
        color.withAlphaComponent(fillOpacity).setFill()
        fillPath.fill()

        let insetRect = capsuleRect.insetBy(dx: Self.capsuleBorderWidth / 2, dy: Self.capsuleBorderWidth / 2)
        let borderPath = NSBezierPath(
            roundedRect: insetRect,
            xRadius: Self.capsuleCornerRadius,
            yRadius: Self.capsuleCornerRadius
        )
        borderPath.lineWidth = Self.capsuleBorderWidth
        color.withAlphaComponent(borderOpacity).setStroke()
        borderPath.stroke()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Selection drawing is done here (not in drawSelection) so we can use
        // selectionHighlightStyle = .none on the outline view to fully suppress
        // AppKit's own selection rect (which adds an unwanted border on right-click).
        if isSelected {
            drawCapsuleBorderAndFill(color: .controlAccentColor)
        } else if showsWaitingHighlight {
            drawCapsuleBorderAndFill(color: .systemOrange, fillOpacity: 0.06, borderOpacity: 0.5)
        } else if showsCompletionHighlight {
            drawCapsuleBorderAndFill(color: .systemGreen, fillOpacity: 0.06, borderOpacity: 0.5)
        } else {
            // Subtle border + fill for unselected threads.
            let fillPath = NSBezierPath(
                roundedRect: capsuleRect,
                xRadius: Self.capsuleCornerRadius,
                yRadius: Self.capsuleCornerRadius
            )
            NSColor.white.withAlphaComponent(0.05).setFill()
            fillPath.fill()

            // Skip static border when the animated busy border is active.
            if busyBorderContainer == nil {
                let insetRect = capsuleRect.insetBy(dx: Self.capsuleBorderWidth / 2, dy: Self.capsuleBorderWidth / 2)
                let borderPath = NSBezierPath(
                    roundedRect: insetRect,
                    xRadius: Self.capsuleCornerRadius,
                    yRadius: Self.capsuleCornerRadius
                )
                borderPath.lineWidth = 1
                NSColor.white.withAlphaComponent(0.12).setStroke()
                borderPath.stroke()
            }
        }

        if showsSubtleBottomSeparator {
            let separatorY = isFlipped ? (bounds.maxY - 1) : bounds.minY
            let separatorRect = NSRect(
                x: bounds.minX + 8,
                y: separatorY,
                width: max(0, bounds.width - 16),
                height: 1
            )
            NSColor.separatorColor.withAlphaComponent(0.24).setFill()
            NSBezierPath(rect: separatorRect).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // No-op: all capsule drawing is in drawBackground to allow
        // selectionHighlightStyle = .none without losing our custom highlight.
    }

    private func updateBusyShimmerAnimation() {
        guard let contentView = targetContentView(),
              let contentLayer = contentView.layer else {
            stopBusyShimmerAnimation()
            return
        }
        if showsBusyShimmer {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                stopBusyShimmerAnimation()
                stopBusyBorderAnimation()
                return
            }
            startBusyBorderAnimation()
            let maskLayer = ensureBusyOpacityMaskLayer()
            maskLayer.frame = busyMaskFrame(for: contentLayer.bounds)
            if contentLayer.mask !== maskLayer {
                contentLayer.mask = maskLayer
            }
            maskedContentView = contentView

            guard maskLayer.animation(forKey: Self.busyOpacitySweepAnimationKey) == nil else { return }

            // Keep the dip fully offscreen at cycle boundaries so leading icons
            // do not appear to blink/disappear when the animation loops.
            let startLocations: [NSNumber] = [-0.72, -0.56, -0.47, -0.38, -0.22]
            let endLocations: [NSNumber] = [1.22, 1.38, 1.47, 1.56, 1.72]
            maskLayer.locations = startLocations

            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = startLocations
            animation.toValue = endLocations
            animation.duration = 2.6
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            maskLayer.add(animation, forKey: Self.busyOpacitySweepAnimationKey)
        } else {
            stopBusyShimmerAnimation()
        }
    }

    private func stopBusyShimmerAnimation() {
        busyOpacityMaskLayer?.removeAnimation(forKey: Self.busyOpacitySweepAnimationKey)
        if let maskedContentView,
           let maskedLayer = maskedContentView.layer,
           maskedLayer.mask === busyOpacityMaskLayer {
            maskedLayer.mask = nil
        }
        maskedContentView = nil
        stopBusyBorderAnimation()
    }

    private func ensureBusyOpacityMaskLayer() -> CAGradientLayer {
        if let busyOpacityMaskLayer {
            return busyOpacityMaskLayer
        }
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [
            NSColor.white.withAlphaComponent(1.0).cgColor,
            NSColor.white.withAlphaComponent(1.0).cgColor,
            NSColor.white.withAlphaComponent(0.74).cgColor,
            NSColor.white.withAlphaComponent(1.0).cgColor,
            NSColor.white.withAlphaComponent(1.0).cgColor,
        ]
        busyOpacityMaskLayer = mask
        return mask
    }

    private func targetContentView() -> NSView? {
        if let maskedContentView, subviews.contains(maskedContentView) {
            return maskedContentView
        }
        if let cellView = subviews.first(where: { $0 is NSTableCellView }) {
            return cellView
        }
        return subviews.first
    }

    private func busyMaskFrame(for contentBounds: CGRect) -> CGRect {
        CGRect(
            x: -Self.busyMaskOverscanLeft,
            y: contentBounds.minY,
            width: contentBounds.width + Self.busyMaskOverscanLeft + Self.busyMaskOverscanRight,
            height: contentBounds.height
        )
    }

    // MARK: - Busy Border Animation

    private func makeBorderRotationAnimation() -> CABasicAnimation {
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0.0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 3.0
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        // Pin to the original start time so CA computes the correct phase
        // even when the animation is re-added after being dropped.
        rotation.beginTime = busyBorderAnimationStartTime
        return rotation
    }

    private func startBusyBorderAnimation() {
        guard window != nil else { return }
        if let existing = busyBorderContainer {
            // Re-add rotation if CA dropped it (e.g. view left and re-entered window).
            if let gradient = existing.sublayers?.first as? CAGradientLayer,
               gradient.animation(forKey: Self.busyBorderRotationAnimationKey) == nil {
                gradient.add(makeBorderRotationAnimation(), forKey: Self.busyBorderRotationAnimationKey)
            }
            return
        }

        let rect = capsuleRect
        let cornerRadius = Self.capsuleCornerRadius
        let borderWidth: CGFloat = Self.capsuleBorderWidth

        // Container sits behind content but above row background.
        let container = CALayer()
        container.frame = bounds
        container.zPosition = -1
        layer?.addSublayer(container)

        // The conic gradient that will rotate. Made larger than the capsule
        // so the gradient sweep looks smooth even at the corners.
        let gradientLayer = CAGradientLayer()
        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)

        applyBorderGradientColors(gradientLayer, selected: isSelected)
        gradientLayer.locations = [0.0, 0.08, 0.16, 0.5, 0.84, 0.92, 1.0]

        // Expand gradient frame so rotation doesn't clip.
        let diagonal = sqrt(rect.width * rect.width + rect.height * rect.height)
        gradientLayer.frame = CGRect(
            x: rect.midX - diagonal / 2,
            y: rect.midY - diagonal / 2,
            width: diagonal,
            height: diagonal
        )
        container.addSublayer(gradientLayer)

        // Mask the gradient to just the capsule border stroke.
        let borderPath = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        let shapeMask = CAShapeLayer()
        shapeMask.path = borderPath
        shapeMask.fillColor = nil
        shapeMask.strokeColor = NSColor.white.cgColor
        shapeMask.lineWidth = borderWidth
        container.mask = shapeMask

        // Reuse existing start time if this thread was already animating
        // (e.g. row view was recreated by a structural reload), otherwise
        // record a new one.
        if busyBorderAnimationStartTime == 0 {
            busyBorderAnimationStartTime = CACurrentMediaTime()
        }
        gradientLayer.add(makeBorderRotationAnimation(), forKey: Self.busyBorderRotationAnimationKey)

        busyBorderContainer = container
    }

    /// Set the gradient colors based on selection state.
    private func applyBorderGradientColors(_ gradientLayer: CAGradientLayer, selected: Bool) {
        let brightColor: NSColor
        let dimColor: NSColor
        if selected {
            brightColor = NSColor.white.withAlphaComponent(0.9)
            dimColor = NSColor.white.withAlphaComponent(0.25)
        } else {
            let accentColor = NSColor.controlAccentColor
            var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
            accentColor.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            brightColor = NSColor(hue: hue, saturation: max(sat * 0.7, 0.3), brightness: min(bri * 1.1, 1.0), alpha: 0.8)
            dimColor = NSColor.white.withAlphaComponent(0.12)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            gradientLayer.colors = [
                brightColor.cgColor,
                brightColor.withAlphaComponent(selected ? 0.5 : 0.4).cgColor,
                dimColor.cgColor,
                dimColor.cgColor,
                dimColor.cgColor,
                brightColor.withAlphaComponent(selected ? 0.5 : 0.4).cgColor,
                brightColor.cgColor,
            ]
        }
    }

    private func updateBusyBorderSelectionColors() {
        guard let container = busyBorderContainer,
              let gradient = container.sublayers?.first as? CAGradientLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyBorderGradientColors(gradient, selected: isSelected)
        CATransaction.commit()
    }

    private func stopBusyBorderAnimation() {
        guard busyBorderContainer != nil else { return }
        busyBorderContainer?.removeFromSuperlayer()
        busyBorderContainer = nil
        busyBorderAnimationStartTime = 0
    }

    private func layoutBusyBorderLayers() {
        guard let container = busyBorderContainer else { return }
        // Disable implicit animations so frame/path changes don't
        // create transactions that reset the running rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let rect = capsuleRect
        let cornerRadius = Self.capsuleCornerRadius

        if let gradientLayer = container.sublayers?.first as? CAGradientLayer {
            let diagonal = sqrt(rect.width * rect.width + rect.height * rect.height)
            gradientLayer.frame = CGRect(
                x: rect.midX - diagonal / 2,
                y: rect.midY - diagonal / 2,
                width: diagonal,
                height: diagonal
            )
        }
        if let shapeMask = container.mask as? CAShapeLayer {
            shapeMask.path = CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }
        CATransaction.commit()
    }

    // MARK: - Sign Emoji

    /// Configure the sign emoji displayed on the capsule's leading edge.
    func configureSignEmoji(_ emoji: String?, tintColor: NSColor?, isSelected: Bool) {
        signEmojiTintColor = tintColor
        guard let emoji, !emoji.isEmpty else {
            signEmojiLabel?.isHidden = true
            return
        }
        let label = ensureSignEmojiLabel()
        label.stringValue = emoji
        label.font = (emoji == "↑" || emoji == "↓")
            ? .systemFont(ofSize: 12, weight: .bold)
            : .systemFont(ofSize: 9, weight: .bold)
        label.textColor = isSelected ? .white : (tintColor ?? .labelColor)
        label.isHidden = false
    }

    private func updateSignEmojiSelectionColor() {
        guard let label = signEmojiLabel, !label.isHidden else { return }
        label.textColor = isSelected ? .white : (signEmojiTintColor ?? .labelColor)
    }

    private func ensureSignEmojiLabel() -> NSTextField {
        if let label = signEmojiLabel { return label }
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.isHidden = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.capsuleLeadingInset
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        signEmojiLabel = label
        return label
    }

    private func updateArchivingOverlay() {
        if showsArchivingOverlay {
            ensureArchivingOverlay()
        } else {
            archivingOverlay?.removeFromSuperview()
            archivingOverlay = nil
        }
    }

    private func ensureArchivingOverlay() {
        guard archivingOverlay == nil else { return }

        let overlay = ArchivingRowOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Archiving…")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        archivingOverlay = overlay
    }
}

final class ProjectHeaderRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

final class SidebarSpacerRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
    }
}

final class SidebarSpacerCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
