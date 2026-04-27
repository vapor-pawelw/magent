import Foundation
import MagentCore

extension ThreadManager {

    func isTerminalCorrupted(sessionName: String) -> Bool {
        rendererUnhealthySessions.contains(sessionName) || replayCorruptedSessions.contains(sessionName)
    }

    func setTerminalRendererHealth(sessionName: String, isHealthy: Bool) {
        let wasCorrupted = isTerminalCorrupted(sessionName: sessionName)
        if isHealthy {
            rendererUnhealthySessions.remove(sessionName)
        } else {
            rendererUnhealthySessions.insert(sessionName)
        }
        let isCorruptedNow = isTerminalCorrupted(sessionName: sessionName)
        guard wasCorrupted != isCorruptedNow else { return }
        postTerminalCorruptionChanged(sessionName: sessionName, isCorrupted: isCorruptedNow)
    }

    func clearTerminalCorruption(sessionName: String) {
        let wasCorrupted = isTerminalCorrupted(sessionName: sessionName)
        rendererUnhealthySessions.remove(sessionName)
        replayCorruptedSessions.remove(sessionName)
        guard wasCorrupted else { return }
        postTerminalCorruptionChanged(sessionName: sessionName, isCorrupted: false)
    }

    func checkForTerminalCorruptionSignals() async {
        let liveThreads = threads.filter { !$0.isArchived }
        let referencedSessions = Set(liveThreads.flatMap(\.tmuxSessionNames))
        pruneTerminalCorruptionState(to: referencedSessions)

        var candidateSessions = Set<String>()
        for thread in liveThreads {
            for sessionName in thread.tmuxSessionNames {
                guard !thread.deadSessions.contains(sessionName) else { continue }
                guard !evictedIdleSessions.contains(sessionName) else { continue }
                candidateSessions.insert(sessionName)
            }
        }
        guard !candidateSessions.isEmpty else { return }

        for sessionName in candidateSessions {
            guard let pane = await tmux.capturePane(sessionName: sessionName, lastLines: 260) else { continue }
            let hasReplayCorruption = TerminalCorruptionHeuristics.hasRepeatedTailBlock(in: pane)
            setTerminalReplayCorrupted(sessionName: sessionName, isCorrupted: hasReplayCorruption)
        }
    }

    private func setTerminalReplayCorrupted(sessionName: String, isCorrupted: Bool) {
        let wasCorrupted = isTerminalCorrupted(sessionName: sessionName)
        if isCorrupted {
            replayCorruptedSessions.insert(sessionName)
        } else {
            replayCorruptedSessions.remove(sessionName)
        }
        let isCorruptedNow = isTerminalCorrupted(sessionName: sessionName)
        guard wasCorrupted != isCorruptedNow else { return }
        postTerminalCorruptionChanged(sessionName: sessionName, isCorrupted: isCorruptedNow)
    }

    private func pruneTerminalCorruptionState(to referencedSessions: Set<String>) {
        rendererUnhealthySessions = rendererUnhealthySessions.intersection(referencedSessions)
        replayCorruptedSessions = replayCorruptedSessions.intersection(referencedSessions)
    }

    private func postTerminalCorruptionChanged(sessionName: String, isCorrupted: Bool) {
        guard let threadId = threads.first(where: { $0.tmuxSessionNames.contains(sessionName) })?.id else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .magentTerminalCorruptionChanged,
                object: nil,
                userInfo: [
                    "threadId": threadId,
                    "sessionName": sessionName,
                    "isCorrupted": isCorrupted,
                ]
            )
        }
    }

}
