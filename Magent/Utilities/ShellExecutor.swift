import Foundation

enum ShellError: LocalizedError {
    case commandFailed(status: Int32, stderr: String)
    case spawnFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let stderr):
            return "Command failed (exit \(status)): \(stderr)"
        case .spawnFailed(let errno):
            return "Failed to spawn process: \(errno)"
        }
    }
}

enum ShellExecutor {

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Runs a command using /bin/sh -c and returns the result.
    static func run(_ command: String, workingDirectory: String? = nil) async throws -> String {
        let result = await execute(command, workingDirectory: workingDirectory)

        if result.exitCode != 0 {
            throw ShellError.commandFailed(status: result.exitCode, stderr: result.stderr)
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command and returns the full result including exit code.
    static func execute(_ command: String, workingDirectory: String? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = synchronousExecute(command, workingDirectory: workingDirectory)
                continuation.resume(returning: result)
            }
        }
    }

    private static func synchronousExecute(_ command: String, workingDirectory: String?) -> Result {
        // Create pipes for stdout and stderr
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        pipe(&stdoutPipe)
        pipe(&stderrPipe)

        // Set up file actions
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

        // Build the full command with optional cd
        var fullCommand = command
        if let wd = workingDirectory {
            fullCommand = "cd \(shellQuote(wd)) && \(command)"
        }

        // Set up environment with PATH
        let env = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let envCStrings = env.map { strdup($0) } + [nil]
        defer { envCStrings.compactMap { $0 }.forEach { free($0) } }

        // Spawn /bin/sh -c "<command>"
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"),
            strdup("-c"),
            strdup(fullCommand),
            nil,
        ]
        defer { argv.compactMap { $0 }.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, "/bin/sh", &fileActions, nil, argv, envCStrings)

        posix_spawn_file_actions_destroy(&fileActions)

        // Close write ends in parent
        close(stdoutPipe[1])
        close(stderrPipe[1])

        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return Result(stdout: "", stderr: "posix_spawn failed: \(spawnResult)", exitCode: -1)
        }

        // Read stdout and stderr
        let stdoutData = readAll(fd: stdoutPipe[0])
        let stderrData = readAll(fd: stderrPipe[0])
        close(stdoutPipe[0])
        close(stderrPipe[0])

        // Wait for child
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        // Extract exit code: WIFEXITED / WEXITSTATUS macros aren't available in Swift
        let exitCode: Int32
        if (status & 0x7f) == 0 {
            // Normal termination — exit code is in bits 8..15
            exitCode = (status >> 8) & 0xff
        } else {
            exitCode = -1
        }

        return Result(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    private static func readAll(fd: Int32) -> Data {
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(fd, buffer, bufferSize)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
