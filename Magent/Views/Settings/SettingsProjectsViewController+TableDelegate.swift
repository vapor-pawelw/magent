import Cocoa
import MagentCore

private enum SettingsProjectsTableLayout {
    static let horizontalInset: CGFloat = 4
    static let iconSpacing: CGFloat = 6
    static let iconButtonSize: CGFloat = 16
}

extension SettingsProjectsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sectionsTableView {
            return projectSortedSections.count
        }
        return settings.projects.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if tableView === projectTableView {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: Self.projectRowPasteboardType)
            return item
        }

        guard tableView === sectionsTableView else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.sectionRowPasteboardType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if tableView === projectTableView {
            return dropOperation == .above ? .move : []
        }

        guard tableView === sectionsTableView else { return [] }
        return dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === projectTableView {
            guard let item = info.draggingPasteboard.pasteboardItems?.first,
                  let rowStr = item.string(forType: Self.projectRowPasteboardType),
                  let sourceRow = Int(rowStr),
                  sourceRow >= 0,
                  sourceRow < settings.projects.count else { return false }

            let destinationRow = min(max(row, 0), settings.projects.count)
            if sourceRow == destinationRow || sourceRow + 1 == destinationRow {
                return false
            }

            let movedProject = settings.projects.remove(at: sourceRow)
            let insertIndex = sourceRow < destinationRow ? destinationRow - 1 : destinationRow
            settings.projects.insert(movedProject, at: insertIndex)
            try? persistence.saveSettings(settings)
            reloadProjectsAndSelect(row: insertIndex)
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
            return true
        }

        guard tableView === sectionsTableView,
              let index = selectedProjectIndex,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let rowStr = item.string(forType: Self.sectionRowPasteboardType),
              let sourceRow = Int(rowStr) else { return false }

        var sections = projectSortedSections
        let moved = sections.remove(at: sourceRow)
        let dest = sourceRow < row ? row - 1 : row
        sections.insert(moved, at: dest)

        for (i, section) in sections.enumerated() {
            if var projectSections = settings.projects[index].threadSections,
               let idx = projectSections.firstIndex(where: { $0.id == section.id }) {
                projectSections[idx].sortOrder = i
                settings.projects[index].threadSections = projectSections
            }
        }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        return true
    }
}

extension SettingsProjectsViewController: NSTableViewDelegate {
    @objc func projectSectionTableDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < projectSortedSections.count, projectSectionNameWasDoubleClicked(in: sender, row: row) else { return }
        beginInlineProjectSectionRename(for: projectSortedSections[row].id)
    }

    private func projectSectionNameWasDoubleClicked(in tableView: NSTableView, row: Int) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        let pointInTable = tableView.convert(event.locationInWindow, from: nil)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let label = cell.viewWithTag(Self.sectionNameLabelTag) else { return false }
        let pointInCell = cell.convert(pointInTable, from: tableView)
        return label.frame.insetBy(dx: -2, dy: -2).contains(pointInCell)
    }

    private func beginInlineProjectSectionRename(for sectionId: UUID) {
        if let activeInlineRenameSectionId, activeInlineRenameSectionId != sectionId {
            finishInlineProjectSectionRename(commit: true)
        }
        activeInlineRenameSectionId = sectionId
        sectionsTableView.reloadData()
        focusProjectInlineRenameField(selectAll: true)
    }

    private func focusProjectInlineRenameField(selectAll: Bool) {
        guard let field = projectInlineRenameField() else { return }
        view.window?.makeFirstResponder(field)
        if selectAll {
            field.selectText(nil)
        }
    }

    private func projectInlineRenameField() -> NSTextField? {
        guard let sectionId = activeInlineRenameSectionId,
              let row = projectSortedSections.firstIndex(where: { $0.id == sectionId }),
              let cell = sectionsTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return nil
        }
        return cell.viewWithTag(Self.sectionInlineRenameFieldTag) as? NSTextField
    }

    private enum InlineProjectRenameError: LocalizedError {
        case emptyName
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Section names cannot be empty."
            case .duplicateName(let name):
                return "A section named \"\(name)\" already exists."
            }
        }
    }

    func finishInlineProjectSectionRename(commit: Bool) {
        guard let sectionId = activeInlineRenameSectionId,
              let index = selectedProjectIndex,
              let currentSection = settings.projects[index].threadSections?.first(where: { $0.id == sectionId }) else {
            activeInlineRenameSectionId = nil
            return
        }

        let rawValue = projectInlineRenameField()?.stringValue ?? currentSection.name
        let newName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if !commit {
            activeInlineRenameSectionId = nil
            sectionsTableView.reloadData()
            return
        }

        do {
            try persistInlineProjectSectionRename(
                projectIndex: index,
                sectionId: sectionId,
                newName: newName,
                originalName: currentSection.name
            )
            activeInlineRenameSectionId = nil
            sectionsTableView.reloadData()
            refreshDefaultSectionPopup(for: settings.projects[index])
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Rename Section Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            sectionsTableView.reloadData()
            focusProjectInlineRenameField(selectAll: true)
        }
    }

    private func persistInlineProjectSectionRename(
        projectIndex: Int,
        sectionId: UUID,
        newName: String,
        originalName: String
    ) throws {
        guard !newName.isEmpty else { throw InlineProjectRenameError.emptyName }
        if newName == originalName { return }
        guard var sections = settings.projects[projectIndex].threadSections else { return }
        if sections.contains(where: {
            $0.id != sectionId && $0.name.caseInsensitiveCompare(newName) == .orderedSame
        }) {
            throw InlineProjectRenameError.duplicateName(newName)
        }
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[sectionIndex].name = newName
        settings.projects[projectIndex].threadSections = sections
        try persistence.saveSettings(settings)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sectionsTableView {
            return sectionsCellView(for: row, in: tableView)
        }

        let project = settings.projects[row]
        let identifier = NSUserInterfaceItemIdentifier("ProjectListCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.imagePosition = .imageOnly
            visBtn.imageScaling = .scaleProportionallyDown
            visBtn.setContentHuggingPriority(.required, for: .horizontal)
            visBtn.setContentHuggingPriority(.required, for: .vertical)
            visBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
            visBtn.setContentCompressionResistancePriority(.required, for: .vertical)
            visBtn.tag = 100
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: SettingsProjectsTableLayout.horizontalInset),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: visBtn.leadingAnchor, constant: -SettingsProjectsTableLayout.iconSpacing),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -SettingsProjectsTableLayout.horizontalInset),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.widthAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                visBtn.heightAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
            ])
            return c
        }()

        cell.textField?.stringValue = project.name
        if let visBtn = cell.viewWithTag(100) as? NSButton {
            let symbolName = project.isHidden ? "eye.slash" : "eye"
            visBtn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visBtn.contentTintColor = project.isHidden ? NSColor(resource: .textSecondary) : NSColor(resource: .textPrimary)
            visBtn.toolTip = project.isHidden ? "Show in sidebar" : "Hide from sidebar"
            visBtn.target = self
            visBtn.action = #selector(toggleProjectVisibility(_:))
        }

        if project.isValid {
            cell.textField?.textColor = project.isHidden ? NSColor(resource: .textSecondary) : .labelColor
        } else {
            cell.textField?.textColor = .systemRed
        }
        cell.alphaValue = project.isHidden ? 0.8 : 1.0
        return cell
    }

    func sectionsCellView(for row: Int, in tableView: NSTableView) -> NSView? {
        let section = projectSortedSections[row]
        let currentDefaultSectionId = selectedProject.flatMap { settings.defaultSection(for: $0.id)?.id }
        let identifier = NSUserInterfaceItemIdentifier("ProjectSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.imagePosition = .imageOnly
            colorBtn.imageScaling = .scaleProportionallyDown
            colorBtn.tag = 200
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            let tf = NSTextField(labelWithString: "")
            tf.tag = Self.sectionNameLabelTag
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            let editor = NSTextField(string: "")
            editor.tag = Self.sectionInlineRenameFieldTag
            editor.translatesAutoresizingMaskIntoConstraints = false
            editor.isHidden = true
            editor.delegate = self
            c.addSubview(editor)

            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.imagePosition = .imageOnly
            visBtn.imageScaling = .scaleProportionallyDown
            visBtn.setContentHuggingPriority(.required, for: .horizontal)
            visBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
            visBtn.tag = 201
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.imagePosition = .imageOnly
            delBtn.imageScaling = .scaleProportionallyDown
            delBtn.setContentHuggingPriority(.required, for: .horizontal)
            delBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
            delBtn.tag = 202
            delBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(delBtn)

            NSLayoutConstraint.activate([
                colorBtn.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: SettingsProjectsTableLayout.horizontalInset),
                colorBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                colorBtn.widthAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                colorBtn.heightAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                tf.leadingAnchor.constraint(equalTo: colorBtn.trailingAnchor, constant: 8),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: delBtn.leadingAnchor, constant: -SettingsProjectsTableLayout.iconSpacing),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                editor.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -SettingsProjectsTableLayout.iconSpacing),
                editor.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -SettingsProjectsTableLayout.horizontalInset),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.widthAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                visBtn.heightAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                delBtn.trailingAnchor.constraint(equalTo: visBtn.leadingAnchor, constant: -SettingsProjectsTableLayout.iconSpacing),
                delBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                delBtn.widthAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
                delBtn.heightAnchor.constraint(equalToConstant: SettingsProjectsTableLayout.iconButtonSize),
            ])
            return c
        }()

        cell.textField?.stringValue = section.name
        cell.textField?.isHidden = activeInlineRenameSectionId == section.id

        if let editor = cell.viewWithTag(Self.sectionInlineRenameFieldTag) as? NSTextField {
            let isEditing = activeInlineRenameSectionId == section.id
            editor.isHidden = !isEditing
            editor.stringValue = isEditing ? section.name : ""
            editor.placeholderString = "Section name"
        }

        if let colorBtn = cell.viewWithTag(200) as? NSButton {
            colorBtn.image = colorDotImage(color: section.color, size: 12)
            colorBtn.target = self
            colorBtn.action = #selector(projectSectionColorDotClicked(_:))
        }

        if let visBtn = cell.viewWithTag(201) as? NSButton {
            let symbolName = section.isVisible ? "eye" : "eye.slash"
            visBtn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            visBtn.contentTintColor = section.isVisible ? NSColor(resource: .textPrimary) : NSColor(resource: .textSecondary)
            visBtn.target = self
            visBtn.action = #selector(projectSectionVisibilityToggled(_:))
        }

        if let delBtn = cell.viewWithTag(202) as? NSButton {
            let isDefaultSection = section.id == currentDefaultSectionId
            delBtn.isHidden = isDefaultSection
            delBtn.isEnabled = !isDefaultSection
            delBtn.target = self
            delBtn.action = #selector(deleteProjectSectionTapped(_:))
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView === projectTableView else { return }
        updateRemoveButtonState()
        guard let project = selectedProject else {
            showEmptyState()
            return
        }
        showDetailForProject(project)
    }
}

extension SettingsProjectsViewController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let index = selectedProjectIndex else { return }

        if textView === terminalInjectionTextView {
            let value = textView.string
            settings.projects[index].terminalInjectionCommand = value.isEmpty ? nil : value
        } else if textView === preAgentInjectionTextView {
            let value = textView.string
            settings.projects[index].preAgentInjectionCommand = value.isEmpty ? nil : value
        } else if textView === agentContextTextView {
            let value = textView.string
            settings.projects[index].agentContextInjection = value.isEmpty ? nil : value
        } else if textView === localFileSyncPathsTextView {
            let rawPaths = textView.string.components(separatedBy: .newlines)
            settings.projects[index].localFileSyncPaths = Project.normalizeLocalFileSyncPaths(rawPaths)
        } else if textView === slugPromptTextView {
            settings.projects[index].autoRenameSlugPrompt = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}

extension SettingsProjectsViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control.tag == Self.sectionInlineRenameFieldTag else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(nil)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineProjectSectionRename(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.tag == Self.sectionInlineRenameFieldTag else { return }

        let movementValue = notification.userInfo?["NSTextMovement"] as? Int
        finishInlineProjectSectionRename(commit: movementValue != NSTextMovement.cancel.rawValue)
    }
}
