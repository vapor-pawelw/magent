import Foundation
import ShellInfra
import MagentModels

public final class TmuxService: Sendable {

    public static let shared = TmuxService()
    public static let legacyAgentBellPipeEnabled = false
    private static let requiredTerminalFeatureEntries = [
        "alacritty*:RGB",
        "foot*:RGB",
        "ghostty*:RGB",
        "screen*:RGB",
        "tmux*:RGB",
        "wezterm*:RGB",
        "xterm*:RGB",
        "xterm*:hyperlinks",
    ]
    private let agentCompletionEventsPath = "/tmp/magent-agent-completion-events.log"
    private let mouseOpenableURLStatePath = "/tmp/magent-tmux-mouse-openable-url-state.tsv"
    private let paneCache = PaneCaptureCache()
    private static let linkBoundaryCharacters = CharacterSet(
        charactersIn: "<>[](){}\"'`.,;:!?"
    )
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
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
        // tmux may have been auto-started by new-session; re-apply global terminal
        // capabilities so lazy server startup gets the same feature set as app launch.
        await ensureRequiredTerminalFeatures()
        await configureBellMonitoring()
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
        await ensureRequiredTerminalFeatures()
        await configureMouseOpenableURLTracking()
        await configureBellMonitoring()
    }

    public static func ensureTerminalFeaturesShellCommand() -> String {
        requiredTerminalFeatureEntries
            .map { feature in
                let quotedFeature = shellQuote(feature)
                return "tmux show -gv terminal-features 2>/dev/null | grep -Fqx -- \(quotedFeature) || tmux set-option -ga terminal-features \(quotedFeature)"
            }
            .joined(separator: " ; ")
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
                "tmux bind-key -T root WheelUpPane if-shell -F '#{pane_in_mode}' 'send-keys -X -N 6 scroll-up' 'copy-mode -e ; send-keys -X -N 6 scroll-up'"
            )
            // When in copy-mode: scroll down if there is history above, otherwise exit
            // copy-mode (so the user returns to live output automatically).
            _ = try? await ShellExecutor.run(
                "tmux bind-key -T root WheelDownPane if-shell -F '#{pane_in_mode}' \"if-shell -F '#{scroll_position}' 'send-keys -X -N 6 scroll-down' 'send-keys -X cancel'\" ''"
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

    /// Re-installs `/tmp` helper scripts if they were purged by macOS.
    /// Called periodically by the IPC watchdog.
    public func ensureHelperScriptsExist() {
        installBellWatcherScript()
        installMouseOpenableURLCaptureScript()
    }

    private func configureBellMonitoring() async {
        guard Self.legacyAgentBellPipeEnabled else { return }
        // Legacy rollback path only: ensure the event log file exists so
        // pipe-pane can append to it when the old watcher mechanism is enabled.
        // Never truncate on startup — accumulated events are consumed by
        // ThreadManager at launch via consumeAgentCompletionSessions().
        _ = try? await ShellExecutor.run("touch \(shellQuote(agentCompletionEventsPath))")
        // Install the bell-watcher script used by pipe-pane on agent sessions.
        installBellWatcherScript()
    }

    private func configureMouseOpenableURLTracking() async {
        installMouseOpenableURLCaptureScript()
        let emptySentinel = "__MAGENT_EMPTY__"
        let binding = """
        run-shell "\(mouseOpenableURLCaptureScriptPath) #{q:session_name} #{?mouse_hyperlink,#{q:mouse_hyperlink},\(emptySentinel)} #{?mouse_word,#{q:mouse_word},\(emptySentinel)} #{?mouse_x,#{mouse_x},-1} #{?mouse_line,#{q:mouse_line},\(emptySentinel)}" ; select-pane -t = ; send-keys -M
        """
        _ = try? await ShellExecutor.run(
            "tmux bind-key -T root MouseDown1Pane \(shellQuote(binding))"
        )
    }

    private func ensureTerminalFeature(_ feature: String) async {
        let current = (try? await ShellExecutor.run("tmux show -gv terminal-features")) ?? ""
        let existing = current
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !existing.contains(feature) else { return }
        _ = try? await ShellExecutor.run("tmux set-option -ga terminal-features \(shellQuote(feature))")
    }

    private func ensureRequiredTerminalFeatures() async {
        for feature in Self.requiredTerminalFeatureEntries {
            await ensureTerminalFeature(feature)
        }
    }

    public func recentMouseOpenableURL(sessionName: String, maxAge: TimeInterval = 2) -> String? {
        guard let contents = try? String(contentsOfFile: mouseOpenableURLStatePath, encoding: .utf8) else {
            return nil
        }
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let parts = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6,
              let timestamp = TimeInterval(parts[0]),
              parts[1] == Substring(sessionName) else {
            return nil
        }

        guard Date().timeIntervalSince1970 - timestamp <= maxAge else { return nil }

        if let hyperlink = normalizedOpenableURL(from: String(parts[2])) {
            return hyperlink
        }
        if let word = normalizedOpenableURL(from: String(parts[3])) {
            return word
        }

        let mouseX = Int(parts[4])
        let lineBase64 = String(parts[5])
        guard let lineData = Data(base64Encoded: lineBase64),
              let mouseLine = String(data: lineData, encoding: .utf8) else {
            return nil
        }
        return detectedLink(in: mouseLine, nearColumn: mouseX)
    }

    public func visibleOpenableURL(
        sessionName: String,
        xFraction: Double,
        yFraction: Double
    ) async -> String? {
        guard let metadataOutput = try? await ShellExecutor.run(
            "tmux display-message -p -t \(shellQuote(sessionName)) '#{pane_width}\t#{pane_height}\t#{pane_in_mode}'"
        ) else {
            return nil
        }

        let metadata = metadataOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", omittingEmptySubsequences: false)
        guard metadata.count == 3,
              let paneWidth = Int(metadata[0]),
              let paneHeight = Int(metadata[1]) else {
            return nil
        }

        let inMode = metadata[2] != "0"
        let captureCommand = inMode
            ? "tmux capture-pane -p -N -M -t \(shellQuote(sessionName))"
            : "tmux capture-pane -p -N -t \(shellQuote(sessionName))"
        guard let visibleOutput = try? await ShellExecutor.run(captureCommand) else {
            return nil
        }

        var visibleLines = visibleOutput.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if visibleLines.count > paneHeight, visibleLines.last == "" {
            visibleLines.removeLast()
        }

        let clampedX = min(max(xFraction, 0), 0.999_999)
        let clampedY = min(max(yFraction, 0), 0.999_999)
        let column = min(max(Int(floor(clampedX * Double(paneWidth))), 0), max(paneWidth - 1, 0))
        let row = min(max(Int(floor(clampedY * Double(paneHeight))), 0), max(paneHeight - 1, 0))

        if row < visibleLines.count,
           let lineURL = detectedLink(in: visibleLines[row], nearColumn: column) {
            return lineURL
        }

        if row > 0, row - 1 < visibleLines.count,
           let lineURL = detectedLink(in: visibleLines[row - 1], nearColumn: column) {
            return lineURL
        }

        if row + 1 < visibleLines.count,
           let lineURL = detectedLink(in: visibleLines[row + 1], nearColumn: column) {
            return lineURL
        }

        return nil
    }

    private func normalizedOpenableURL(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidates = [trimmed]
        let stripped = trimmed.trimmingCharacters(in: Self.linkBoundaryCharacters)
        if !stripped.isEmpty, stripped != trimmed {
            candidates.append(stripped)
        }

        for candidate in candidates {
            if let urlString = Self.detectedLink(in: candidate) {
                return urlString
            }
            if candidate.hasPrefix("www."),
               let url = URL(string: "https://\(candidate)") {
                return url.absoluteString
            }
        }

        return nil
    }

    private static func detectedLink(in candidate: String) -> String? {
        guard let linkDetector else { return nil }
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let match = linkDetector.firstMatch(in: candidate, options: [], range: range),
              match.range.location == 0,
              match.range.length == range.length,
              let url = match.url else {
            return nil
        }
        return url.absoluteString
    }

    private func detectedLink(in line: String, nearColumn mouseX: Int?) -> String? {
        guard let linkDetector = Self.linkDetector else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = linkDetector.matches(in: line, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        let bestMatch: NSTextCheckingResult
        if let mouseX {
            if let containing = matches.first(where: { mouseX >= $0.range.location && mouseX < $0.range.location + $0.range.length }) {
                bestMatch = containing
            } else {
                bestMatch = matches.min {
                    distance(from: mouseX, to: $0.range) < distance(from: mouseX, to: $1.range)
                } ?? matches[0]
            }
        } else {
            bestMatch = matches[0]
        }

        return bestMatch.url?.absoluteString
    }

    private func distance(from point: Int, to range: NSRange) -> Int {
        if point < range.location {
            return range.location - point
        }
        let end = range.location + range.length
        if point >= end {
            return point - end
        }
        return 0
    }

    private var mouseOpenableURLCaptureScriptPath: String {
        "/tmp/magent-mouse-openable-url-capture.sh"
    }

    private func installMouseOpenableURLCaptureScript() {
        let path = mouseOpenableURLCaptureScriptPath
        let marker = "# magent-mouse-openable-url-capture-v3"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing.contains(marker) {
            return
        }

        let script = """
        #!/bin/sh
        \(marker)
        session_name="$1"
        mouse_hyperlink="$2"
        mouse_word="$3"
        mouse_x="$4"
        mouse_line="$5"

        if [ "$mouse_hyperlink" = "__MAGENT_EMPTY__" ]; then
          mouse_hyperlink=""
        fi
        if [ "$mouse_word" = "__MAGENT_EMPTY__" ]; then
          mouse_word=""
        fi
        if [ "$mouse_line" = "__MAGENT_EMPTY__" ]; then
          mouse_line=""
        fi

        line_base64=$(printf '%s' "$mouse_line" | base64 | tr -d '\n')

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$(date +%s)" \
          "$session_name" \
          "$mouse_hyperlink" \
          "$mouse_word" \
          "$mouse_x" \
          "$line_base64" \
          > "\(mouseOpenableURLStatePath)"
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path
        )
    }

    /// Legacy rollback path only: sets up `pipe-pane` on a tmux session to detect
    /// bell characters (0x07) in pane output.
    public func setupBellPipe(for sessionName: String) async {
        guard Self.legacyAgentBellPipeEnabled else { return }
        installBellWatcherScript()
        _ = try? await ShellExecutor.run(
            "tmux pipe-pane -o -t \(shellQuote(sessionName)) \(shellQuote("\(bellWatcherScriptPath) \(sessionName)"))"
        )
    }

    /// Legacy rollback path only: like `setupBellPipe(for:)` but always replaces an
    /// existing pipe. Use after tmux session rename so fallback completion events keep
    /// the new session name.
    public func forceSetupBellPipe(for sessionName: String) async {
        guard Self.legacyAgentBellPipeEnabled else { return }
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

    public func clearBellPipe(for sessionName: String) async {
        _ = try? await ShellExecutor.run("tmux pipe-pane -t \(shellQuote(sessionName))")
    }

    public func consumeAgentCompletionSessions() async -> [String] {
        // Atomically move the event log to a temp path, then read it.
        // mv is atomic on the same filesystem, so no events are lost between
        // read and truncation (the old cat-then-truncate had that race).
        let tmpPath = agentCompletionEventsPath + ".consuming"
        let command = "mv \(shellQuote(agentCompletionEventsPath)) \(shellQuote(tmpPath)) 2>/dev/null && cat \(shellQuote(tmpPath)) && rm -f \(shellQuote(tmpPath))"
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
    /// Uses a named tmux buffer to avoid races with concurrent load-buffer/paste-buffer
    /// calls that would otherwise collide on the global default buffer.
    public func sendText(sessionName: String, text: String) async throws {
        let bufferId = UUID().uuidString
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magent-tmux-buffer-\(bufferId).txt")
        try text.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let bufferName = "magent-\(bufferId)"

        _ = try await ShellExecutor.run(
            "tmux load-buffer -b \(shellQuote(bufferName)) \(shellQuote(tempURL.path)); " +
            "tmux paste-buffer -d -b \(shellQuote(bufferName)) -t \(shellQuote(sessionName))"
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
        let sn = shellQuote(sessionName)
        _ = try await ShellExecutor.run(
            "tmux copy-mode -e -t \(sn); tmux send-keys -t \(sn) -X halfpage-up"
        )
    }

    public func scrollPageDown(sessionName: String) async throws {
        let sn = shellQuote(sessionName)
        _ = try await ShellExecutor.run(
            "tmux copy-mode -e -t \(sn); tmux send-keys -t \(sn) -X halfpage-down"
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

    /// Like `capturePane`, but preserves ANSI escape sequences (`-e` flag).
    /// Useful for distinguishing styled text (e.g. dim placeholder vs normal user input).
    public func capturePaneWithEscapes(sessionName: String, lastLines: Int = 15) async -> String? {
        guard let output = try? await ShellExecutor.run(
            "tmux capture-pane -p -e -t \(shellQuote(sessionName)) -S -\(lastLines)"
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
