import AppKit
import Foundation
import MagentCore

extension ThreadManager {

    private func publishTmuxHealthChanged() {
        NotificationCenter.default.post(name: .magentTmuxHealthChanged, object: nil)
    }

    private func setTmuxZombieSummary(_ summary: TmuxService.ZombieParentSummary?) {
        let didChange = lastTmuxZombieSummary?.parentPid != summary?.parentPid
            || lastTmuxZombieSummary?.zombieCount != summary?.zombieCount
        lastTmuxZombieSummary = summary
        if didChange {
            publishTmuxHealthChanged()
        }
    }

    @discardableResult
    private func refreshTmuxZombieSummary() async -> TmuxService.ZombieParentSummary? {
        let summary = await tmux.zombieParentSummaries().max(by: { $0.zombieCount < $1.zombieCount })
        setTmuxZombieSummary(summary)
        return summary
    }

    // MARK: - Session Monitor

    func startSessionMonitor() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startSessionMonitor()
            }
            return
        }
        guard sessionMonitorTimer == nil else { return }
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runSessionMonitorTick()
            }
        }
        // Fire once immediately so we don't wait 5 seconds for the first sync.
        runSessionMonitorTick()
    }

    func stopSessionMonitor() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
    }

    private func runSessionMonitorTick() {
        guard !isSessionMonitorTickRunning else { return }
        isSessionMonitorTickRunning = true
        let shouldRunStaleCleanup = shouldRunStaleSessionCleanupTick()
        Task {
            defer { self.isSessionMonitorTickRunning = false }

            // Fast checks — every tick (5s)
            await self.checkForAgentCompletions()
            await self.checkForWaitingForInput()
            await self.checkForRateLimitedSessions()
            await self.syncBusySessionsFromProcessState()
            await self.ensureBellPipes()
            await self.checkForDeadSessions()

            // Slow checks — every 12th tick (~1 minute)
            _slowTickCounter += 1
            if _slowTickCounter >= 12 {
                _slowTickCounter = 0
                await self.checkForMissingWorktrees()
                await self.evictIdleSessionsIfNeeded()
                if shouldRunStaleCleanup {
                    _ = await self.cleanupStaleMagentSessions(minimumStaleAge: 30)
                }
                await self.checkTmuxZombieHealth()
                await self.checkForTerminalCorruptionSignals()
            }

            var didRunStatusSync = false
            var syncHadErrors = false
            var syncFailureSummaries: [String] = []

            // Refresh dirty and delivered states every 10th tick (~50 seconds)
            dirtyCheckTickCounter += 1
            if dirtyCheckTickCounter >= 10 {
                dirtyCheckTickCounter = 0
                await refreshDirtyStates()
                await refreshDeliveredStates()
                await refreshBranchStates()
                // Sync tab names with the model/effort the user switched to via /model.
                await syncTabNamesFromModelChanges()
            }

            // Jira sync every 60th tick (~5 minutes)
            _jiraSyncTickCounter += 1
            if _jiraSyncTickCounter >= 60 {
                _jiraSyncTickCounter = 0
                let jiraResult = await runJiraSyncTick()
                if jiraResult.hadErrors {
                    syncHadErrors = true
                    if let summary = jiraResult.failureSummary {
                        syncFailureSummaries.append(summary)
                    }
                }
                didRunStatusSync = true
            }

            // PR sync every 60th tick (~5 minutes).
            // Runs with yields between threads to avoid blocking.
            _prSyncTickCounter += 1
            if _prSyncTickCounter >= 60 {
                _prSyncTickCounter = 0
                let prResult = await runPRSyncTick()
                if prResult.hadErrors {
                    syncHadErrors = true
                    if let summary = prResult.failureSummary {
                        syncFailureSummaries.append(summary)
                    }
                }
                didRunStatusSync = true
            }

            if didRunStatusSync {
                lastStatusSyncAt = Date()
                lastStatusSyncFailed = syncHadErrors
                lastStatusSyncFailureSummary = syncHadErrors
                    ? mergeStatusSyncFailureSummaries(syncFailureSummaries)
                    : nil
                await MainActor.run {
                    NotificationCenter.default.post(name: .magentStatusSyncCompleted, object: nil)
                }
            }
        }
    }

    /// Force-refreshes PR and Jira statuses for all threads immediately.
    /// Skips if a sync pass is already in progress.
    func forceRefreshStatuses() {
        Task {
            let prResult = await runPRSyncTick()
            let jiraResult = await runJiraSyncTick()
            await verifyDetectedJiraTickets()
            lastStatusSyncAt = Date()
            lastStatusSyncFailed = prResult.hadErrors || jiraResult.hadErrors
            lastStatusSyncFailureSummary = lastStatusSyncFailed
                ? mergeStatusSyncFailureSummaries([prResult.failureSummary, jiraResult.failureSummary].compactMap { $0 })
                : nil
            // Reset counters so the next periodic tick doesn't re-run immediately.
            _prSyncTickCounter = 0
            _jiraSyncTickCounter = 0
            await MainActor.run {
                NotificationCenter.default.post(name: .magentStatusSyncCompleted, object: nil)
            }
        }
    }

    private func shouldRunStaleSessionCleanupTick(now: Date = Date()) -> Bool {
        let cleanupInterval: TimeInterval = 5 * 60
        guard now.timeIntervalSince(lastStaleSessionCleanupAt) >= cleanupInterval else { return false }
        lastStaleSessionCleanupAt = now
        return true
    }

    // MARK: - Missing Worktree Detection

    private func checkForMissingWorktrees() async {
        let candidates = threads.filter { !$0.isMain && !$0.isArchived }
        var pruneRepos = Set<String>()
        var archivedAny = false

        for thread in candidates {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: thread.worktreePath, isDirectory: &isDir)
            guard !exists || !isDir.boolValue else { continue }

            let settings = persistence.loadSettings()
            if let project = settings.projects.first(where: { $0.id == thread.projectId }) {
                pruneRepos.insert(project.repoPath)
            }
            _ = try? await archiveThread(thread)
            archivedAny = true
        }

        if archivedAny {
            let settings = persistence.loadSettings()
            if settings.playSoundForAgentCompletion {
                let soundName = settings.agentCompletionSoundName
                if let sound = NSSound(named: NSSound.Name(soundName)) {
                    sound.play()
                }
            }
        }

        for repoPath in pruneRepos {
            await git.pruneWorktrees(repoPath: repoPath)
        }
    }

    // MARK: - Tmux Zombie Health

    func checkTmuxZombieHealth() async {
        let now = Date()
        guard now.timeIntervalSince(lastTmuxZombieHealthCheckAt) >= 60 else { return }
        lastTmuxZombieHealthCheckAt = now
        guard !isRestartingTmuxForRecovery else { return }

        let threshold = 200
        guard let worst = await refreshTmuxZombieSummary(),
              worst.zombieCount >= threshold else {
            didShowTmuxZombieWarning = false
            return
        }
        guard !didShowTmuxZombieWarning else { return }
        didShowTmuxZombieWarning = true

        await MainActor.run {
            BannerManager.shared.show(
                message: "tmux health issue: \(worst.zombieCount) defunct processes on parent \(worst.parentPid). Restart and recover sessions.",
                style: .warning,
                duration: nil,
                actions: [
                    BannerAction(title: "Restart tmux + Recover") { [weak self] in
                        Task { await self?.restartTmuxAndRecoverSessions() }
                    },
                    BannerAction(title: "Ignore") { [weak self] in
                        self?.didShowTmuxZombieWarning = false
                    },
                ]
            )
        }
    }

    func restartTmuxAndRecoverSessions() async {
        guard !isRestartingTmuxForRecovery else { return }
        isRestartingTmuxForRecovery = true
        didShowTmuxZombieWarning = false
        publishTmuxHealthChanged()

        let recoverySessionsByThread = Dictionary(uniqueKeysWithValues: threads
            .filter { !$0.isArchived }
            .map { thread in
                (
                    thread.id,
                    thread.tmuxSessionNames.filter { sessionName in
                        !thread.deadSessions.contains(sessionName)
                            && !evictedIdleSessions.contains(sessionName)
                    }
                )
            })

        await MainActor.run {
            BannerManager.shared.show(
                message: "Restarting tmux and recovering sessions...",
                style: .warning,
                duration: nil,
                isDismissible: false
            )
            stopSessionMonitor()
        }

        await tmux.killServer()
        setTmuxZombieSummary(nil)

        // tmux `bind-key` state is server-global and is lost when the server
        // is killed. Re-install Magent's wheel-scroll bindings before any
        // new sessions spin up, so copy-mode scrolling doesn't fall back to
        // tmux's stock `-N5` multiplier / broken wheel behavior.
        await tmux.applyMouseWheelScrollSettings(behavior: persistence.loadSettings().terminalMouseWheelBehavior)

        var recreatedCount = 0
        let activeThreads = threads.filter { !$0.isArchived }
        for thread in activeThreads {
            let sessionsToRecover = recoverySessionsByThread[thread.id] ?? []
            for sessionName in sessionsToRecover {
                let recreated = await recreateSessionIfNeeded(sessionName: sessionName, thread: thread)
                if recreated {
                    recreatedCount += 1
                }
            }
        }

        await ensureBellPipes()
        await syncBusySessionsFromProcessState()
        _ = await cleanupStaleMagentSessions()
        persistence.debouncedSaveActiveThreads(threads)
        _ = await refreshTmuxZombieSummary()

        isRestartingTmuxForRecovery = false
        publishTmuxHealthChanged()

        await MainActor.run {
            updateDockBadge()
            delegate?.threadManager(self, didUpdateThreads: threads)
            BannerManager.shared.show(
                message: "tmux restarted. Recovered \(recreatedCount) session\(recreatedCount == 1 ? "" : "s").",
                style: .info
            )
            startSessionMonitor()
        }
    }
}
