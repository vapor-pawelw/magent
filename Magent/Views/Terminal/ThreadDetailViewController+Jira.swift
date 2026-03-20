import Cocoa
import MagentCore

/// NSButton subclass that forwards middle-click events to a callback.
final class MiddleClickButton: NSButton {
    var onMiddleClick: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            onMiddleClick?()
        } else {
            super.otherMouseDown(with: event)
        }
    }
}

extension ThreadDetailViewController {

    // MARK: - Jira Button

    func refreshJiraButton() {
        let settings = PersistenceService.shared.loadSettings()

        guard settings.jiraIntegrationEnabled else {
            openInJiraButton.isHidden = true
            refreshPRJiraSeparator()
            return
        }

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
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraBoard) + "\nMiddle-click: open in tab"
            } else {
                openInJiraButton.title = ""
                openInJiraButton.imagePosition = .imageOnly
                openInJiraButton.toolTip = String(localized: .ThreadStrings.threadOpenJiraProject) + "\nMiddle-click: open in tab"
            }
            refreshPRJiraSeparator()
            return
        }
#endif

        // Branch-detected ticket: show button to open ticket directly
        guard settings.jiraTicketDetectionEnabled,
              let ticketKey = thread.effectiveJiraTicketKey(settings: settings), !siteURL.isEmpty else {
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
            openInJiraButton.toolTip = "\(ticketKey): \(summary)\nClick: open in browser · Middle-click: open in tab"
        } else {
            openInJiraButton.toolTip = "\(ticketKey)\nClick: open in browser · Middle-click: open in tab"
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

    /// Resolves the Jira URL and ticket key for the current thread, if available.
    private func resolveJiraURLAndKey() -> (url: URL, ticketKey: String?)? {
        let settings = PersistenceService.shared.loadSettings()
        let project = settings.projects.first(where: { $0.id == thread.projectId })
        let siteURL = project?.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return nil }
        let jira = JiraService.shared

        var url: URL?
        var ticketKey: String?

#if FEATURE_JIRA_SYNC
        if let key = thread.jiraTicketKey {
            ticketKey = key
            url = jira.ticketURL(siteURL: siteURL, ticketKey: key)
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

        if url == nil, let key = thread.effectiveJiraTicketKey(settings: settings) {
            ticketKey = key
            url = jira.ticketURL(siteURL: siteURL, ticketKey: key)
        }

        guard let url else { return nil }
        return (url, ticketKey)
    }

    /// Middle-click: open Jira ticket in an in-app web tab.
    func openJiraInWebTab() {
        guard let resolved = resolveJiraURLAndKey() else {
            BannerManager.shared.show(
                message: String(localized: .JiraStrings.jiraCouldNotBuildURL),
                style: .warning,
                duration: 5.0
            )
            return
        }

        let ticketKey = resolved.ticketKey
        let identifier = ticketKey.map { "jira:\($0)" } ?? "jira:\(resolved.url.absoluteString)"
        let title = ticketKey ?? "Jira"
        let icon = jiraButtonImage()

        openWebTab(url: resolved.url, identifier: identifier, title: title, icon: icon, iconType: .jira)
    }

    @objc func openInJiraTapped() {
        guard let resolved = resolveJiraURLAndKey() else {
            BannerManager.shared.show(
                message: String(localized: .JiraStrings.jiraCouldNotBuildURL),
                style: .warning,
                duration: 5.0
            )
            return
        }
        NSWorkspace.shared.open(resolved.url)
    }
}
