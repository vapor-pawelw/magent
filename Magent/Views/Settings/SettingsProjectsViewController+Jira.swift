import Cocoa
import MagentCore

extension SettingsProjectsViewController {

    // MARK: - Jira Field Handlers

    @objc func jiraProjectKeyChanged() {
        let value = jiraProjectKeyField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        jiraProjectKeyField.stringValue = value
        _ = mutateSelectedProject { settings, index in
            settings.projects[index].jiraProjectKey = value.isEmpty ? nil : value
        }
    }

    @objc func jiraBoardChanged() {
        let selected = jiraBoardPopup.indexOfSelectedItem
        _ = mutateSelectedProject { settings, index in
            if selected >= 0, selected < jiraBoards.count {
                let board = jiraBoards[selected]
                settings.projects[index].jiraBoardId = board.id
                settings.projects[index].jiraBoardName = board.name
            } else {
                settings.projects[index].jiraBoardId = nil
                settings.projects[index].jiraBoardName = nil
            }
        }
    }

    @objc func refreshBoardsTapped() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            jiraBoardPopup.removeAllItems()
            jiraBoardPopup.addItem(withTitle: "Loading...")

            do {
                let boards = try await JiraService.shared.listBoards()
                self.jiraBoards = boards

                jiraBoardPopup.removeAllItems()
                if boards.isEmpty {
                    jiraBoardPopup.addItem(withTitle: "No boards found")
                } else {
                    for board in boards {
                        jiraBoardPopup.addItem(withTitle: "\(board.name) (#\(board.id))")
                    }
                    // Select current board if set
                    if let index = selectedProjectIndex,
                       let currentId = settings.projects[index].jiraBoardId,
                       let boardIndex = boards.firstIndex(where: { $0.id == currentId }) {
                        jiraBoardPopup.selectItem(at: boardIndex)
                    }
                }
            } catch {
                jiraBoardPopup.removeAllItems()
                jiraBoardPopup.addItem(withTitle: "Error: \(error.localizedDescription)")
            }
        }
    }

    @objc func jiraAssigneeChanged() {
        let value = jiraAssigneeField.stringValue.trimmingCharacters(in: .whitespaces)
        _ = mutateSelectedProject { settings, index in
            settings.projects[index].jiraAssigneeAccountId = value.isEmpty ? nil : value
        }
    }

    // MARK: - Sync

    @objc func syncSectionsFromJiraTapped() {
        guard let index = selectedProjectIndex else { return }
        let project = settings.projects[index]

        guard project.jiraProjectKey?.isEmpty == false else {
            BannerManager.shared.show(message: "Set a Jira project key first", style: .warning, duration: 3.0)
            return
        }

        jiraSyncButton.isEnabled = false
        jiraSyncButton.title = "Syncing..."

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                jiraSyncButton.isEnabled = true
                jiraSyncButton.title = "Sync Sections from Jira"
            }

            do {
                let sections = try await ThreadManager.shared.syncSectionsFromJira(project: project)
                guard !sections.isEmpty else {
                    BannerManager.shared.show(message: "No statuses found for \(project.jiraProjectKey ?? "")", style: .warning, duration: 3.0)
                    return
                }

                guard let project = mutateSelectedProject({ settings, index in
                    settings.projects[index].threadSections = sections
                    settings.projects[index].jiraAcknowledgedStatuses = nil
                }) else { return }
                NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

                // Update sections card UI
                sectionsModePopup?.selectItem(at: 1)
                updateSectionsVisibilityControls(for: project)
                sectionsTableView?.reloadData()
                refreshDefaultSectionPopup(for: project)

                BannerManager.shared.show(
                    message: "Created \(sections.count) sections from Jira statuses",
                    style: .info,
                    duration: 3.0
                )
            } catch {
                BannerManager.shared.show(
                    message: "Failed to sync: \(error.localizedDescription)",
                    style: .error,
                    duration: 5.0
                )
            }
        }
    }

    @objc func jiraAutoSyncToggled() {
        guard let index = selectedProjectIndex else { return }
        let enabling = jiraAutoSyncCheckbox.state == .on

        if enabling {
            let project = settings.projects[index]
            var missing: [String] = []
            if project.jiraProjectKey?.isEmpty != false { missing.append("Project Key") }
            if project.jiraAssigneeAccountId?.isEmpty != false { missing.append("Assignee Account ID") }
            let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
            if siteURL.isEmpty { missing.append("Jira Site URL (set in Settings > Jira)") }

            if !missing.isEmpty {
                jiraAutoSyncCheckbox.state = .off
                BannerManager.shared.show(
                    message: "Cannot enable sync — missing: \(missing.joined(separator: ", "))",
                    style: .warning,
                    duration: 5.0
                )
                return
            }
        }

        guard let updatedProject = mutateSelectedProject({ settings, index in
            settings.projects[index].jiraSyncEnabled = enabling
        }) else { return }

        // Auto-create project sections from Jira when enabling sync and no custom sections exist
        if enabling, updatedProject.threadSections == nil {
            let project = updatedProject
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let sections = try await ThreadManager.shared.syncSectionsFromJira(project: project)
                    guard !sections.isEmpty else { return }
                    guard let refreshedProject = mutateSelectedProject({ settings, index in
                        settings.projects[index].threadSections = sections
                    }) else { return }
                    NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)

                    // Update sections card UI
                    sectionsModePopup?.selectItem(at: 1)
                    updateSectionsVisibilityControls(for: refreshedProject)
                    sectionsTableView?.reloadData()
                    refreshDefaultSectionPopup(for: refreshedProject)

                    BannerManager.shared.show(
                        message: "Created \(sections.count) sections from Jira statuses",
                        style: .info,
                        duration: 3.0
                    )
                } catch {
                    // Non-critical — sync will retry on next tick
                }
            }
        }
    }
}
