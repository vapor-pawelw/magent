import Cocoa
import MagentCore

extension SettingsThreadsViewController {

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
                return thread.resolvedSectionId(knownSectionIds: knownSectionIds, fallback: defaultSectionId) == section.id
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
        refreshDefaultSectionPopup()
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc private func deleteSectionTapped(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = sortedSections[row]

        guard settings.threadSections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let knownSectionIds = Set(settings.threadSections.map(\.id))
        let defaultSectionId = settings.defaultSection?.id
        let threadsInSection = ThreadManager.shared.threads.filter { thread in
            guard !thread.isMain else { return false }
            return thread.resolvedSectionId(knownSectionIds: knownSectionIds, fallback: defaultSectionId) == section.id
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

        if settings.defaultSectionId == section.id {
            settings.defaultSectionId = nil
        }
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
            delBtn.target = self
            delBtn.action = #selector(deleteSectionTapped(_:))
        }

        return cell
    }
}
