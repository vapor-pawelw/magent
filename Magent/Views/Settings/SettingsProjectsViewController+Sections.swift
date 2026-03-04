import Cocoa

extension SettingsProjectsViewController {

    // MARK: - Sections Mode

    @objc func sectionsModeChanged() {
        guard let index = selectedProjectIndex else { return }
        let isCustom = sectionsModePopup.indexOfSelectedItem == 1

        if isCustom {
            if settings.projects[index].threadSections == nil {
                settings.projects[index].threadSections = settings.threadSections
            }
        } else {
            settings.projects[index].threadSections = nil
            settings.projects[index].defaultSectionId = nil
        }

        try? persistence.saveSettings(settings)
        sectionsContentStack.isHidden = !isCustom
        sectionsTableView?.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Add / Delete Sections

    @objc func addProjectSectionTapped() {
        guard let index = selectedProjectIndex else { return }

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

        var sections = settings.projects[index].threadSections ?? []
        let maxOrder = sections.map(\.sortOrder).max() ?? -1
        let section = ThreadSection(
            name: name,
            colorHex: "#8E8E93",
            sortOrder: maxOrder + 1
        )
        sections.append(section)
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

        showProjectColorPicker(for: section)
    }

    func threadsInProjectSection(_ section: ThreadSection, projectIndex: Int) -> [MagentThread] {
        let project = settings.projects[projectIndex]
        let sections = project.threadSections ?? []
        let knownIds = Set(sections.map(\.id))
        let defaultId = settings.defaultSection(for: project.id)?.id
        return ThreadManager.shared.threads.filter { thread in
            guard !thread.isMain, thread.projectId == project.id else { return false }
            let effectiveId: UUID?
            if let sid = thread.sectionId, knownIds.contains(sid) {
                effectiveId = sid
            } else {
                effectiveId = defaultId
            }
            return effectiveId == section.id
        }
    }

    @objc func deleteProjectSectionTapped(_ sender: NSButton) {
        guard let index = selectedProjectIndex else { return }
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = projectSortedSections[row]
        guard var sections = settings.projects[index].threadSections else { return }

        guard sections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let threadsInSection = threadsInProjectSection(section, projectIndex: index)
        if !threadsInSection.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "Move all threads out of \"\(section.name)\" before deleting it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if settings.projects[index].defaultSectionId == section.id {
            settings.projects[index].defaultSectionId = nil
        }
        sections.removeAll { $0.id == section.id }
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Visibility

    @objc func projectSectionVisibilityToggled(_ sender: NSButton) {
        guard let index = selectedProjectIndex else { return }
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = projectSortedSections[row]
        guard var sections = settings.projects[index].threadSections,
              let sectionIndex = sections.firstIndex(where: { $0.id == section.id }) else { return }

        if section.isVisible {
            let threadsHere = threadsInProjectSection(section, projectIndex: index)
            if !threadsHere.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Cannot Hide Section"
                alert.informativeText = "Move all threads out of \"\(section.name)\" before hiding it."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
        }

        sections[sectionIndex].isVisible.toggle()
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
        refreshDefaultSectionPopup(for: settings.projects[index])
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Color Picker

    @objc func projectSectionColorDotClicked(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }
        showProjectColorPicker(for: projectSortedSections[row])
    }

    func showProjectColorPicker(for section: ThreadSection) {
        let panel = NSColorPanel.shared
        panel.color = section.color
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(projectSectionColorChanged(_:)))
        currentEditingSectionId = section.id
        panel.orderFront(nil)
    }

    @objc func projectSectionColorChanged(_ sender: NSColorPanel) {
        guard let sectionId = currentEditingSectionId,
              let index = selectedProjectIndex,
              var sections = settings.projects[index].threadSections,
              let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }

        sections[sectionIndex].colorHex = sender.color.hexString
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }
}
