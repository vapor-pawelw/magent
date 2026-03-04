import Cocoa

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
            visBtn.tag = 100
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: visBtn.leadingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                visBtn.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                visBtn.centerYAnchor.constraint(equalTo: c.centerYAnchor),
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
        let identifier = NSUserInterfaceItemIdentifier("ProjectSectionCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier

            let colorBtn = NSButton()
            colorBtn.bezelStyle = .inline
            colorBtn.isBordered = false
            colorBtn.tag = 200
            colorBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(colorBtn)

            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf

            let visBtn = NSButton(image: NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!, target: nil, action: nil)
            visBtn.bezelStyle = .inline
            visBtn.isBordered = false
            visBtn.tag = 201
            visBtn.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(visBtn)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: nil, action: nil)
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            delBtn.tag = 202
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
        } else if textView === slugPromptTextView {
            settings.projects[index].autoRenameSlugPrompt = textView.string
        }

        try? persistence.saveSettings(settings)
    }
}
