import Foundation
import ShellInfra

/// Caches `tmux capture-pane` output per session with a TTL, and coalesces concurrent
/// requests for the same session so only one subprocess is spawned at a time.
///
/// - Always captures `captureLines` lines (the maximum any caller needs).
/// - Callers requesting fewer lines receive a trimmed slice of the cached content.
/// - Concurrent requests for the same session that arrive while a fetch is in flight
///   all await the same Task and share its result — no duplicate subprocesses.
actor PaneCaptureCache {

    /// Number of lines always fetched. Must be >= the maximum any caller requests.
    static let captureLines = 200

    private let ttl: TimeInterval

    private struct Entry {
        let content: String
        let fetchedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    init(ttl: TimeInterval = 5) {
        self.ttl = ttl
    }

    /// Returns pane content for `sessionName`, using a cached result when available.
    /// `lastLines` controls how many trailing lines are returned from the cache.
    func get(sessionName: String, lastLines: Int) async -> String? {
        let now = Date()

        // Cache hit — serve from stored content, trimmed if needed.
        if let entry = cache[sessionName], now.timeIntervalSince(entry.fetchedAt) < ttl {
            return trimmed(entry.content, to: lastLines)
        }

        // Coalesce with an in-flight fetch for this session.
        if let task = inFlight[sessionName] {
            let result = await task.value
            return result.map { trimmed($0, to: lastLines) }
        }

        // No cache hit and no in-flight — start a fresh fetch.
        let sessionForTask = sessionName
        let task = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 0) // yield before spawning subprocess
            return try? await ShellExecutor.run(
                "tmux capture-pane -p -t \(shellQuote(sessionForTask)) -S -\(PaneCaptureCache.captureLines)"
            )
        }
        inFlight[sessionName] = task

        let result = await task.value

        // Re-acquire actor isolation after the await to update state.
        inFlight.removeValue(forKey: sessionName)
        if let result {
            cache[sessionName] = Entry(content: result, fetchedAt: Date())
        }
        return result.map { trimmed($0, to: lastLines) }
    }

    /// Evicts the cached entry for `sessionName`, forcing the next call to fetch fresh output.
    func invalidate(sessionName: String) {
        cache.removeValue(forKey: sessionName)
    }

    // MARK: - Helpers

    private func trimmed(_ content: String, to lastLines: Int) -> String {
        guard lastLines < PaneCaptureCache.captureLines else { return content }
        let lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > lastLines else { return content }
        return lines.suffix(lastLines).joined(separator: "\n")
    }
}
