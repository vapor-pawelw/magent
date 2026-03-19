import Cocoa
import MagentModels

/// A tiny rounded-rect pill displaying a status label with a colored background.
/// Used inline in sidebar rows and top-bar buttons to show PR/Jira status.
final class StatusBadgeView: NSView {

    struct Style {
        let backgroundColor: NSColor
        let textColor: NSColor

        // PR statuses — darkened for white-text legibility
        static let open = Style(backgroundColor: NSColor(red: 0.15, green: 0.55, blue: 0.20, alpha: 1), textColor: .white)
        static let draft = Style(backgroundColor: NSColor(red: 0.40, green: 0.40, blue: 0.42, alpha: 1), textColor: .white)
        static let merged = Style(backgroundColor: NSColor(red: 0.50, green: 0.22, blue: 0.70, alpha: 1), textColor: .white)
        static let approved = Style(backgroundColor: NSColor(red: 0.12, green: 0.50, blue: 0.15, alpha: 1), textColor: .white)
        static let changesRequested = Style(backgroundColor: NSColor(red: 0.80, green: 0.50, blue: 0.10, alpha: 1), textColor: .white)
        static let closed = Style(backgroundColor: NSColor(red: 0.70, green: 0.20, blue: 0.20, alpha: 1), textColor: .white)

        // Jira status category colors (from Jira's own category system)
        static let jiraTodo = Style(backgroundColor: NSColor(red: 0.35, green: 0.38, blue: 0.42, alpha: 1), textColor: .white)
        static let jiraInProgress = Style(backgroundColor: NSColor(red: 0.15, green: 0.45, blue: 0.75, alpha: 1), textColor: .white)
        static let jiraDone = Style(backgroundColor: NSColor(red: 0.15, green: 0.55, blue: 0.20, alpha: 1), textColor: .white)
    }

    private let label = NSTextField(labelWithString: "")

    override var wantsUpdateLayer: Bool { true }

    private var badgeBackgroundColor: NSColor = .clear
    private var cornerRadius: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        addSubview(label)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = self.badgeBackgroundColor.cgColor
            self.layer?.cornerRadius = self.cornerRadius
        }
    }

    func configure(text: String, style: Style, fontSize: CGFloat) {
        label.stringValue = text
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = style.textColor
        badgeBackgroundColor = style.backgroundColor
        needsDisplay = true
    }

    // MARK: - PR Status

    static func prStyle(for pr: PullRequestInfo) -> Style {
        if pr.isMerged { return .merged }
        if pr.isClosed { return .closed }
        if pr.isDraft { return .draft }
        switch pr.reviewDecision {
        case .approved: return .approved
        case .changesRequested: return .changesRequested
        case .reviewRequired, nil: return .open
        }
    }

    // MARK: - Jira Status

    /// Returns the Jira category background color, or nil for unknown categories.
    static func jiraCategoryColor(forKey categoryKey: String?) -> NSColor? {
        switch categoryKey {
        case "new": return Style.jiraTodo.backgroundColor
        case "indeterminate": return Style.jiraInProgress.backgroundColor
        case "done": return Style.jiraDone.backgroundColor
        default: return nil
        }
    }

    /// Maps the Jira `statusCategory.key` to a badge style.
    /// Falls back to keyword matching on the status name when category is unavailable.
    static func jiraStyle(forCategoryKey categoryKey: String?) -> Style {
        switch categoryKey {
        case "done": return .jiraDone
        case "indeterminate": return .jiraInProgress
        case "new": return .jiraTodo
        default: return .jiraTodo
        }
    }
}
