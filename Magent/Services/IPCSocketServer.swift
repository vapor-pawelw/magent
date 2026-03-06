import Foundation

actor IPCSocketServer {

    static let socketPath = "/tmp/magent.sock"
    private static let cliPath = "/tmp/magent-cli"
    private static let cliVersion = "magent-cli-v18"

    private var serverFD: Int32 = -1
    private var isRunning = false

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
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(Self.socketPath)
        NSLog("[IPC] Server stopped")
    }

    // MARK: - Accept Loop

    private func acceptLoop(serverFD: Int32) async {
        while await self.isRunning {
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
                if await self.isRunning {
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

        die() { echo "Error: $1" >&2; exit 1; }

        have_cmd() {
            command -v "$1" >/dev/null 2>&1
        }

        require_jq() {
            have_cmd jq || die "jq is required for this command."
        }

        can_use_fzf() {
            have_cmd fzf || return 1
            [ "${MAGENT_USE_PLAIN_MENU:-0}" != "1" ] || return 1
            [ "${TERM:-}" != "dumb" ] || return 1
            [ -z "${SSH_CONNECTION:-}" ] || [ "${MAGENT_USE_FZF_OVER_SSH:-0}" = "1" ] || return 1
            return 0
        }

        # Escape a value for JSON string embedding
        json_escape() {
            printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
        }

        json_kv() {
            printf '"%s":"%s"' "$1" "$(json_escape "$2")"
        }

        send_request() {
            printf '%s\n' "$1" | nc -U "$SOCKET" -w 5 2>/dev/null
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

        pick_value() {
            picker_prompt="$1"
            picker_tmp=$(mktemp 2>/dev/null || mktemp -t magent-picker)
            cat >"$picker_tmp"

            if [ ! -s "$picker_tmp" ]; then
                rm -f "$picker_tmp"
                return 1
            fi

            picker_choice=""
            if can_use_fzf; then
                picker_selected=$(awk -F '\037' '{
                    label = $2
                    if (NF >= 3 && $3 != "") {
                        label = label "  |  " $3
                    }
                    printf "%s\t%s\n", label, $1
                }' "$picker_tmp" \
                    | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_COMMAND fzf --prompt="$picker_prompt> " --height=40% --layout=reverse --border)
                picker_status=$?
                if [ "$picker_status" -eq 0 ]; then
                    picker_choice=$(printf '%s' "$picker_selected" | awk -F '\t' '{print $NF}')
                fi
            fi

            if [ -z "$picker_choice" ] && ! can_use_fzf; then
                awk -F '\037' '{
                    printf "%3d) %s\n", NR, $2
                    if (NF >= 3 && $3 != "") {
                        printf "     %s\n", $3
                    }
                    printf "\n"
                }' "$picker_tmp" >/dev/tty
                printf '%s> ' "$picker_prompt" >/dev/tty
                IFS= read -r picker_idx </dev/tty || picker_idx=""
                case "$picker_idx" in
                    ''|*[!0-9]*) picker_choice="" ;;
                    *) picker_choice=$(awk -F '\037' -v n="$picker_idx" 'NR == n { print $1 }' "$picker_tmp") ;;
                esac
            fi

            rm -f "$picker_tmp"
            [ -n "$picker_choice" ] || return 1
            printf '%s\n' "$picker_choice"
        }

        attach_tmux_session() {
            attach_session="$1"
            [ -n "$attach_session" ] || die "Missing tmux session name"
            have_cmd tmux || die "tmux is required."
            tmux has-session -t "$attach_session" 2>/dev/null || die "tmux session not found: $attach_session"

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

        pick_thread_or_create() {
            project_name="$1"
            thread_req="{$(json_kv command list-threads),$(json_kv project "$project_name")}"
            thread_resp=$(send_checked_request "$thread_req")
            thread_lines=$(printf '%s' "$thread_resp" | jq -r '
                .threads
                | sort_by((if .isMain then 0 else 1 end), .name)
                | .[]
                | . as $t
                | (if $t.isMain then "main" else (if ($t.taskDescription // "") != "" then $t.taskDescription else $t.name end) end) as $title
                | (($t.name) + " · " + (($t.worktreePath | split("/") | last)) + " · " + ($t.agentType // "terminal")) as $detail
                | "\($t.id)\u001f\($title)\u001f\($detail)"
            ')
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

            tab_lines=$(printf '%s' "$tab_resp" | jq -r '.tabs | sort_by(.index)[] | "\(.sessionName)\u001fTab #\(.index)\u001f\((if .isAgent then (.agentType // "agent") else "terminal" end)) · \(.sessionName)"')
            {
                printf '__back__%s← Back%sReturn to thread list\n' "$SEP" "$SEP"
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
            [ -n "$interactive_project" ] && interactive_fixed_project=1

            while :; do
                if [ -z "$interactive_project" ]; then
                    interactive_project=$(pick_project) || exit 1
                fi

                interactive_pick=$(pick_thread_or_create "$interactive_project") || exit 1

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

                while :; do
                    interactive_session=$(pick_tab_session "$interactive_pick") || exit 1
                    if [ "$interactive_session" = "__back__" ]; then
                        break
                    fi
                    attach_tmux_session "$interactive_session"
                    return
                done
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
                | jq -r '.threads[] | [.id, .projectName, .name, (.agentType // "terminal"), (.taskDescription // ""), .tmuxSession] | @tsv' \
                | while IFS="$(printf '\t')" read -r ls_id ls_project_name ls_name ls_agent ls_desc ls_session; do
                    ls_info_req="{$(json_kv command thread-info),$(json_kv threadId "$ls_id")}"
                    ls_info_resp=$(send_checked_request "$ls_info_req")
                    ls_branch=$(printf '%s' "$ls_info_resp" | jq -r '.thread.status.branchName // "-"')
                    ls_status=$(printf '%s' "$ls_info_resp" | jq -r '
                        .thread.status as $s
                        | [
                            (if $s.isBusy then "busy" else empty end),
                            (if $s.isWaitingForInput then "input" else empty end),
                            (if $s.hasUnreadCompletion then "done" else empty end),
                            (if $s.isDirty then "dirty" else empty end),
                            (if $s.isBlockedByRateLimit then "limited" else empty end)
                        ]
                        | if length == 0 then "-" else join(",") end
                    ')
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
            project=""; agent=""; prompt=""; name=""; desc=""; section=""; base_thread=""; base_branch=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project)     project="$2"; shift 2 ;;
                    --agent)       agent="$2"; shift 2 ;;
                    --prompt)      prompt="$2"; shift 2 ;;
                    --name)        name="$2"; shift 2 ;;
                    --description) desc="$2"; shift 2 ;;
                    --section)     section="$2"; shift 2 ;;
                    --base-thread) base_thread="$2"; shift 2 ;;
                    --base-branch) base_branch="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$project" ] || die "Usage: magent-cli create-thread --project <name> [--agent claude|codex|custom|terminal] [--prompt <text>] [--name <slug>] [--description <text>] [--section <name>] [--base-thread <name> | --base-branch <name>]"
            [ -z "$base_thread" ] || [ -z "$base_branch" ] || die "Use either --base-thread or --base-branch, not both"
            json="{$(json_kv command create-thread),$(json_kv project "$project")"
            [ -n "$agent" ] && json="$json,$(json_kv agentType "$agent")"
            [ -n "$prompt" ] && json="$json,$(json_kv prompt "$prompt")"
            [ -n "$name" ] && json="$json,$(json_kv newName "$name")"
            [ -n "$desc" ] && json="$json,$(json_kv description "$desc")"
            [ -n "$section" ] && json="$json,$(json_kv sectionName "$section")"
            [ -n "$base_thread" ] && json="$json,$(json_kv baseThreadName "$base_thread")"
            [ -n "$base_branch" ] && json="$json,$(json_kv baseBranch "$base_branch")"
            json="$json}"
            send_request "$json"
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
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] && [ -n "$prompt" ] || die "Usage: magent-cli send-prompt --thread <name> --prompt <text>"
            send_request "{$(json_kv command send-prompt),$(json_kv threadName "$thread"),$(json_kv prompt "$prompt")}"
            ;;
        archive-thread)
            thread=""
            force=0
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --force) force=1; shift ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli archive-thread --thread <name> [--force]"
            json="{$(json_kv command archive-thread),$(json_kv threadName "$thread")"
            [ "$force" = "1" ] && json="$json,\"force\":true"
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
            thread=""; agent=""; prompt=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    --agent)  agent="$2"; shift 2 ;;
                    --prompt) prompt="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli create-tab --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]"
            json="{$(json_kv command create-tab),$(json_kv threadName "$thread")"
            [ -n "$agent" ] && json="$json,$(json_kv agentType "$agent")"
            [ -n "$prompt" ] && json="$json,$(json_kv prompt "$prompt")"
            json="$json}"
            send_request "$json"
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
            send_request "{$(json_kv command auto-rename-thread),$(json_kv threadName "$thread"),$(json_kv prompt "$prompt")}"
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
            echo "  create-thread        --project <name> [--agent claude|codex|custom|terminal] [--prompt <text>] [--name <slug>] [--description <text>] [--section <name>] [--base-thread <name> | --base-branch <name>]"
            echo "  list-projects"
            echo "  list-threads         [--project <name>]"
            echo "  send-prompt          --thread <name> --prompt <text>"
            echo "  archive-thread       --thread <name> [--force]  (removes worktree, keeps branch)"
            echo "  delete-thread        --thread <name>    (removes worktree and branch)"
            echo "  list-tabs            (--thread <name> | --thread-id <id>)"
            echo "  create-tab           --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]"
            echo "  close-tab            --thread <name> (--index <n> | --session <name>)"
            echo "  current-thread                                               (returns current thread info)"
            echo "  auto-rename-thread   --thread <name> --prompt <text>       (AI-generated branch + description)"
            echo "  rename-thread        --thread <name> --prompt <text>       (alias for auto-rename-thread)"
            echo "  rename-branch        --thread <name> --name <text>         (exact branch name)"
            echo "  rename-thread-exact  --thread <name> --name <text>         (alias for rename-branch)"
            echo "  set-description      --thread <name> [--description <text> | --clear]"
            echo "  set-thread-icon      --thread <name> --icon <type>         (set thread icon: feature|fix|improvement|refactor|test|other)"
            echo "  thread-info          (--thread <name> | --thread-id <id>)  (full thread details)"
            echo "  move-thread          --thread <name> --section <name>      (move thread to section)"
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

        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
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
