import Cocoa
import MagentCore

#if FEATURE_JIRA
extension ThreadDetailViewController {

    // MARK: - Jira Button

    func refreshJiraButton() {
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else {
            openInJiraButton.isHidden = true
            return
        }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        let hasJiraConfig = project.jiraProjectKey != nil && !siteURL.isEmpty
        openInJiraButton.isHidden = !hasJiraConfig

        if hasJiraConfig {
            openInJiraButton.image = jiraButtonImage()
            if thread.jiraTicketKey != nil {
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenTicketInJira)
            } else if thread.isMain {
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraBoard)
            } else {
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraProject)
            }
        }
    }

    func jiraButtonImage() -> NSImage {
        if let image = NSImage(named: NSImage.Name("JiraIcon")) {
            let sized = (image.copy() as? NSImage) ?? image
            sized.size = NSSize(width: 16, height: 16)
            sized.isTemplate = false
            return sized
        }
        return NSImage(systemSymbolName: "ticket", accessibilityDescription: String(localized: .JiraStrings.jiraTitle)) ?? NSImage()
    }

    @objc func openInJiraTapped() {
        let settings = PersistenceService.shared.loadSettings()
        guard let project = settings.projects.first(where: { $0.id == thread.projectId }) else { return }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return }
        let jira = JiraService.shared

        let url: URL?
        if let ticketKey = thread.jiraTicketKey {
            url = jira.ticketURL(siteURL: siteURL, ticketKey: ticketKey)
        } else if thread.isMain, let projectKey = project.jiraProjectKey {
            if let boardId = project.jiraBoardId {
                url = jira.boardURL(siteURL: siteURL, projectKey: projectKey, boardId: boardId)
            } else {
                url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
            }
        } else if let projectKey = project.jiraProjectKey {
            url = jira.projectURL(siteURL: siteURL, projectKey: projectKey)
        } else {
            url = nil
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
#else
extension ThreadDetailViewController {
    func refreshJiraButton() {
        openInJiraButton.isHidden = true
    }

    func jiraButtonImage() -> NSImage {
        NSImage(systemSymbolName: "ticket", accessibilityDescription: "Jira") ?? NSImage()
    }

    @objc func openInJiraTapped() {}
}
#endif
