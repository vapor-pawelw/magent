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
        // Click anywhere to clear selection but stay in copy-mode (preserves scroll position)
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode MouseDown1Pane send-keys -X clear-selection")
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode-vi MouseDown1Pane send-keys -X clear-selection")
        await configureBellMonitoring(resetEventLog: true)
    }

    private func configureBellMonitoring(resetEventLog: Bool) async {
        if resetEventLog {
            _ = try? await ShellExecutor.run(": > \(shellQuote(agentCompletionEventsPath))")
        } else {
            _ = try? await ShellExecutor.run("touch \(shellQuote(agentCompletionEventsPath))")
        }
        // Install the bell-watcher script used by pipe-pane on agent sessions.
        installBellWatcherScript()
    }

    /// Sets up `pipe-pane` on a tmux session to detect bell characters (0x07) in pane output.
    /// This replaces the broken tmux `alert-bell` hook (which does not fire in tmux ≤3.6a).
    func setupBellPipe(for sessionName: String) async {
        installBellWatcherScript()
        _ = try? await ShellExecutor.run(
            "tmux pipe-pane -o -t \(shellQuote(sessionName)) \(shellQuote("\(bellWatcherScriptPath) \(sessionName)"))"
        )
    }

    private var bellWatcherScriptPath: String {
        "/tmp/magent-bell-watcher.sh"
    }

    private func installBellWatcherScript() {
        let path = bellWatcherScriptPath
        // Only write if missing or outdated
        let marker = "# magent-bell-watcher-v3"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing.hasPrefix(marker) {
            return
        }
        // Reads pane output in chunks via perl, detects standalone BEL (0x07).
        // Uses a state machine to filter out BEL used as String Terminator (ST)
        // inside escape sequences: OSC (ESC ]), APC (ESC _), PM (ESC ^),
        // DCS (ESC P), SOS (ESC X), and their C1 single-byte equivalents.
        // State persists across buffer boundaries.
        let script = """
        \(marker)
        #!/bin/sh
        SESSION="$1"
        LOG="\(agentCompletionEventsPath)"
        exec perl -e '
        $| = 1;
        my $s = $ARGV[0];
        my $f = $ARGV[1];
        # States: 0=normal, 1=saw_esc, 2=in_string_cmd
        my $st = 0;
        while (sysread(STDIN, my $buf, 8192)) {
            for my $i (0..length($buf)-1) {
                my $c = ord(substr($buf, $i, 1));
                if ($st == 0) {
                    if ($c == 0x1b) {
                        $st = 1;
                    } elsif ($c == 0x90 || $c == 0x98 || $c == 0x9d || $c == 0x9e || $c == 0x9f) {
                        $st = 2;  # C1 string command starter
                    } elsif ($c == 0x07) {
                        open(my $fh, ">>", $f);
                        print $fh "$s\\n";
                        close($fh);
                    }
                } elsif ($st == 1) {
                    # After ESC: ] _ ^ P X start string commands
                    if ($c == 0x5d || $c == 0x5f || $c == 0x5e || $c == 0x50 || $c == 0x58) {
                        $st = 2;
                    } else {
                        $st = 0;
                    }
                } elsif ($st == 2) {
                    if ($c == 0x07) {
                        $st = 0;  # BEL as ST — not a real bell
                    } elsif ($c == 0x1b) {
                        $st = 1;  # Could be ESC \\ (ST) or new sequence
                    }
                }
            }
        }
        ' "$SESSION" "$LOG"
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    /// Returns the set of session names that currently have an active pipe-pane.
    func sessionsWithActivePipe() async -> Set<String> {
        // Query all panes: session_name and pane_pipe flag
        guard let output = try? await ShellExecutor.run(
            "tmux list-panes -a -F '#{session_name} #{pane_pipe}'"
        ), !output.isEmpty else {
            return []
        }
        var result = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[1] == "1" {
                result.insert(String(parts[0]))
            }
        }
        return result
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

    /// Updates live shell panes to a new working directory.
    /// Non-shell panes (e.g. running agent binaries) are left untouched.
    /// Returns the set of pane IDs that received the `cd` command.
    @discardableResult
    func updateWorkingDirectory(sessionName: String, to path: String) async -> Set<String> {
        let output: String
        do {
            output = try await ShellExecutor.run(
                "tmux list-panes -t \(shellQuote(sessionName)) -F '#{pane_id}\t#{pane_current_command}'"
            )
        } catch {
            return []
        }

        let cdCommand = "cd \(shellQuote(path))"
        var enforcedPanes = Set<String>()

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let paneId = parts[0]
            let paneCommand = parts[1]
            guard Self.shellCommands.contains(paneCommand) else { continue }

            // Clear any partial input before sending cd
            _ = try? await ShellExecutor.run(
                "tmux send-keys -t \(shellQuote(paneId)) C-u"
            )
            _ = try? await ShellExecutor.run(
                "tmux send-keys -t \(shellQuote(paneId)) \(shellQuote(cdCommand)) Enter"
            )
            enforcedPanes.insert(paneId)
        }

        return enforcedPanes
    }

    /// Sends `cd` to shell panes that haven't been enforced yet.
    /// Returns the set of newly enforced pane IDs, and whether any non-shell panes remain unenforced.
    func enforceWorkingDirectoryOnNewPanes(
        sessionName: String,
        path: String,
        alreadyEnforced: Set<String>
    ) async -> (newlyEnforced: Set<String>, hasUnenforced: Bool) {
        let output: String
        do {
            output = try await ShellExecutor.run(
                "tmux list-panes -t \(shellQuote(sessionName)) -F '#{pane_id}\t#{pane_current_command}'"
            )
        } catch {
            return ([], false) // session gone
        }

        let cdCommand = "cd \(shellQuote(path))"
        var newlyEnforced = Set<String>()
        var hasUnenforced = false

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let paneId = parts[0]
            let paneCommand = parts[1]

            if alreadyEnforced.contains(paneId) { continue }

            if Self.shellCommands.contains(paneCommand) {
                _ = try? await ShellExecutor.run(
                    "tmux send-keys -t \(shellQuote(paneId)) C-u"
                )
                _ = try? await ShellExecutor.run(
                    "tmux send-keys -t \(shellQuote(paneId)) \(shellQuote(cdCommand)) Enter"
                )
                newlyEnforced.insert(paneId)
            } else {
                hasUnenforced = true
            }
        }

        return (newlyEnforced, hasUnenforced)
    }

    /// Returns a dictionary mapping session names to their active pane's current command.
    /// Only includes sessions from the given set that are alive.
    func activeCommands(forSessions sessionNames: Set<String>) async -> [String: String] {
        guard !sessionNames.isEmpty else { return [:] }
        guard let output = try? await ShellExecutor.run(
            "tmux list-panes -a -F '#{session_name}\t#{pane_active}\t#{pane_current_command}'"
        ), !output.isEmpty else {
            return [:]
        }
        var result = [String: String]()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count >= 3 else { continue }
            let session = String(parts[0])
            guard sessionNames.contains(session) else { continue }
            let isActive = parts[1] == "1"
            let command = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer the active pane; fall back to first pane seen
            if isActive || result[session] == nil {
                result[session] = command
            }
        }
        return result
    }

    /// Captures the last N lines of the active pane in a tmux session.
    func capturePane(sessionName: String, lastLines: Int = 15) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux capture-pane -p -t \(shellQuote(sessionName)) -S -\(lastLines)"
        ) else {
            return nil
        }
        return output
    }

    static let shellCommands: Set<String> = [
        "sh", "bash", "zsh", "fish", "ksh", "tcsh", "csh",
        "-sh", "-bash", "-zsh", "-fish", "-ksh", "-tcsh", "-csh"
    ]

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
