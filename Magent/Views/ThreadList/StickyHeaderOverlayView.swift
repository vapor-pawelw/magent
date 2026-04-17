import Cocoa

/// Floating overlay that pins project and section headers at the top of the sidebar
/// scroll view so the user always knows which project/section the visible threads
/// belong to. Positioned above the scroll view in the view hierarchy.
final class StickyHeaderOverlayView: NSView {

    // MARK: - Layout constants (match outline view cell layout)

    static let projectRowHeight: CGFloat = ThreadListViewController.projectHeaderRowHeight
    static let sectionRowHeight: CGFloat = 28
    private static let leadingInset: CGFloat = ThreadListViewController.capsuleAlignedLeading
    private static let trailingInset: CGFloat = ThreadListViewController.capsuleAlignedTrailing
    private static let fadeHeight: CGFloat = 12

    // MARK: - Subviews

    /// Opaque background behind the header labels (excludes the fade zone).
    private let opaqueBackground = NSView()

    private let projectContainer = NSView()
    private let projectNameLabel = NSTextField(labelWithString: "")
    private let projectPinIcon = NSImageView()

    private let sectionContainer = NSView()
    private let sectionDotView = NSImageView()
    private let sectionNameLabel = NSTextField(labelWithString: "")

    private let fadeGradientView = NSView()

    private var sectionTopToProject: NSLayoutConstraint!
    private var sectionTopToSuperview: NSLayoutConstraint!
    /// Pins the fade just below whichever header row is last.
    private var fadeTopToProject: NSLayoutConstraint!
    private var fadeTopToSection: NSLayoutConstraint!

    // MARK: - State

    struct HeaderState: Equatable {
        var projectName: String?
        var projectIsPinned: Bool = false
        var sectionName: String?
        var sectionColor: NSColor?

        static let hidden = HeaderState()
    }

    private var currentState = HeaderState.hidden

    /// Called when the user clicks the sticky project header.
    var onProjectClicked: (() -> Void)?
    /// Called when the user clicks the sticky section header.
    var onSectionClicked: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        // Opaque background (covers header rows but not the fade)
        opaqueBackground.translatesAutoresizingMaskIntoConstraints = false
        opaqueBackground.wantsLayer = true
        addSubview(opaqueBackground)

        // Project header row
        projectContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(projectContainer)

        projectNameLabel.font = .systemFont(ofSize: 20, weight: .bold)
        projectNameLabel.textColor = .labelColor
        projectNameLabel.lineBreakMode = .byTruncatingTail
        projectNameLabel.translatesAutoresizingMaskIntoConstraints = false
        projectContainer.addSubview(projectNameLabel)

        projectPinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        projectPinIcon.contentTintColor = NSColor(resource: .primaryBrand)
        projectPinIcon.translatesAutoresizingMaskIntoConstraints = false
        projectPinIcon.isHidden = true
        projectContainer.addSubview(projectPinIcon)

        // Section header row
        sectionContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionContainer)

        sectionDotView.translatesAutoresizingMaskIntoConstraints = false
        sectionContainer.addSubview(sectionDotView)

        sectionNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sectionNameLabel.textColor = NSColor(resource: .textSecondary)
        sectionNameLabel.lineBreakMode = .byTruncatingTail
        sectionNameLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionContainer.addSubview(sectionNameLabel)

        // Fade gradient (within bounds, below headers)
        fadeGradientView.translatesAutoresizingMaskIntoConstraints = false
        fadeGradientView.wantsLayer = true
        addSubview(fadeGradientView)

        // Constraints
        sectionTopToProject = sectionContainer.topAnchor.constraint(
            equalTo: projectContainer.bottomAnchor
        )
        sectionTopToSuperview = sectionContainer.topAnchor.constraint(equalTo: topAnchor)

        // Fade sits below project (section-only hidden) or below section
        fadeTopToProject = fadeGradientView.topAnchor.constraint(
            equalTo: projectContainer.bottomAnchor
        )
        fadeTopToSection = fadeGradientView.topAnchor.constraint(
            equalTo: sectionContainer.bottomAnchor
        )

        NSLayoutConstraint.activate([
            // Opaque background covers from top to the fade
            opaqueBackground.topAnchor.constraint(equalTo: topAnchor),
            opaqueBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            opaqueBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            opaqueBackground.bottomAnchor.constraint(equalTo: fadeGradientView.topAnchor),

            projectContainer.topAnchor.constraint(equalTo: topAnchor),
            projectContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            projectContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            projectContainer.heightAnchor.constraint(equalToConstant: Self.projectRowHeight),

            projectNameLabel.centerYAnchor.constraint(equalTo: projectContainer.centerYAnchor, constant: -1),
            projectNameLabel.leadingAnchor.constraint(
                equalTo: projectContainer.leadingAnchor,
                constant: Self.leadingInset
            ),
            projectNameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: projectPinIcon.leadingAnchor,
                constant: -6
            ),

            projectPinIcon.centerYAnchor.constraint(equalTo: projectNameLabel.centerYAnchor),
            projectPinIcon.widthAnchor.constraint(equalToConstant: 10),
            projectPinIcon.heightAnchor.constraint(equalToConstant: 10),
            projectPinIcon.trailingAnchor.constraint(
                lessThanOrEqualTo: projectContainer.trailingAnchor,
                constant: -Self.trailingInset
            ),

            sectionTopToProject,

            sectionContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionContainer.heightAnchor.constraint(equalToConstant: Self.sectionRowHeight),

            sectionDotView.leadingAnchor.constraint(
                equalTo: sectionContainer.leadingAnchor,
                constant: Self.leadingInset
            ),
            sectionDotView.centerYAnchor.constraint(equalTo: sectionContainer.centerYAnchor),
            sectionDotView.widthAnchor.constraint(equalToConstant: 8),
            sectionDotView.heightAnchor.constraint(equalToConstant: 8),

            sectionNameLabel.leadingAnchor.constraint(equalTo: sectionDotView.trailingAnchor, constant: 6),
            sectionNameLabel.centerYAnchor.constraint(equalTo: sectionContainer.centerYAnchor),
            sectionNameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: sectionContainer.trailingAnchor,
                constant: -Self.trailingInset
            ),

            fadeGradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fadeGradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fadeGradientView.heightAnchor.constraint(equalToConstant: Self.fadeHeight),
            fadeGradientView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        isHidden = true
    }

    // MARK: - Update

    func update(state: HeaderState) {
        guard state != currentState else { return }
        currentState = state

        let showProject = state.projectName != nil
        let showSection = state.sectionName != nil

        if !showProject && !showSection {
            isHidden = true
            projectContainer.isHidden = true
            sectionContainer.isHidden = true
            return
        }

        isHidden = false

        // Project row
        projectContainer.isHidden = !showProject
        if showProject {
            projectNameLabel.stringValue = state.projectName ?? ""
            projectPinIcon.isHidden = !state.projectIsPinned
        }

        // Section row
        sectionContainer.isHidden = !showSection
        if showSection {
            sectionNameLabel.stringValue = (state.sectionName ?? "").uppercased()
            if let color = state.sectionColor {
                sectionDotView.image = colorDotImage(color: color, size: 8)
            }
        }

        // Adjust section top constraint
        sectionTopToProject.isActive = showProject && showSection
        sectionTopToSuperview.isActive = !showProject && showSection

        // Fade anchors below the last visible header row
        fadeTopToSection.isActive = showSection
        fadeTopToProject.isActive = !showSection && showProject

        updateBackground()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        var h: CGFloat = 0
        if !projectContainer.isHidden { h += Self.projectRowHeight }
        if !sectionContainer.isHidden { h += Self.sectionRowHeight }
        if h > 0 { h += Self.fadeHeight }
        return NSSize(width: NSView.noIntrinsicMetric, height: h)
    }

    private func updateBackground() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let bgColor: NSColor = isDark
                ? NSColor.windowBackgroundColor
                : NSColor(resource: .appBackground)
            opaqueBackground.layer?.backgroundColor = bgColor.cgColor

            // Rebuild the gradient sublayer
            let gradientLayer: CAGradientLayer
            if let existing = fadeGradientView.layer?.sublayers?.first as? CAGradientLayer {
                gradientLayer = existing
            } else {
                let gl = CAGradientLayer()
                fadeGradientView.layer?.addSublayer(gl)
                gradientLayer = gl
            }
            gradientLayer.colors = [bgColor.withAlphaComponent(0).cgColor, bgColor.cgColor]
            gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
            gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
            gradientLayer.frame = fadeGradientView.bounds
        }
    }

    override func layout() {
        super.layout()
        if let gl = fadeGradientView.layer?.sublayers?.first as? CAGradientLayer {
            gl.frame = fadeGradientView.bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !isHidden { updateBackground() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !isHidden { updateBackground() }
    }

    // MARK: - Click Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !sectionContainer.isHidden, sectionContainer.frame.contains(point) {
            onSectionClicked?()
        } else if !projectContainer.isHidden, projectContainer.frame.contains(point) {
            onProjectClicked?()
        }
        // Don't call super — absorb the click so it doesn't pass through
    }
}
