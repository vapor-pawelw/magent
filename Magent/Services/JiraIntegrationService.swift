import Foundation
import MagentCore

/// Owns all Jira ticket detection, verification, cache management, and sync logic.
/// Extracted from `ThreadManager+Jira.swift` and `ThreadManager+JiraDetection.swift`.
///
/// Mutates `store.threads` directly; the caller is responsible for delegate/UI notifications
/// unless the service posts them via `onThreadsChanged`.
final class JiraIntegrationService {

    let store: ThreadStore
    let persistence: PersistenceService

    /// Called when thread data changes and the delegate/UI should be notified.
    var onThreadsChanged: (() -> Void)?

    // MARK: - State (moved from ThreadManager)

    var jiraTicketCache: [String: JiraTicketCacheEntry] = [:]
    var jiraTicketCacheLoaded = false
    var isJiraVerificationRunning = false
    var _jiraProjectStatusesCache: [String: [JiraProjectStatus]] = [:]
    var _jiraProjectStatusesCacheLoaded = false
    /// Tracks projects that have already shown a section-mismatch banner this session.
    var mismatchBannerShownProjectIds: Set<UUID> = []

    // MARK: - Init

    init(store: ThreadStore, persistence: PersistenceService) {
        self.store = store
        self.persistence = persistence
    }

    // MARK: - Cache TTL

    /// How long a cache entry is considered fresh before re-verification.
    /// Slightly above the 5-minute polling cadence so mid-cycle refreshes
    /// (e.g. on thread selection) survive until the next periodic tick.
    private static let jiraTicketCacheTTL: TimeInterval = 6 * 60

    // MARK: - Cache Loading

    func loadJiraTicketCacheIfNeeded() {
        guard !jiraTicketCacheLoaded else { return }
        jiraTicketCache = persistence.loadJiraTicketCache()
        jiraTicketCacheLoaded = true
    }

    // MARK: - Verification

    /// Verifies detected Jira ticket keys against Jira via acli.
    /// If `forThreadIds` is nil, scans all active threads. Otherwise only the specified threads.
    /// Populates `verifiedJiraTicket` on matching threads from cache or fresh verification.
    /// Only one verification pass runs at a time — concurrent calls are skipped.
    func verifyDetectedJiraTickets(forThreadIds: Set<UUID>? = nil) async {
        let settings = persistence.loadSettings()
        guard settings.jiraIntegrationEnabled, settings.jiraTicketDetectionEnabled else { return }
        guard !isJiraVerificationRunning else { return }
        isJiraVerificationRunning = true
        defer { isJiraVerificationRunning = false }

        loadJiraTicketCacheIfNeeded()

        let snapshot: [MagentThread]
        if let ids = forThreadIds {
            snapshot = store.threads.filter { ids.contains($0.id) && !$0.isArchived }
        } else {
            snapshot = store.threads.filter { !$0.isArchived }
        }

        // Collect detected ticket keys and which threads reference them
        var keyToThreadIds: [String: [UUID]] = [:]
        for thread in snapshot {
            guard let ticketKey = thread.effectiveJiraTicketKey(settings: settings) else { continue }
            keyToThreadIds[ticketKey, default: []].append(thread.id)
        }

        guard !keyToThreadIds.isEmpty else {
            // No detected keys — just populate from cache and prune
            populateVerifiedTicketsFromCache()
            if forThreadIds == nil { pruneJiraTicketCache(settings: settings) }
            return
        }

        // Populate existing cached entries immediately (so UI shows cached data fast)
        populateVerifiedTicketsFromCache()

        // Determine which keys need (re-)verification
        let now = Date()
        let staleThreshold = now.addingTimeInterval(-Self.jiraTicketCacheTTL)
        let keysNeedingVerification = keyToThreadIds.keys.filter { key in
            guard let cached = jiraTicketCache[key] else { return true }
            return cached.verifiedAt < staleThreshold
        }

        // If we have keys to verify, try acli
        if !keysNeedingVerification.isEmpty {
            let hasSiteURL: Bool = {
                if !settings.jiraSiteURL.isEmpty { return true }
                return settings.projects.contains { $0.jiraSiteURL?.isEmpty == false }
            }()

            if hasSiteURL {
                await verifyTicketKeysViaAcli(Array(keysNeedingVerification))
            }
        }

        // Re-populate transient fields after verification
        populateVerifiedTicketsFromCache()

        if forThreadIds == nil {
            pruneJiraTicketCache(settings: settings)
        }
    }

    /// Called when Jira detection is enabled or acli auth becomes available.
    /// Populates from cache immediately for instant UI, then verifies in the background.
    func enableAndRefreshJiraDetection() {
        loadJiraTicketCacheIfNeeded()
        populateVerifiedTicketsFromCache()
        Task {
            await verifyDetectedJiraTickets()
        }
    }

    // MARK: - Acli Verification

    private func verifyTicketKeysViaAcli(_ keys: [String]) async {
        guard await JiraService.shared.isAcliInstalled() else { return }

        // Batch query: key in (IP-1234, IP-5678)
        let keyList = keys.joined(separator: ", ")
        let jql = "key in (\(keyList))"

        do {
            let tickets = try await JiraService.shared.searchTickets(jql: jql)
            let now = Date()
            loadProjectStatusesCacheIfNeeded()
            var projectKeysToFetchStatuses = Set<String>()
            for ticket in tickets {
                let entry = JiraTicketCacheEntry(
                    key: ticket.key,
                    summary: ticket.summary,
                    status: ticket.status,
                    statusCategoryKey: ticket.statusCategoryKey,
                    priority: ticket.priority,
                    verifiedAt: now
                )
                jiraTicketCache[ticket.key] = entry
                // Collect project keys for status discovery
                if let projectKey = ticket.key.split(separator: "-").first.map(String.init),
                   _jiraProjectStatusesCache[projectKey] == nil {
                    projectKeysToFetchStatuses.insert(projectKey)
                }
            }
            persistence.saveJiraTicketCache(jiraTicketCache)

            // Pre-fetch project statuses for context menu
            for projectKey in projectKeysToFetchStatuses {
                _ = await fetchAndCacheProjectStatuses(projectKey: projectKey)
            }
        } catch {
            // Auth failure or acli error — skip silently, existing cache entries remain valid
        }
    }

    // MARK: - Cache Population

    /// Populates the transient `verifiedJiraTicket` field on all active threads from the cache.
    private func populateVerifiedTicketsFromCache() {
        let s = persistence.loadSettings()
        let detectionEnabled = s.jiraIntegrationEnabled && s.jiraTicketDetectionEnabled
        var changed = false
        var persistentChanged = false
        for i in store.threads.indices where !store.threads[i].isArchived {
            let previous = store.threads[i].verifiedJiraTicket
            if detectionEnabled,
               let ticketKey = store.threads[i].effectiveJiraTicketKey(settings: s),
               let cached = jiraTicketCache[ticketKey] {
                store.threads[i].verifiedJiraTicket = cached
                if previous != cached { changed = true }

                // Per-thread auto-sync: overwrite description/priority from the
                // cached ticket for subscribed threads. Overwrite-only-if-different
                // keeps notifications quiet; user edits snap back on the next tick,
                // which is the documented contract for the toggle.
                if store.threads[i].syncWithJira {
                    let trimmed = cached.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, store.threads[i].taskDescription != trimmed {
                        store.threads[i].taskDescription = trimmed
                        persistentChanged = true
                    }
                    if let p = cached.priority, (1...5).contains(p), store.threads[i].priority != p {
                        store.threads[i].priority = p
                        persistentChanged = true
                    }
                }
            } else if previous != nil {
                store.threads[i].verifiedJiraTicket = nil
                changed = true
            }
        }
        if persistentChanged {
            try? persistence.saveActiveThreads(store.threads)
        }
        if changed || persistentChanged {
            Task { @MainActor in
                onThreadsChanged?()
                NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            }
        }
    }

    // MARK: - Detection Toggle

    /// Clears all Jira detection transient state from threads and notifies the UI.
    func clearAllJiraDetectionState() {
        var changed = false
        for i in store.threads.indices {
            if store.threads[i].verifiedJiraTicket != nil {
                store.threads[i].verifiedJiraTicket = nil
                changed = true
            }
        }
        if changed {
            Task { @MainActor in
                onThreadsChanged?()
                NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            }
        }
    }

    // MARK: - Single-Ticket Refresh on Selection

    /// Refreshes a single Jira ticket in the background when a thread is selected.
    /// Unlike `verifyDetectedJiraTickets`, this always runs (no batch guard) but
    /// skips if the cached entry was verified less than 60 seconds ago.
    func refreshJiraTicketForSelectedThread(_ thread: MagentThread) {
        let refreshSettings = persistence.loadSettings()
        guard refreshSettings.jiraIntegrationEnabled, refreshSettings.jiraTicketDetectionEnabled else { return }
        guard let ticketKey = thread.effectiveJiraTicketKey(settings: refreshSettings) else { return }

        loadJiraTicketCacheIfNeeded()
        if let cached = jiraTicketCache[ticketKey],
           Date().timeIntervalSince(cached.verifiedAt) < 60 {
            return
        }

        Task {
            await refreshSingleTicketKey(ticketKey)
        }
    }

    private func refreshSingleTicketKey(_ key: String) async {
        guard await JiraService.shared.isAcliInstalled() else { return }

        do {
            let tickets = try await JiraService.shared.searchTickets(jql: "key = \(key)")
            guard let ticket = tickets.first else { return }

            let entry = JiraTicketCacheEntry(
                key: ticket.key,
                summary: ticket.summary,
                status: ticket.status,
                statusCategoryKey: ticket.statusCategoryKey,
                priority: ticket.priority,
                verifiedAt: Date()
            )

            let oldEntry = jiraTicketCache[key]
            jiraTicketCache[key] = entry
            persistence.saveJiraTicketCache(jiraTicketCache)

            if oldEntry != entry {
                populateVerifiedTicketsFromCache()
            }
        } catch {
            // Silently skip — cached data remains
        }
    }

    // MARK: - Cache Pruning

    /// Removes cache entries not referenced by any active thread's settings-filtered Jira ticket key.
    private func pruneJiraTicketCache(settings: AppSettings) {
        let referencedKeys = Set(
            store.threads
                .filter { !$0.isArchived }
                .compactMap { $0.effectiveJiraTicketKey(settings: settings) }
        )
        let before = jiraTicketCache.count
        jiraTicketCache = jiraTicketCache.filter { referencedKeys.contains($0.key) }
        if jiraTicketCache.count != before {
            persistence.saveJiraTicketCache(jiraTicketCache)
        }
    }

    // MARK: - Force Refresh (Context Menu)

    /// Force-refreshes a single thread's Jira ticket data, bypassing the 60-second throttle.
    func forceRefreshJiraTicket(for thread: MagentThread) {
        let settings = persistence.loadSettings()
        guard let ticketKey = thread.effectiveJiraTicketKey(settings: settings) else { return }
        loadJiraTicketCacheIfNeeded()
        // Also invalidate project statuses so they're re-fetched on next menu open
        loadProjectStatusesCacheIfNeeded()
        if let projectKey = ticketKey.split(separator: "-").first.map(String.init) {
            _jiraProjectStatusesCache.removeValue(forKey: projectKey)
            saveProjectStatusesCache()
        }
        Task {
            await refreshSingleTicketKey(ticketKey)
        }
    }

    // MARK: - Project Statuses Cache

    private static var jiraProjectStatusesCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
            .appendingPathComponent("jira-project-statuses-cache.json")
    }

    /// Loads cached project statuses from disk if not already loaded.
    private func loadProjectStatusesCacheIfNeeded() {
        guard !_jiraProjectStatusesCacheLoaded else { return }
        _jiraProjectStatusesCacheLoaded = true
        let url = Self.jiraProjectStatusesCacheURL
        guard let data = try? Data(contentsOf: url) else { return }
        _jiraProjectStatusesCache = (try? JSONDecoder().decode([String: [JiraProjectStatus]].self, from: data)) ?? [:]
    }

    /// Persists project statuses cache to disk.
    private func saveProjectStatusesCache() {
        let url = Self.jiraProjectStatusesCacheURL
        guard let data = try? JSONEncoder().encode(_jiraProjectStatusesCache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Returns cached project statuses, or nil if not yet fetched.
    func cachedProjectStatuses(for projectKey: String) -> [JiraProjectStatus]? {
        loadProjectStatusesCacheIfNeeded()
        return _jiraProjectStatusesCache[projectKey]
    }

    /// Fetches project statuses from Jira and caches them (in memory + disk).
    func fetchAndCacheProjectStatuses(projectKey: String) async -> [JiraProjectStatus] {
        loadProjectStatusesCacheIfNeeded()
        if let cached = _jiraProjectStatusesCache[projectKey] {
            return cached
        }
        do {
            let statuses = try await JiraService.shared.discoverProjectStatuses(projectKey: projectKey)
            _jiraProjectStatusesCache[projectKey] = statuses
            saveProjectStatusesCache()
            return statuses
        } catch {
            return []
        }
    }

    // MARK: - Status Transition

    /// Transitions a Jira ticket to a new status and refreshes the cache on success.
    func transitionJiraTicket(ticketKey: String, toStatus: String) async throws {
        try await JiraService.shared.transitionTicket(key: ticketKey, toStatus: toStatus)

        // Refresh the ticket cache to reflect the new status
        await refreshSingleTicketKey(ticketKey)
    }
}

// MARK: - FEATURE_JIRA_SYNC Extension

#if FEATURE_JIRA_SYNC
extension JiraIntegrationService {

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

    /// Returns a summary of any Jira sync failures encountered during the pass.
    @discardableResult
    func runJiraSyncTick(
        createThread: @escaping (Project, String) async throws -> MagentThread,
        injectPrompt: @escaping (String, String) -> Void
    ) async -> ThreadManager.StatusSyncResult {
        let settings = persistence.loadSettings()
        var failureCount = 0
        var failureDetails: [String] = []
        for project in settings.projects where project.jiraSyncEnabled {
            let result = await syncJiraForProject(
                project,
                settings: settings,
                createThread: createThread,
                injectPrompt: injectPrompt
            )
            if result.hadErrors {
                failureCount += 1
                if let summary = result.failureSummary, failureDetails.count < 3 {
                    failureDetails.append(summary)
                }
            }
        }
        guard failureCount > 0 else { return .success }
        let summary = failureDetails.isEmpty
            ? "Jira sync failed (\(failureCount) error\(failureCount == 1 ? "" : "s"))."
            : "Jira sync failed:\n" + failureDetails.prefix(3).map { "- \($0)" }.joined(separator: "\n")
        return .failure(summary)
    }

    // MARK: - Per-project Sync

    private func syncJiraForProject(
        _ project: Project,
        settings: AppSettings,
        createThread: @escaping (Project, String) async throws -> MagentThread,
        injectPrompt: @escaping (String, String) -> Void
    ) async -> ThreadManager.StatusSyncResult {
        guard let projectKey = project.jiraProjectKey, !projectKey.isEmpty else { return .success }
        guard let assigneeId = project.jiraAssigneeAccountId, !assigneeId.isEmpty else { return .success }

        let siteURL = project.jiraSiteURL ?? settings.jiraSiteURL
        guard !siteURL.isEmpty else { return .success }

        // Auto-create project sections from Jira if none exist.
        // Return after creating — the next sync tick will match tickets using the persisted sections.
        if project.threadSections == nil {
            do {
                let sections = try await syncSectionsFromJira(project: project)
                guard !sections.isEmpty else { return .success }
                var updatedSettings = persistence.loadSettings()
                if let idx = updatedSettings.projects.firstIndex(where: { $0.id == project.id }) {
                    updatedSettings.projects[idx].threadSections = sections
                    try? persistence.saveSettings(updatedSettings)
                    await MainActor.run {
                        NotificationCenter.default.post(name: .magentSectionsDidChange, object: nil)
                    }
                }
            } catch {
                return .failure("\(project.name): failed to sync Jira sections (\(error.localizedDescription))")
            }
            return .success
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
            return .failure("\(project.name): Jira auth expired. Re-authenticate in Settings > Jira.")
        } catch {
            return .failure("\(project.name): \(error.localizedDescription)")
        }

        let ticketKeys = Set(tickets.map(\.key))

        for ticket in tickets {
            if let threadIndex = store.threads.firstIndex(where: { $0.jiraTicketKey == ticket.key }) {
                // Thread exists — check if status changed, move to matching section
                if let section = findMatchingSection(for: ticket.status, in: project.id, settings: settings) {
                    if store.threads[threadIndex].sectionId != section.id {
                        store.threads[threadIndex].sectionId = section.id
                    }
                }
                // Clear unassigned flag since ticket is still assigned
                if store.threads[threadIndex].jiraUnassigned {
                    store.threads[threadIndex].jiraUnassigned = false
                }
            } else {
                // No thread for this ticket — create if not excluded
                guard !project.jiraExcludedTicketKeys.contains(ticket.key) else { continue }

                let sectionId = findMatchingSection(for: ticket.status, in: project.id, settings: settings)?.id
                await createThreadForJiraTicket(
                    ticket,
                    project: project,
                    sectionId: sectionId,
                    createThread: createThread,
                    injectPrompt: injectPrompt
                )
            }
        }

        // Mark threads whose ticket is no longer in results as unassigned
        for i in store.threads.indices {
            guard store.threads[i].projectId == project.id,
                  let ticketKey = store.threads[i].jiraTicketKey,
                  !store.threads[i].isArchived else { continue }
            if !ticketKeys.contains(ticketKey) {
                store.threads[i].jiraUnassigned = true
            }
        }

        try? persistence.saveActiveThreads(store.threads)
        await MainActor.run {
            onThreadsChanged?()
        }

        // Detect Jira statuses that don't match any section
        let allStatuses = Set(tickets.map(\.status))
        let sectionNames = Set(settings.sections(for: project.id).map { $0.name.lowercased() })
        let unmatchedStatuses = allStatuses.filter { !sectionNames.contains($0.lowercased()) }

        if !unmatchedStatuses.isEmpty {
            let acknowledged = project.jiraAcknowledgedStatuses ?? []
            let newUnmatched = unmatchedStatuses.subtracting(acknowledged)
            if !newUnmatched.isEmpty && !mismatchBannerShownProjectIds.contains(project.id) {
                mismatchBannerShownProjectIds.insert(project.id)
                await showStatusMismatchBanner(statuses: newUnmatched, projectId: project.id, projectName: project.name)
            }
        } else {
            mismatchBannerShownProjectIds.remove(project.id)
        }
        return .success
    }

    // MARK: - Thread Creation for Tickets

    private func createThreadForJiraTicket(
        _ ticket: JiraTicket,
        project: Project,
        sectionId: UUID?,
        createThread: @escaping (Project, String) async throws -> MagentThread,
        injectPrompt: @escaping (String, String) -> Void
    ) async {
        let threadName = ticket.key.lowercased()

        do {
            var thread = try await createThread(project, threadName)
            thread.jiraTicketKey = ticket.key
            if let sectionId {
                thread.sectionId = sectionId
            }

            // Update the thread in our array
            if let idx = store.threads.firstIndex(where: { $0.id == thread.id }) {
                store.threads[idx] = thread
            }
            try? persistence.saveActiveThreads(store.threads)

            // Inject ticket summary as prompt text without submitting
            if !ticket.summary.isEmpty,
               let sessionName = thread.tmuxSessionNames.first {
                injectPrompt(sessionName, ticket.summary)
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

    // MARK: - Exclude Ticket

    func excludeJiraTicket(key: String, projectId: UUID) {
        ThreadManager.excludeJiraTicketInPersistence(key: key, projectId: projectId, persistence: persistence)
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
extension JiraIntegrationService {
    func syncSectionsFromJira(project: Project) async throws -> [ThreadSection] { [] }

    @discardableResult
    func runJiraSyncTick(
        createThread: @escaping (Project, String) async throws -> MagentThread,
        injectPrompt: @escaping (String, String) -> Void
    ) async -> ThreadManager.StatusSyncResult { .success }

    func excludeJiraTicket(key: String, projectId: UUID) {}

    func findMatchingSection(for statusName: String, in projectId: UUID, settings: AppSettings) -> ThreadSection? { nil }
}
#endif
