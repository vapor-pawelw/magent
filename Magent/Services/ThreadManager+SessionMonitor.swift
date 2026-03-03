import AppKit
import Foundation

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
        sessionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.runSessionMonitorTick()
        }
        // Fire once immediately so we don't wait 3 seconds for the first sync.
        runSessionMonitorTick()
    }

    func stopSessionMonitor() {
        sessionMonitorTimer?.invalidate()
        sessionMonitorTimer = nil
    }

    private func runSessionMonitorTick() {
        Task {
            await self.checkForMissingWorktrees()
            await self.checkForDeadSessions()
            await self.checkForAgentCompletions()
            await self.checkForWaitingForInput()
            await self.checkForRateLimitedSessions()
            await self.syncBusySessionsFromProcessState()
            await self.ensureBellPipes()
            await self.checkPendingCwdEnforcements()
            await self.checkTmuxZombieHealth()

            // Refresh dirty and delivered states every 10th tick (~30 seconds)
            dirtyCheckTickCounter += 1
            if dirtyCheckTickCounter >= 10 {
                dirtyCheckTickCounter = 0
                await refreshDirtyStates()
                await refreshDeliveredStates()
                await refreshBranchStates()
            }

            // Jira sync every 20th tick (~60 seconds)
            _jiraSyncTickCounter += 1
            if _jiraSyncTickCounter >= 20 {
                _jiraSyncTickCounter = 0
                await runJiraSyncTick()
            }

            // PR sync every 20th tick (~60 seconds)
            _prSyncTickCounter += 1
            if _prSyncTickCounter >= 20 {
                _prSyncTickCounter = 0
                await runPRSyncTick()
            }
        }
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
            try? await archiveThread(thread)
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
        guard now.timeIntervalSince(lastTmuxZombieHealthCheckAt) >= 15 else { return }
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
        try? persistence.saveThreads(threads)

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
