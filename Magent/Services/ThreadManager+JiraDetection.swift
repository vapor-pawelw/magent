import Foundation
import MagentCore

// MARK: - Forwarding layer — logic lives in JiraIntegrationService

extension ThreadManager {

    func loadJiraTicketCacheIfNeeded() {
        jiraIntegrationService.loadJiraTicketCacheIfNeeded()
    }

    func verifyDetectedJiraTickets(forThreadIds: Set<UUID>? = nil) async {
        await jiraIntegrationService.verifyDetectedJiraTickets(forThreadIds: forThreadIds)
    }

    func enableAndRefreshJiraDetection() {
        jiraIntegrationService.enableAndRefreshJiraDetection()
    }

    func clearAllJiraDetectionState() {
        jiraIntegrationService.clearAllJiraDetectionState()
    }

    func refreshJiraTicketForSelectedThread(_ thread: MagentThread) {
        jiraIntegrationService.refreshJiraTicketForSelectedThread(thread)
    }

    func forceRefreshJiraTicket(for thread: MagentThread) {
        jiraIntegrationService.forceRefreshJiraTicket(for: thread)
    }

    func cachedProjectStatuses(for projectKey: String) -> [JiraProjectStatus]? {
        jiraIntegrationService.cachedProjectStatuses(for: projectKey)
    }

    func fetchAndCacheProjectStatuses(projectKey: String) async -> [JiraProjectStatus] {
        await jiraIntegrationService.fetchAndCacheProjectStatuses(projectKey: projectKey)
    }

    func transitionJiraTicket(ticketKey: String, toStatus: String) async throws {
        try await jiraIntegrationService.transitionJiraTicket(ticketKey: ticketKey, toStatus: toStatus)
    }
}
