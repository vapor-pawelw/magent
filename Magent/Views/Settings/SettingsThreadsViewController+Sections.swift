import Cocoa
import MagentCore

extension SettingsThreadsViewController {

    @objc func sectionTableDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < sortedSections.count, sectionNameWasDoubleClicked(in: sender, row: row) else { return }
        beginInlineRename(for: sortedSections[row].id)
    }

    private func sectionNameWasDoubleClicked(in tableView: NSTableView, row: Int) -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        let pointInTable = tableView.convert(event.locationInWindow, from: nil)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let label = cell.viewWithTag(Self.sectionNameLabelTag) else { return false }
        let pointInCell = cell.convert(pointInTable, from: tableView)
        return label.frame.insetBy(dx: -2, dy: -2).contains(pointInCell)
    }

    private func beginInlineRename(for sectionId: UUID) {
        if let activeInlineRenameSectionId, activeInlineRenameSectionId != sectionId {
            finishInlineRename(commit: true)
        }
        activeInlineRenameSectionId = sectionId
        sectionsTableView.reloadData()
        focusInlineRenameField(selectAll: true)
    }

    private func focusInlineRenameField(selectAll: Bool) {
        guard let field = inlineRenameField() else { return }
        view.window?.makeFirstResponder(field)
        if selectAll {
            field.selectText(nil)
        }
    }

    private func inlineRenameField() -> NSTextField? {
        guard let sectionId = activeInlineRenameSectionId,
              let row = sortedSections.firstIndex(where: { $0.id == sectionId }),
              let cell = sectionsTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else {
            return nil
        }
        return cell.viewWithTag(Self.sectionInlineRenameFieldTag) as? NSTextField
    }

    private enum InlineRenameError: LocalizedError {
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

    func finishInlineRename(commit: Bool) {
        guard let sectionId = activeInlineRenameSectionId,
              let currentSection = settings.threadSections.first(where: { $0.id == sectionId }) else {
            activeInlineRenameSectionId = nil
            return
        }

        let rawValue = inlineRenameField()?.stringValue ?? currentSection.name
        let newName = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if !commit {
            activeInlineRenameSectionId = nil
            sectionsTableView.reloadData()
            return
        }

        do {
            try persistInlineRename(sectionId: sectionId, newName: newName, originalName: currentSection.name)
            activeInlineRenameSectionId = nil
            sectionsTableView.reloadData()
            refreshDefaultSectionPopup()
            NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Rename Section Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            sectionsTableView.reloadData()
            focusInlineRenameField(selectAll: true)
        }
    }

    private func persistInlineRename(sectionId: UUID, newName: String, originalName: String) throws {
        guard !newName.isEmpty else { throw InlineRenameError.emptyName }
        if newName == originalName { return }
        if settings.threadSections.contains(where: {
            $0.id != sectionId && $0.name.caseInsensitiveCompare(newName) == .orderedSame
        }) {
            throw InlineRenameError.duplicateName(newName)
        }
        guard let index = settings.threadSections.firstIndex(where: { $0.id == sectionId }) else { return }
        settings.threadSections[index].name = newName
        try persistence.saveSettings(settings)
    }

    private func threadsInGlobalSection(_ section: ThreadSection) -> [MagentThread] {
        ThreadManager.shared.threadsAssigned(toSection: section.id, settings: settings)
    }

    @objc private func visibilityToggled(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard let index = settings.threadSections.firstIndex(where: { $0.id == section.id }) else { return }

        if section.isVisible {
            let threadsInSection = threadsInGlobalSection(section)
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
        refreshDefaultSectionPopup()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func deleteSectionTapped(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]
        guard let defaultSection = settings.defaultSection else { return }

        guard settings.threadSections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard defaultSection.id != section.id else { return }

        let threadCount = threadsInGlobalSection(section).count
        let alert = NSAlert()
        alert.messageText = "Delete Section?"
        alert.informativeText = threadCount == 1
            ? "Delete \"\(section.name)\"? 1 thread will be moved to \"\(defaultSection.name)\"."
            : "Delete \"\(section.name)\"? \(threadCount) threads will be moved to \"\(defaultSection.name)\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        ThreadManager.shared.reassignThreadsAssigned(
            toSection: section.id,
            toSection: defaultSection.id,
            settings: settings
        )

        settings.threadSections.removeAll { $0.id == section.id }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func colorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }
        showColorPicker(for: sortedSections[row])
    }

    func showColorPicker(for section: ThreadSection) {
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        currentEditingSectionId = section.id
        isUpdatingSectionColorPanel = true
        panel.identifier = Self.sectionColorPanelIdentifier
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = section.color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        isUpdatingSectionColorPanel = false
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard !isUpdatingSectionColorPanel else { return }
        guard let sectionId = currentEditingSectionId,
              let index = settings.threadSections.firstIndex(where: { $0.id == sectionId }) else { return }

        settings.threadSections[index].colorHex = sender.color.hexString
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    func dismissSectionColorPickerIfNeeded() {
        currentEditingSectionId = nil
        isUpdatingSectionColorPanel = false

        let panel = NSColorPanel.shared
        guard panel.identifier == Self.sectionColorPanelIdentifier else { return }
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.identifier = nil
        panel.orderOut(nil)
    }

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

        let previousDefaultId = settings.defaultSection?.id
        var sections = sortedSections
        let moved = sections.remove(at: sourceRow)
        let dest = sourceRow < row ? row - 1 : row
        sections.insert(moved, at: dest)

        for (i, section) in sections.enumerated() {
            if let idx = settings.threadSections.firstIndex(where: { $0.id == section.id }) {
                settings.threadSections[idx].sortOrder = i
            }
        }
        if settings.defaultSectionId == nil {
            settings.defaultSectionId = previousDefaultId
        }
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sortedSections[row]
        let currentDefaultSectionId = settings.defaultSection?.id
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
                editor.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: visBtn.leadingAnchor, constant: -8),
                editor.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                delBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                delBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor, constant: -4),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
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

        if let colorBtn = cell.viewWithTag(100) as? NSButton {
            colorBtn.image = colorDotImage(color: section.color, size: 12)
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
            let isDefaultSection = section.id == currentDefaultSectionId
            delBtn.isHidden = isDefaultSection
            delBtn.isEnabled = !isDefaultSection
            delBtn.target = self
            delBtn.action = #selector(deleteSectionTapped(_:))
        }

        return cell
    }
}

extension SettingsThreadsViewController: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control.tag == Self.sectionInlineRenameFieldTag else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(nil)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineRename(commit: false)
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.tag == Self.sectionInlineRenameFieldTag else { return }

        let movementValue = notification.userInfo?["NSTextMovement"] as? Int
        finishInlineRename(commit: movementValue != NSTextMovement.cancel.rawValue)
    }
}
