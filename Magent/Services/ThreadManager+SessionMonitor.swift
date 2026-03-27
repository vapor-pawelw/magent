import AppKit
import Foundation
import MagentCore

extension ThreadManager {

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

            // Slow checks — every 12th tick (~1 minute)
            _slowTickCounter += 1
            if _slowTickCounter >= 12 {
                _slowTickCounter = 0
                await self.checkForMissingWorktrees()
                await self.checkForDeadSessions()
                if shouldRunStaleCleanup {
                    _ = await self.cleanupStaleMagentSessions(minimumStaleAge: 30)
                }
                await self.checkTmuxZombieHealth()
            }

            var didRunStatusSync = false
            var syncHadErrors = false

            // Refresh dirty and delivered states every 10th tick (~50 seconds)
            dirtyCheckTickCounter += 1
            if dirtyCheckTickCounter >= 10 {
                dirtyCheckTickCounter = 0
                await refreshDirtyStates()
                await refreshDeliveredStates()
                await refreshBranchStates()
            }

            // Jira sync every 60th tick (~5 minutes)
            _jiraSyncTickCounter += 1
            if _jiraSyncTickCounter >= 60 {
                _jiraSyncTickCounter = 0
                let jiraOk = await runJiraSyncTick()
                if !jiraOk { syncHadErrors = true }
                didRunStatusSync = true
            }

            // PR sync every 60th tick (~5 minutes).
            // Runs with yields between threads to avoid blocking.
            _prSyncTickCounter += 1
            if _prSyncTickCounter >= 60 {
                _prSyncTickCounter = 0
                let prOk = await runPRSyncTick()
                if !prOk { syncHadErrors = true }
                didRunStatusSync = true
            }

            if didRunStatusSync {
                lastStatusSyncAt = Date()
                lastStatusSyncFailed = syncHadErrors
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
            let prOk = await runPRSyncTick()
            let jiraOk = await runJiraSyncTick()
            await verifyDetectedJiraTickets()
            lastStatusSyncAt = Date()
            lastStatusSyncFailed = !prOk || !jiraOk
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

        let summaries = await tmux.zombieParentSummaries()
        let threshold = 200
        guard let worst = summaries.max(by: { $0.zombieCount < $1.zombieCount }),
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

        var recreatedCount = 0
        let activeThreads = threads.filter { !$0.isArchived }
        for thread in activeThreads {
            for sessionName in thread.tmuxSessionNames {
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

        isRestartingTmuxForRecovery = false

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
