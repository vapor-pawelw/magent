import Foundation
import ShellInfra
import MagentModels

public final class TmuxService: Sendable {

    public static let shared = TmuxService()
    private let agentCompletionEventsPath = "/tmp/magent-agent-completion-events.log"
    private let paneCache = PaneCaptureCache()
    public struct ZombieParentSummary {
        public let parentPid: Int
        public let zombieCount: Int

        public init(parentPid: Int, zombieCount: Int) {
            self.parentPid = parentPid
            self.zombieCount = zombieCount
        }
    }

    // MARK: - Session Operations

    public func createSession(name: String, workingDirectory: String, command: String? = nil) async throws {
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
    public func applyGlobalSettings() async {
        // Keep selection visible after mouse drag — don't copy or exit copy-mode
        _ = try? await ShellExecutor.run("tmux unbind-key -T copy-mode MouseDragEnd1Pane")
        _ = try? await ShellExecutor.run("tmux unbind-key -T copy-mode-vi MouseDragEnd1Pane")
        // Click anywhere to clear selection but stay in copy-mode (preserves scroll position)
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode MouseDown1Pane send-keys -X clear-selection")
        _ = try? await ShellExecutor.run("tmux bind-key -T copy-mode-vi MouseDown1Pane send-keys -X clear-selection")
        // Keep tmux scrollbars off; otherwise they reappear inside embedded Ghostty
        // and look like Ghostty's own scrollbar regressed.
        _ = try? await ShellExecutor.run("tmux set-option -g pane-scrollbars off")
        await configureBellMonitoring(resetEventLog: true)
    }

    /// Applies tmux mouse settings for the given wheel-scroll behavior.
    /// Must be called at startup (after applyGlobalSettings) and whenever the setting changes.
    /// - For .magentDefaultScroll: enables tmux mouse and forces wheel to always enter
    ///   copy-mode (history scrolling), never passing events to apps that request mouse.
    /// - For .allowAppsToCapture: enables tmux mouse with default behavior so apps that
    ///   request mouse reporting receive wheel events normally.
    /// - For .inheritGhosttyGlobal: no-op; the user's own tmux config governs behavior.
    public func applyMouseWheelScrollSettings(behavior: TerminalMouseWheelBehavior) async {
        switch behavior {
        case .magentDefaultScroll:
            _ = try? await ShellExecutor.run("tmux set-option -g mouse on")
            // Force wheel to always scroll terminal history (copy-mode), regardless of
            // whether the pane's running app has requested mouse reporting.
            _ = try? await ShellExecutor.run(
                "tmux bind-key -T root WheelUpPane if-shell -F '#{pane_in_mode}' 'send-keys -X scroll-up' 'copy-mode -e ; send-keys -X scroll-up'"
            )
            // When in copy-mode: scroll down if there is history above, otherwise exit
            // copy-mode (so the user returns to live output automatically).
            _ = try? await ShellExecutor.run(
                "tmux bind-key -T root WheelDownPane if-shell -F '#{pane_in_mode}' \"if-shell -F '#{scroll_position}' 'send-keys -X scroll-down' 'send-keys -X cancel'\" ''"
            )
        case .allowAppsToCapture:
            _ = try? await ShellExecutor.run("tmux set-option -g mouse on")
            // Restore tmux's default wheel behavior: apps that request mouse reporting
            // receive wheel events; plain shell / no-mouse apps go to copy-mode.
            _ = try? await ShellExecutor.run("tmux unbind-key -T root WheelUpPane 2>/dev/null; true")
            _ = try? await ShellExecutor.run("tmux unbind-key -T root WheelDownPane 2>/dev/null; true")
        case .inheritGhosttyGlobal:
            // Don't touch tmux mouse settings — governed by the user's own tmux config.
            break
        }
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
    public func setupBellPipe(for sessionName: String) async {
        installBellWatcherScript()
        _ = try? await ShellExecutor.run(
            "tmux pipe-pane -o -t \(shellQuote(sessionName)) \(shellQuote("\(bellWatcherScriptPath) \(sessionName)"))"
        )
    }

    /// Like `setupBellPipe(for:)` but always replaces an existing pipe.
    /// Use after tmux session rename: the old pipe survives the rename and keeps writing
    /// the pre-rename session name to the event log. Stopping it first and starting fresh
    /// ensures subsequent bell events are attributed to the correct (new) session name.
    public func forceSetupBellPipe(for sessionName: String) async {
        installBellWatcherScript()
        // Stop any existing pipe on this session (idempotent; no-op if already stopped).
        _ = try? await ShellExecutor.run("tmux pipe-pane -t \(shellQuote(sessionName))")
        // Start fresh pipe without -o so it always takes effect.
        _ = try? await ShellExecutor.run(
            "tmux pipe-pane -t \(shellQuote(sessionName)) \(shellQuote("\(bellWatcherScriptPath) \(sessionName)"))"
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
    public func sessionsWithActivePipe() async -> Set<String> {
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

    public func consumeAgentCompletionSessions() async -> [String] {
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
    public func copySelectionToClipboard(sessionName: String) async {
        _ = try? await ShellExecutor.run("tmux send-keys -t \(shellQuote(sessionName)) -X copy-pipe-and-cancel pbcopy")
    }

    public func killSession(name: String) async throws {
        _ = try await ShellExecutor.run("tmux kill-session -t \(shellQuote(name))")
    }

    public func killServer() async {
        _ = await ShellExecutor.execute("tmux kill-server")
        // Also kill any zombie-heavy tmux processes that kill-server may not reach
        await killZombieHeavyTmuxProcesses()
    }

    /// Finds tmux processes that are parents of zombie children and kills them.
    /// After killing, waits briefly for the OS to reap the zombies.
    public func killZombieHeavyTmuxProcesses() async {
        let summaries = await zombieParentSummaries()
        for summary in summaries where summary.zombieCount >= 10 {
            _ = await ShellExecutor.execute("kill -9 \(summary.parentPid)")
        }
        guard !summaries.isEmpty else { return }
        // Give the OS time to reap zombie processes after their parent dies
        try? await Task.sleep(for: .seconds(2))
    }

    public func hasSession(name: String) async -> Bool {
        do {
            _ = try await ShellExecutor.run("tmux has-session -t \(shellQuote(name))")
            return true
        } catch {
            return false
        }
    }

    public func renameSession(from oldName: String, to newName: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux rename-session -t \(shellQuote(oldName)) \(shellQuote(newName))"
        )
    }

    public func listSessions() async throws -> [String] {
        let output = try await ShellExecutor.run("tmux list-sessions -F '#{session_name}'")
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    public func sendKeys(sessionName: String, keys: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux send-keys -t \(shellQuote(sessionName)) \(shellQuote(keys)) Enter"
        )
    }

    /// Sends text without pressing Enter — use `sendEnter` separately to submit.
    public func sendText(sessionName: String, text: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux send-keys -t \(shellQuote(sessionName)) \(shellQuote(text))"
        )
    }

    public func sendEnter(sessionName: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux send-keys -t \(shellQuote(sessionName)) Enter"
        )
    }

    public func setEnvironment(sessionName: String, key: String, value: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux set-environment -t \(shellQuote(sessionName)) \(shellQuote(key)) \(shellQuote(value))"
        )
    }

    public func environmentValue(sessionName: String, key: String) async -> String? {
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

    public func sessionPath(sessionName: String) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux display-message -p -t \(shellQuote(sessionName)) '#{session_path}'"
        ) else {
            return nil
        }

        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public func sessionCreatedAt(sessionName: String) async -> Date? {
        guard let output = try? await ShellExecutor.run(
            "tmux display-message -p -t \(shellQuote(sessionName)) '#{session_created}'"
        ) else {
            return nil
        }

        let rawValue = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = TimeInterval(rawValue), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func activePaneInfo(sessionName: String) async -> (command: String, path: String)? {
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

    /// Returns a dictionary mapping session names to their active pane's current command.
    /// Only includes sessions from the given set that are alive.
    public func activeCommands(forSessions sessionNames: Set<String>) async -> [String: String] {
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

    /// Returns a dictionary mapping session names to the active pane's command, title, and PID.
    /// Only includes sessions from the given set that are alive.
    public func activePaneStates(forSessions sessionNames: Set<String>) async -> [String: (command: String, title: String, pid: pid_t)] {
        guard !sessionNames.isEmpty else { return [:] }
        guard let output = try? await ShellExecutor.run(
            "tmux list-panes -a -F '#{session_name}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}\t#{pane_pid}'"
        ), !output.isEmpty else {
            return [:]
        }
        var result = [String: (command: String, title: String, pid: pid_t)]()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count >= 5 else { continue }
            let session = String(parts[0])
            guard sessionNames.contains(session) else { continue }
            let isActive = parts[1] == "1"
            let command = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = pid_t(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            // Prefer the active pane; fall back to first pane seen.
            if isActive || result[session] == nil {
                result[session] = (command: command, title: title, pid: pid)
            }
        }
        return result
    }

    /// Returns child processes (pid + full args) for each specified parent PID, in one `ps` call.
    public func childProcesses(forParents parentPids: Set<pid_t>) async -> [pid_t: [(pid: pid_t, args: String)]] {
        guard !parentPids.isEmpty else { return [:] }
        guard let output = try? await ShellExecutor.run("ps -o ppid=,pid=,args= -ax"),
              !output.isEmpty else { return [:] }
        var result: [pid_t: [(pid: pid_t, args: String)]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split on whitespace for first two fields only; the rest is args (may contain spaces)
            let parts = trimmed.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let ppid = pid_t(parts[0]),
                  let cpid = pid_t(parts[1]),
                  parentPids.contains(ppid) else { continue }
            let args = parts.count >= 3 ? String(parts[2]) : ""
            result[ppid, default: []].append((pid: cpid, args: args))
        }
        return result
    }

    /// Captures the full scrollback history of the active pane in a tmux session.
    public func captureFullPane(sessionName: String, includeAttributes: Bool = false) async -> String? {
        let attributesFlag = includeAttributes ? "-e " : ""
        let result = await ShellExecutor.execute(
            "tmux capture-pane \(attributesFlag)-p -t \(shellQuote(sessionName)) -S - -E -"
        )
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        // Return raw stdout with NO trimming. Leading empty lines must be preserved so that
        // split array indexes match tmux copy-mode absolute line numbers (history-top = line 0).
        // Trailing newlines are harmless: split(omittingEmptySubsequences: false) produces one
        // trailing empty element which is never matched as a prompt and doesn't affect lineIndex.
        return result.stdout
    }

    /// Scrolls the pane in copy-mode so the specified history line is anchored
    /// near the top of the viewport when enough lines are available below it.
    public func scrollHistoryLineToTop(sessionName: String, lineIndex: Int) async throws {
        let normalizedLine = max(0, lineIndex)
        let sn = shellQuote(sessionName)
        // history-top + scroll-down is race-condition-free: depends only on lineIndex (stable;
        // lines above it never shift) — not on historySize (grows as agent outputs).
        //
        // `scroll-down` moves the viewport 1 line toward newer content without depending on
        // cursor_y. After history-top (viewport top = 0) + N scroll-downs, viewport top = N.
        // So N = lineIndex places the capture-pane lineIndex at the top of the viewport. ✓
        //
        // All commands are chained with \; (tmux's own command separator) so the tmux client
        // delivers them to the server in ONE IPC message. The server processes the full list
        // before its next event-loop iteration, preventing any intermediate render of the
        // history-top state that would produce a visible double-jump flash.
        let scrollPart = normalizedLine > 0
            ? " \\; send-keys -t \(sn) -X -N \(normalizedLine) scroll-down"
            : ""
        let command = "tmux copy-mode -t \(sn) \\; send-keys -t \(sn) -X history-top\(scrollPart)"
        _ = try await ShellExecutor.run(command)
    }

    public func scrollPageUp(sessionName: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux copy-mode -e -t \(shellQuote(sessionName)); tmux send-keys -t \(shellQuote(sessionName)) -X page-up"
        )
    }

    public func scrollPageDown(sessionName: String) async throws {
        _ = try await ShellExecutor.run(
            "tmux copy-mode -e -t \(shellQuote(sessionName)); tmux send-keys -t \(shellQuote(sessionName)) -X page-down-and-cancel"
        )
    }

    public func scrollToBottom(sessionName: String) async throws {
        // Ignore "not in a mode" — pane is already at the bottom (not in copy-mode), which is fine.
        _ = try? await ShellExecutor.run(
            "tmux send-keys -t \(shellQuote(sessionName)) -X cancel"
        )
    }

    /// Returns how many lines the active pane is currently scrolled above live output.
    public func scrollPosition(sessionName: String) async -> UInt64? {
        guard let output = try? await ShellExecutor.run(
            "tmux display-message -p -t \(shellQuote(sessionName)) '#{scroll_position}'"
        ) else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return UInt64(trimmed)
    }

    /// Captures the last N lines of the active pane in a tmux session.
    public func capturePane(sessionName: String, lastLines: Int = 15) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux capture-pane -p -t \(shellQuote(sessionName)) -S -\(lastLines)"
        ) else {
            return nil
        }
        return output
    }

    /// Like `capturePane`, but results are cached for up to 5 seconds per session.
    /// Concurrent calls for the same session coalesce into a single subprocess.
    /// Use this from periodic polling paths; use `capturePane` when you need fresh output.
    public func cachedCapturePane(sessionName: String, lastLines: Int = 15) async -> String? {
        await paneCache.get(sessionName: sessionName, lastLines: lastLines)
    }

    /// Returns tmux parent processes that currently hold zombie children.
    public func zombieParentSummaries() async -> [ZombieParentSummary] {
        let command = """
        ps -axo pid=,ppid=,state=,comm= | awk '
        $4=="tmux" { tmux[$1]=1 }
        $3 ~ /^Z/ { z[$2]++ }
        END {
          for (pid in z) {
            if (pid in tmux) print pid " " z[pid]
          }
        }'
        """
        let result = await ShellExecutor.execute(command)
        guard result.exitCode == 0 else { return [] }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2,
                      let pid = Int(parts[0]),
                      let zombies = Int(parts[1]) else {
                    return nil
                }
                return ZombieParentSummary(parentPid: pid, zombieCount: zombies)
            }
            .sorted { $0.zombieCount > $1.zombieCount }
    }

}

public enum TmuxError: LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return "tmux error: \(message)"
        }
    }
}
