import Foundation
import MagentCore

// MARK: - Forwarding layer — logic lives in JiraIntegrationService

#if FEATURE_JIRA_SYNC
extension ThreadManager {

    func syncSectionsFromJira(project: Project) async throws -> [ThreadSection] {
        try await jiraIntegrationService.syncSectionsFromJira(project: project)
    }

    @discardableResult
    func runJiraSyncTick() async -> StatusSyncResult {
        await jiraIntegrationService.runJiraSyncTick(
            createThread: { [weak self] project, name in
                guard let self else { throw CancellationError() }
                return try await self.createThread(project: project, requestedName: name)
            },
            injectPrompt: { [weak self] sessionName, prompt in
                self?.injectPromptWithoutSubmitting(sessionName: sessionName, prompt: prompt)
            }
        )
    }

    func findMatchingSection(for statusName: String, in projectId: UUID, settings: AppSettings) -> ThreadSection? {
        jiraIntegrationService.findMatchingSection(for: statusName, in: projectId, settings: settings)
    }

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

    func excludeJiraTicket(key: String, projectId: UUID) {
        jiraIntegrationService.excludeJiraTicket(key: key, projectId: projectId)
    }
}
#else
extension ThreadManager {
    func syncSectionsFromJira(project: Project) async throws -> [ThreadSection] {
        []
    }

    @discardableResult
    func runJiraSyncTick() async -> StatusSyncResult { .success }

    func excludeJiraTicket(key: String, projectId: UUID) {}
}
#endif
