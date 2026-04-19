import AppKit
import Foundation
import UserNotifications
import MagentCore

// MARK: - Forwarding layer — logic lives in RateLimitService

extension ThreadManager {

    // MARK: - Rate-Limit Summary

    func globalRateLimitSummaryText(now: Date = Date()) -> String? {
        rateLimitService.globalRateLimitSummaryText(now: now)
    }

    func globalRateLimitEntries(now: Date = Date()) -> [(agent: AgentType, countdown: String)] {
        rateLimitService.globalRateLimitEntries(now: now)
    }

    func hasActiveRateLimit(for agent: AgentType, now: Date = Date()) -> Bool {
        rateLimitService.hasActiveRateLimit(for: agent, now: now)
    }

    // MARK: - Detection

    func applyRateLimitDetectionSettingChange() {
        rateLimitService.applyRateLimitDetectionSettingChange()
    }

    func checkForRateLimitedSessions() async {
        await rateLimitService.checkForRateLimitedSessions()
    }

    @discardableResult
    func applyRateLimitMarker(
        _ info: AgentRateLimitInfo,
        for agent: AgentType,
        runtimeActiveSessionsByAgent: [AgentType: Set<String>]? = nil,
        changedThreadIds: inout Set<UUID>
    ) -> Bool {
        rateLimitService.applyRateLimitMarker(
            info,
            for: agent,
            runtimeActiveSessionsByAgent: runtimeActiveSessionsByAgent,
            changedThreadIds: &changedThreadIds
        )
    }

    @discardableResult
    func clearPromptRateLimitMarkers(for agent: AgentType, changedThreadIds: inout Set<UUID>) -> Bool {
        rateLimitService.clearPromptRateLimitMarkers(for: agent, changedThreadIds: &changedThreadIds)
    }

    func runtimeActiveRateLimitSessionsByAgent(now: Date = Date()) async -> [AgentType: Set<String>] {
        await rateLimitService.runtimeActiveRateLimitSessionsByAgent(now: now)
    }

    func publishRateLimitSummaryIfNeeded() async {
        await rateLimitService.publishRateLimitSummaryIfNeeded()
    }

    func paneHasActiveNonIgnoredRateLimit(
        for agent: AgentType,
        paneContent: String,
        now: Date = Date(),
        lastSubmittedPrompt: String? = nil,
        sessionName: String? = nil
    ) -> Bool {
        rateLimitService.paneHasActiveNonIgnoredRateLimit(
            for: agent,
            paneContent: paneContent,
            now: now,
            lastSubmittedPrompt: lastSubmittedPrompt,
            sessionName: sessionName
        )
    }

    @discardableResult
    func clearRateLimitAfterRecovery(
        threadId: UUID,
        sessionName: String,
        paneContent: String? = nil
    ) async -> Set<UUID> {
        await rateLimitService.clearRateLimitAfterRecovery(
            threadId: threadId,
            sessionName: sessionName,
            paneContent: paneContent
        )
    }

    @discardableResult
    func liftRateLimitManually(for agent: AgentType) async -> Set<UUID> {
        await rateLimitService.liftRateLimitManually(for: agent)
    }

    @discardableResult
    func liftAndIgnoreCurrentRateLimitFingerprints(for agent: AgentType) async -> Int {
        await rateLimitService.liftAndIgnoreCurrentRateLimitFingerprints(for: agent)
    }
}
