import AppKit
import Foundation
import UserNotifications

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

        // Lazy-load persisted rate-limit caches on first use.
        ensureRateLimitCachesLoaded()

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

                if detectionEnabled {
                    let cachedGlobalInfo = activeGlobalRateLimit(for: sessionAgent, now: now)
                    if let cachedGlobalInfo, updatedRateLimits[sessionName] != cachedGlobalInfo {
                        updatedRateLimits[sessionName] = cachedGlobalInfo
                        changedThreadIds.insert(threadId)
                    }
                }

                guard let paneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 120),
                      let detection = rateLimitDetection(from: paneContent, now: now) else {
                    if detectionEnabled {
                        // Preserve prompt-based markers — they are managed by
                        // syncBusySessionsFromProcessState, not by this function.
                        if let existing = updatedRateLimits[sessionName], existing.isPromptBased {
                            // keep prompt-based marker
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

                    // Preserve original detectedAt from in-memory state if available.
                    if let existing = updatedRateLimits[sessionName] {
                        info.detectedAt = existing.detectedAt
                    }

                    if updatedRateLimits[sessionName] != info {
                        updatedRateLimits[sessionName] = info
                        changedThreadIds.insert(threadId)
                    }
                    if globalAgentRateLimits[sessionAgent] != info {
                        globalAgentRateLimits[sessionAgent] = info
                        didChangeGlobalCache = true
                    }
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
                if globalAgentRateLimits[sessionAgent] != info {
                    globalAgentRateLimits[sessionAgent] = info
                    didChangeGlobalCache = true
                }
            }

            for sessionName in Array(updatedRateLimits.keys) where !validSessions.contains(sessionName) {
                updatedRateLimits.removeValue(forKey: sessionName)
                changedThreadIds.insert(threadId)
            }

            // Re-lookup after await — the thread may have been archived/removed
            if let j = threads.firstIndex(where: { $0.id == threadId }),
               updatedRateLimits != threads[j].rateLimitedSessions {
                threads[j].rateLimitedSessions = updatedRateLimits
                changedThreadIds.insert(threadId)
            }
        }

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

    private func activeGlobalRateLimit(for agent: AgentType, now: Date) -> AgentRateLimitInfo? {
        guard let info = globalAgentRateLimits[agent] else { return nil }
        guard info.resetAt > now else { return nil }
        return info
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
        guard settings.notifyOnRateLimitLifted else { return }

        let agentNames = agents.map(\.rawValue).joined(separator: ", ")

        if settings.showSystemBanners {
            let content = UNMutableNotificationContent()
            content.title = "Rate Limit Lifted"
            content.body = agents.count == 1
                ? "\(agents[0].rawValue.capitalized) is ready to use again"
                : "\(agentNames) are ready to use again"
            content.sound = UNNotificationSound(named: UNNotificationSoundName(settings.rateLimitLiftedSoundName))

            let request = UNNotificationRequest(
                identifier: "magent-rate-limit-lifted-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        let soundName = settings.rateLimitLiftedSoundName
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
                      let detection = rateLimitDetection(from: paneContent, now: now) else {
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
        guard let detection = rateLimitDetection(from: paneContent, now: now) else { return false }
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
        let latestPaneContent: String?
        if let paneContent {
            latestPaneContent = paneContent
        } else {
            latestPaneContent = await tmux.capturePane(sessionName: sessionName, lastLines: 120)
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

    private func rateLimitDetection(from paneContent: String, now: Date) -> RateLimitDetection? {
        let lines = paneContent.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let tail = lines.suffix(80).map(String.init)
        let normalizedRecentTail = tail.suffix(20).joined(separator: "\n").lowercased()

        // Strong indicators — unambiguously mean the agent is blocked.
        let hasStrongIndicator = normalizedRecentTail.contains("too many requests")
            || normalizedRecentTail.contains("quota exceeded")
            || normalizedRecentTail.contains("retry after")
            || normalizedRecentTail.contains("try again in")
            || normalizedRecentTail.contains("limit reached")
            || normalizedRecentTail.contains("limit exceeded")
            || normalizedRecentTail.contains("rate limited")
            || normalizedRecentTail.contains("hit your usage limit")
            || normalizedRecentTail.contains("hit your rate limit")
            || normalizedRecentTail.contains("you've hit your limit")
            || normalizedRecentTail.contains("you've hit your limit")
            || (normalizedRecentTail.contains("hit your limit") && normalizedRecentTail.contains("reset"))
            || normalizedRecentTail.contains("you've been rate")

        // Weak indicators — "rate limit" / "usage limit" can appear in informational
        // displays (e.g. Claude Code status line, or agent output discussing rate limits).
        // Require additional blocking context to avoid false positives.
        if !hasStrongIndicator {
            let hasWeakKeyword = normalizedRecentTail.contains("rate limit")
                || normalizedRecentTail.contains("usage limit")
            let hasBlockingContext = normalizedRecentTail.contains("exceeded")
                || normalizedRecentTail.contains("reached")
                || normalizedRecentTail.contains("throttl")
                || normalizedRecentTail.contains("blocked")
                || normalizedRecentTail.contains("paused")
                || normalizedRecentTail.contains("wait")
                    && normalizedRecentTail.contains("until")
            guard hasWeakKeyword && hasBlockingContext else { return nil }
        }

        let focusText = rateLimitFocusText(from: tail)
        let relativeResetAt = parseRelativeResetDate(from: focusText, now: now)
        let explicitResult = parseExplicitResetDate(from: focusText, now: now)
        let absoluteResetAt = parseAbsoluteResetDate(from: focusText, now: now)

        let resetAt: Date
        let hasExplicitDateAnchor: Bool
        if let rel = relativeResetAt {
            resetAt = rel
            hasExplicitDateAnchor = true // relative durations are anchored to "now"
        } else if let exp = explicitResult {
            resetAt = exp.date
            hasExplicitDateAnchor = exp.hasDayToken
        } else if let abs = absoluteResetAt {
            resetAt = abs
            hasExplicitDateAnchor = focusTextHasDateMarkers(focusText)
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

        let resetDescription = extractRateLimitResetDescription(from: focusText)
        let fingerprint = rateLimitFingerprint(from: focusText, fallback: resetDescription)
        return RateLimitDetection(
            info: AgentRateLimitInfo(resetAt: resetAt, resetDescription: resetDescription, detectedAt: now),
            fingerprint: fingerprint,
            hasRelativeReset: relativeResetAt != nil,
            hasExplicitDateAnchor: hasExplicitDateAnchor
        )
    }

    private func rateLimitFocusText(from tail: [String]) -> String {
        let focusLines = tail.filter { line in
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
        return (focusLines.isEmpty ? tail.suffix(20) : focusLines.suffix(12))
            .joined(separator: "\n")
    }

    private func rateLimitFingerprint(from focusText: String, fallback: String?) -> String {
        let normalizedFocus = focusText
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedFocus.isEmpty {
            return normalizedFocus
        }
        let normalizedFallback = fallback?
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedFallback, !normalizedFallback.isEmpty {
            return normalizedFallback
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
        let pattern = #"resets?\s+(?:at\s+)?(?:(today|tomorrow|mon(?:day)?|tues?(?:day)?|wed(?:nesday)?|thurs?(?:day)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)\s+)?(\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)(?:\s*\(([^)\n]+)\))?"#
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
                return (date: baseDate, hasDayToken: hasDayToken)
            }
            if let shifted = calendar.date(byAdding: .day, value: dayOffset, to: baseDate) {
                return (date: shifted, hasDayToken: hasDayToken)
            }
        }

        return nil
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
