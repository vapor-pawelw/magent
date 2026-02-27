import Foundation

final class TmuxService {

    static let shared = TmuxService()
    private let agentCompletionEventsPath = "/tmp/magent-agent-completion-events.log"

    // MARK: - Session Operations

    func createSession(name: String, workingDirectory: String, command: String? = nil) async throws {
        var cmd = "tmux new-session -d -s \(shellQuote(name)) -c \(shellQuote(workingDirectory))"
        if let command {
            cmd += " \(shellQuote(command))"
        }
        _ = try await ShellExecutor.run(cmd)
        // tmux may have been auto-started by new-session; ensure bell monitoring is configured.
        await configureBellMonitoring(resetEventLog: false)
    }

    /// Configures tmux settings needed by Magent (mouse selection behavior, etc.).
    /// Called once at app startup; applies globally to all sessions.
    func applyGlobalSettings() async {
        // Keep selection visible after mouse drag — don't copy or exit copy-mode
        _ = try? await ShellExecutor.run("tmux unbind-key -T copy-mode MouseDragEnd1Pane")
        _ = try? await ShellExecutor.run("tmux unbind-key -T copy-mode-vi MouseDragEnd1Pane")
        // Click anywhere to deselect (exit copy-mode)
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode MouseDown1Pane send-keys -X cancel")
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode-vi MouseDown1Pane send-keys -X cancel")
        await configureBellMonitoring(resetEventLog: true)
    }

    private func configureBellMonitoring(resetEventLog: Bool) async {
        // Capture terminal bell events emitted by agent sessions for completion notifications.
        _ = try? await ShellExecutor.run("tmux set-option -g monitor-bell on")
        if resetEventLog {
            _ = try? await ShellExecutor.run(": > \(shellQuote(agentCompletionEventsPath))")
        } else {
            _ = try? await ShellExecutor.run("touch \(shellQuote(agentCompletionEventsPath))")
        }
        let bellHook = "run-shell \"echo #{session_name} >> \(agentCompletionEventsPath)\""
        _ = try? await ShellExecutor.run("tmux set-hook -g alert-bell \(shellQuote(bellHook))")
    }

    func consumeAgentCompletionSessions() async -> [String] {
        let command = "if [ -f \(shellQuote(agentCompletionEventsPath)) ]; then cat \(shellQuote(agentCompletionEventsPath)); : > \(shellQuote(agentCompletionEventsPath)); fi"
        guard let output = try? await ShellExecutor.run(command), !output.isEmpty else {
            return []
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Copies the current tmux copy-mode selection to the system clipboard, then exits copy-mode.
    func copySelectionToClipboard(sessionName: String) async {
        _ = try? await ShellExecutor.run("tmux send-keys -t \(shellQuote(sessionName)) -X copy-pipe-and-cancel pbcopy")
    }

    func killSession(name: String) async throws {
        _ = try await ShellExecutor.run("tmux kill-session -t \(shellQuote(name))")
    }

    func hasSession(name: String) async -> Bool {
        do {
            _ = try await ShellExecutor.run("tmux has-session -t \(shellQuote(name))")
            return true
        } catch {
            return false
        }
    }

    func renameSession(from oldName: String, to newName: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux rename-session -t \(shellQuote(oldName)) \(shellQuote(newName))"
        )
    }

    func listSessions() async throws -> [String] {
        let output = try await ShellExecutor.run("tmux list-sessions -F '#{session_name}'")
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func sendKeys(sessionName: String, keys: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux send-keys -t \(shellQuote(sessionName)) \(shellQuote(keys)) Enter"
        )
    }

    func setEnvironment(sessionName: String, key: String, value: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux set-environment -t \(shellQuote(sessionName)) \(shellQuote(key)) \(shellQuote(value))"
        )
    }

    func environmentValue(sessionName: String, key: String) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux show-environment -t \(shellQuote(sessionName)) \(shellQuote(key))"
        ) else {
            return nil
        }

        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("-") else { return nil }

        let prefix = "\(key)="
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    func sessionPath(sessionName: String) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux display-message -p -t \(shellQuote(sessionName)) '#{session_path}'"
        ) else {
            return nil
        }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func activePaneInfo(sessionName: String) async -> (command: String, path: String)? {
        guard let output = try? await ShellExecutor.run(
            "tmux list-panes -t \(shellQuote(sessionName)) -F '#{pane_active}\t#{pane_current_command}\t#{pane_current_path}'"
        ) else {
            return nil
        }

        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let selectedLine = lines.first(where: { $0.hasPrefix("1\t") }) ?? lines[0]
        let parts = selectedLine.components(separatedBy: "\t")
        guard parts.count >= 3 else { return nil }

        let command = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !path.isEmpty else { return nil }
        return (command, path)
    }

    /// Updates tmux defaults and live shell panes to a new working directory.
    /// Non-shell panes (e.g. running agent binaries) are left untouched.
    func updateWorkingDirectory(sessionName: String, to path: String) async {
        let output: String
        do {
            output = try await ShellExecutor.run(
                "tmux list-panes -t \(shellQuote(sessionName)) -F '#{pane_id}\t#{pane_current_command}'"
            )
        } catch {
            return
        }

        let shellCommands: Set<String> = ["sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh"]
        let cdCommand = "cd \(shellQuote(path))"

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let paneId = parts[0]
            let paneCommand = parts[1]
            guard shellCommands.contains(paneCommand) else { continue }

            _ = try? await ShellExecutor.run(
                "tmux send-keys -t \(shellQuote(paneId)) \(shellQuote(cdCommand)) Enter"
            )
        }
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum TmuxError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "tmux error: \(message)"
        }
    }
}
