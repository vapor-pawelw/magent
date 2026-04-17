import Foundation
import MagentCore
import TmuxCore

actor IPCSocketServer {

    static let socketPath = "/tmp/magent.sock"
    private static let cliPath = "/tmp/magent-cli"
    private static let cliVersion = "magent-cli-v28"

    private var serverFD: Int32 = -1
    private var isRunning = false
    private var cliWatchdogTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        // Clean up stale socket
        unlink(Self.socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            NSLog("[IPC] Failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let pathBytes = Self.socketPath.utf8CString
            pathBytes.withUnsafeBufferPointer { buf in
                _ = memcpy(ptr, buf.baseAddress!, min(buf.count, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[IPC] Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverFD)
            serverFD = -1
            return
        }

        // Allow any user to connect (agents may run as different user in some setups)
        chmod(Self.socketPath, 0o666)

        guard listen(serverFD, 5) == 0 else {
            NSLog("[IPC] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverFD)
            serverFD = -1
            return
        }

        isRunning = true
        Self.installCLIScript()
        startCLIWatchdog()
        NSLog("[IPC] Server listening on \(Self.socketPath)")

        // Accept loop on background queue
        let fd = serverFD
        Task.detached { [weak self] in
            await self?.acceptLoop(serverFD: fd)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cliWatchdogTask?.cancel()
        cliWatchdogTask = nil
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(Self.socketPath)
        NSLog("[IPC] Server stopped")
    }

    // MARK: - Accept Loop

    private func acceptLoop(serverFD: Int32) async {
        while self.isRunning {
            let clientFD = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    var clientAddr = sockaddr_un()
                    var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                    let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            accept(serverFD, sockPtr, &clientAddrLen)
                        }
                    }
                    continuation.resume(returning: fd)
                }
            }

            guard clientFD >= 0 else {
                if self.isRunning {
                    NSLog("[IPC] Accept failed: \(String(cString: strerror(errno)))")
                }
                break
            }

            // Handle each connection in a detached task — uses static method
            // to avoid holding the actor lock during blocking I/O.
            Task.detached {
                await Self.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection Handling

    /// Handles a single IPC connection. Nonisolated so blocking socket I/O
    /// doesn't hold the actor lock.
    nonisolated private static func handleConnection(_ fd: Int32) async {
        defer { Darwin.close(fd) }

        // Read until newline
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
            if data.contains(UInt8(ascii: "\n")) { break }
        }

        // Trim to first line
        if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.startIndex..<newlineIndex]
        }

        guard !data.isEmpty else { return }

        let response: IPCResponse
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            response = await IPCCommandHandler.shared.handle(request)
        } catch let decodeError as DecodingError {
            // Provide actionable diagnostics instead of the opaque Foundation message.
            switch decodeError {
            case .keyNotFound(let key, _):
                response = .failure("Invalid JSON: missing required key '\(key.stringValue)'")
            case .typeMismatch(_, let ctx):
                response = .failure("Invalid JSON: type mismatch — \(ctx.debugDescription)")
            case .valueNotFound(_, let ctx):
                response = .failure("Invalid JSON: value not found — \(ctx.debugDescription)")
            case .dataCorrupted(let ctx):
                // Common cause: pretty-printed specs.json embedded in the request caused
                // truncation at the first newline. The CLI compacts the JSON now, but give
                // a hint in case the caller bypasses the CLI.
                let hint = "Ensure the full request is on a single line (no literal newlines inside the JSON)"
                response = .failure("Invalid JSON: \(ctx.debugDescription). \(hint)")
            @unknown default:
                response = .failure("Invalid JSON: \(decodeError.localizedDescription)")
            }
        } catch {
            response = .failure("Invalid JSON: \(error.localizedDescription)")
        }

        // Encode response and write
        guard let responseData = try? JSONEncoder().encode(response) else { return }
        var toWrite = responseData
        toWrite.append(UInt8(ascii: "\n"))
        toWrite.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
    }

    // MARK: - CLI Watchdog

    /// Periodically checks that `/tmp/magent-cli` still exists (macOS can purge `/tmp`)
    /// and reinstalls it if missing.
    private func startCLIWatchdog() {
        cliWatchdogTask?.cancel()
        cliWatchdogTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                if !FileManager.default.fileExists(atPath: Self.cliPath) {
                    NSLog("[IPC] CLI script missing at %@, reinstalling", Self.cliPath)
                    Self.installCLIScript()
                }
                TmuxService.shared.ensureHelperScriptsExist()
                guard await self?.isRunning == true else { break }
            }
        }
    }

    // MARK: - CLI Script

    nonisolated private static func installCLIScript() {
        let path = cliPath
        let marker = cliVersion

        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           existing.contains(marker) {
            installPersistentLaunchers()
            return
        }

        let script = #"""
        #!/bin/sh
        # \#(marker)
        # Magent IPC CLI — installed by Magent.app
        # Usage: magent-cli <command> [options]

        SOCKET="${MAGENT_SOCKET:-\#(socketPath)}"
        SEP="$(printf '\037')"
        INTERACTIVE_STATE_FILE="${MAGENT_CLI_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/magent/interactive-last.json}"

        die() { echo "Error: $1" >&2; exit 1; }

        have_cmd() {
            command -v "$1" >/dev/null 2>&1
        }

        require_jq() {
            have_cmd jq || die "jq is required for this command."
        }



        can_use_color() {
            [ "${MAGENT_USE_COLOR:-1}" != "0" ] || return 1
            [ -z "${NO_COLOR:-}" ] || return 1
            [ "${TERM:-}" != "dumb" ] || return 1
            return 0
        }

        setup_colors() {
            if can_use_color; then
                ANSI_RESET="$(printf '\033[0m')"
                ANSI_BOLD="$(printf '\033[1m')"
                ANSI_DIM="$(printf '\033[2m')"
                ANSI_WHITE="$(printf '\033[97m')"
                ANSI_MUTED="$(printf '\033[38;5;245m')"
                ANSI_BLUE="$(printf '\033[38;5;117m')"
                ANSI_GREEN="$(printf '\033[38;5;78m')"
                ANSI_YELLOW="$(printf '\033[38;5;221m')"
                ANSI_ORANGE="$(printf '\033[38;5;215m')"
                ANSI_RED="$(printf '\033[38;5;203m')"
                ANSI_CYAN="$(printf '\033[38;5;81m')"
                ANSI_MAGENTA="$(printf '\033[38;5;176m')"
            else
                ANSI_RESET=""
                ANSI_BOLD=""
                ANSI_DIM=""
                ANSI_WHITE=""
                ANSI_MUTED=""
                ANSI_BLUE=""
                ANSI_GREEN=""
                ANSI_YELLOW=""
                ANSI_ORANGE=""
                ANSI_RED=""
                ANSI_CYAN=""
                ANSI_MAGENTA=""
            fi
        }

        paint() {
            paint_color="$1"
            shift
            if [ -n "$paint_color" ]; then
                printf '%s%s%s' "$paint_color" "$*" "$ANSI_RESET"
            else
                printf '%s' "$*"
            fi
        }

        paint_hex() {
            ph_hex=$(printf '%s' "$1" | sed 's/^#//')
            ph_text="$2"
            if [ -n "$ANSI_RESET" ] && [ "${#ph_hex}" -ge 6 ]; then
                ph_r=$(printf '%d' "0x$(printf '%.2s' "$ph_hex")")
                ph_g=$(printf '%d' "0x$(printf '%.2s' "${ph_hex#??}")")
                ph_b=$(printf '%d' "0x$(printf '%.2s' "${ph_hex#????}")")
                printf '\033[38;2;%d;%d;%dm%s%s' "$ph_r" "$ph_g" "$ph_b" "$ph_text" "$ANSI_RESET"
            else
                printf '%s' "$ph_text"
            fi
        }

        join_with_dot() {
            joined=""
            while [ $# -gt 0 ]; do
                if [ -n "$1" ]; then
                    if [ -n "$joined" ]; then
                        joined="$joined · $1"
                    else
                        joined="$1"
                    fi
                fi
                shift
            done
            printf '%s' "$joined"
        }

        append_badge() {
            existing="$1"
            badge="$2"
            if [ -n "$existing" ] && [ -n "$badge" ]; then
                printf '%s %s' "$existing" "$badge"
            elif [ -n "$badge" ]; then
                printf '%s' "$badge"
            else
                printf '%s' "$existing"
            fi
        }

        format_thread_badges() {
            badges=""
            [ "$1" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_BLUE" "[busy]")")
            [ "$2" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_YELLOW" "[input]")")
            [ "$3" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_GREEN" "[done]")")
            [ "$4" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_ORANGE" "[dirty]")")
            [ "$5" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_RED" "[limited]")")
            [ "$6" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_CYAN" "[delivered]")")
            [ "$7" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_MAGENTA" "[pinned]")")
            [ "$8" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_MUTED" "[hidden]")")
            [ "$9" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_YELLOW" "[branch?]")")
            [ "${10}" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_RED" "[jira]")")
            [ "${11}" = "true" ] && badges=$(append_badge "$badges" "$(paint "$ANSI_RED" "[♥]")")
            printf '%s' "$badges"
        }

        format_tab_badges() {
            tab_badges=""
            [ "$1" = "true" ] && tab_badges=$(append_badge "$tab_badges" "$(paint "$ANSI_BLUE" "[busy]")")
            [ "$2" = "true" ] && tab_badges=$(append_badge "$tab_badges" "$(paint "$ANSI_YELLOW" "[input]")")
            [ "$3" = "true" ] && tab_badges=$(append_badge "$tab_badges" "$(paint "$ANSI_GREEN" "[done]")")
            [ "$4" = "true" ] && tab_badges=$(append_badge "$tab_badges" "$(paint "$ANSI_RED" "[limited]")")
            printf '%s' "$tab_badges"
        }

        format_picker_title() {
            picker_is_main="$1"
            picker_title="$2"
            if [ "$picker_is_main" = "true" ]; then
                paint "$ANSI_BOLD$ANSI_CYAN" "$picker_title"
            else
                paint "$ANSI_BOLD$ANSI_WHITE" "$picker_title"
            fi
        }

        format_picker_detail() {
            picker_title="$1"
            picker_name="$2"
            picker_branch="$3"
            picker_worktree="$4"
            picker_agent="$5"

            picker_meta=""
            if [ -n "$picker_name" ] && [ "$picker_name" != "$picker_title" ]; then
                picker_meta=$(join_with_dot "$picker_meta" "$(paint "$ANSI_MUTED" "$picker_name")")
            fi
            picker_meta=$(join_with_dot "$picker_meta" "$(paint "$ANSI_WHITE" "$picker_branch")")
            picker_meta=$(join_with_dot "$picker_meta" "$(paint "$ANSI_MUTED" "$picker_worktree")")
            picker_meta=$(join_with_dot "$picker_meta" "$(paint "$ANSI_BLUE" "$picker_agent")")

            printf '%s' "$picker_meta"
        }

        format_picker_pr_jira() {
            pr_label="$1"
            pr_status="$2"
            jira_key="$3"

            pr_jira=""
            if [ -n "$pr_label" ] && [ "$pr_label" != "-" ]; then
                pr_text="$pr_label"
                if [ -n "$pr_status" ] && [ "$pr_status" != "-" ]; then
                    pr_text="$pr_text ($pr_status)"
                fi
                pr_jira=$(join_with_dot "$pr_jira" "$(paint "$ANSI_CYAN" "$pr_text")")
            fi
            if [ -n "$jira_key" ] && [ "$jira_key" != "-" ]; then
                pr_jira=$(join_with_dot "$pr_jira" "$(paint "$ANSI_YELLOW" "$jira_key")")
            fi
            printf '%s' "$pr_jira"
        }

        format_ls_status() {
            ls_badges=$(format_thread_badges "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}")
            printf '%s' "$ls_badges" | sed 's/\[//g; s/\]//g; s/ /,/g'
        }

        # Escape a value for JSON string embedding (handles newlines, CR, tabs, quotes, backslashes)
        json_escape() {
            printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | \
                awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {gsub(/\r/,"\\r"); print}'
        }

        json_kv() {
            printf '"%s":"%s"' "$1" "$(json_escape "$2")"
        }

        save_last_attach_state() {
            save_project="$1"
            save_thread_id="$2"
            save_session="$3"
            [ -n "$save_project" ] || return 0
            [ -n "$save_thread_id" ] || return 0
            save_dir=$(dirname "$INTERACTIVE_STATE_FILE")
            mkdir -p "$save_dir" 2>/dev/null || return 0
            save_tmp="${INTERACTIVE_STATE_FILE}.tmp.$$"
            printf '{%s,%s,%s}\n' \
                "$(json_kv project "$save_project")" \
                "$(json_kv threadId "$save_thread_id")" \
                "$(json_kv sessionName "$save_session")" >"$save_tmp" 2>/dev/null || {
                rm -f "$save_tmp"
                return 0
            }
            mv "$save_tmp" "$INTERACTIVE_STATE_FILE" 2>/dev/null || rm -f "$save_tmp"
        }

        remember_attach_context_from_session() {
            remember_session="$1"
            [ -n "$remember_session" ] || return 0
            have_cmd jq || return 0
            remember_req="{$(json_kv command current-thread),$(json_kv sessionName "$remember_session")}"
            remember_resp=$(send_checked_request "$remember_req" 2>/dev/null) || return 0
            remember_project=$(printf '%s' "$remember_resp" | jq -r '.thread.projectName // empty' 2>/dev/null)
            remember_thread_id=$(printf '%s' "$remember_resp" | jq -r '.thread.id // empty' 2>/dev/null)
            [ -n "$remember_project" ] && [ -n "$remember_thread_id" ] || return 0
            save_last_attach_state "$remember_project" "$remember_thread_id" "$remember_session"
        }

        load_last_attach_state() {
            LAST_ATTACHED_PROJECT=""
            LAST_ATTACHED_THREAD_ID=""
            LAST_ATTACHED_SESSION=""
            [ -f "$INTERACTIVE_STATE_FILE" ] || return 0
            have_cmd jq || return 0
            LAST_ATTACHED_PROJECT=$(jq -r '.project // empty' "$INTERACTIVE_STATE_FILE" 2>/dev/null)
            LAST_ATTACHED_THREAD_ID=$(jq -r '.threadId // empty' "$INTERACTIVE_STATE_FILE" 2>/dev/null)
            LAST_ATTACHED_SESSION=$(jq -r '.sessionName // empty' "$INTERACTIVE_STATE_FILE" 2>/dev/null)
        }

        send_request() {
            printf '%s\n' "$1" | nc -U "$SOCKET" -w "${2:-10}" 2>/dev/null
        }

        send_checked_request() {
            require_jq
            checked_resp=$(send_request "$1")
            [ -n "$checked_resp" ] || die "Cannot reach Magent IPC at $SOCKET. Is Magent.app running?"
            checked_ok=$(printf '%s' "$checked_resp" | jq -r '.ok // false' 2>/dev/null)
            [ "$checked_ok" = "true" ] || {
                checked_err=$(printf '%s' "$checked_resp" | jq -r '.error // "Unknown error"' 2>/dev/null)
                die "$checked_err"
            }
            checked_warning=$(printf '%s' "$checked_resp" | jq -r '.warning // empty' 2>/dev/null)
            [ -z "$checked_warning" ] || echo "Warning: $checked_warning" >&2
            printf '%s\n' "$checked_resp"
        }

        setup_colors

        pick_value() {
            picker_prompt="$1"
            picker_tmp=$(mktemp 2>/dev/null || mktemp -t magent-picker)
            cat >"$picker_tmp"

            if [ ! -s "$picker_tmp" ]; then
                rm -f "$picker_tmp"
                return 1
            fi

            picker_choice=""
            awk -F '\037' '
                BEGIN { n = 0 }
                {
                    if ($1 ~ /^__section__/) {
                        printf "\n  %s\n", $2
                    } else {
                        n++
                        printf "%3d) %s\n", n, $2
                        for (i = 3; i <= NF; i++) {
                            if ($i != "") printf "     %s\n", $i
                        }
                        printf "\n"
                    }
                }
            ' "$picker_tmp" >/dev/tty
            printf '%s> ' "$picker_prompt" >/dev/tty
            IFS= read -r picker_idx </dev/tty || picker_idx=""
            case "$picker_idx" in
                ''|*[!0-9]*) picker_choice="" ;;
                *) picker_choice=$(awk -F '\037' -v n="$picker_idx" '
                    BEGIN { idx = 0 }
                    $1 ~ /^__section__/ { next }
                    { idx++ }
                    idx == n { print $1; exit }
                ' "$picker_tmp") ;;
            esac

            rm -f "$picker_tmp"
            [ -n "$picker_choice" ] || return 1
            printf '%s\n' "$picker_choice"
        }

        attach_tmux_session() {
            attach_session="$1"
            [ -n "$attach_session" ] || die "Missing tmux session name"
            have_cmd tmux || die "tmux is required."
            tmux has-session -t "$attach_session" 2>/dev/null || die "tmux session not found: $attach_session"
            remember_attach_context_from_session "$attach_session"

            if [ -n "${TMUX:-}" ]; then
                tmux switch-client -t "$attach_session"
            else
                exec tmux attach -t "$attach_session"
            fi
        }

        pick_project() {
            project_resp=$(send_checked_request "{$(json_kv command list-projects)}")
            project_lines=$(printf '%s' "$project_resp" | jq -r '.projects | sort_by(.name)[] | "\(.name)\u001f\(.name)\u001f\(.repoPath)"')
            [ -n "$project_lines" ] || die "No projects configured."
            printf '%s\n' "$project_lines" | pick_value "Project"
        }

        project_exists() {
            project_name="$1"
            [ -n "$project_name" ] || return 1
            project_exists_resp=$(send_checked_request "{$(json_kv command list-projects)}")
            printf '%s' "$project_exists_resp" | jq -e --arg name "$project_name" '.projects[] | select(.name == $name)' >/dev/null 2>&1
        }

        thread_exists_in_project() {
            thread_project="$1"
            thread_id="$2"
            [ -n "$thread_project" ] || return 1
            [ -n "$thread_id" ] || return 1
            thread_exists_req="{$(json_kv command list-sections),$(json_kv project "$thread_project")}"
            thread_exists_resp=$(send_checked_request "$thread_exists_req")
            printf '%s' "$thread_exists_resp" | jq -e --arg id "$thread_id" '.sections[] | (.threads // [])[] | select(.id == $id)' >/dev/null 2>&1
        }

        pick_thread_or_create() {
            project_name="$1"
            thread_req="{$(json_kv command list-sections),$(json_kv project "$project_name")}"
            thread_resp=$(send_checked_request "$thread_req")
            # Build a flat list: "S<TAB>SectionName" for headers, "T<TAB>id<TAB>..." for threads
            thread_raw=$(printf '%s' "$thread_resp" | jq -r '
                .sections[]
                | . as $sec
                | (.threads // []) as $threads
                | if ($threads | length) == 0 then empty
                  else
                    (["S", $sec.name, ($sec.colorHex // "")] | @tsv),
                    ($threads[] | [
                        "T",
                        .id,
                        (if .isMain then "true" else "false" end),
                        (if .isMain then "main" else (if (.taskDescription // "") != "" then .taskDescription else .name end) end),
                        .name,
                        (.status.branchName // "-"),
                        (.worktreePath | split("/") | last),
                        (.agentType // "terminal"),
                        (if (.status.isBusy // false) then "true" else "false" end),
                        (if (.status.isWaitingForInput // false) then "true" else "false" end),
                        (if (.status.hasUnreadCompletion // false) then "true" else "false" end),
                        (if (.status.isDirty // false) then "true" else "false" end),
                        (if (.status.isBlockedByRateLimit // false) then "true" else "false" end),
                        (if (.status.isFullyDelivered // false) then "true" else "false" end),
                        (if (.status.isPinned // false) then "true" else "false" end),
                        (if (.status.isSidebarHidden // false) then "true" else "false" end),
                        (if (.status.hasBranchMismatch // false) then "true" else "false" end),
                        (if (.status.jiraUnassigned // false) then "true" else "false" end),
                        (if (.status.isFavorite // false) then "true" else "false" end),
                        (.prLabel // "-"),
                        (.prStatusText // "-"),
                        (.jiraTicketKey // "-")
                    ] | @tsv)
                  end
            ')
            thread_lines=""
            if [ -n "$thread_raw" ]; then
                thread_tmp=$(mktemp 2>/dev/null || mktemp -t magent-thread-picker)
                printf '%s\n' "$thread_raw" >"$thread_tmp"
                thread_lines=$(while IFS="$(printf '\t')" read -r row_type thread_id thread_is_main thread_title thread_name thread_branch thread_worktree thread_agent thread_busy thread_input thread_done thread_dirty thread_limited thread_delivered thread_pinned thread_hidden thread_mismatch thread_jira thread_favorite thread_pr_label thread_pr_status thread_jira_key; do
                    if [ "$row_type" = "S" ]; then
                        section_color="$thread_is_main"
                        section_bullet=$(paint_hex "$section_color" "●")
                        section_name=$(printf '%s%s%s' "$ANSI_BOLD" "$(paint_hex "$section_color" "$thread_id")" "$ANSI_RESET")
                        section_label="$section_bullet $section_name"
                        printf '__section__%s%s%s%s\n' "$thread_id" "$SEP" "$section_label" "$SEP"
                    else
                        thread_label=$(format_picker_title "$thread_is_main" "$thread_title")
                        thread_detail=$(format_picker_detail "$thread_title" "$thread_name" "$thread_branch" "$thread_worktree" "$thread_agent")
                        thread_pr_jira=$(format_picker_pr_jira "$thread_pr_label" "$thread_pr_status" "$thread_jira_key")
                        thread_badges=$(format_thread_badges "$thread_busy" "$thread_input" "$thread_done" "$thread_dirty" "$thread_limited" "$thread_delivered" "$thread_pinned" "$thread_hidden" "$thread_mismatch" "$thread_jira" "$thread_favorite")
                        printf '%s%s%s%s%s%s%s%s%s\n' "$thread_id" "$SEP" "$thread_label" "$SEP" "$thread_detail" "$SEP" "$thread_pr_jira" "$SEP" "$thread_badges"
                    fi
                done <"$thread_tmp")
                rm -f "$thread_tmp"
            fi
            if [ -n "$thread_lines" ]; then
                {
                    printf '__back__%s← Back%sReturn to project list\n' "$SEP" "$SEP"
                    printf '__create__%s+ Create thread%sPick agent/terminal and attach\n' "$SEP" "$SEP"
                    printf '%s\n' "$thread_lines"
                } | pick_value "Thread"
            else
                {
                    printf '__back__%s← Back%sReturn to project list\n' "$SEP" "$SEP"
                    printf '__create__%s+ Create thread%sPick agent/terminal and attach\n' "$SEP" "$SEP"
                } | pick_value "Thread"
            fi
        }

        pick_tab_session() {
            tab_thread_id="$1"
            tab_req="{$(json_kv command list-tabs),$(json_kv threadId "$tab_thread_id")}"
            tab_resp=$(send_checked_request "$tab_req")
            tab_count=$(printf '%s' "$tab_resp" | jq -r '.tabs | length')
            [ "$tab_count" -gt 0 ] || die "Thread has no tabs."

            if [ "$tab_count" -eq 1 ]; then
                printf '%s' "$tab_resp" | jq -r '.tabs[0].sessionName'
                return 0
            fi

            tab_raw=$(printf '%s' "$tab_resp" | jq -r '.tabs | sort_by(.index)[] | [
                .sessionName,
                .index,
                (.displayName // ("Tab " + (.index | tostring))),
                (if .isAgent then (.agentType // "agent") else "terminal" end),
                (if (.isBusy // false) then "true" else "false" end),
                (if (.isWaitingForInput // false) then "true" else "false" end),
                (if (.hasUnreadCompletion // false) then "true" else "false" end),
                (if (.isBlockedByRateLimit // false) then "true" else "false" end)
            ] | @tsv')
            tab_lines=$(printf '%s\n' "$tab_raw" | while IFS="$(printf '\t')" read -r tab_session tab_idx tab_label tab_agent_type tab_busy tab_input tab_done tab_limited; do
                tab_detail=$(join_with_dot "" "$(paint "$ANSI_BLUE" "$tab_agent_type")" "$(paint "$ANSI_MUTED" "$tab_session")")
                tab_badges=$(format_tab_badges "$tab_busy" "$tab_input" "$tab_done" "$tab_limited")
                printf '%s%s%s%s%s%s%s\n' "$tab_session" "$SEP" "$tab_label" "$SEP" "$tab_detail" "$SEP" "$tab_badges"
            done)
            {
                printf '__back_thread__%s← Back to threads%sReturn to thread list\n' "$SEP" "$SEP"
                printf '__back_project__%s← Back to projects%sReturn to project list\n' "$SEP" "$SEP"
                printf '%s\n' "$tab_lines"
            } | pick_value "Tab"
        }

        interactive_create_thread() {
            create_project="$1"
            create_agents_req="{$(json_kv command list-projects)}"
            create_agents_resp=$(send_checked_request "$create_agents_req")
            create_agent_lines=$(printf '%s' "$create_agents_resp" | jq -r '
                .activeAgents // []
                | .[]
                | select(. == "claude" or . == "codex" or . == "custom")
                | . + "\u001f" + (if . == "claude" then "Claude" elif . == "codex" then "Codex" else "Custom" end)
            ')
            create_mode=$(
                {
                    printf 'default%sUse Project Default\n' "$SEP"
                    if [ -n "$create_agent_lines" ]; then
                        printf '%s\n' "$create_agent_lines"
                    fi
                    printf 'terminal%sTerminal\n' "$SEP"
                    printf '__back__%s← Back\n' "$SEP"
                } | pick_value "Thread Type"
            ) || return 1
            [ "$create_mode" = "__back__" ] && return 2

            create_req="{$(json_kv command create-thread),$(json_kv project "$create_project")"
            if [ "$create_mode" != "default" ]; then
                create_req="$create_req,$(json_kv agentType "$create_mode")"
            fi
            create_req="$create_req}"

            create_resp=$(send_checked_request "$create_req")
            create_session=$(printf '%s' "$create_resp" | jq -r '.thread.tmuxSession // empty')
            [ -n "$create_session" ] || die "Created thread has no tmux session."
            attach_tmux_session "$create_session"
        }

        run_interactive() {
            interactive_project="$1"
            interactive_fixed_project=0
            interactive_resume_thread=""
            [ -n "$interactive_project" ] && interactive_fixed_project=1
            if [ "$interactive_fixed_project" -eq 0 ]; then
                load_last_attach_state
                if [ -n "$LAST_ATTACHED_PROJECT" ] && project_exists "$LAST_ATTACHED_PROJECT"; then
                    interactive_project="$LAST_ATTACHED_PROJECT"
                    interactive_resume_thread="$LAST_ATTACHED_THREAD_ID"
                fi
            fi

            while :; do
                if [ -z "$interactive_project" ]; then
                    interactive_project=$(pick_project) || exit 1
                fi

                if [ -n "$interactive_resume_thread" ] && thread_exists_in_project "$interactive_project" "$interactive_resume_thread"; then
                    interactive_pick="$interactive_resume_thread"
                else
                    interactive_resume_thread=""
                    interactive_pick=$(pick_thread_or_create "$interactive_project") || exit 1
                fi

                case "$interactive_pick" in __section__*) continue ;; esac

                if [ "$interactive_pick" = "__back__" ]; then
                    if [ "$interactive_fixed_project" -eq 1 ]; then
                        continue
                    fi
                    interactive_project=""
                    continue
                fi

                if [ "$interactive_pick" = "__create__" ]; then
                    interactive_create_thread "$interactive_project"
                    create_status=$?
                    if [ "$create_status" -eq 2 ]; then
                        continue
                    fi
                    return "$create_status"
                fi

                interactive_back_to_project=0
                while :; do
                    interactive_session=$(pick_tab_session "$interactive_pick") || exit 1
                    if [ "$interactive_session" = "__back_thread__" ]; then
                        interactive_resume_thread=""
                        break
                    fi
                    if [ "$interactive_session" = "__back_project__" ]; then
                        interactive_project=""
                        interactive_resume_thread=""
                        interactive_back_to_project=1
                        break
                    fi
                    attach_tmux_session "$interactive_session"
                    return
                done
                if [ "$interactive_back_to_project" -eq 1 ]; then
                    continue
                fi
            done
        }

        run_ls() {
            ls_project="$1"
            ls_req="{$(json_kv command list-threads)"
            [ -n "$ls_project" ] && ls_req="$ls_req,$(json_kv project "$ls_project")"
            ls_req="$ls_req}"

            ls_resp=$(send_checked_request "$ls_req")
            ls_count=$(printf '%s' "$ls_resp" | jq -r '.threads | length')
            if [ "$ls_count" -eq 0 ]; then
                echo "No threads found."
                return 0
            fi

            ls_tmp=$(mktemp 2>/dev/null || mktemp -t magent-ls)
            printf '%s' "$ls_resp" \
                | jq -r '.threads[] | [
                    .projectName,
                    .name,
                    (.status.branchName // "-"),
                    (.agentType // "terminal"),
                    (.taskDescription // ""),
                    .tmuxSession,
                    (if (.status.isBusy // false) then "true" else "false" end),
                    (if (.status.isWaitingForInput // false) then "true" else "false" end),
                    (if (.status.hasUnreadCompletion // false) then "true" else "false" end),
                    (if (.status.isDirty // false) then "true" else "false" end),
                    (if (.status.isBlockedByRateLimit // false) then "true" else "false" end),
                    (if (.status.isFullyDelivered // false) then "true" else "false" end),
                    (if (.status.isPinned // false) then "true" else "false" end),
                    (if (.status.isSidebarHidden // false) then "true" else "false" end),
                    (if (.status.hasBranchMismatch // false) then "true" else "false" end),
                    (if (.status.jiraUnassigned // false) then "true" else "false" end),
                    (if (.status.isFavorite // false) then "true" else "false" end)
                ] | @tsv' \
                | while IFS="$(printf '\t')" read -r ls_project_name ls_name ls_branch ls_agent ls_desc ls_session ls_busy ls_input ls_done ls_dirty ls_limited ls_delivered ls_pinned ls_hidden ls_mismatch ls_jira ls_favorite; do
                    ls_status=$(format_ls_status "$ls_busy" "$ls_input" "$ls_done" "$ls_dirty" "$ls_limited" "$ls_delivered" "$ls_pinned" "$ls_hidden" "$ls_mismatch" "$ls_jira" "$ls_favorite")
                    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ls_project_name" "$ls_name" "$ls_branch" "$ls_agent" "$ls_status" "$ls_desc" "$ls_session"
                done >"$ls_tmp"

            {
                printf 'PROJECT\tTHREAD\tBRANCH\tTYPE\tSTATUS\tDESCRIPTION\tSESSION\n'
                sort -t "$(printf '\t')" -k1,1 -k2,2 "$ls_tmp"
            } | if have_cmd column; then
                column -t -s "$(printf '\t')"
            else
                cat
            fi
            rm -f "$ls_tmp"
        }

        cmd="${1:-}"
        [ -n "$cmd" ] && shift
        if [ -z "$cmd" ] && [ -t 0 ] && [ -t 1 ]; then
            cmd="interactive"
        fi

        case "$cmd" in
        create-thread)
            project=""; agent=""; model=""; reasoning=""; prompt=""; name=""; desc=""; section=""; base_thread=""; base_branch=""; do_select=""; no_submit=""; from_thread=""; priority=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project)      project="$2"; shift 2 ;;
                    --agent)        agent="$2"; shift 2 ;;
                    --model)        model="$2"; shift 2 ;;
                    --reasoning)    reasoning="$2"; shift 2 ;;
                    --prompt)       prompt="$2"; shift 2 ;;
                    --prompt-file)  [ -f "$2" ] || die "Prompt file not found: $2"; prompt="$(cat "$2")"; shift 2 ;;
                    --name)         name="$2"; shift 2 ;;
                    --description)  desc="$2"; shift 2 ;;
                    --section)      section="$2"; shift 2 ;;
                    --base-thread)  base_thread="$2"; shift 2 ;;
                    --base-branch)  base_branch="$2"; shift 2 ;;
                    --from-thread)  from_thread="$2"; shift 2 ;;
                    --priority)     priority="$2"; shift 2 ;;
                    --select)       do_select=1; shift ;;
                    --no-submit)    no_submit=1; shift ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$project" ] || die "Usage: magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--prompt <text>] [--name <slug>] [--description <text>] [--section <name>] [--base-thread <name> | --base-branch <name>] [--from-thread <name|main|none>] [--priority 1-5] [--select] [--no-submit]"
            [ -z "$base_thread" ] || [ -z "$base_branch" ] || die "Use either --base-thread or --base-branch, not both"
            if [ -n "$priority" ]; then
                case "$priority" in
                    1|2|3|4|5) : ;;
                    *) die "--priority must be an integer 1-5" ;;
                esac
            fi
            json="{$(json_kv command create-thread),$(json_kv project "$project")"
            [ -n "$agent" ] && json="$json,$(json_kv agentType "$agent")"
            [ -n "$model" ] && json="$json,$(json_kv modelId "$model")"
            [ -n "$reasoning" ] && json="$json,$(json_kv reasoningLevel "$reasoning")"
            [ -n "$prompt" ] && json="$json,$(json_kv prompt "$prompt")"
            [ -n "$name" ] && json="$json,$(json_kv newName "$name")"
            [ -n "$desc" ] && json="$json,$(json_kv description "$desc")"
            [ -n "$section" ] && json="$json,$(json_kv sectionName "$section")"
            [ -n "$base_thread" ] && json="$json,$(json_kv baseThreadName "$base_thread")"
            [ -n "$base_branch" ] && json="$json,$(json_kv baseBranch "$base_branch")"
            [ -n "$priority" ] && json="$json,\"priority\":$priority"
            # --from-thread: explicit name ("main", "none", or thread name)
            if [ -n "$from_thread" ]; then
                json="$json,$(json_kv fromThreadName "$from_thread")"
            elif [ -n "$MAGENT_THREAD_ID" ]; then
                # Auto-inject current thread context when running inside a Magent session
                json="$json,$(json_kv fromThreadId "$MAGENT_THREAD_ID")"
            fi
            [ "$do_select" = "1" ] && json="$json,\"select\":true"
            [ "$no_submit" = "1" ] && json="$json,\"noSubmit\":true"
            json="$json}"
            send_request "$json" 120
            ;;
        batch-create)
            require_jq
            project=""; no_submit=""; bc_file=""; from_thread=""
            specs="[]"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project)      project="$2"; shift 2 ;;
                    --no-submit)    no_submit=1; shift ;;
                    --file)         bc_file="$2"; shift 2 ;;
                    --from-thread)  from_thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$project" ] || die "Usage: magent-cli batch-create --project <name> --file <specs.json> [--from-thread <name|main|none>] [--no-submit]"
            [ -n "$bc_file" ] || die "Missing --file <specs.json>. File must contain a JSON array of thread specs."
            [ -f "$bc_file" ] || die "File not found: $bc_file"
            raw_specs=$(cat "$bc_file") || die "Failed to read: $bc_file"
            # Validate it is a JSON array and compact it — the IPC protocol is
            # newline-delimited, so pretty-printed JSON with embedded newlines
            # would be truncated at the first \n and cause an "Invalid JSON" error.
            specs=$(printf '%s' "$raw_specs" | jq -ec 'if type == "array" then . else error("not an array") end' 2>/dev/null) \
                || die "File must contain a JSON array of thread specs"
            json="{$(json_kv command batch-create),$(json_kv project "$project"),\"threads\":$specs"
            [ "$no_submit" = "1" ] && json="$json,\"noSubmit\":true"
            # --from-thread: explicit name applies to all specs without per-spec fromThreadName
            if [ -n "$from_thread" ]; then
                json="$json,$(json_kv fromThreadName "$from_thread")"
            elif [ -n "$MAGENT_THREAD_ID" ]; then
                json="$json,$(json_kv fromThreadId "$MAGENT_THREAD_ID")"
            fi
            json="$json}"
            send_request "$json" 300
            ;;
        list-projects)
            send_request "{$(json_kv command list-projects)}"
            ;;
        list-threads)
            project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            json="{$(json_kv command list-threads)"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        list-archived)
            archived_project=""
            archived_limit=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) archived_project="$2"; shift 2 ;;
                    --limit) archived_limit="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            json="{$(json_kv command list-archived)"
            [ -n "$archived_project" ] && json="$json,$(json_kv project "$archived_project")"
            if [ -n "$archived_limit" ]; then
                case "$archived_limit" in
                    ''|*[!0-9]*) die "--limit must be a positive integer" ;;
                esac
                json="$json,\"limit\":$archived_limit"
            fi
            json="$json}"
            send_request "$json"
            ;;
        ls)
            ls_project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) ls_project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            run_ls "$ls_project"
            ;;
        interactive)
            interactive_project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) interactive_project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            run_interactive "$interactive_project"
            ;;
        attach)
            attach_thread=""
            attach_thread_id=""
            attach_tab_index=""
            attach_session=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) attach_thread="$2"; shift 2 ;;
                    --thread-id) attach_thread_id="$2"; shift 2 ;;
                    --index) attach_tab_index="$2"; shift 2 ;;
                    --session) attach_session="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done

            if [ -n "$attach_session" ]; then
                attach_tmux_session "$attach_session"
                exit $?
            fi

            [ -z "$attach_thread" ] || [ -z "$attach_thread_id" ] || die "Use either --thread or --thread-id, not both"
            [ -n "$attach_thread" ] || [ -n "$attach_thread_id" ] || die "Usage: magent-cli attach (--thread <name> | --thread-id <id>) [--index <n> | --session <name>]"

            attach_list_req="{$(json_kv command list-tabs),"
            if [ -n "$attach_thread_id" ]; then
                attach_list_req="$attach_list_req$(json_kv threadId "$attach_thread_id")"
            else
                attach_list_req="$attach_list_req$(json_kv threadName "$attach_thread")"
            fi
            attach_list_req="$attach_list_req}"
            attach_list_resp=$(send_checked_request "$attach_list_req")

            if [ -n "$attach_tab_index" ]; then
                case "$attach_tab_index" in
                    ''|*[!0-9]*) die "--index must be an integer" ;;
                esac
                attach_session=$(printf '%s' "$attach_list_resp" | jq -r --argjson idx "$attach_tab_index" '.tabs[] | select(.index == $idx) | .sessionName' | head -1)
            else
                attach_session=$(printf '%s' "$attach_list_resp" | jq -r '.tabs[0].sessionName // empty')
            fi

            [ -n "$attach_session" ] || die "No matching tab found."
            attach_tmux_session "$attach_session"
            ;;
        send-prompt)
            thread=""; prompt=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --prompt) prompt="$2"; shift 2 ;;
                    --prompt-file) [ -f "$2" ] || die "Prompt file not found: $2"; prompt="$(cat "$2")"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$prompt" ] || die "Usage: magent-cli send-prompt --thread <name> --prompt <text|--prompt-file path>"
            send_request "{$(json_kv command send-prompt),$(json_kv threadName "$thread"),$(json_kv prompt "$prompt")}"
            ;;
        archive-thread)
            thread=""
            force=0
            skip_local_sync=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --force) force=1; shift ;;
                    --skip-local-sync) skip_local_sync=1; shift ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli archive-thread --thread <name> [--force] [--skip-local-sync]
        Archive removes the worktree directory and keeps the git branch. Without --force, archive is refused when the worktree is dirty (uncommitted/untracked changes).
        Dirty worktrees must be committed/stashed/discarded before archive.
        --force does NOT bypass dirty-worktree refusal; it only continues when local sync fails for non-conflict reasons."
            json="{$(json_kv command archive-thread),$(json_kv threadName "$thread")"
            [ "$force" = "1" ] && json="$json,\"force\":true"
            [ "$skip_local_sync" = "1" ] && json="$json,\"skipLocalSync\":true"
            json="$json}"
            send_checked_request "$json" >/dev/null
            ;;
        delete-thread)
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli delete-thread --thread <name>"
            send_request "{$(json_kv command delete-thread),$(json_kv threadName "$thread")}"
            ;;
        list-tabs)
            thread=""; thread_id=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --thread-id) thread_id="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -z "$thread" ] || [ -z "$thread_id" ] || die "Use either --thread or --thread-id, not both"
            [ -n "$thread" ] || [ -n "$thread_id" ] || die "Usage: magent-cli list-tabs (--thread <name> | --thread-id <id>)"
            if [ -n "$thread_id" ]; then
                send_request "{$(json_kv command list-tabs),$(json_kv threadId "$thread_id")}"
            else
                send_request "{$(json_kv command list-tabs),$(json_kv threadName "$thread")}"
            fi
            ;;
        create-tab)
            thread=""; agent=""; model=""; reasoning=""; prompt=""; title=""; fresh=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)    thread="$2"; shift 2 ;;
                    --agent)     agent="$2"; shift 2 ;;
                    --model)     model="$2"; shift 2 ;;
                    --reasoning) reasoning="$2"; shift 2 ;;
                    --prompt)    prompt="$2"; shift 2 ;;
                    --title)     title="$2"; shift 2 ;;
                    --fresh|--no-resume) fresh=1; shift ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--title <text>] [--fresh|--no-resume] [--prompt <text>]"
            json="{$(json_kv command create-tab),$(json_kv threadName "$thread")"
            [ -n "$agent" ] && json="$json,$(json_kv agentType "$agent")"
            [ -n "$model" ] && json="$json,$(json_kv modelId "$model")"
            [ -n "$reasoning" ] && json="$json,$(json_kv reasoningLevel "$reasoning")"
            [ -n "$title" ] && json="$json,$(json_kv title "$title")"
            [ "$fresh" = "1" ] && json="$json,\"fresh\":true"
            [ -n "$prompt" ] && json="$json,$(json_kv prompt "$prompt")"
            json="$json}"
            send_request "$json" 60
            ;;
        close-tab)
            thread=""; tab_index=""; session=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)  thread="$2"; shift 2 ;;
                    --index)   tab_index="$2"; shift 2 ;;
                    --session) session="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli close-tab --thread <name> (--index <n> | --session <name>)"
            json="{$(json_kv command close-tab),$(json_kv threadName "$thread")"
            if [ -n "$tab_index" ]; then
                json="$json,\"tabIndex\":$tab_index"
            elif [ -n "$session" ]; then
                json="$json,$(json_kv sessionName "$session")"
            else
                die "Specify --index <n> or --session <name>"
            fi
            json="$json}"
            send_request "$json"
            ;;
        current-thread)
            session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
            [ -n "$session" ] || die "Not running inside a tmux session"
            send_request "{$(json_kv command current-thread),$(json_kv sessionName "$session")}"
            ;;
        auto-rename-thread|rename-thread)
            thread=""; prompt=""; description=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)      thread="$2"; shift 2 ;;
                    --prompt)      prompt="$2"; shift 2 ;;
                    --description) description="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -z "$prompt" ] && [ -n "$description" ] && prompt="$description"
            [ -n "$thread" ] && [ -n "$prompt" ] || die "Usage: magent-cli auto-rename-thread --thread <name> --prompt <text>"
            send_request "{$(json_kv command auto-rename-thread),$(json_kv threadName "$thread"),$(json_kv prompt "$prompt")}" 60
            ;;
        rename-branch|rename-thread-exact)
            thread=""; name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --name)   name="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$name" ] || die "Usage: magent-cli rename-branch --thread <name> --name <text>"
            send_request "{$(json_kv command rename-branch),$(json_kv threadName "$thread"),$(json_kv newName "$name")}"
            ;;
        set-description)
            thread=""; description=""; clear=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)      thread="$2"; shift 2 ;;
                    --description) description="$2"; shift 2 ;;
                    --clear)       clear="1"; shift 1 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli set-description --thread <name> [--description <text> | --clear]"
            [ -z "$clear" ] || [ -z "$description" ] || die "Choose either --description or --clear"
            json="{$(json_kv command set-description),$(json_kv threadName "$thread")"
            [ -n "$description" ] && json="$json,$(json_kv description "$description")"
            json="$json}"
            send_request "$json"
            ;;
        set-priority)
            thread=""; priority=""; clear=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)   thread="$2"; shift 2 ;;
                    --priority) priority="$2"; shift 2 ;;
                    --clear)    clear="1"; shift 1 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli set-priority --thread <name> (--priority 1-5 | --clear)"
            [ -z "$clear" ] || [ -z "$priority" ] || die "Choose either --priority or --clear"
            [ -n "$clear" ] || [ -n "$priority" ] || die "Missing --priority <1-5> or --clear"
            if [ -n "$priority" ]; then
                case "$priority" in
                    1|2|3|4|5) : ;;
                    *) die "--priority must be an integer 1-5" ;;
                esac
            fi
            json="{$(json_kv command set-priority),$(json_kv threadName "$thread")"
            if [ -n "$clear" ]; then
                json="$json,\"remove\":true"
            else
                json="$json,\"priority\":$priority"
            fi
            json="$json}"
            send_request "$json"
            ;;
        set-thread-icon)
            thread=""; icon=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --icon)   icon="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$icon" ] || die "Usage: magent-cli set-thread-icon --thread <name> --icon <feature|fix|improvement|refactor|test|other>"
            send_request "{$(json_kv command set-thread-icon),$(json_kv threadName "$thread"),$(json_kv icon "$icon")}"
            ;;
        set-base-branch)
            thread=""; base_branch=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)      thread="$2"; shift 2 ;;
                    --base-branch) base_branch="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$base_branch" ] || die "Usage: magent-cli set-base-branch --thread <name> --base-branch <branch>"
            send_request "{$(json_kv command set-base-branch),$(json_kv threadName "$thread"),$(json_kv baseBranch "$base_branch")}"
            ;;
        hide-thread)
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli hide-thread --thread <name>"
            send_request "{$(json_kv command hide-thread),$(json_kv threadName "$thread")}"
            ;;
        unhide-thread)
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli unhide-thread --thread <name>"
            send_request "{$(json_kv command unhide-thread),$(json_kv threadName "$thread")}"
            ;;
        favorite-thread)
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli favorite-thread --thread <name>"
            send_request "{$(json_kv command favorite-thread),$(json_kv threadName "$thread")}"
            ;;
        unfavorite-thread)
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli unfavorite-thread --thread <name>"
            send_request "{$(json_kv command unfavorite-thread),$(json_kv threadName "$thread")}"
            ;;
        thread-info)
            thread=""; thread_id=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --thread-id) thread_id="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -z "$thread" ] || [ -z "$thread_id" ] || die "Use either --thread or --thread-id, not both"
            [ -n "$thread" ] || [ -n "$thread_id" ] || die "Usage: magent-cli thread-info (--thread <name> | --thread-id <id>)"
            if [ -n "$thread_id" ]; then
                send_request "{$(json_kv command thread-info),$(json_kv threadId "$thread_id")}"
            else
                send_request "{$(json_kv command thread-info),$(json_kv threadName "$thread")}"
            fi
            ;;
        move-thread)
            thread=""; section=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)  thread="$2"; shift 2 ;;
                    --section) section="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$section" ] || die "Usage: magent-cli move-thread --thread <name> --section <name>"
            send_request "{$(json_kv command move-thread),$(json_kv threadName "$thread"),$(json_kv sectionName "$section")}"
            ;;
        list-sections)
            project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            json="{$(json_kv command list-sections)"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        add-section)
            section_name=""; color=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    section_name="$2"; shift 2 ;;
                    --color)   color="$2"; shift 2 ;;
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] || die "Usage: magent-cli add-section --name <name> [--color <hex>] [--project <name>]"
            json="{$(json_kv command add-section),$(json_kv sectionName "$section_name")"
            [ -n "$color" ] && json="$json,$(json_kv sectionColor "$color")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        remove-section)
            section_name=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    section_name="$2"; shift 2 ;;
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] || die "Usage: magent-cli remove-section --name <name> [--project <name>]"
            json="{$(json_kv command remove-section),$(json_kv sectionName "$section_name")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        reorder-section)
            section_name=""; position=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)     section_name="$2"; shift 2 ;;
                    --position) position="$2"; shift 2 ;;
                    --project)  project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] && [ -n "$position" ] || die "Usage: magent-cli reorder-section --name <name> --position <n> [--project <name>]"
            json="{$(json_kv command reorder-section),$(json_kv sectionName "$section_name"),\"position\":$position"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        rename-section)
            section_name=""; new_name=""; color=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)     section_name="$2"; shift 2 ;;
                    --new-name) new_name="$2"; shift 2 ;;
                    --color)    color="$2"; shift 2 ;;
                    --project)  project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] && [ -n "$new_name" ] || die "Usage: magent-cli rename-section --name <name> --new-name <text> [--color <hex>] [--project <name>]"
            json="{$(json_kv command rename-section),$(json_kv sectionName "$section_name"),$(json_kv newName "$new_name")"
            [ -n "$color" ] && json="$json,$(json_kv sectionColor "$color")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        hide-section)
            section_name=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    section_name="$2"; shift 2 ;;
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] || die "Usage: magent-cli hide-section --name <name> [--project <name>]"
            json="{$(json_kv command hide-section),$(json_kv sectionName "$section_name")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        show-section)
            section_name=""; project=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    section_name="$2"; shift 2 ;;
                    --project) project="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] || die "Usage: magent-cli show-section --name <name> [--project <name>]"
            json="{$(json_kv command show-section),$(json_kv sectionName "$section_name")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            json="$json}"
            send_request "$json"
            ;;
        keep-alive-thread)
            thread=""; remove=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --remove) remove="1"; shift 1 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli keep-alive-thread --thread <name> [--remove]"
            json="{$(json_kv command keep-alive-thread),$(json_kv threadName "$thread")"
            [ -n "$remove" ] && json="$json,\"remove\":true"
            json="$json}"
            send_request "$json"
            ;;
        keep-alive-tab)
            thread=""; session=""; remove=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread)  thread="$2"; shift 2 ;;
                    --session) session="$2"; shift 2 ;;
                    --remove)  remove="1"; shift 1 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$session" ] || die "Usage: magent-cli keep-alive-tab --thread <name> --session <name> [--remove]"
            json="{$(json_kv command keep-alive-tab),$(json_kv threadName "$thread"),$(json_kv sessionName "$session")"
            [ -n "$remove" ] && json="$json,\"remove\":true"
            json="$json}"
            send_request "$json"
            ;;
        keep-alive-section)
            section_name=""; project=""; remove=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name)    section_name="$2"; shift 2 ;;
                    --project) project="$2"; shift 2 ;;
                    --remove)  remove="1"; shift 1 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$section_name" ] || die "Usage: magent-cli keep-alive-section --name <name> [--project <name>] [--remove]"
            json="{$(json_kv command keep-alive-section),$(json_kv sectionName "$section_name")"
            [ -n "$project" ] && json="$json,$(json_kv project "$project")"
            [ -n "$remove" ] && json="$json,\"remove\":true"
            json="$json}"
            send_request "$json"
            ;;
        docs|ipc-docs)
            cat <<'MAGENT_IPC_DOCS'
        \#(IPCAgentDocs.cliReferenceText)
        MAGENT_IPC_DOCS
            ;;
        ""|help|-h|--help)
            echo "Usage: magent-cli <command> [options]"
            echo ""
            echo "Interactive:"
            echo "  magent-cli                           (opens interactive picker in TTY)"
            echo "  magent-cli interactive [--project <name>]"
            echo "  magent-cli ls [--project <name>]"
            echo "  magent-cli attach (--thread <name> | --thread-id <id>) [--index <n>]"
            echo "  magent-cli attach --session <tmux-session>"
            echo "  magent-cli docs                      (full IPC command reference + usage guidance)"
            echo ""
            echo "Thread commands:"
            echo "  create-thread        --project <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--prompt <text> | --prompt-file <path>] [--name <slug>] [--description <text>] [--section <name>] [--base-thread <name> | --base-branch <name>] [--priority 1-5] [--select] [--no-submit]"
            echo "  batch-create         --project <name> --file <specs.json> [--no-submit]  (parallel thread creation; per-spec keys: agentType, modelId, reasoningLevel, prompt, ...)"
            echo "  list-projects"
            echo "  list-threads         [--project <name>]"
            echo "  list-archived        [--project <name>] [--limit <n>]  (most recently archived first)"
            echo "  send-prompt          --thread <name> (--prompt <text> | --prompt-file <path>)"
            echo "  archive-thread       --thread <name> [--force] [--skip-local-sync]  (removes worktree, keeps branch; dirty worktrees are always refused; --force only continues after non-conflict local-sync failures)"
            echo "  delete-thread        --thread <name>    (removes worktree and branch)"
            echo "  list-tabs            (--thread <name> | --thread-id <id>)"
            echo "  create-tab           --thread <name> [--agent claude|codex|custom|terminal] [--model <id>] [--reasoning low|medium|high|max] [--title <text>] [--fresh|--no-resume] [--prompt <text>]"
            echo "  close-tab            --thread <name> (--index <n> | --session <name>)"
            echo "  current-thread                                               (returns current thread info)"
            echo "  auto-rename-thread   --thread <name> --prompt <text>       (AI-generated branch + description)"
            echo "  rename-thread        --thread <name> --prompt <text>       (alias for auto-rename-thread)"
            echo "  rename-branch        --thread <name> --name <text>         (exact branch name)"
            echo "  rename-thread-exact  --thread <name> --name <text>         (alias for rename-branch)"
            echo "  set-description      --thread <name> [--description <text> | --clear]"
            echo "  set-priority         --thread <name> (--priority 1-5 | --clear)                (1 lowest, 5 highest)"
            echo "  set-thread-icon      --thread <name> --icon <type>         (set thread icon: feature|fix|improvement|refactor|test|other)"
            echo "  set-base-branch      --thread <name> --base-branch <branch>"
            echo "  hide-thread         --thread <name>                        (move thread to dimmed bottom group)"
            echo "  unhide-thread       --thread <name>                        (restore thread to normal group)"
            echo "  favorite-thread     --thread <name>                        (add thread to favorites; max 10)"
            echo "  unfavorite-thread   --thread <name>                        (remove thread from favorites)"
            echo "  thread-info          (--thread <name> | --thread-id <id>)  (full thread details)"
            echo "  move-thread          --thread <name> --section <name>      (move thread to section)"
            echo ""
            echo "Keep Alive commands:"
            echo "  keep-alive-thread    --thread <name> [--remove]                          (protect all sessions from eviction)"
            echo "  keep-alive-tab       --thread <name> --session <name> [--remove]         (protect single session)"
            echo "  keep-alive-section   --name <name> [--project <name>] [--remove]         (protect all threads in section)"
            echo ""
            echo "Section commands:"
            echo "  list-sections        [--project <name>]"
            echo "  add-section          --name <name> [--color <hex>] [--project <name>]"
            echo "  remove-section       --name <name> [--project <name>]"
            echo "  reorder-section      --name <name> --position <n> [--project <name>]"
            echo "  rename-section       --name <name> --new-name <text> [--color <hex>] [--project <name>]"
            echo "  hide-section         --name <name> [--project <name>]"
            echo "  show-section         --name <name> [--project <name>]"
            ;;
        *)
            die "Unknown command: $cmd. Run 'magent-cli help' for usage."
            ;;
        esac
        """#

        do {
            try script.write(toFile: path, atomically: false, encoding: .utf8)
            chmod(path, 0o755)
            NSLog("[IPC] CLI script installed at %@", path)
        } catch {
            NSLog("[IPC] Failed to write CLI script to %@: %@", path, error.localizedDescription)
        }
        installPersistentLaunchers()
    }

    nonisolated private static func installPersistentLaunchers() {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidateDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
        ]
        let launcherNames = ["magent", "magent-cli", "magent-tmux"]

        for dir in candidateDirs {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
                if dir.hasPrefix(home) {
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    isDir = true
                } else {
                    continue
                }
            }
            guard isDir.boolValue, Self.isWritableDirectory(dir) else { continue }
            for launcherName in launcherNames {
                let launcherPath = (dir as NSString).appendingPathComponent(launcherName)
                installPersistentLauncher(at: launcherPath)
            }
        }
    }

    nonisolated private static func installPersistentLauncher(at path: String) {
        let launcherMarker = "magent-launcher-v1"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.contains(launcherMarker) {
            return
        }

        let script = """
        #!/bin/sh
        # \(launcherMarker)
        exec "\(cliPath)" "$@"
        """
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    nonisolated private static func isWritableDirectory(_ path: String) -> Bool {
        let fm = FileManager.default
        let probe = (path as NSString).appendingPathComponent(".magent-write-probe-\(UUID().uuidString)")
        guard fm.createFile(atPath: probe, contents: Data()) else {
            return false
        }
        try? fm.removeItem(atPath: probe)
        return true
    }
}
