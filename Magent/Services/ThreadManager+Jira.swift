import Foundation
import MagentCore

#if FEATURE_JIRA_SYNC
extension ThreadManager {

    // MARK: - Section Sync

    func syncSectionsFromJira(project: Project) async throws -> [ThreadSection] {
        guard let projectKey = project.jiraProjectKey, !projectKey.isEmpty else {
            throw JiraError.commandFailed("No Jira project key set")
        }

        let statuses = try await JiraService.shared.discoverStatuses(projectKey: projectKey)
        guard !statuses.isEmpty else { return [] }

        let colors = ["#007AFF", "#FF9500", "#AF52DE", "#34C759", "#FF3B30", "#5AC8FA", "#FF2D55", "#FFCC00"]
        var sections: [ThreadSection] = []
        for (i, status) in statuses.enumerated() {
            sections.append(ThreadSection(
                name: status,
                colorHex: colors[i % colors.count],
                sortOrder: i,
                isDefault: i == 0
            ))
        }

        return sections
    }

    // MARK: - Auto-sync Tick

    func runJiraSyncTick() async {
        let settings = persistence.loadSettings()
        for project in settings.projects where project.jiraSyncEnabled {
            await syncJiraForProject(project, settings: settings)
        }
    }

    // MARK: - Per-project Sync

    private func syncJiraForProject(_ project: Project, settings: AppSettings) async {
        guard let projectKey = project.jiraProjectKey, !projectKey.isEmpty else { return }
        guard let assigneeId = project.jiraAssigneeAccountId, !assigneeId.isEmpty else { return }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return }

        // Auto-create project sections from Jira if none exist.
        // Return after creating — the next sync tick will match tickets using the persisted sections.
        if project.threadSections == nil {
            do {
                let sections = try await syncSectionsFromJira(project: project)
                guard !sections.isEmpty else { return }
                var updatedSettings = persistence.loadSettings()
                if let idx = updatedSettings.projects.firstIndex(where: { $0.id == project.id }) {
                    updatedSettings.projects[idx].threadSections = sections
                    try? persistence.saveSettings(updatedSettings)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                    }
                }
            } catch {
                // Can't sync without sections — skip this project
            }
            return
        }

        let jql = "project = \(projectKey) AND assignee = \"\(assigneeId)\" AND statusCategory != Done ORDER BY updated DESC"

        let tickets: [JiraTicket]
        do {
            tickets = try await JiraService.shared.searchTickets(jql: jql)
        } catch JiraError.notAuthenticated {
            // Disable sync on auth error
            disableSyncForProject(project.id)
            await MainActor.run {
                BannerManager.shared.show(
                    message: "Jira auth expired. Re-authenticate in Settings > Jira",
                    style: .warning,
                    duration: nil,
                    isDismissible: true
                )
            }
            return
        } catch {
            // Transient error — skip this tick
            return
        }

        let ticketKeys = Set(tickets.map(\.key))

        for ticket in tickets {
            if let threadIndex = threads.firstIndex(where: { $0.jiraTicketKey == ticket.key }) {
                // Thread exists — check if status changed, move to matching section
                if let section = findMatchingSection(for: ticket.status, in: project.id, settings: settings) {
                    if threads[threadIndex].sectionId != section.id {
                        threads[threadIndex].sectionId = section.id
                    }
                }
                // Clear unassigned flag since ticket is still assigned
                if threads[threadIndex].jiraUnassigned {
                    threads[threadIndex].jiraUnassigned = false
                }
            } else {
                // No thread for this ticket — create if not excluded
                guard !project.jiraExcludedTicketKeys.contains(ticket.key) else { continue }

                let sectionId = findMatchingSection(for: ticket.status, in: project.id, settings: settings)?.id
                await createThreadForJiraTicket(ticket, project: project, sectionId: sectionId)
            }
        }

        // Mark threads whose ticket is no longer in results as unassigned
        for i in threads.indices {
            guard threads[i].projectId == project.id,
                  let ticketKey = threads[i].jiraTicketKey,
                  !threads[i].isArchived else { continue }
            if !ticketKeys.contains(ticketKey) {
                threads[i].jiraUnassigned = true
            }
        }

        try? persistence.saveActiveThreads(threads)
        await MainActor.run {
            delegate?.threadManager(self, didUpdateThreads: threads)
        }

        // Detect Jira statuses that don't match any section
        let allStatuses = Set(tickets.map(\.status))
        let sectionNames = Set(settings.sections(for: project.id).map { $0.name.lowercased() })
        let unmatchedStatuses = allStatuses.filter { !sectionNames.contains($0.lowercased()) }

        if !unmatchedStatuses.isEmpty {
            let acknowledged = project.jiraAcknowledgedStatuses ?? []
            let newUnmatched = unmatchedStatuses.subtracting(acknowledged)
            if !newUnmatched.isEmpty && !_mismatchBannerShownProjectIds.contains(project.id) {
                _mismatchBannerShownProjectIds.insert(project.id)
                await showStatusMismatchBanner(statuses: newUnmatched, projectId: project.id, projectName: project.name)
            }
        } else {
            _mismatchBannerShownProjectIds.remove(project.id)
        }
    }

    // MARK: - Thread Creation for Tickets

    private func createThreadForJiraTicket(_ ticket: JiraTicket, project: Project, sectionId: UUID?) async {
        let threadName = ticket.key.lowercased()

        do {
            var thread = try await createThread(
                project: project,
                requestedName: threadName
            )
            thread.jiraTicketKey = ticket.key
            if let sectionId {
                thread.sectionId = sectionId
            }

            // Update the thread in our array
            if let idx = threads.firstIndex(where: { $0.id == thread.id }) {
                threads[idx] = thread
            }
            try? persistence.saveActiveThreads(threads)

            // Inject ticket summary as prompt text without submitting
            if !ticket.summary.isEmpty,
               let sessionName = thread.tmuxSessionNames.first {
                injectPromptWithoutSubmitting(sessionName: sessionName, prompt: ticket.summary)
            }
        } catch {
            await MainActor.run {
                BannerManager.shared.show(
                    message: "Failed to create thread for \(ticket.key): \(error.localizedDescription)",
                    style: .warning,
                    duration: 5.0
                )
            }
        }
    }

    // MARK: - Section Matching

    func findMatchingSection(for statusName: String, in projectId: UUID, settings: AppSettings) -> ThreadSection? {
        let sections = settings.sections(for: projectId)
        let lowered = statusName.lowercased()
        return sections.first { $0.name.lowercased() == lowered }
    }

    // MARK: - Prompt Injection

    func injectPromptWithoutSubmitting(sessionName: String, prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            // Wait for agent TUI to initialize
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            try? await tmux.sendText(sessionName: sessionName, text: trimmed)
            // Intentionally NOT sending Enter
        }
    }

    // MARK: - Exclude Ticket

    func excludeJiraTicket(key: String, projectId: UUID) {
        var settings = persistence.loadSettings()
        if let idx = settings.projects.firstIndex(where: { $0.id == projectId }) {
            settings.projects[idx].jiraExcludedTicketKeys.insert(key)
            try? persistence.saveSettings(settings)
        }
    }

    // MARK: - Status Mismatch Banner

    private func showStatusMismatchBanner(statuses: Set<String>, projectId: UUID, projectName: String) async {
        let sortedStatuses = statuses.sorted().joined(separator: ", ")
        await MainActor.run { [weak self] in
            BannerManager.shared.show(
                message: "Jira statuses not matching sections in \(projectName): \(sortedStatuses)",
                style: .warning,
                duration: nil,
                isDismissible: true,
                actions: [
                    BannerAction(title: "Resync Sections") {
                        guard let self else { return }
                        Task {
                            var settings = self.persistence.loadSettings()
                            guard let idx = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }
                            let project = settings.projects[idx]
                            do {
                                let sections = try await self.syncSectionsFromJira(project: project)
                                guard !sections.isEmpty else { return }
                                settings.projects[idx].threadSections = sections
                                settings.projects[idx].jiraAcknowledgedStatuses = nil
                                try? self.persistence.saveSettings(settings)
                                self._mismatchBannerShownProjectIds.remove(projectId)
                                await MainActor.run {
                                    NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                                    BannerManager.shared.show(
                                        message: "Synced \(sections.count) sections from Jira for \(projectName)",
                                        style: .info,
                                        duration: 3.0
                                    )
                                }
                            } catch {
                                await MainActor.run {
                                    BannerManager.shared.show(
                                        message: "Failed to resync: \(error.localizedDescription)",
                                        style: .error,
                                        duration: 5.0
                                    )
                                }
                            }
                        }
                    },
                    BannerAction(title: "Don't Show Again") {
                        guard let self else { return }
                        var settings = self.persistence.loadSettings()
                        guard let idx = settings.projects.firstIndex(where: { $0.id == projectId }) else { return }
                        let existing = settings.projects[idx].jiraAcknowledgedStatuses ?? []
                        settings.projects[idx].jiraAcknowledgedStatuses = existing.union(statuses)
                        try? self.persistence.saveSettings(settings)
                        self._mismatchBannerShownProjectIds.remove(projectId)
                    }
                ]
            )
        }
    }

    // MARK: - Disable Sync

    private func disableSyncForProject(_ projectId: UUID) {
        var settings = persistence.loadSettings()
        if let idx = settings.projects.firstIndex(where: { $0.id == projectId }) {
            settings.projects[idx].jiraSyncEnabled = false
            try? persistence.saveSettings(settings)
        }
    }
}
#else
extension ThreadManager {
    func syncSectionsFromJira(project: Project) async throws -> [ThreadSection] {
        []
    }

    func runJiraSyncTick() async {}

    func excludeJiraTicket(key: String, projectId: UUID) {}
}
#endif
