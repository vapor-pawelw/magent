import AppKit
import Foundation
import UserNotifications
import MagentCore

extension ThreadManager {

    // MARK: - Rate-Limit Summary

    func globalRateLimitSummaryText(now: Date = Date()) -> String? {
        let ordered: [AgentType] = [.claude, .codex]
        let entries = ordered.compactMap { agent -> String? in
            guard let info = globalAgentRateLimits[agent] else { return nil }
            guard info.resetAt > now else { return nil }
            return "\(agent.displayName): \(countdownText(until: info.resetAt, now: now))"
        }

        guard !entries.isEmpty else { return nil }
        return "Rate limits: " + entries.joined(separator: "  ·  ")
    }

    /// Returns per-agent rate limit entries for building attributed strings with inline icons.
    func globalRateLimitEntries(now: Date = Date()) -> [(agent: AgentType, countdown: String)] {
        let ordered: [AgentType] = [.claude, .codex]
        return ordered.compactMap { agent in
            guard let info = globalAgentRateLimits[agent] else { return nil }
            guard info.resetAt > now else { return nil }
            return (agent: agent, countdown: countdownText(until: info.resetAt, now: now))
        }
    }

    private func countdownText(until resetAt: Date, now: Date) -> String {
        let remaining = max(0, Int(resetAt.timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(max(1, minutes))m"
    }

    func hasActiveRateLimit(for agent: AgentType, now: Date = Date()) -> Bool {
        guard isRateLimitTrackable(agent: agent) else { return false }
        return activeGlobalRateLimit(for: agent, now: now) != nil
    }

    private func ensureRateLimitCachesLoaded() {
        if !rateLimitCacheLoaded {
            rateLimitFingerprintCache = persistence.loadRateLimitCache()
            rateLimitCacheLoaded = true
        }
        if !ignoredRateLimitCacheLoaded {
            ignoredRateLimitFingerprintsByAgent = persistence.loadIgnoredRateLimitFingerprints()
            ignoredRateLimitCacheLoaded = true
        }
    }

    private func isIgnoredRateLimitFingerprint(_ fingerprint: String, for agent: AgentType) -> Bool {
        let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return ignoredRateLimitFingerprintsByAgent[agent]?.contains(normalized) ?? false
    }

    private func hasUnexpiredConcreteRateLimit(
        _ info: AgentRateLimitInfo?,
        now: Date
    ) -> Bool {
        guard let info, !info.isPromptBased else { return false }
        return info.resetAt > now
    }

    private func persistIgnoredRateLimitCacheIfNeeded() {
        guard ignoredRateLimitCacheDirty else { return }
        ignoredRateLimitCacheDirty = false
        persistence.saveIgnoredRateLimitFingerprints(ignoredRateLimitFingerprintsByAgent)
    }

    // MARK: - Rate-Limit Detection

    private struct RateLimitDetection {
        var info: AgentRateLimitInfo
        var fingerprint: String
        var hasRelativeReset: Bool
        var hasExplicitDateAnchor: Bool
    }

    /// Called when the rate-limit detection setting is toggled in Settings.
    /// Immediately clears state (if disabled) or runs a full scan (if enabled).
    func applyRateLimitDetectionSettingChange() {
        Task { await checkForRateLimitedSessions() }
    }

    func checkForRateLimitedSessions() async {
        let detectionEnabled = persistence.loadSettings().enableRateLimitDetection
        if !detectionEnabled {
            // Clear text-based rate-limit state so sidebar indicators disappear,
            // but preserve prompt-based markers (managed by syncBusySessionsFromProcessState).
            // Continue scanning panes below to keep the fingerprint cache warm.
            var changed = false
            for i in threads.indices {
                let promptOnly = threads[i].rateLimitedSessions.filter { $0.value.isPromptBased }
                if threads[i].rateLimitedSessions.count != promptOnly.count {
                    threads[i].rateLimitedSessions = promptOnly
                    changed = true
                }
            }
            let hadGlobal = !globalAgentRateLimits.isEmpty
            globalAgentRateLimits.removeAll()
            if changed || hadGlobal {
                lastPublishedRateLimitSummary = nil
                await MainActor.run {
                    delegate?.threadManager(self, didUpdateThreads: threads)
                    NotificationCenter.default.post(name: .magentAgentRateLimitChanged, object: nil)
                    NotificationCenter.default.post(name: .magentGlobalRateLimitSummaryChanged, object: nil)
                }
            }
        }
        let now = Date()
        var changedThreadIds = Set<UUID>()
        var didChangeGlobalCache = pruneExpiredGlobalRateLimits(now: now, changedThreadIds: &changedThreadIds)
        var newlyDetectedAgents = Set<AgentType>()

        // Lazy-load persisted rate-limit caches on first use.
        ensureRateLimitCachesLoaded()

        // Determine the currently visible session so we can scan it on every tick.
        // All other sessions are throttled to one scan per 15 seconds.
        let activeSession: String? = threads.first(where: { $0.id == activeThreadId })?.lastSelectedTabIdentifier
        let rateLimitThrottle: TimeInterval = 15

        let rateLimitSnapshot = threads.filter { !$0.isArchived }
        for thread in rateLimitSnapshot {
            let threadId = thread.id
            var updatedRateLimits = thread.rateLimitedSessions
            let validSessions = Set(thread.tmuxSessionNames)

            for sessionName in thread.tmuxSessionNames {
                guard thread.agentTmuxSessions.contains(sessionName) else {
                    if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(threadId)
                    }
                    continue
                }

                guard let sessionAgent = agentType(for: thread, sessionName: sessionName),
                      isRateLimitTrackable(agent: sessionAgent) else {
                    if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(threadId)
                    }
                    continue
                }

                // Non-active sessions: skip pane fetch if scanned recently.
                // Existing markers survive via `pruneExpiredGlobalRateLimits`; no state is lost.
                let isActiveSession = sessionName == activeSession
                let lastScan = lastRateLimitScanBySession[sessionName] ?? .distantPast
                if !isActiveSession && now.timeIntervalSince(lastScan) < rateLimitThrottle {
                    continue
                }
                lastRateLimitScanBySession[sessionName] = now

                guard let paneContent = await tmux.cachedCapturePane(sessionName: sessionName, lastLines: 120),
                      let detection = rateLimitDetection(from: paneContent, now: now, agent: sessionAgent) else {
                    if detectionEnabled {
                        let existing = updatedRateLimits[sessionName]
                        // Concrete fingerprint-based limits stay active until
                        // resetAt expires or the user clears them manually.
                        if (existing?.isPromptBased == true)
                            || hasUnexpiredConcreteRateLimit(existing, now: now) {
                            // keep existing marker
                        } else if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                            changedThreadIds.insert(threadId)
                        }
                    }
                    continue
                }

                if isIgnoredRateLimitFingerprint(detection.fingerprint, for: sessionAgent) {
                    if detectionEnabled {
                        if let existing = updatedRateLimits[sessionName], existing.isPromptBased {
                            // keep prompt-based marker
                        } else if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                            changedThreadIds.insert(threadId)
                        }
                    }
                    continue
                }

                // Check persisted fingerprint cache: if we've seen this exact text before,
                // use the concrete resetAt from first detection instead of re-parsing.
                if let cachedResetAt = rateLimitFingerprintCache[detection.fingerprint] {
                    if cachedResetAt <= now {
                        // Already expired — skip detection entirely.
                        if detectionEnabled {
                            if let existing = updatedRateLimits[sessionName], existing.isPromptBased {
                                // keep prompt-based marker
                            } else if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                                changedThreadIds.insert(threadId)
                            }
                        }
                        continue
                    }
                    // Fingerprint already cached with valid time — update visible state only.
                    guard detectionEnabled else { continue }
                    var info = detection.info
                    info.resetAt = cachedResetAt

                    if updatedRateLimits[sessionName] != info {
                        updatedRateLimits[sessionName] = info
                        changedThreadIds.insert(threadId)
                    }
                    updateGlobalRateLimit(
                        info,
                        for: sessionAgent,
                        now: now,
                        didChangeGlobalCache: &didChangeGlobalCache,
                        newlyDetectedAgents: &newlyDetectedAgents
                    )
                    continue
                }

                // First time seeing this fingerprint — anchor the resetAt as a concrete date.
                // Always cache, even when detection is disabled, so re-enabling works correctly.
                rateLimitFingerprintCache[detection.fingerprint] = detection.info.resetAt
                rateLimitCacheDirty = true

                guard detectionEnabled else { continue }

                let info = detection.info

                // Discard if reset time is already in the past (already cached above).
                if info.resetAt <= now {
                    if let existing = updatedRateLimits[sessionName], existing.isPromptBased {
                        // keep prompt-based marker
                    } else if updatedRateLimits.removeValue(forKey: sessionName) != nil {
                        changedThreadIds.insert(threadId)
                    }
                    continue
                }

                if updatedRateLimits[sessionName] != info {
                    updatedRateLimits[sessionName] = info
                    changedThreadIds.insert(threadId)
                }
                updateGlobalRateLimit(
                    info,
                    for: sessionAgent,
                    now: now,
                    didChangeGlobalCache: &didChangeGlobalCache,
                    newlyDetectedAgents: &newlyDetectedAgents
                )
            }

            for sessionName in Array(updatedRateLimits.keys) where !validSessions.contains(sessionName) {
                updatedRateLimits.removeValue(forKey: sessionName)
                changedThreadIds.insert(threadId)
            }

            // Re-lookup after await — the thread may have been archived/removed
            if let j = threads.firstIndex(where: { $0.id == threadId }),
               updatedRateLimits != threads[j].rateLimitedSessions {
                // Mark newly rate-limited sessions as unread for "requires attention" UX.
                let previousSessions = Set(threads[j].rateLimitedSessions.keys)
                let newSessions = Set(updatedRateLimits.keys).subtracting(previousSessions)
                if !newSessions.isEmpty {
                    threads[j].unreadRateLimitSessions.formUnion(newSessions)
                }
                threads[j].rateLimitedSessions = updatedRateLimits
                changedThreadIds.insert(threadId)
            }
        }

        propagateActiveGlobalRateLimits(now: now, changedThreadIds: &changedThreadIds)

        if !changedThreadIds.isEmpty {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in changedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: self,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
        }

        if didChangeGlobalCache {
            lastPublishedRateLimitSummary = nil
        }
        playRateLimitDetectedSound(for: newlyDetectedAgents)
        await publishRateLimitSummaryIfNeeded()

        // Persist fingerprint cache if it changed.
        if rateLimitCacheDirty {
            rateLimitCacheDirty = false
            persistence.saveRateLimitCache(rateLimitFingerprintCache)
        }
        persistIgnoredRateLimitCacheIfNeeded()
    }

    private func isRateLimitTrackable(agent: AgentType) -> Bool {
        return agent == .claude || agent == .codex
    }

    private func mergedRateLimitInfo(existing: AgentRateLimitInfo, candidate: AgentRateLimitInfo) -> AgentRateLimitInfo {
        if existing.isPromptBased && candidate.isPromptBased {
            return existing
        }
        if existing.isPromptBased != candidate.isPromptBased {
            return existing.isPromptBased ? candidate : existing
        }
        var result: AgentRateLimitInfo
        if candidate.resetAt != existing.resetAt {
            result = candidate.resetAt > existing.resetAt ? candidate : existing
        } else {
            result = candidate.detectedAt >= existing.detectedAt ? candidate : existing
        }
        // A directly-detected (non-propagated) marker wins over a propagated one.
        if !existing.isPropagated || !candidate.isPropagated {
            result.isPropagated = false
        }
        return result
    }

    private func activeGlobalRateLimit(for agent: AgentType, now: Date) -> AgentRateLimitInfo? {
        guard let info = globalAgentRateLimits[agent] else { return nil }
        guard info.resetAt > now else { return nil }
        return info
    }

    private func updateGlobalRateLimit(
        _ info: AgentRateLimitInfo,
        for agent: AgentType,
        now: Date,
        didChangeGlobalCache: inout Bool,
        newlyDetectedAgents: inout Set<AgentType>
    ) {
        let hadActiveGlobalRateLimit = activeGlobalRateLimit(for: agent, now: now) != nil
        let nextInfo: AgentRateLimitInfo
        if let existing = activeGlobalRateLimit(for: agent, now: now) {
            nextInfo = mergedRateLimitInfo(existing: existing, candidate: info)
        } else {
            nextInfo = info
        }

        if globalAgentRateLimits[agent] != nextInfo {
            globalAgentRateLimits[agent] = nextInfo
            didChangeGlobalCache = true
        }
        if !hadActiveGlobalRateLimit {
            newlyDetectedAgents.insert(agent)
        }
    }

    @discardableResult
    func applyRateLimitMarker(
        _ info: AgentRateLimitInfo,
        for agent: AgentType,
        changedThreadIds: inout Set<UUID>
    ) -> Bool {
        var changed = false
        // Markers applied through fan-out are propagated unless the session
        // already has a directly-detected (non-propagated) marker.
        var propagatedInfo = info
        propagatedInfo.isPropagated = true
        propagatedInfo.agentType = agent

        for i in threads.indices where !threads[i].isArchived {
            var updatedRateLimits = threads[i].rateLimitedSessions

            for sessionName in threads[i].agentTmuxSessions {
                guard agentType(for: threads[i], sessionName: sessionName) == agent else { continue }
                let candidate = propagatedInfo
                let nextInfo: AgentRateLimitInfo
                if let existing = updatedRateLimits[sessionName] {
                    nextInfo = mergedRateLimitInfo(existing: existing, candidate: candidate)
                } else {
                    nextInfo = candidate
                }

                if updatedRateLimits[sessionName] != nextInfo {
                    updatedRateLimits[sessionName] = nextInfo
                    changed = true
                }
            }

            if updatedRateLimits != threads[i].rateLimitedSessions {
                threads[i].rateLimitedSessions = updatedRateLimits
                changedThreadIds.insert(threads[i].id)
            }
        }

        return changed
    }

    @discardableResult
    func clearPromptRateLimitMarkers(for agent: AgentType, changedThreadIds: inout Set<UUID>) -> Bool {
        var changed = false

        for i in threads.indices where !threads[i].isArchived {
            var updatedRateLimits = threads[i].rateLimitedSessions
            let promptKeys = updatedRateLimits.keys.filter { sessionName in
                guard let existing = updatedRateLimits[sessionName], existing.isPromptBased else { return false }
                return agentType(for: threads[i], sessionName: sessionName) == agent
            }

            guard !promptKeys.isEmpty else { continue }
            for key in promptKeys {
                updatedRateLimits.removeValue(forKey: key)
            }

            if updatedRateLimits != threads[i].rateLimitedSessions {
                threads[i].rateLimitedSessions = updatedRateLimits
                changedThreadIds.insert(threads[i].id)
                changed = true
            }
        }

        return changed
    }

    private func propagateActiveGlobalRateLimits(now: Date, changedThreadIds: inout Set<UUID>) {
        for agent in [AgentType.claude, .codex] {
            guard let info = activeGlobalRateLimit(for: agent, now: now) else { continue }
            _ = applyRateLimitMarker(info, for: agent, changedThreadIds: &changedThreadIds)
        }
    }

    @discardableResult
    private func pruneExpiredGlobalRateLimits(now: Date, changedThreadIds: inout Set<UUID>) -> Bool {
        let expiredAgents = globalAgentRateLimits.compactMap { entry -> AgentType? in
            guard entry.value.resetAt <= now else { return nil }
            return entry.key
        }
        guard !expiredAgents.isEmpty else { return false }

        for agent in expiredAgents {
            globalAgentRateLimits.removeValue(forKey: agent)
            clearRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
        }
        sendRateLimitLiftedNotification(for: expiredAgents)
        return true
    }

    private func sendRateLimitLiftedNotification(for agents: [AgentType]) {
        let settings = persistence.loadSettings()
        let shouldShowSystemNotification = settings.showSystemNotificationOnRateLimitLifted
        let shouldPlaySound = settings.notifyOnRateLimitLifted
        guard shouldShowSystemNotification || shouldPlaySound else { return }

        let agentNames = agents.map(\.displayName).joined(separator: ", ")

        if shouldShowSystemNotification && settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = String(localized: .NotificationStrings.notificationsRateLimitLiftedTitle)
            content.body = agents.count == 1
                ? String(localized: .NotificationStrings.notificationsRateLimitLiftedBodyOne(agents[0].displayName))
                : String(localized: .NotificationStrings.notificationsRateLimitLiftedBodyMany(agentNames))
            if shouldPlaySound {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.rateLimitLiftedSoundName))
            }

            let request = UNNotificationRequest(
                identifier: "magent-rate-limit-lifted-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if shouldPlaySound {
            let soundName = settings.rateLimitLiftedSoundName
            DispatchQueue.main.async {
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func playRateLimitDetectedSound(for agents: Set<AgentType>) {
        guard !agents.isEmpty else { return }

        let settings = persistence.loadSettings()
        guard settings.enableRateLimitDetection else { return }
        guard settings.playSoundOnRateLimitDetected else { return }

        let soundName = settings.rateLimitDetectedSoundName
        DispatchQueue.main.async {
            if let sound = NSSound(named: NSSound.Name(soundName)) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    }

    func publishRateLimitSummaryIfNeeded() async {
        let summary = globalRateLimitSummaryText()
        guard summary != lastPublishedRateLimitSummary else { return }
        lastPublishedRateLimitSummary = summary
        await MainActor.run {
            NotificationCenter.default.post(
                name: .magentGlobalRateLimitSummaryChanged,
                object: self
            )
        }
    }

    private func clearRateLimitMarkers(for agent: AgentType, changedThreadIds: inout Set<UUID>) {
        for i in threads.indices {
            var filtered = threads[i].rateLimitedSessions
            let keysToRemove = filtered.keys.filter { sessionName in
                agentType(for: threads[i], sessionName: sessionName) == agent
            }
            guard !keysToRemove.isEmpty else { continue }
            for key in keysToRemove {
                filtered.removeValue(forKey: key)
            }
            threads[i].rateLimitedSessions = filtered
            threads[i].unreadRateLimitSessions.subtract(keysToRemove)
            changedThreadIds.insert(threads[i].id)
        }
    }

    @discardableResult
    func liftRateLimitManually(for agent: AgentType) async -> Set<UUID> {
        guard isRateLimitTrackable(agent: agent) else { return [] }
        let hadGlobal = globalAgentRateLimits.removeValue(forKey: agent) != nil

        var changedThreadIds = Set<UUID>()
        clearRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
        guard hadGlobal || !changedThreadIds.isEmpty else { return [] }

        lastPublishedRateLimitSummary = nil
        if !changedThreadIds.isEmpty {
            await MainActor.run {
                delegate?.threadManager(self, didUpdateThreads: threads)
                for threadId in changedThreadIds {
                    NotificationCenter.default.post(
                        name: .magentAgentRateLimitChanged,
                        object: self,
                        userInfo: ["threadId": threadId]
                    )
                }
            }
        }
        await publishRateLimitSummaryIfNeeded()
        return changedThreadIds
    }

    @discardableResult
    func liftAndIgnoreCurrentRateLimitFingerprints(for agent: AgentType) async -> Int {
        guard isRateLimitTrackable(agent: agent) else { return 0 }
        ensureRateLimitCachesLoaded()

        let now = Date()
        let snapshot = threads.filter { !$0.isArchived }
        var activeFingerprints = Set<String>()

        for thread in snapshot {
            for sessionName in thread.agentTmuxSessions {
                guard agentType(for: thread, sessionName: sessionName) == agent else { continue }
                guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 120),
                      let detection = rateLimitDetection(from: paneContent, now: now, agent: agent) else {
                    continue
                }
                let effectiveResetAt = rateLimitFingerprintCache[detection.fingerprint] ?? detection.info.resetAt
                guard effectiveResetAt > now else { continue }
                activeFingerprints.insert(detection.fingerprint)
            }
        }

        var ignored = ignoredRateLimitFingerprintsByAgent[agent] ?? []
        let before = ignored.count
        ignored.formUnion(activeFingerprints)
        let added = ignored.count - before
        if added > 0 {
            ignoredRateLimitFingerprintsByAgent[agent] = ignored
            ignoredRateLimitCacheDirty = true
            persistIgnoredRateLimitCacheIfNeeded()
        }

        _ = await liftRateLimitManually(for: agent)
        return added
    }

    func paneHasActiveNonIgnoredRateLimit(for agent: AgentType, paneContent: String, now: Date = Date()) -> Bool {
        guard isRateLimitTrackable(agent: agent) else { return false }
        ensureRateLimitCachesLoaded()
        guard let detection = rateLimitDetection(from: paneContent, now: now, agent: agent) else { return false }
        guard !isIgnoredRateLimitFingerprint(detection.fingerprint, for: agent) else { return false }

        if let cachedResetAt = rateLimitFingerprintCache[detection.fingerprint] {
            return cachedResetAt > now
        }
        return detection.info.resetAt > now
    }

    /// If an agent starts processing work after being rate-limited, clear the rate-limit
    /// cache for that agent globally and remove markers from all tabs using it.
    @discardableResult
    func clearRateLimitAfterRecovery(
        threadId: UUID,
        sessionName: String,
        paneContent: String? = nil
    ) async -> Set<UUID> {
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }
        guard let agent = agentType(for: thread, sessionName: sessionName),
              isRateLimitTrackable(agent: agent) else {
            return []
        }

        let hadSessionMarker = thread.rateLimitedSessions[sessionName] != nil
        let hadGlobalMarker = globalAgentRateLimits[agent] != nil
        guard hadSessionMarker || hadGlobalMarker else { return [] }

        let now = Date()
        if hasUnexpiredConcreteRateLimit(thread.rateLimitedSessions[sessionName], now: now)
            || activeGlobalRateLimit(for: agent, now: now) != nil {
            return []
        }

        let latestPaneContent: String?
        if let paneContent {
            latestPaneContent = paneContent
        } else {
            latestPaneContent = await tmux.cachedCapturePane(sessionName: sessionName, lastLines: 120)
        }
        guard let latestPaneContent else { return [] }
        if paneHasActiveNonIgnoredRateLimit(for: agent, paneContent: latestPaneContent, now: now) {
            return []
        }

        globalAgentRateLimits.removeValue(forKey: agent)
        lastPublishedRateLimitSummary = nil

        var changedThreadIds = Set<UUID>()
        clearRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
        return changedThreadIds
    }

    // MARK: - Rate-Limit Parsing

    private static let rateLimitTailLineCount = 80
    private static let rateLimitIndicatorWindowLineCount = 10
    private static let rateLimitFocusContextBeforeLines = 2
    private static let rateLimitFocusContextAfterLines = 8
    private static let claudePromptDeadlineLookbackLines = 14
    private static let maxRateLimitFingerprintLength = 512

    private func rateLimitDetection(from paneContent: String, now: Date, agent: AgentType) -> RateLimitDetection? {
        let tail = rateLimitTail(from: paneContent, agent: agent)
        if agent == .claude,
           let claudePromptDetection = claudeInteractiveRateLimitDetection(in: tail, now: now) {
            return claudePromptDetection
        }

        // Codex shows an interactive model-switch prompt when approaching (not hitting)
        // rate limits. Skip detection when this prompt is visible — the agent isn't blocked.
        if agent == .codex, codexHasModelSwitchPrompt(in: tail) {
            return nil
        }

        guard let indicatorAnchor = latestRateLimitIndicatorAnchor(in: tail) else { return nil }

        let focusText = rateLimitFocusText(from: tail, anchorIndex: indicatorAnchor)
        guard let parsed = parseResetDate(from: focusText, now: now) else { return nil }

        let resetDescription = extractRateLimitResetDescription(from: focusText)
        let fingerprint = rateLimitFingerprint(from: focusText, fallback: resetDescription)
        return RateLimitDetection(
            info: AgentRateLimitInfo(resetAt: parsed.resetAt, resetDescription: resetDescription, detectedAt: now, agentType: agent),
            fingerprint: fingerprint,
            hasRelativeReset: parsed.hasRelativeReset,
            hasExplicitDateAnchor: parsed.hasExplicitDateAnchor
        )
    }

    private func rateLimitTail(from paneContent: String, agent: AgentType) -> [String] {
        let lines = paneContent
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        let tail = Array(lines.suffix(Self.rateLimitTailLineCount))
        guard agent == .codex else {
            // Claude output often prints the reset timestamp immediately above
            // an options separator; keep the full tail for Claude parsing.
            return tail
        }
        guard let scopeSeparatorIndex = tail.lastIndex(where: { isRateLimitScopeSeparator($0) }) else {
            // No separator in the latest pane block — inspect the full tail.
            return tail
        }

        let scopedStart = tail.index(after: scopeSeparatorIndex)
        guard scopedStart < tail.endIndex else { return tail }
        return Array(tail[scopedStart...])
    }

    /// Detects Codex's interactive model-switch prompt that appears when *approaching*
    /// (not hitting) rate limits. The prompt offers switching to a cheaper model and
    /// contains "rate limit" text that could otherwise trigger false positive detection.
    private func codexHasModelSwitchPrompt(in tail: [String]) -> Bool {
        let recentLines = tail.suffix(15)
        let hasApproaching = recentLines.contains { $0.lowercased().contains("approaching rate limit") }
        let hasSwitchOffer = recentLines.contains {
            let lower = $0.lowercased()
            return lower.contains("switch to") && (lower.contains("codex") || lower.contains("gpt-"))
        }
        return hasApproaching && hasSwitchOffer
    }

    private func isRateLimitScopeSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 20 else { return false }
        return trimmed.allSatisfy { $0 == "─" || $0 == "-" }
    }

    private func claudeInteractiveRateLimitDetection(in tail: [String], now: Date) -> RateLimitDetection? {
        guard let choiceIndex = tail.lastIndex(where: { isClaudeRateLimitWaitChoiceLine($0) }) else {
            return nil
        }

        let lookbackStart = max(tail.startIndex, choiceIndex - Self.claudePromptDeadlineLookbackLines)
        let choiceLine = tail[choiceIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let switchChoiceLine: String? = {
            let nextIndex = choiceIndex + 1
            guard nextIndex < tail.endIndex else { return nil }
            let line = tail[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return isClaudeRateLimitSwitchChoiceLine(line) ? line : nil
        }()

        var candidateIndices = [choiceIndex]
        if lookbackStart < choiceIndex {
            candidateIndices.append(contentsOf: stride(from: choiceIndex - 1, through: lookbackStart, by: -1))
        }

        for candidateIndex in candidateIndices {
            let deadlineLine = tail[candidateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deadlineLine.isEmpty else { continue }

            let normalized = deadlineLine.lowercased()
            let hasResetKeyword = normalized.contains("reset")
                || normalized.contains("try again")
                || normalized.contains("retry")
                || normalized.contains("available")
                || normalized.contains("until")
            guard hasResetKeyword else { continue }

            var focusLines = [deadlineLine]
            if deadlineLine != choiceLine {
                focusLines.append(choiceLine)
            }
            if let switchChoiceLine, !switchChoiceLine.isEmpty {
                focusLines.append(switchChoiceLine)
            }
            if let contextIndex = stride(from: candidateIndex, through: lookbackStart, by: -1).first(where: { idx in
                let context = tail[idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return context.contains("limit") || context.contains("rate") || context.contains("quota")
            }) {
                let contextLine = tail[contextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !contextLine.isEmpty, contextLine != deadlineLine {
                    focusLines.insert(contextLine, at: 0)
                }
            }

            let focusText = focusLines.joined(separator: "\n")
            guard let parsed = parseResetDate(from: focusText, now: now) else { continue }

            let resetDescription = extractRateLimitResetDescription(from: focusText)
            let fingerprint = rateLimitFingerprint(
                from: focusText,
                fallback: resetDescription
            )
            return RateLimitDetection(
                info: AgentRateLimitInfo(resetAt: parsed.resetAt, resetDescription: resetDescription, detectedAt: now, agentType: .claude),
                fingerprint: fingerprint,
                hasRelativeReset: parsed.hasRelativeReset,
                hasExplicitDateAnchor: parsed.hasExplicitDateAnchor
            )
        }
        return nil
    }

    private func isClaudeRateLimitWaitChoiceLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.range(of: #"^\d+\.\s*stop and wait\b"#, options: .regularExpression) != nil else {
            return false
        }
        return normalized.contains("reset")
            || normalized.contains("limit")
            || normalized.contains("quota")
            || normalized.contains("until")
            || normalized.contains("available")
            || normalized.contains("try again")
            || normalized.contains("retry")
    }

    private func isClaudeRateLimitSwitchChoiceLine(_ line: String) -> Bool {
        let normalized = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.range(of: #"^\d+\.\s*switch to\b"#, options: .regularExpression) != nil else {
            return false
        }
        return normalized.contains("extra usage")
            || normalized.contains("max")
            || normalized.contains("pro")
            || normalized.contains("plan")
    }

    private func parseResetDate(
        from focusText: String,
        now: Date
    ) -> (resetAt: Date, hasExplicitDateAnchor: Bool, hasRelativeReset: Bool)? {
        let relativeResetAt = parseRelativeResetDate(from: focusText, now: now)
        let explicitResult = parseExplicitResetDate(from: focusText, now: now)
        let fullDateResetAt = parseFullDateResetDate(from: focusText)
        let absoluteResetAt = parseAbsoluteResetDate(from: focusText, now: now)

        let resetAt: Date
        let hasExplicitDateAnchor: Bool
        let hasRelativeReset: Bool
        if let rel = relativeResetAt {
            resetAt = rel
            hasExplicitDateAnchor = true // relative durations are anchored to "now"
            hasRelativeReset = true
        } else if let exp = explicitResult {
            resetAt = exp.date
            hasExplicitDateAnchor = exp.hasDayToken
            hasRelativeReset = false
        } else if let fullDate = fullDateResetAt {
            resetAt = fullDate
            hasExplicitDateAnchor = true
            hasRelativeReset = false
        } else if let abs = absoluteResetAt {
            resetAt = abs
            hasExplicitDateAnchor = focusTextHasDateMarkers(focusText)
            hasRelativeReset = false
        } else {
            // No parseable reset time — skip detection entirely (resetAt is mandatory).
            return nil
        }

        // Cap bare-time resets at 8 hours to avoid stale overnight detections
        // (e.g. "resets 4pm" parsed as today's 4pm when the message is from yesterday).
        let maxBareTimeDuration: TimeInterval = 8 * 3600
        if !hasExplicitDateAnchor && resetAt > now.addingTimeInterval(maxBareTimeDuration) {
            return nil
        }

        return (resetAt: resetAt, hasExplicitDateAnchor: hasExplicitDateAnchor, hasRelativeReset: hasRelativeReset)
    }

    private func latestRateLimitIndicatorAnchor(in tail: [String]) -> Int? {
        let indexedRecentLines: [(index: Int, text: String)] = tail.enumerated().compactMap { index, line in
            let normalized = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty else { return nil }
            return (index, normalized)
        }
        guard !indexedRecentLines.isEmpty else { return nil }

        let recentWindow = Array(indexedRecentLines.suffix(Self.rateLimitIndicatorWindowLineCount))
        guard !recentWindow.isEmpty else { return nil }

        if let strongHit = recentWindow.last(where: { isStrongRateLimitIndicator($0.text) }) {
            return strongHit.index
        }

        let normalizedRecentWindow = recentWindow.map(\.text).joined(separator: "\n")
        guard hasWeakRateLimitSignal(in: normalizedRecentWindow) else { return nil }
        return recentWindow.last?.index
    }

    private func isStrongRateLimitIndicator(_ normalizedText: String) -> Bool {
        normalizedText.contains("too many requests")
            || normalizedText.contains("quota exceeded")
            || normalizedText.contains("retry after")
            || normalizedText.contains("try again in")
            || normalizedText.contains("limit reached")
            || normalizedText.contains("limit exceeded")
            || normalizedText.contains("rate limited")
            || normalizedText.contains("hit your usage limit")
            || normalizedText.contains("hit your rate limit")
            || normalizedText.contains("you've hit your limit")
            || (normalizedText.contains("hit your limit") && normalizedText.contains("reset"))
            || normalizedText.contains("you've been rate")
    }

    private func hasWeakRateLimitSignal(in normalizedText: String) -> Bool {
        let hasWeakKeyword = normalizedText.contains("rate limit")
            || normalizedText.contains("usage limit")
        let hasBlockingContext = normalizedText.contains("exceeded")
            || normalizedText.contains("reached")
            || normalizedText.contains("throttl")
            || normalizedText.contains("blocked")
            || normalizedText.contains("paused")
            || (normalizedText.contains("wait") && normalizedText.contains("until"))
        return hasWeakKeyword && hasBlockingContext
    }

    private func rateLimitFocusText(from tail: [String], anchorIndex: Int) -> String {
        guard !tail.isEmpty else { return "" }

        let start = max(tail.startIndex, anchorIndex - Self.rateLimitFocusContextBeforeLines)
        let end = min(tail.endIndex - 1, anchorIndex + Self.rateLimitFocusContextAfterLines)
        let context = Array(tail[start...end])

        let focusLines = context.filter { line in
            let normalized = line.lowercased()
            return normalized.contains("rate")
                || normalized.contains("limit")
                || normalized.contains("quota")
                || normalized.contains("retry")
                || normalized.contains("try again")
                || normalized.contains("reset")
                || normalized.contains("available")
                || normalized.contains("until")
        }
        return (focusLines.isEmpty ? context.suffix(12) : focusLines.suffix(12))
            .joined(separator: "\n")
    }

    private func rateLimitFingerprint(from focusText: String, fallback: String?) -> String {
        let normalizedFocus = focusText
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFocus.isEmpty {
            return String(normalizedFocus.prefix(Self.maxRateLimitFingerprintLength))
        }
        let normalizedFallback = fallback?
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedFallback, !normalizedFallback.isEmpty {
            return String(normalizedFallback.prefix(Self.maxRateLimitFingerprintLength))
        }
        return "__empty_rate_limit_fingerprint__"
    }

    private func parseRelativeResetDate(from text: String, now: Date) -> Date? {
        let normalized = text.lowercased()
        let triggerPattern = #"(?:try again|retry|resets?|reset|available)\s+(?:in|after)\s+([^\n\.;,]+)"#
        guard let triggerRegex = try? NSRegularExpression(pattern: triggerPattern, options: []) else { return nil }
        let searchRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

        for match in triggerRegex.matches(in: normalized, options: [], range: searchRange) {
            guard match.numberOfRanges >= 2,
                  let durationRange = Range(match.range(at: 1), in: normalized) else { continue }
            let durationText = String(normalized[durationRange])
            if let seconds = parseDurationSeconds(from: durationText), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }

        // Fallback for common API wording (e.g. "retry after 30s").
        if let seconds = parseDurationSeconds(from: normalized), seconds > 0,
           normalized.contains("retry after") || normalized.contains("try again in") {
            return now.addingTimeInterval(seconds)
        }

        return nil
    }

    private func parseDurationSeconds(from text: String) -> TimeInterval? {
        let tokenPattern = #"(\d+)\s*(days?|d|hours?|hrs?|hr|h|minutes?|mins?|min|m|seconds?|secs?|sec|s)\b"#
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var seconds: TimeInterval = 0
        var matchedAny = false

        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges >= 3,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange]) else {
                continue
            }
            matchedAny = true

            switch text[unitRange] {
            case "d", "day", "days":
                seconds += value * 86_400
            case "h", "hr", "hrs", "hour", "hours":
                seconds += value * 3_600
            case "m", "min", "mins", "minute", "minutes":
                seconds += value * 60
            case "s", "sec", "secs", "second", "seconds":
                seconds += value
            default:
                continue
            }
        }

        return matchedAny ? seconds : nil
    }

    /// Parses explicit reset times like:
    /// "You've hit your limit · resets 4pm (Europe/Warsaw)".
    /// If no day token is provided, the reset is assumed to be today in the parsed timezone.
    private func focusTextHasDateMarkers(_ text: String) -> Bool {
        let lower = text.lowercased()
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if monthNames.contains(where: { lower.contains($0) }) { return true }
        if lower.range(of: #"\b20\d{2}\b"#, options: .regularExpression) != nil { return true }
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                        "tomorrow"]
        if dayNames.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    private func parseExplicitResetDate(from text: String, now: Date) -> (date: Date, hasDayToken: Bool)? {
        let pattern = #"(?:resets?|try again|retry)\s+(?:(?:at|on)\s+)?(?:(today|tomorrow|mon(?:day)?|tues?(?:day)?|wed(?:nesday)?|thurs?(?:day)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)[,;]?\s+)?(?:at\s+)?(\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)(?:\s*\(([^)\n]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let clockRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let dayToken: String? = {
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[range])
            }()
            let timezoneToken: String? = {
                guard match.numberOfRanges >= 4,
                      let range = Range(match.range(at: 3), in: text) else { return nil }
                return String(text[range])
            }()

            guard let clock = parseResetClockComponents(from: String(text[clockRange])) else { continue }

            let timezone = parseResetTimeZone(from: timezoneToken) ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone

            let dayOffset = parseResetDayOffset(from: dayToken, now: now, calendar: calendar)
            var dateComponents = calendar.dateComponents([.year, .month, .day], from: now)
            dateComponents.timeZone = timezone
            dateComponents.hour = clock.hour
            dateComponents.minute = clock.minute
            dateComponents.second = 0

            guard let baseDate = calendar.date(from: dateComponents) else { continue }
            let hasDayToken = dayToken != nil
            if dayOffset == 0 {
                if dayToken == nil,
                   baseDate.timeIntervalSince(now) > 12 * 3600,
                   let yesterday = calendar.date(byAdding: .day, value: -1, to: baseDate),
                   now.timeIntervalSince(yesterday) >= 0,
                   now.timeIntervalSince(yesterday) <= 6 * 3600 {
                    return (date: yesterday, hasDayToken: hasDayToken)
                }
                return (date: baseDate, hasDayToken: hasDayToken)
            }
            if let shifted = calendar.date(byAdding: .day, value: dayOffset, to: baseDate) {
                return (date: shifted, hasDayToken: hasDayToken)
            }
        }

        return nil
    }

    /// Parses full date+time phrases like:
    /// "try again at Mar 6th, 2026 1:17 AM"
    /// "retry at March 6, 2026 1:17AM"
    /// "available at Feb 28th, 2026 11:30 PM"
    private func parseFullDateResetDate(from text: String) -> Date? {
        let pattern = #"(?:try again|retry|available|resets?)\s+at\s+(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{4})\s+(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 7,
              let monthRange = Range(match.range(at: 1), in: text),
              let dayRange = Range(match.range(at: 2), in: text),
              let yearRange = Range(match.range(at: 3), in: text),
              let hourRange = Range(match.range(at: 4), in: text),
              let minuteRange = Range(match.range(at: 5), in: text),
              let meridiemRange = Range(match.range(at: 6), in: text) else {
            return nil
        }

        let monthStr = String(text[monthRange]).lowercased().prefix(3)
        let monthMap: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        guard let month = monthMap[String(monthStr)],
              let day = Int(text[dayRange]),
              let year = Int(text[yearRange]),
              let hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange]),
              (1...12).contains(hour) else {
            return nil
        }

        let meridiem = String(text[meridiemRange])
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hour24: Int
        if meridiem.hasPrefix("p") {
            hour24 = hour == 12 ? 12 : hour + 12
        } else if meridiem.hasPrefix("a") {
            hour24 = hour == 12 ? 0 : hour
        } else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour24
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private func parseResetClockComponents(from text: String) -> (hour: Int, minute: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(\d{1,2})(?::([0-5]\d))?\s*([ap]\.?m\.?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 4,
              let hourRange = Range(match.range(at: 1), in: trimmed),
              let hourValue = Int(trimmed[hourRange]) else {
            return nil
        }

        let minuteValue: Int = {
            guard let minuteRange = Range(match.range(at: 2), in: trimmed),
                  let minute = Int(trimmed[minuteRange]) else {
                return 0
            }
            return minute
        }()

        let meridiem = Range(match.range(at: 3), in: trimmed).map { String(trimmed[$0]) }
        if let meridiem {
            let normalized = meridiem
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...12).contains(hourValue) else { return nil }
            if normalized.hasPrefix("p") {
                return (hour: hourValue == 12 ? 12 : hourValue + 12, minute: minuteValue)
            }
            if normalized.hasPrefix("a") {
                return (hour: hourValue == 12 ? 0 : hourValue, minute: minuteValue)
            }
            return nil
        }

        guard (0...23).contains(hourValue) else { return nil }
        return (hour: hourValue, minute: minuteValue)
    }

    private func parseResetTimeZone(from token: String?) -> TimeZone? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let tz = TimeZone(identifier: trimmed) {
            return tz
        }

        let underscored = trimmed.replacingOccurrences(of: " ", with: "_")
        if let tz = TimeZone(identifier: underscored) {
            return tz
        }

        return TimeZone(abbreviation: trimmed.uppercased())
    }

    private func parseResetDayOffset(from token: String?, now: Date, calendar: Calendar) -> Int {
        guard let token else { return 0 }
        let normalized = token
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == "today" {
            return 0
        }
        if normalized == "tomorrow" {
            return 1
        }
        guard let targetWeekday = weekdayIndex(forResetDayToken: normalized) else {
            // Unknown day token: keep today semantics.
            return 0
        }

        let currentWeekday = calendar.component(.weekday, from: now)
        return (targetWeekday - currentWeekday + 7) % 7
    }

    private func weekdayIndex(forResetDayToken token: String) -> Int? {
        if token.hasPrefix("sun") { return 1 }
        if token.hasPrefix("mon") { return 2 }
        if token.hasPrefix("tue") { return 3 }
        if token.hasPrefix("wed") { return 4 }
        if token.hasPrefix("thu") { return 5 }
        if token.hasPrefix("fri") { return 6 }
        if token.hasPrefix("sat") { return 7 }
        return nil
    }

    private func parseAbsoluteResetDate(from text: String, now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let relevantLines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                let normalized = line.lowercased()
                return normalized.contains("reset")
                    || normalized.contains("available")
                    || normalized.contains("until")
                    || normalized.contains("try again")
                    || normalized.contains("retry")
            }
        let detectorText = relevantLines.isEmpty ? text : relevantLines.joined(separator: "\n")
        let range = NSRange(detectorText.startIndex..<detectorText.endIndex, in: detectorText)

        return detector.matches(in: detectorText, options: [], range: range)
            .compactMap(\.date)
            .filter { $0 > now.addingTimeInterval(-60) }
            .sorted()
            .first
    }

    private func extractRateLimitResetDescription(from text: String) -> String? {
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let candidate = lines.reversed().first { line in
            let normalized = line.lowercased()
            return normalized.contains("reset")
                || normalized.contains("available")
                || normalized.contains("until")
                || normalized.contains("retry")
                || normalized.contains("try again")
        } ?? lines.last

        guard let candidate else { return nil }
        let normalizedWhitespace = candidate.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalizedWhitespace.isEmpty ? nil : normalizedWhitespace
    }
}
