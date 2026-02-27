import Foundation

actor IPCSocketServer {

    static let socketPath = "/tmp/magent.sock"
    private static let cliPath = "/tmp/magent-cli"
    private static let cliVersion = "magent-cli-v3"

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
            return
        }

        let script = """
        #!/bin/sh
        # \(marker)
        # Magent IPC CLI — installed by Magent.app
        # Usage: magent-cli <command> [options]

        SOCKET="${MAGENT_SOCKET:-\(socketPath)}"

        die() { echo "Error: $1" >&2; exit 1; }

        # Escape a value for JSON string embedding
        json_escape() {
            printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g; s/\\t/\\\\t/g'
        }

        json_kv() {
            printf '"%s":"%s"' "$1" "$(json_escape "$2")"
        }

        send_request() {
            printf '%s\\n' "$1" | nc -U "$SOCKET" -w 5 2>/dev/null
        }

        cmd="${1:-}"; shift 2>/dev/null || true

        case "$cmd" in
        create-thread)
            project=""; agent=""; prompt=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --project) project="$2"; shift 2 ;;
                    --agent)   agent="$2"; shift 2 ;;
                    --prompt)  prompt="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$project" ] || die "Usage: magent-cli create-thread --project <name> [--agent claude|codex|custom] [--prompt <text>]"
            json="{$(json_kv command create-thread),$(json_kv project "$project")"
            [ -n "$agent" ] && json="$json,$(json_kv agentType "$agent")"
            [ -n "$prompt" ] && json="$json,$(json_kv prompt "$prompt")"
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
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli archive-thread --thread <name>"
            send_request "{$(json_kv command archive-thread),$(json_kv threadName "$thread")}"
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
            thread=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --thread) thread="$2"; shift 2 ;;
                    *) die "Unknown option: $1" ;;
                esac
            done
            [ -n "$thread" ] || die "Usage: magent-cli list-tabs --thread <name>"
            send_request "{$(json_kv command list-tabs),$(json_kv threadName "$thread")}"
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
                json="$json,\\"tabIndex\\":$tab_index"
            elif [ -n "$session" ]; then
                json="$json,$(json_kv sessionName "$session")"
            else
                die "Specify --index <n> or --session <name>"
            fi
            json="$json}"
            send_request "$json"
            ;;
        ""|help|-h|--help)
            echo "Usage: magent-cli <command> [options]"
            echo ""
            echo "Commands:"
            echo "  create-thread   --project <name> [--agent claude|codex|custom] [--prompt <text>]"
            echo "  list-projects"
            echo "  list-threads    [--project <name>]"
            echo "  send-prompt     --thread <name> --prompt <text>"
            echo "  archive-thread  --thread <name>    (removes worktree, keeps branch)"
            echo "  delete-thread   --thread <name>    (removes worktree and branch)"
            echo "  list-tabs       --thread <name>"
            echo "  create-tab      --thread <name> [--agent claude|codex|custom|terminal] [--prompt <text>]"
            echo "  close-tab       --thread <name> (--index <n> | --session <name>)"
            ;;
        *)
            die "Unknown command: $cmd. Run 'magent-cli help' for usage."
            ;;
        esac
        """

        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }
}
