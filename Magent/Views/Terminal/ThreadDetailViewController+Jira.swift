import Cocoa
import MagentCore

extension ThreadDetailViewController {

    // MARK: - Jira Button

    func refreshJiraButton() {
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let siteURL = project?.jiraSiteURL ?? settings.jiraSiteURL

#if FEATURE_JIRA_SYNC
        // Full Jira config: show button for board/project/ticket navigation
        if let project,
           let projectKey = project.jiraProjectKey, !projectKey.isEmpty,
           !siteURL.isEmpty {
            openInJiraButton.isHidden = false
            openInJiraButton.image = jiraButtonImage()
            if let ticketKey = thread.jiraTicketKey {
                applyJiraButtonTitle(ticketKey: ticketKey)
            } else if thread.isMain {
                openInJiraButton.title = ""
                openInJiraButton.imagePosition = .imageOnly
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraBoard)
            } else {
                openInJiraButton.title = ""
                openInJiraButton.imagePosition = .imageOnly
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraProject)
            }
            refreshPRJiraSeparator()
            return
        }
#endif

        // Branch-detected ticket: show button to open ticket directly
        guard settings.jiraTicketDetectionEnabled,
              let ticketKey = thread.effectiveJiraTicketKey, !siteURL.isEmpty else {
            openInJiraButton.isHidden = true
            refreshPRJiraSeparator()
            return
        }

        openInJiraButton.isHidden = false
        openInJiraButton.image = jiraButtonImage()
        applyJiraButtonTitle(ticketKey: ticketKey)
        refreshPRJiraSeparator()
    }

    private func applyJiraButtonTitle(ticketKey: String) {
        openInJiraButton.title = ticketKey
        openInJiraButton.imagePosition = .imageLeading
        if let summary = thread.verifiedJiraTicket?.summary, !summary.isEmpty {
            openInJiraButton.toolTip = "\(ticketKey): \(summary) — Open in Jira"
        } else {
            openInJiraButton.toolTip = "\(ticketKey) — Open in Jira"
        }
    }

    func jiraButtonImage() -> NSImage {
        if let image = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (image.copy() as? NSImage) ?? image
            sized.size = NSSize(width: 16, height: 16)
            sized.isTemplate = false
            return sized
        }
        return NSImage(systemSymbolName: "ticket", accessibilityDescription: "Jira") ?? NSImage()
    }

    @objc func openInJiraTapped() {
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let siteURL = project?.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return }
        let jira = JiraService.shared

        var url: URL?

#if FEATURE_JIRA_SYNC
        if let ticketKey = thread.jiraTicketKey {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        } else if thread.isMain, let projectKey = project?.jiraProjectKey {
            if let boardId = project?.jiraBoardId {
                url = jira.boardURL(siteURL: siteURL, projectKey: projectKey, boardId: boardId)
            } else {
                url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
            }
        } else if let projectKey = project?.jiraProjectKey {
            url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
        }
#endif

        // Fall back to branch-detected ticket
        if url == nil, let ticketKey = thread.effectiveJiraTicketKey {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        }

        if let url {
            NSWorkspace.shared.open(url)
        } else {
            BannerManager.shared.show(
                message: String(localized: .JiraStrings.jiraCouldNotBuildURL),
                style: .warning,
                duration: 5.0
            )
        }
    }
}
