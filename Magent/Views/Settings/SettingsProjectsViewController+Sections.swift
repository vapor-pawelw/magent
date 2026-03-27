import Cocoa
import MagentCore

extension SettingsProjectsViewController {

    // MARK: - Sections Mode

    func updateSectionsVisibilityControls(for project: Project) {
        let sectionsEnabled = settings.shouldUseThreadSections(for: project.id)
        defaultSectionContainer?.isHidden = !sectionsEnabled
        sectionsOverridesStack?.isHidden = !sectionsEnabled
        jiraSectionsSyncControlsStack?.isHidden = !sectionsEnabled
        sectionsContentStack?.isHidden = !sectionsEnabled || project.threadSections == nil
    }

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
        updateSectionsVisibilityControls(for: settings.projects[index])
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

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var sections = settings.projects[index].threadSections ?? []
        if sections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let dupAlert = NSAlert()
            dupAlert.messageText = "Duplicate Section"
            dupAlert.informativeText = "A section named \"\(name)\" already exists."
            dupAlert.alertStyle = .warning
            dupAlert.addButton(withTitle: "OK")
            dupAlert.runModal()
            return
        }

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
        return ThreadManager.shared.threadsAssigned(
            toSection: section.id,
            projectId: project.id,
            settings: settings
        )
    }

    @objc func deleteProjectSectionTapped(_ sender: NSButton) {
        guard let index = selectedProjectIndex else { return }
        let point = sender.convert(NSPoint.zero, to: sectionsTableView)
        let row = sectionsTableView.row(at: point)
        guard row >= 0 else { return }

        let section = projectSortedSections[row]
        guard var sections = settings.projects[index].threadSections else { return }
        guard let defaultSection = settings.defaultSection(for: settings.projects[index].id) else { return }

        guard sections.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Cannot Delete Section"
            alert.informativeText = "At least one section is required."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard defaultSection.id != section.id else { return }

        let threadCount = threadsInProjectSection(section, projectIndex: index).count
        if threadCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Delete Section?"
            alert.informativeText = threadCount == 1
                ? "Delete \"\(section.name)\"? 1 thread will be moved to \"\(defaultSection.name)\"."
                : "Delete \"\(section.name)\"? \(threadCount) threads will be moved to \"\(defaultSection.name)\"."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        ThreadManager.shared.reassignThreadsAssigned(
            toSection: section.id,
            toSection: defaultSection.id,
            projectId: settings.projects[index].id,
            settings: settings
        )

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
        panel.orderOut(nil)
        currentEditingSectionId = section.id
        isUpdatingSectionColorPanel = true
        panel.identifier = Self.sectionColorPanelIdentifier
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = section.color
        panel.setTarget(self)
        panel.setAction(#selector(projectSectionColorChanged(_:)))
        isUpdatingSectionColorPanel = false
        panel.orderFront(nil)
    }

    @objc func projectSectionColorChanged(_ sender: NSColorPanel) {
        guard !isUpdatingSectionColorPanel else { return }
        guard let sectionId = currentEditingSectionId,
              let index = selectedProjectIndex,
              var sections = settings.projects[index].threadSections,
              let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }

        sections[sectionIndex].colorHex = sender.color.hexString
        settings.projects[index].threadSections = sections
        try? persistence.saveSettings(settings)
        sectionsTableView.reloadData()
    }

    func dismissProjectSectionColorPickerIfNeeded() {
        currentEditingSectionId = nil
        isUpdatingSectionColorPanel = false

        let panel = NSColorPanel.shared
        guard panel.identifier == Self.sectionColorPanelIdentifier else { return }
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.identifier = nil
        panel.orderOut(nil)
    }
}
