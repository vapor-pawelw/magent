import Foundation
import MagentCore

extension ThreadManager {

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
        guard settings.jiraTicketDetectionEnabled else { return }
        guard !isJiraVerificationRunning else { return }
        isJiraVerificationRunning = true
        defer { isJiraVerificationRunning = false }

        loadJiraTicketCacheIfNeeded()

        let snapshot: [MagentThread]
        if let ids = forThreadIds {
            snapshot = threads.filter { ids.contains($0.id) && !$0.isArchived }
        } else {
            snapshot = threads.filter { !$0.isArchived }
        }

        // Collect detected ticket keys and which threads reference them
        var keyToThreadIds: [String: [UUID]] = [:]
        for thread in snapshot {
            guard let ticketKey = thread.effectiveJiraTicketKey else { continue }
            keyToThreadIds[ticketKey, default: []].append(thread.id)
        }

        guard !keyToThreadIds.isEmpty else {
            // No detected keys — just populate from cache and prune
            populateVerifiedTicketsFromCache()
            if forThreadIds == nil { pruneJiraTicketCache() }
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
            pruneJiraTicketCache()
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
            for ticket in tickets {
                let entry = JiraTicketCacheEntry(
                    key: ticket.key,
                    summary: ticket.summary,
                    status: ticket.status,
                    statusCategoryKey: ticket.statusCategoryKey,
                    verifiedAt: now
                )
                jiraTicketCache[ticket.key] = entry
            }
            persistence.saveJiraTicketCache(jiraTicketCache)
        } catch {
            // Auth failure or acli error — skip silently, existing cache entries remain valid
        }
    }

    // MARK: - Cache Population

    /// Populates the transient `verifiedJiraTicket` field on all active threads from the cache.
    private func populateVerifiedTicketsFromCache() {
        let detectionEnabled = persistence.loadSettings().jiraTicketDetectionEnabled
        var changed = false
        for i in threads.indices where !threads[i].isArchived {
            let previous = threads[i].verifiedJiraTicket
            if detectionEnabled,
               let ticketKey = threads[i].effectiveJiraTicketKey,
               let cached = jiraTicketCache[ticketKey] {
                threads[i].verifiedJiraTicket = cached
                if previous != cached { changed = true }
            } else if previous != nil {
                threads[i].verifiedJiraTicket = nil
                changed = true
            }
        }
        if changed {
            Task { @MainActor in
                delegate?.threadManager(self, didUpdateThreads: threads)
                NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            }
        }
    }

    // MARK: - Detection Toggle

    /// Clears all Jira detection transient state from threads and notifies the UI.
    func clearAllJiraDetectionState() {
        var changed = false
        for i in threads.indices {
            if threads[i].verifiedJiraTicket != nil {
                threads[i].verifiedJiraTicket = nil
                changed = true
            }
        }
        if changed {
            Task { @MainActor in
                delegate?.threadManager(self, didUpdateThreads: threads)
                NotificationCenter.default.post(name: .magentJiraTicketInfoChanged, object: nil)
            }
        }
    }

    // MARK: - Single-Ticket Refresh on Selection

    /// Refreshes a single Jira ticket in the background when a thread is selected.
    /// Unlike `verifyDetectedJiraTickets`, this always runs (no batch guard) but
    /// skips if the cached entry was verified less than 60 seconds ago.
    func refreshJiraTicketForSelectedThread(_ thread: MagentThread) {
        guard persistence.loadSettings().jiraTicketDetectionEnabled else { return }
        guard let ticketKey = thread.effectiveJiraTicketKey else { return }

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

    /// Removes cache entries not referenced by any active thread's `effectiveJiraTicketKey`.
    private func pruneJiraTicketCache() {
        let referencedKeys = Set(
            threads
                .filter { !$0.isArchived }
                .compactMap(\.effectiveJiraTicketKey)
        )
        let before = jiraTicketCache.count
        jiraTicketCache = jiraTicketCache.filter { referencedKeys.contains($0.key) }
        if jiraTicketCache.count != before {
            persistence.saveJiraTicketCache(jiraTicketCache)
        }
    }
}
