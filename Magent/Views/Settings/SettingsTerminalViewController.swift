import Cocoa
import MagentCore

final class SettingsTerminalViewController: NSViewController {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false
    private var appearancePopup: NSPopUpButton!
    private var mouseWheelPopup: NSPopUpButton!
    private var mouseWheelDescriptionLabel: NSTextField!
    private var showScrollToBottomIndicatorCheckbox: NSButton!
    private var showScrollOverlayCheckbox: NSButton!
    private var showPromptTOCCheckbox: NSButton!

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
            title: "Appearance",
            description: "Choose whether Magent follows the system appearance or stays explicitly light or dark. The terminal follows the same preference."
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
            labeledPopupRow(label: "App appearance", popup: appearancePopup)
        )

        let appearanceNote = NSTextField(
            wrappingLabelWithString: "System mode lets AppKit update the app chrome automatically and refreshes the embedded terminal when macOS changes appearance, including scheduled auto switching."
        )
        appearanceNote.font = .systemFont(ofSize: 11)
        appearanceNote.textColor = NSColor(resource: .textSecondary)
        appearanceSection.addArrangedSubview(appearanceNote)

        let (mouseCard, mouseSection) = createSectionCard(
            title: "Mouse Wheel",
            description: "Control whether trackpad and wheel scrolling is reserved for terminal history or can be captured by prompts and terminal apps."
        )
        stackView.addArrangedSubview(mouseCard)

        mouseWheelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        mouseWheelPopup.controlSize = .small
        mouseWheelPopup.font = .systemFont(ofSize: 12)
        mouseWheelPopup.addItems(withTitles: TerminalMouseWheelBehavior.allCases.map(\.displayName))
        if let index = TerminalMouseWheelBehavior.allCases.firstIndex(of: settings.terminalMouseWheelBehavior) {
            mouseWheelPopup.selectItem(at: index)
        }
        mouseWheelPopup.target = self
        mouseWheelPopup.action = #selector(mouseWheelPopupChanged)
        mouseSection.addArrangedSubview(
            labeledPopupRow(label: "Wheel behavior", popup: mouseWheelPopup)
        )

        mouseWheelDescriptionLabel = NSTextField(wrappingLabelWithString: "")
        mouseWheelDescriptionLabel.font = .systemFont(ofSize: 11)
        mouseWheelDescriptionLabel.textColor = NSColor(resource: .textSecondary)
        mouseSection.addArrangedSubview(mouseWheelDescriptionLabel)
        refreshMouseWheelDescription()

        let (overlaysCard, overlaysSection) = createSectionCard(
            title: "Terminal Overlays",
            description: "Control always-on helpers that stay above the embedded terminal."
        )
        stackView.addArrangedSubview(overlaysCard)

        showScrollToBottomIndicatorCheckbox = NSButton(
            checkboxWithTitle: "Show scroll-to-bottom indicator",
            target: self,
            action: #selector(showScrollToBottomIndicatorToggled)
        )
        showScrollToBottomIndicatorCheckbox.state = settings.showScrollToBottomIndicator ? .on : .off
        overlaysSection.addArrangedSubview(showScrollToBottomIndicatorCheckbox)

        let showScrollToBottomIndicatorDesc = NSTextField(
            wrappingLabelWithString: "Shows the floating `Scroll to bottom` pill when you are away from live output."
        )
        showScrollToBottomIndicatorDesc.font = .systemFont(ofSize: 11)
        showScrollToBottomIndicatorDesc.textColor = NSColor(resource: .textSecondary)
        overlaysSection.addArrangedSubview(showScrollToBottomIndicatorDesc)

        showScrollOverlayCheckbox = NSButton(
            checkboxWithTitle: "Show terminal scroll overlay controls",
            target: self,
            action: #selector(showScrollOverlayToggled)
        )
        showScrollOverlayCheckbox.state = settings.showTerminalScrollOverlay ? .on : .off
        overlaysSection.addArrangedSubview(showScrollOverlayCheckbox)

        let showScrollOverlayDesc = NSTextField(
            wrappingLabelWithString: "Shows the bottom-right page up/down/jump overlay."
        )
        showScrollOverlayDesc.font = .systemFont(ofSize: 11)
        showScrollOverlayDesc.textColor = NSColor(resource: .textSecondary)
        overlaysSection.addArrangedSubview(showScrollOverlayDesc)

        showPromptTOCCheckbox = NSButton(
            checkboxWithTitle: "Show prompt Table of Contents overlay",
            target: self,
            action: #selector(showPromptTOCToggled)
        )
        showPromptTOCCheckbox.state = settings.showPromptTOCOverlay ? .on : .off
        overlaysSection.addArrangedSubview(showPromptTOCCheckbox)

        let showPromptTOCDesc = NSTextField(
            wrappingLabelWithString: "When disabled, TOC stays hidden and the top-right TOC toggle is removed."
        )
        showPromptTOCDesc.font = .systemFont(ofSize: 11)
        showPromptTOCDesc.textColor = NSColor(resource: .textSecondary)
        overlaysSection.addArrangedSubview(showPromptTOCDesc)

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
            mouseCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            overlaysCard.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            appearanceNote.widthAnchor.constraint(equalTo: appearanceSection.widthAnchor),
            mouseWheelDescriptionLabel.widthAnchor.constraint(equalTo: mouseSection.widthAnchor),
            showScrollToBottomIndicatorDesc.widthAnchor.constraint(equalTo: overlaysSection.widthAnchor),
            showScrollOverlayDesc.widthAnchor.constraint(equalTo: overlaysSection.widthAnchor),
            showPromptTOCDesc.widthAnchor.constraint(equalTo: overlaysSection.widthAnchor),
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

    private func refreshMouseWheelDescription() {
        switch settings.terminalMouseWheelBehavior {
        case .magentDefaultScroll:
            mouseWheelDescriptionLabel.stringValue = "Magent override. Wheel input scrolls terminal history by default instead of being handed to prompts or full-screen terminal apps."
        case .inheritGhosttyGlobal:
            mouseWheelDescriptionLabel.stringValue = "No Magent override. Wheel behavior comes from the user's Ghostty config on this Mac."
        case .allowAppsToCapture:
            mouseWheelDescriptionLabel.stringValue = "Magent override. Wheel input is available to prompts and terminal apps that request mouse reporting, which can replace normal terminal scrolling."
        }
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

    @objc private func mouseWheelPopupChanged() {
        let index = mouseWheelPopup.indexOfSelectedItem
        guard TerminalMouseWheelBehavior.allCases.indices.contains(index) else { return }
        settings.terminalMouseWheelBehavior = TerminalMouseWheelBehavior.allCases[index]
        refreshMouseWheelDescription()
        saveSettingsAndNotify()
    }

    @objc private func showScrollToBottomIndicatorToggled() {
        settings.showScrollToBottomIndicator = showScrollToBottomIndicatorCheckbox.state == .on
        saveSettingsAndNotify()
    }

    @objc private func showScrollOverlayToggled() {
        settings.showTerminalScrollOverlay = showScrollOverlayCheckbox.state == .on
        saveSettingsAndNotify()
    }

    @objc private func showPromptTOCToggled() {
        settings.showPromptTOCOverlay = showPromptTOCCheckbox.state == .on
        saveSettingsAndNotify()
    }
}
