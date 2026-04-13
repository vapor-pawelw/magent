import Cocoa
import MagentCore

extension SettingsProjectsViewController {

    // MARK: - Add / Remove Projects

    @objc func addProjectTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository folder"

        let handleSelection: (URL) -> Void = { [weak self] url in
            guard let self else { return }
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
                        guard self.mutateSettings({ settings in
                            settings.projects.append(project)
                        }) else { return }
                        self.currentProjectID = project.id
                        self.reloadProjectsAndSelect()

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

        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                handleSelection(url)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            handleSelection(url)
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

        guard mutateSettings({ settings in
            settings.projects.removeAll { $0.id == project.id }
        }) else { return }
        currentProjectID = nil
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

        let projectID = settings.projects[row].id
        var isNowHidden = false
        guard mutateSettings({ settings in
            guard let index = settings.projects.firstIndex(where: { $0.id == projectID }) else { return }
            settings.projects[index].isHidden.toggle()
            isNowHidden = settings.projects[index].isHidden
        }) else { return }
        projectTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
        NotificationCenter.default.post(
            name: .magentProjectVisibilityDidChange,
            object: nil,
            userInfo: [
                "projectId": projectID,
                "isHidden": isNowHidden
            ]
        )
    }

    // MARK: - Field Handlers

    @objc func nameFieldChanged() {
        let value = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        guard mutateSelectedProject({ settings, index in
            settings.projects[index].name = value
        }) != nil else { return }
        reloadProjectsAndSelect()
    }

    @objc func defaultBranchFieldChanged() {
        let value = defaultBranchField.stringValue.trimmingCharacters(in: .whitespaces)
        _ = mutateSelectedProject { settings, index in
            settings.projects[index].defaultBranch = value.isEmpty ? nil : value
        }
    }

    @objc func addLocalSyncEntryRow() {
        let entries = visibleLocalSyncEntries() + [LocalFileSyncEntry(path: "", mode: .copy)]
        rebuildLocalSyncEntryRows(for: entries)
    }

    @objc func addLocalSyncPathsFromRepo() {
        guard let index = selectedProjectIndex,
              let window = view.window else { return }

        let project = settings.projects[index]
        let repoURL = URL(fileURLWithPath: project.repoPath).standardizedFileURL

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = repoURL
        panel.message = "Select files or folders inside the repository"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }

            var invalidSelections: [String] = []
            let newEntries: [LocalFileSyncEntry] = panel.urls.compactMap { url in
                let standardizedURL = url.standardizedFileURL
                let path = standardizedURL.path
                guard path == repoURL.path || path.hasPrefix(repoURL.path + "/") else {
                    invalidSelections.append(path)
                    return nil
                }

                let relativePath = path == repoURL.path
                    ? ""
                    : String(path.dropFirst(repoURL.path.count + 1))
                guard let entry = Project.normalizeLocalFileSyncEntry(LocalFileSyncEntry(path: relativePath, mode: .copy)) else {
                    invalidSelections.append(path)
                    return nil
                }
                return entry
            }

            let updatedProject = self.mutateSelectedProject { settings, index in
                settings.projects[index].localFileSyncEntries = Project.normalizeLocalFileSyncEntries(
                    self.visibleLocalSyncEntries() + newEntries
                )
            }
            guard let updatedProject else { return }
            self.rebuildLocalSyncEntryRows(for: updatedProject.normalizedLocalFileSyncEntries)

            guard !invalidSelections.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Some paths were skipped"
            alert.informativeText = invalidSelections.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc func agentTypeOverrideChanged() {
        guard let agentTypePopup else { return }
        let activeAgents = settings.availableActiveAgents
        let selected = agentTypePopup.indexOfSelectedItem
        _ = mutateSelectedProject { settings, index in
            if selected == 0 {
                settings.projects[index].agentType = nil
            } else {
                let typeIndex = selected - 1
                if typeIndex >= 0, typeIndex < activeAgents.count {
                    settings.projects[index].agentType = activeAgents[typeIndex]
                }
            }
        }
    }

    @objc func threadListLayoutOverrideChanged() {
        guard let project = mutateSelectedProject({ settings, index in
            switch threadListLayoutPopup.indexOfSelectedItem {
            case 1:
                settings.projects[index].useThreadSectionsOverride = true
            case 2:
                settings.projects[index].useThreadSectionsOverride = false
            default:
                settings.projects[index].useThreadSectionsOverride = nil
            }
        }) else { return }
        updateSectionsVisibilityControls(for: project)
        refreshDefaultSectionPopup(for: project)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    @objc func slugPromptCheckboxToggled() {
        let enabled = slugPromptCheckbox.state == .on
        let globalPrompt = settings.autoRenameSlugPrompt
        if enabled {
            slugPromptTextView.string = globalPrompt
            slugPromptTextView.isEditable = true
        } else {
            slugPromptTextView.string = globalPrompt
            slugPromptTextView.isEditable = false
        }
        slugPromptContainer.isHidden = !enabled
        _ = mutateSelectedProject { settings, index in
            settings.projects[index].autoRenameSlugPrompt = enabled ? globalPrompt : nil
        }
    }

    @objc func resetSlugPromptToGlobal() {
        let globalPrompt = settings.autoRenameSlugPrompt
        slugPromptTextView.string = globalPrompt
        _ = mutateSelectedProject { settings, index in
            settings.projects[index].autoRenameSlugPrompt = globalPrompt
        }
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
        let selected = defaultSectionPopup.indexOfSelectedItem
        guard let project = mutateSelectedProject({ settings, index in
            if selected == 0 {
                settings.projects[index].defaultSectionId = nil
            } else {
                let visible = settings.visibleSections(for: settings.projects[index].id)
                let sectionIndex = selected - 1
                if sectionIndex >= 0, sectionIndex < visible.count {
                    settings.projects[index].defaultSectionId = visible[sectionIndex].id
                }
            }
        }) else { return }
        sectionsTableView?.reloadData()
        refreshDefaultSectionPopup(for: project)
        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
    }

    // MARK: - Browse Paths

    @objc func browseRepoPath() {
        guard let project = selectedProject else { return }
        let projectID = project.id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: project.repoPath)

        let handleSelection: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            let path = url.path
            Task {
                let isRepo = await GitService.shared.isGitRepository(at: path)
                let defaultBranch = isRepo ? await GitService.shared.detectDefaultBranch(repoPath: path) : nil
                await MainActor.run {
                    if isRepo {
                        self.currentProjectID = projectID
                        guard let updatedProject = self.mutateSelectedProject({ settings, index in
                            settings.projects[index].repoPath = path
                            settings.projects[index].defaultBranch = defaultBranch
                        }) else { return }
                        self.reloadProjectsAndSelect()
                        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                        Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: updatedProject) }
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

        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                handleSelection(url)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            handleSelection(url)
        }
    }

    @objc func browseWorktreesPath() {
        guard let project = selectedProject else { return }
        let projectID = project.id
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let oldResolved = project.resolvedWorktreesBasePath()
        panel.directoryURL = URL(fileURLWithPath: oldResolved)

        let handleSelection: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            let newPath = url.path

            // No-op if paths are the same
            guard newPath != oldResolved else { return }

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
                        self.currentProjectID = projectID
                        if let updatedProject = self.mutateSelectedProject({ settings, index in
                            settings.projects[index].worktreesBasePath = newPath
                        }) {
                            self.showDetailForProject(updatedProject)
                        }
                    }

                    if let refreshedProject = await MainActor.run(body: { () -> Project? in
                        self.currentProjectID = projectID
                        self.settings = self.persistence.loadSettings()
                        return self.settings.projects.first(where: { $0.id == projectID })
                    }) {
                        await ThreadManager.shared.syncThreadsWithWorktrees(for: refreshedProject)
                    }
                }
            } else {
                // No worktrees to move — just update the setting
                self.currentProjectID = projectID
                guard let updatedProject = self.mutateSelectedProject({ settings, index in
                    settings.projects[index].worktreesBasePath = newPath
                }) else { return }
                self.showDetailForProject(updatedProject)
                Task { await ThreadManager.shared.syncThreadsWithWorktrees(for: updatedProject) }
            }
        }

        if let window = view.window {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                handleSelection(url)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let url = panel.url else { return }
            handleSelection(url)
        }
    }
}
