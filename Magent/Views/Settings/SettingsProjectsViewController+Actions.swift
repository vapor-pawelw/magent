import Cocoa

extension SettingsProjectsViewController {

    // MARK: - Add / Remove Projects

    @objc func addProjectTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository folder"

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path

            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        let project = Project(
                            name: url.lastPathComponent,
                            repoPath: path,
                            worktreesBasePath: Project.suggestedWorktreesPath(for: path),
                            defaultBranch: defaultBranch
                        )
                        self.settings.projects.append(project)
                        try? self.persistence.saveSettings(self.settings)
                        self.reloadProjectsAndSelect(row: self.settings.projects.count - 1)

                        Task { try? await ThreadManager.shared.createMainThread(project: project) }
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Not a Git Repository"
                        alert.informativeText = "The selected folder is not a git repository."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc func removeProjectTapped() {
        guard let index = selectedProjectIndex else { return }
        let project = settings.projects[index]

        let alert = NSAlert()
        alert.messageText = "Remove Project?"
        alert.informativeText = "Remove \"\(project.name)\" from Magent? This won't delete the repository."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        settings.projects.remove(at: index)
        try? persistence.saveSettings(settings)
        if settings.projects.isEmpty {
            reloadProjectsAndSelect()
        } else {
            reloadProjectsAndSelect(row: min(index, settings.projects.count - 1))
        }
    }

    @objc func toggleProjectVisibility(_ sender: NSButton) {
        let point = sender.convert(NSPoint.zero, to: projectTableView)
        let row = projectTableView.row(at: point)
        guard row >= 0, row < settings.projects.count else { return }

        settings.projects[row].isHidden.toggle()
        try? persistence.saveSettings(settings)
        projectTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Field Handlers

    @objc func nameFieldChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        settings.projects[index].name = value
        try? persistence.saveSettings(settings)
        reloadProjectsAndSelect(row: index)
    }

    @objc func defaultBranchFieldChanged() {
        guard let index = selectedProjectIndex else { return }
        let value = defaultBranchField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.projects[index].defaultBranch = value.isEmpty ? nil : value
        try? persistence.saveSettings(settings)
    }

    @objc func agentTypeOverrideChanged() {
        guard let index = selectedProjectIndex, let agentTypePopup else { return }
        let activeAgents = settings.availableActiveAgents
        let selected = agentTypePopup.indexOfSelectedItem
        if selected == 0 {
            settings.projects[index].agentType = nil
        } else {
            let typeIndex = selected - 1
            if typeIndex >= 0, typeIndex < activeAgents.count {
                settings.projects[index].agentType = activeAgents[typeIndex]
            }
        }
        try? persistence.saveSettings(settings)
    }

    @objc func threadListLayoutOverrideChanged() {
        guard let index = selectedProjectIndex else { return }
        switch threadListLayoutPopup.indexOfSelectedItem {
        case 1:
            settings.projects[index].useThreadSectionsOverride = true
        case 2:
            settings.projects[index].useThreadSectionsOverride = false
        default:
            settings.projects[index].useThreadSectionsOverride = nil
        }
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc func slugPromptCheckboxToggled() {
        guard let index = selectedProjectIndex else { return }
        let enabled = slugPromptCheckbox.state == .on
        if enabled {
            let globalPrompt = settings.autoRenameSlugPrompt
            settings.projects[index].autoRenameSlugPrompt = globalPrompt
            slugPromptTextView.string = globalPrompt
            slugPromptTextView.isEditable = true
        } else {
            settings.projects[index].autoRenameSlugPrompt = nil
            slugPromptTextView.string = settings.autoRenameSlugPrompt
            slugPromptTextView.isEditable = false
        }
        slugPromptContainer.isHidden = !enabled
        try? persistence.saveSettings(settings)
    }

    @objc func resetSlugPromptToGlobal() {
        guard let index = selectedProjectIndex else { return }
        let globalPrompt = settings.autoRenameSlugPrompt
        slugPromptTextView.string = globalPrompt
        settings.projects[index].autoRenameSlugPrompt = globalPrompt
        try? persistence.saveSettings(settings)
    }

    // MARK: - Default Section

    func refreshDefaultSectionPopup(for project: Project) {
        defaultSectionPopup.removeAllItems()
        defaultSectionPopup.addItem(withTitle: "Inherit global")
        let visible = settings.visibleSections(for: project.id)
        for section in visible {
            defaultSectionPopup.addItem(withTitle: section.name)
        }
        if let id = project.defaultSectionId,
           let idx = visible.firstIndex(where: { $0.id == id }) {
            defaultSectionPopup.selectItem(at: idx + 1) // +1 for "Inherit global"
        } else {
            defaultSectionPopup.selectItem(at: 0)
        }
    }

    @objc func defaultSectionChanged() {
        guard let index = selectedProjectIndex else { return }
        let selected = defaultSectionPopup.indexOfSelectedItem
        if selected == 0 {
            settings.projects[index].defaultSectionId = nil
        } else {
            let visible = settings.visibleSections(for: settings.projects[index].id)
            let sectionIndex = selected - 1
            if sectionIndex >= 0, sectionIndex < visible.count {
                settings.projects[index].defaultSectionId = visible[sectionIndex].id
            }
        }
        try? persistence.saveSettings(settings)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Browse Paths

    @objc func browseRepoPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.projects[index].repoPath)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let path = url.path
            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        self.settings.projects[index].repoPath = path
                        self.settings.projects[index].defaultBranch = defaultBranch
                        try? self.persistence.saveSettings(self.settings)
                        self.reloadProjectsAndSelect(row: index)
                        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                        Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index]) }
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Not a Git Repository"
                        alert.informativeText = "The selected folder is not a git repository."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc func browseWorktreesPath() {
        guard let index = selectedProjectIndex else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let oldResolved = settings.projects[index].resolvedWorktreesBasePath()
        panel.directoryURL = URL(fileURLWithPath: oldResolved)

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let newPath = url.path

            // No-op if paths are the same
            guard newPath != oldResolved else { return }

            let project = self.settings.projects[index]
            let fm = FileManager.default
            var oldHasWorktrees = false
            if fm.fileExists(atPath: oldResolved) {
                let contents = (try? fm.contentsOfDirectory(atPath: oldResolved)) ?? []
                oldHasWorktrees = contents.contains { entry in
                    entry != ".magent-cache.json" && !entry.hasPrefix(".")
                }
            }

            if oldHasWorktrees {
                Task {
                    do {
                        try await ThreadManager.shared.moveWorktreesBasePath(
                            for: project, from: oldResolved, to: newPath
                        )
                    } catch let error as ThreadManagerError {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Cannot Change Worktrees Path"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = self.view.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                        return
                    } catch {
                        await MainActor.run {
                            let alert = NSAlert()
                            alert.messageText = "Failed to Move Worktrees"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: "OK")
                            if let window = self.view.window {
                                alert.beginSheetModal(for: window)
                            }
                        }
                        return
                    }

                    await MainActor.run {
                        self.settings.projects[index].worktreesBasePath = newPath
                        try? self.persistence.saveSettings(self.settings)
                        self.showDetailForProject(self.settings.projects[index])
                    }

                    await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index])
                }
            } else {
                // No worktrees to move — just update the setting
                self.settings.projects[index].worktreesBasePath = newPath
                try? self.persistence.saveSettings(self.settings)
                self.showDetailForProject(self.settings.projects[index])
                Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: self.settings.projects[index]) }
            }
        }
    }
}
