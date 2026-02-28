import Cocoa

final class SettingsGeneralViewController: NSViewController, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private let persistence = PersistenceService.shared
    private var settings: AppSettings!
    private var autoRenameCheckbox: NSButton!
    private var slugPromptTextView: NSTextView!
    private var terminalInjectionTextView: NSTextView!
    private var agentContextTextView: NSTextView!
    private var contentScrollView: NSScrollView!
    private var didInitialScrollToTop = false

    // Thread sections
    private var sectionsTableView: NSTableView!
    private var currentEditingSectionId: UUID?

    private var sortedSections: [ThreadSection] {
        settings.threadSections.sorted { $0.sortOrder < $1.sortOrder }
    }

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
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        // Worktree Behavior
        let worktreeSection = NSStackView()
        worktreeSection.orientation = .vertical
        worktreeSection.alignment = .leading
        worktreeSection.spacing = 6

        let worktreeLabel = NSTextField(labelWithString: "Worktree Behavior")
        worktreeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        worktreeSection.addArrangedSubview(worktreeLabel)

        autoRenameCheckbox = NSButton(
            checkboxWithTitle: "Auto-rename worktrees from the first agent prompt",
            target: self,
            action: #selector(autoRenameToggled)
        )
        autoRenameCheckbox.state = settings.autoRenameWorktrees ? .on : .off
        worktreeSection.addArrangedSubview(autoRenameCheckbox)

        let autoRenameDesc = NSTextField(
            wrappingLabelWithString: "Uses AI to generate a meaningful branch name from the prompt. Currently works with Claude Code and Codex."
        )
        autoRenameDesc.font = .systemFont(ofSize: 11)
        autoRenameDesc.textColor = NSColor(resource: .textSecondary)
        worktreeSection.addArrangedSubview(autoRenameDesc)

        // Slug prompt customization (always visible)
        let slugPromptWrapper = NSStackView()
        slugPromptWrapper.orientation = .vertical
        slugPromptWrapper.alignment = .leading
        slugPromptWrapper.spacing = 4

        let slugPromptLabel = NSTextField(labelWithString: "Slug Prompt")
        slugPromptLabel.font = .systemFont(ofSize: 12, weight: .medium)
        slugPromptWrapper.addArrangedSubview(slugPromptLabel)

        let slugPromptDesc = NSTextField(
            wrappingLabelWithString: "Instruction used to generate branch slugs — for auto-rename on first prompt, rename via agent, or CLI rename-thread command."
        )
        slugPromptDesc.font = .systemFont(ofSize: 11)
        slugPromptDesc.textColor = NSColor(resource: .textSecondary)
        slugPromptWrapper.addArrangedSubview(slugPromptDesc)

        slugPromptTextView = NSTextView()
        slugPromptTextView.font = .systemFont(ofSize: 13)
        slugPromptTextView.string = settings.autoRenameSlugPrompt
        slugPromptTextView.isRichText = false
        slugPromptTextView.isAutomaticQuoteSubstitutionEnabled = false
        slugPromptTextView.isAutomaticDashSubstitutionEnabled = false
        slugPromptTextView.isAutomaticTextReplacementEnabled = false
        slugPromptTextView.delegate = self
        slugPromptTextView.isVerticallyResizable = true
        slugPromptTextView.isHorizontallyResizable = false
        slugPromptTextView.textContainerInset = NSSize(width: 4, height: 4)

        let slugPromptScrollView = NonCapturingScrollView()
        slugPromptScrollView.documentView = slugPromptTextView
        slugPromptScrollView.hasVerticalScroller = true
        slugPromptScrollView.autohidesScrollers = true
        slugPromptScrollView.borderType = .bezelBorder
        slugPromptScrollView.translatesAutoresizingMaskIntoConstraints = false

        let slugLineHeight = NSFont.systemFont(ofSize: 13).ascender + abs(NSFont.systemFont(ofSize: 13).descender) + NSFont.systemFont(ofSize: 13).leading
        let slugHeight = max(slugLineHeight * 3 + 12, 56)

        NSLayoutConstraint.activate([
            slugPromptScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: slugHeight),
        ])

        slugPromptWrapper.addArrangedSubview(slugPromptScrollView)

        let resetSlugButton = NSButton(title: "Reset to Default", target: self, action: #selector(resetSlugPromptToDefault))
        resetSlugButton.bezelStyle = .rounded
        resetSlugButton.controlSize = .small
        slugPromptWrapper.addArrangedSubview(resetSlugButton)

        slugPromptWrapper.translatesAutoresizingMaskIntoConstraints = false
        worktreeSection.addArrangedSubview(slugPromptWrapper)

        slugPromptTextView.autoresizingMask = [.width]
        slugPromptTextView.textContainer?.widthTracksTextView = true

        worktreeSection.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(worktreeSection)
        NSLayoutConstraint.activate([
            worktreeSection.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            slugPromptScrollView.widthAnchor.constraint(equalTo: slugPromptWrapper.widthAnchor),
        ])

        // Terminal Injection Command
        terminalInjectionTextView = createSection(
            in: stackView,
            title: "Terminal Injection Command",
            description: "Shell command auto-sent to every new terminal tab after creation.",
            value: settings.terminalInjectionCommand,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )

        // Agent Context Injection
        agentContextTextView = createSection(
            in: stackView,
            title: "Agent Context Injection",
            description: "Text auto-typed into every new agent prompt after startup.",
            value: settings.agentContextInjection,
            font: .systemFont(ofSize: 13)
        )

        // Environment Variables reference
        let envHeader = NSTextField(labelWithString: "Environment Variables")
        envHeader.font = .systemFont(ofSize: 13, weight: .semibold)

        let envDesc = NSTextField(wrappingLabelWithString: "Available in injection commands:")
        envDesc.font = .systemFont(ofSize: 11)
        envDesc.textColor = NSColor(resource: .textSecondary)

        let envVars: [(String, String)] = [
            ("$MAGENT_WORKTREE_PATH", "Absolute path to the thread's git worktree directory"),
            ("$MAGENT_PROJECT_PATH", "Absolute path to the original git repository"),
            ("$MAGENT_WORKTREE_NAME", "Name of the current thread"),
            ("$MAGENT_PROJECT_NAME", "Name of the project (also usable in Worktrees Path)"),
        ]

        let envStack = NSStackView()
        envStack.orientation = .vertical
        envStack.alignment = .leading
        envStack.spacing = 4

        envStack.addArrangedSubview(envHeader)
        envStack.addArrangedSubview(envDesc)

        for (name, desc) in envVars {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            nameLabel.textColor = .systemGreen

            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = .systemFont(ofSize: 11)
            descLabel.textColor = NSColor(resource: .textSecondary)

            row.addArrangedSubview(nameLabel)
            row.addArrangedSubview(descLabel)
            envStack.addArrangedSubview(row)
        }

        stackView.addArrangedSubview(envStack)

        // Separator before Thread Sections
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        // Thread Sections
        let sectionsHeader = NSTextField(labelWithString: "Thread Sections")
        sectionsHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionsHeader.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsHeader)

        let sectionsDesc = NSTextField(wrappingLabelWithString: "Organize threads into sections in the sidebar. Click a color dot to change it. Drag to reorder.")
        sectionsDesc.font = .systemFont(ofSize: 11)
        sectionsDesc.textColor = NSColor(resource: .textSecondary)
        sectionsDesc.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsDesc)

        sectionsTableView = NSTableView()
        sectionsTableView.headerView = nil
        sectionsTableView.style = .inset
        sectionsTableView.rowSizeStyle = .default
        sectionsTableView.selectionHighlightStyle = .none
        sectionsTableView.registerForDraggedTypes([.string])
        sectionsTableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let sectionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SectionColumn"))
        sectionsTableView.addTableColumn(sectionsColumn)
        sectionsTableView.dataSource = self
        sectionsTableView.delegate = self

        let sectionsScrollView = NSScrollView()
        sectionsScrollView.documentView = sectionsTableView
        sectionsScrollView.hasVerticalScroller = true
        sectionsScrollView.autohidesScrollers = true
        sectionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionsScrollView)

        let addSectionButton = NSButton(title: "Add Section...", target: self, action: #selector(addSectionTapped))
        addSectionButton.bezelStyle = .rounded
        addSectionButton.controlSize = .small
        stackView.addArrangedSubview(addSectionButton)

        NSLayoutConstraint.activate([
            sectionsScrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
            sectionsScrollView.heightAnchor.constraint(equalToConstant: 140),
        ])

        // Document view wrapper
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

    private func createSection(
        in stackView: NSStackView,
        title: String,
        description: String,
        value: String,
        font: NSFont
    ) -> NSTextView {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 4

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sectionStack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(wrappingLabelWithString: description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = NSColor(resource: .textSecondary)
        sectionStack.addArrangedSubview(descLabel)

        let textView = NSTextView()
        textView.font = font
        textView.string = value
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 4, height: 4)

        let textScrollView = NonCapturingScrollView()
        textScrollView.documentView = textView
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.borderType = .bezelBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let height = max(lineHeight * 3 + 12, 56)

        let container = ResizableTextContainer(scrollView: textScrollView, minHeight: height)
        sectionStack.addArrangedSubview(container)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sectionStack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: sectionStack.widthAnchor),
            sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -40),
        ])

        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        return textView
    }

    @objc private func autoRenameToggled() {
        settings.autoRenameWorktrees = autoRenameCheckbox.state == .on
        try? persistence.saveSettings(settings)
    }

    @objc private func resetSlugPromptToDefault() {
        slugPromptTextView.string = AppSettings.defaultSlugPrompt
        settings.autoRenameSlugPrompt = AppSettings.defaultSlugPrompt
        try? persistence.saveSettings(settings)
    }

    // MARK: - Thread Section Actions

    @objc private func addSectionTapped() {
        let alert = NSAlert()
        alert.messageText = "New Section"
        alert.informativeText = "Enter section name"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Section name"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = textField.stringValue
        guard !name.isEmpty else { return }

        let maxOrder = settings.threadSections.map(\.sortOrder).max() ?? -1
        let section = ThreadSection(
            name: name,
            colorHex: "#8E8E93",
            sortOrder: maxOrder + 1
        )
        settings.threadSections.append(section)
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()

        showColorPicker(for: section)
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard let index = settings.threadSections.firstIndex(where: { $0.id == section.id }) else { return }

        if section.isVisible {
            let knownSectionIds = Set(settings.threadSections.map(\.id))
            let defaultSectionId = settings.defaultSection?.id
            let threadsInSection = ThreadManager.shared.threads.filter { thread in
                guard !thread.isMain else { return false }
                let effectiveSectionId: UUID?
                if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                    effectiveSectionId = sid
                } else {
                    effectiveSectionId = defaultSectionId
                }
                return effectiveSectionId == section.id
            }
            if !threadsInSection.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Cannot Hide Section"
                alert.informativeText = "Move all threads out of \"\(section.name)\" before hiding it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }

        settings.threadSections[index].isVisible.toggle()
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func deleteSectionTapped(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard !section.isDefault else { return }

        let knownSectionIds = Set(settings.threadSections.map(\.id))
        let defaultSectionId = settings.defaultSection?.id
        let threadsInSection = ThreadManager.shared.threads.filter { thread in
            guard !thread.isMain else { return false }
            let effectiveSectionId: UUID?
            if let sid = thread.sectionId, knownSectionIds.contains(sid) {
                effectiveSectionId = sid
            } else {
                effectiveSectionId = defaultSectionId
            }
            return effectiveSectionId == section.id
        }
        if !threadsInSection.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "Move all threads out of \"\(section.name)\" before deleting it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        settings.threadSections.removeAll { $0.id == section.id }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func colorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }
        showColorPicker(for: sortedSections[row])
    }

    private func showColorPicker(for section: ThreadSection) {
        let panel = NSColorPanel.shared
        panel.color = section.color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        currentEditingSectionId = section.id
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let sectionId = currentEditingSectionId,
              let index = settings.threadSections.firstIndex(where: { $0.id == sectionId }) else { return }

        settings.threadSections[index].colorHex = sender.color.hexString
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    static func colorDotImage(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        return image
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }

        if textView === terminalInjectionTextView {
            settings.terminalInjectionCommand = textView.string
        } else if textView === agentContextTextView {
            settings.agentContextInjection = textView.string
        } else if textView === slugPromptTextView {
            settings.autoRenameSlugPrompt = textView.string
        }

        try? persistence.saveSettings(settings)
    }

    // MARK: - Thread Sections Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedSections.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: .string),
              let sourceRow = Int(rowStr) else { return false }

        var sections = sortedSections
        let moved = sections.remove(at: sourceRow)
        let dest = sourceRow < row ? row - 1 : row
        sections.insert(moved, at: dest)

        for (i, section) in sections.enumerated() {
            if let idx = settings.threadSections.firstIndex(where: { $0.id == section.id }) {
                settings.threadSections[idx].sortOrder = i
            }
        }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sortedSections[row]
        let identifier = NSUserInterfaceItemIdentifier("AppearanceSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.tag = 100
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.tag = 101
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.tag = 102
            delBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(delBtn)

            NSLayoutConstraint.activate([
                colorBtn.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                colorBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                colorBtn.widthAnchor.constraint(equalToConstant: 16),
                colorBtn.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: colorBtn.trailingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                delBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                delBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -4),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        cell.textField?.stringValue = section.name

        if let colorBtn = cell.viewWithTag(100) as? NSButton {
            colorBtn.image = Self.colorDotImage(color: section.color, size: 12)
            colorBtn.target = self
            colorBtn.action = #selector(colorDotClicked(_:))
        }

        if let visBtn = cell.viewWithTag(101) as? NSButton {
            let symbolName = section.isVisible ? "eye" : "eye.slash"
            visBtn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visBtn.contentTintColor = section.isVisible ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
            visBtn.target = self
            visBtn.action = #selector(visibilityToggled(_:))
        }

        if let delBtn = cell.viewWithTag(102) as? NSButton {
            delBtn.isHidden = section.isDefault
            delBtn.target = self
            delBtn.action = #selector(deleteSectionTapped(_:))
        }

        return cell
    }
}
