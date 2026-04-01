import Foundation
import os

private let logger = Logger(subsystem: "com.magent.persistence", category: "BackupService")

/// Manages automatic backups of critical persistence files.
///
/// Two layers of protection:
/// 1. **Rolling `.bak`** — on every save, the previous version is kept as `<name>.bak.json`.
///    Gives instant rollback to the last-known-good state.
/// 2. **Periodic snapshots** — every 30 minutes, critical files are copied into
///    `backups/<ISO-timestamp>/`. Tiered retention keeps snapshots useful over days
///    without unbounded growth.
///
/// Retention policy:
/// - Last 2 hours: every 30-minute snapshot kept
/// - 2–8 hours ago: one snapshot per hour
/// - 8 hours – 3 days ago: one snapshot per day
/// - Older than 3 days: deleted
public final class BackupService {

    public static let shared = BackupService()
    private static let safetySnapshotPrefix = "pre-restore-"

    private let fileManager = FileManager.default
    private var snapshotTimer: Timer?

    /// Files to include in periodic snapshots (basenames).
    private let criticalFiles = PersistenceService.restorableCriticalFileNames

    private var appSupportURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Magent", isDirectory: true)
    }

    private var backupsURL: URL {
        appSupportURL.appendingPathComponent("backups", isDirectory: true)
    }

    // MARK: - Rolling Backup

    /// Copies the current file to `<name>.bak.json` before it's overwritten.
    /// Safe to call even if the file doesn't exist yet.
    public func createRollingBackup(of url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }

        let bakName = url.deletingPathExtension().lastPathComponent + ".bak.json"
        let bakURL = url.deletingLastPathComponent().appendingPathComponent(bakName)

        do {
            if fileManager.fileExists(atPath: bakURL.path) {
                try fileManager.removeItem(at: bakURL)
            }
            try fileManager.copyItem(at: url, to: bakURL)
        } catch {
            logger.error("Rolling backup failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Periodic Snapshots

    /// Starts the periodic snapshot timer (every 30 minutes).
    /// Safe to call multiple times — subsequent calls are no-ops.
    public func startPeriodicSnapshots() {
        guard snapshotTimer == nil else { return }

        // Take an initial snapshot at launch
        createSnapshot()

        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.createSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
        logger.info("Periodic backup snapshots started (every 30 min)")
    }

    public func stopPeriodicSnapshots() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    /// Creates a timestamped snapshot directory and copies all critical files into it.
    /// Returns the number of files copied into the snapshot.
    @discardableResult
    public func createSnapshot() -> Int {
        let timestamp = snapshotDirectoryName(for: Date())
        let snapshotDir = backupsURL.appendingPathComponent(timestamp, isDirectory: true)

        do {
            try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create snapshot directory: \(error.localizedDescription)")
            return 0
        }

        var copiedCount = 0
        for fileName in criticalFiles {
            let sourceURL = appSupportURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

            let destURL = snapshotDir.appendingPathComponent(fileName)
            do {
                try fileManager.copyItem(at: sourceURL, to: destURL)
                copiedCount += 1
            } catch {
                logger.error("Snapshot copy failed for \(fileName): \(error.localizedDescription)")
            }
        }

        if copiedCount > 0 {
            logger.info("Snapshot created: \(timestamp) (\(copiedCount) files)")
        } else {
            // No files to back up — remove empty directory
            try? fileManager.removeItem(at: snapshotDir)
        }

        pruneSnapshots()
        NotificationCenter.default.post(name: .magentBackupSnapshotsDidChange, object: nil)
        return copiedCount
    }

    // MARK: - Pruning

    /// Applies tiered retention to the backups directory.
    ///
    /// - Last 2 hours: keep all (≈ every 30 min)
    /// - 2–8 hours ago: keep one per hour
    /// - 8 hours – 3 days ago: keep one per day
    /// - Older than 3 days: delete
    func pruneSnapshots() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let now = Date()

        // Parse snapshot directories into (url, date) pairs
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var snapshots: [(url: URL, date: Date)] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            if let date = parseSnapshotDirName(entry.lastPathComponent) {
                snapshots.append((url: entry, date: date))
            }
        }

        // Sort newest first
        snapshots.sort { $0.date > $1.date }

        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        let eightHoursAgo = now.addingTimeInterval(-8 * 3600)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 3600)

        var keepURLs = Set<URL>()

        // Tier 1: last 2 hours — keep all
        for s in snapshots where s.date >= twoHoursAgo {
            keepURLs.insert(s.url)
        }

        // Tier 2: 2–8 hours ago — keep one per hour
        let tier2 = snapshots.filter { $0.date < twoHoursAgo && $0.date >= eightHoursAgo }
        keepBestPerBucket(tier2, bucketSize: 3600, into: &keepURLs)

        // Tier 3: 8 hours – 3 days ago — keep one per day
        let tier3 = snapshots.filter { $0.date < eightHoursAgo && $0.date >= threeDaysAgo }
        keepBestPerBucket(tier3, bucketSize: 24 * 3600, into: &keepURLs)

        // Delete anything not kept
        var deletedCount = 0
        for s in snapshots where !keepURLs.contains(s.url) {
            do {
                try fileManager.removeItem(at: s.url)
                deletedCount += 1
            } catch {
                logger.error("Failed to prune snapshot \(s.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            logger.info("Pruned \(deletedCount) old snapshot(s), kept \(keepURLs.count)")
        }
    }

    /// Keeps the newest snapshot per time bucket (e.g. per hour or per day).
    private func keepBestPerBucket(
        _ snapshots: [(url: URL, date: Date)],
        bucketSize: TimeInterval,
        into keepURLs: inout Set<URL>
    ) {
        var buckets: [Int: (url: URL, date: Date)] = [:]
        for s in snapshots {
            let bucket = Int(s.date.timeIntervalSince1970 / bucketSize)
            if let existing = buckets[bucket] {
                // Keep the newest in each bucket
                if s.date > existing.date {
                    buckets[bucket] = s
                }
            } else {
                buckets[bucket] = s
            }
        }
        for entry in buckets.values {
            keepURLs.insert(entry.url)
        }
    }

    // MARK: - Snapshot Listing

    /// A snapshot available for restore.
    public struct Snapshot {
        public let url: URL
        public let date: Date
        public let files: [String]
        public let isSafetySnapshot: Bool
    }

    /// Returns all available snapshots, newest first.
    public func listSnapshots() -> [Snapshot] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: backupsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var snapshots: [Snapshot] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let date = parseSnapshotDirName(entry.lastPathComponent) else {
                continue
            }
            let files = (try? fileManager.contentsOfDirectory(atPath: entry.path)) ?? []
            let snapshotFiles = criticalFiles.filter { files.contains($0) }
            guard !snapshotFiles.isEmpty else { continue }
            snapshots.append(Snapshot(
                url: entry,
                date: date,
                files: snapshotFiles,
                isSafetySnapshot: entry.lastPathComponent.hasPrefix(Self.safetySnapshotPrefix)
            ))
        }

        snapshots.sort { $0.date > $1.date }
        return snapshots
    }

    /// Returns the newest user-facing snapshot.
    public func latestSnapshot() -> Snapshot? {
        let snapshots = listSnapshots()
        return snapshots.first(where: { !$0.isSafetySnapshot })
    }

    // MARK: - Restore

    /// Restores files from a snapshot, replacing the current critical files that are
    /// actually present in that snapshot.
    /// A safety snapshot of the current state is taken first so the user can undo.
    /// Returns the safety snapshot directory name on success.
    @discardableResult
    public func restoreSnapshot(_ snapshot: Snapshot) throws -> String {
        // 1. Take a safety snapshot of current state
        let safetyTimestamp = snapshotDirectoryName(for: Date(), prefix: Self.safetySnapshotPrefix)
        let safetyDir = backupsURL.appendingPathComponent(safetyTimestamp, isDirectory: true)
        try fileManager.createDirectory(at: safetyDir, withIntermediateDirectories: true)

        for fileName in criticalFiles {
            let sourceURL = appSupportURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            try fileManager.copyItem(at: sourceURL, to: safetyDir.appendingPathComponent(fileName))
        }
        logger.info("Safety snapshot created: \(safetyTimestamp)")

        // 2. Replace only the files that are present in the selected snapshot.
        //    Leaving missing files untouched avoids turning a partial snapshot into
        //    destructive data loss during restore.
        let snapshotFiles = Set(snapshot.files)
        for fileName in criticalFiles where snapshotFiles.contains(fileName) {
            let snapshotFileURL = snapshot.url.appendingPathComponent(fileName)
            let targetURL = appSupportURL.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: snapshotFileURL, to: targetURL)
        }

        let missingFiles = criticalFiles.filter { !snapshotFiles.contains($0) }
        if !missingFiles.isEmpty {
            logger.error(
                "Restored partial snapshot \(snapshot.url.lastPathComponent); left current copies in place for: \(missingFiles.joined(separator: ", "))"
            )
        }

        logger.info("Restored from snapshot: \(snapshot.url.lastPathComponent)")
        return safetyTimestamp
    }

    // MARK: - Directory Name Parsing

    /// Parses a snapshot directory name back into a Date.
    /// Directory names use ISO8601 with colons replaced by dashes in the time portion.
    /// Example: `2026-04-01T14-30-00Z` → `2026-04-01T14:30:00Z`
    private func parseSnapshotDirName(_ name: String) -> Date? {
        let normalizedName: String
        if name.hasPrefix(Self.safetySnapshotPrefix) {
            normalizedName = String(name.dropFirst(Self.safetySnapshotPrefix.count))
        } else {
            normalizedName = name
        }

        // Find the 'T' separator — everything after it had colons replaced
        guard let tIndex = normalizedName.firstIndex(of: "T") else { return nil }
        let datePart = normalizedName[normalizedName.startIndex..<tIndex]
        let timePart = normalizedName[normalizedName.index(after: tIndex)...]

        // Restore colons in time part: "14-30-00Z" → "14:30:00Z"
        // Time part dashes are at positions for HH-MM-SS, but date part also has dashes.
        // Since we split at T, the time part dashes are the ones to restore.
        let restoredTime = restoreTimeColons(String(timePart))
        let isoString = "\(datePart)T\(restoredTime)"

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private func snapshotDirectoryName(for date: Date, prefix: String = "") -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return prefix + timestamp
    }

    /// Restores the first two dashes in a time string to colons.
    /// `14-30-00Z` → `14:30:00Z`, `14-30-00+05-00` → `14:30:00+05:00`
    private func restoreTimeColons(_ time: String) -> String {
        var result = ""
        var dashCount = 0
        for char in time {
            if char == "-" && dashCount < 2 {
                result.append(":")
                dashCount += 1
            } else {
                result.append(char)
            }
        }
        return result
    }
}

public extension Notification.Name {
    static let magentBackupSnapshotsDidChange = Notification.Name("magentBackupSnapshotsDidChange")
}
