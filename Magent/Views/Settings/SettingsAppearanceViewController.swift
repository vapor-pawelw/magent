import Cocoa
import MagentCore

final class SettingsAppearanceViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false
    private var appearancePopup: NSPopUpButton!

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 640))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        settings = persistence.loadSettings()

        contentScrollView = NSScrollView()
        contentScrollView.hasVerticalScroller = true
        contentScrollView.autohidesScrollers = true
        contentScrollView.drawsBackground = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let (appearanceCard, appearanceSection) = createSectionCard(
            title: "App Appearance",
            description: "Choose whether Magent follows the system appearance or stays explicitly light or dark. Terminal surfaces and terminal overlays refresh with the same preference."
        )
        stackView.addArrangedSubview(appearanceCard)

        appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        appearancePopup.controlSize = .small
        appearancePopup.font = .systemFont(ofSize: 12)
        appearancePopup.addItems(withTitles: AppAppearanceMode.allCases.map(\.displayName))
        if let index = AppAppearanceMode.allCases.firstIndex(of: settings.appAppearanceMode) {
            appearancePopup.selectItem(at: index)
        }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearancePopupChanged)
        appearanceSection.addArrangedSubview(
            labeledPopupRow(label: "Appearance", popup: appearancePopup)
        )

        let appearanceNote = NSTextField(
            wrappingLabelWithString: "System mode lets AppKit and Ghostty track macOS appearance changes, including scheduled automatic light/dark switching."
        )
        appearanceNote.font = .systemFont(ofSize: 11)
        appearanceNote.textColor = NSColor(resource: .textSecondary)
        appearanceSection.addArrangedSubview(appearanceNote)

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)
        contentScrollView.documentView = documentView

        view.addSubview(contentScrollView)

        NSLayoutConstraint.activate([
            contentScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            contentScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: contentScrollView.widthAnchor),
            appearanceCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            appearanceNote.widthAnchor.constraint(equalTo: appearanceSection.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !didInitialScrollToTop {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didInitialScrollToTop, view.window != nil {
            scrollToTop()
            didInitialScrollToTop = true
        }
    }

    private func scrollToTop() {
        guard let clipView = contentScrollView?.contentView as NSClipView? else { return }
        clipView.scroll(to: NSPoint(x: 0, y: 0))
        contentScrollView.reflectScrolledClipView(clipView)
    }

    private func saveSettingsAndNotify() {
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSettingsDidChange, object: nil)
    }

    private func labeledPopupRow(label: String, popup: NSPopUpButton) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 12)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(popup)
        return row
    }

    private func createSectionCard(title: String, description: String? = nil) -> (container: NSView, content: NSStackView) {
        let container = SettingsSectionCardView()

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        content.addArrangedSubview(titleLabel)

        if let description, !description.isEmpty {
            let descriptionLabel = NSTextField(wrappingLabelWithString: description)
            descriptionLabel.font = .systemFont(ofSize: 11)
            descriptionLabel.textColor = NSColor(resource: .textSecondary)
            content.addArrangedSubview(descriptionLabel)
            content.setCustomSpacing(12, after: descriptionLabel)
            NSLayoutConstraint.activate([
                descriptionLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        return (container, content)
    }

    @objc private func appearancePopupChanged() {
        let index = appearancePopup.indexOfSelectedItem
        guard AppAppearanceMode.allCases.indices.contains(index) else { return }
        settings.appAppearanceMode = AppAppearanceMode.allCases[index]
        saveSettingsAndNotify()
    }
}
