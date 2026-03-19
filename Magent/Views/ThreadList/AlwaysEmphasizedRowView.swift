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
    private static let busyMaskOverscanLeft: CGFloat = 96
    private static let busyMaskOverscanRight: CGFloat = 48
    private var busyOpacityMaskLayer: CAGradientLayer?
    private weak var maskedContentView: NSView?
    private var archivingOverlay: ArchivingRowOverlayView?

    var showsCompletionHighlight = false {
        didSet { needsDisplay = true }
    }
    var showsSubtleBottomSeparator = false {
        didSet { needsDisplay = true }
    }
    var showsBusyShimmer = false {
        didSet { updateBusyShimmerAnimation() }
    }
    var showsArchivingOverlay = false {
        didSet { updateArchivingOverlay() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
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
        guard let busyOpacityMaskLayer,
              let maskedContentView,
              let contentLayer = maskedContentView.layer else { return }
        busyOpacityMaskLayer.frame = busyMaskFrame(for: contentLayer.bounds)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if showsCompletionHighlight, !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
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

    private func updateBusyShimmerAnimation() {
        guard let contentView = targetContentView(),
              let contentLayer = contentView.layer else {
            stopBusyShimmerAnimation()
            return
        }
        if showsBusyShimmer {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                stopBusyShimmerAnimation()
                return
            }
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
    private let dividerView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.wantsLayer = true
        addSubview(dividerView)

        NSLayoutConstraint.activate([
            dividerView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ThreadListViewController.projectSpacerDividerLeadingInset
            ),
            dividerView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ThreadListViewController.projectSpacerDividerTrailingInset
            ),
            dividerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: ThreadListViewController.projectSpacerDividerHeight),
        ])
        updateDividerColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDividerColor()
    }

    private func updateDividerColor() {
        dividerView.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
    }
}
