import Foundation

// MARK: - Schema Versioning Contract
//
// Every critical persistence file (threads.json, settings.json) is wrapped in a
// VersionedEnvelope: {"schemaVersion": N, "data": <payload>}
//
// This enables:
//   1. DETECTION of incompatible files written by a newer app version
//   2. MIGRATION of older files to the current schema
//   3. USER NOTIFICATION when files cannot be loaded
//
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// WHEN TO BUMP A SCHEMA VERSION
//
// Bump the version constant in SchemaVersion AND register a migration closure
// in PersistenceService when you make a BREAKING change — one that would cause
// the PREVIOUS app version's decoder to fail on the new JSON.
//
// Changes that REQUIRE a version bump + migration:
//   - Renaming or removing an existing JSON key
//   - Changing a field's type (e.g. Bool -> String, [String] -> Set<String>)
//   - Restructuring nested objects (e.g. flattening or nesting)
//
// Changes that do NOT require a version bump:
//   - Adding a new optional field with a decodeIfPresent default
//   - Adding a field that is only encoded when non-default
//
// HOW TO ADD A MIGRATION
//
// 1. Bump the version constant (e.g. SchemaVersion.threads: 1 -> 2)
// 2. Add a migration closure in PersistenceService.threadsMigrations (or
//    settingsMigrations) that transforms the JSON payload (Any from
//    JSONSerialization) from version N-1 to N.
//    Example:
//      threadsMigrations[1] = { payload in
//          // payload is the deserialized "data" field (e.g. [[String: Any]])
//          guard var threads = payload as? [[String: Any]] else { return payload }
//          for i in threads.indices {
//              threads[i]["newKey"] = threads[i].removeValue(forKey: "oldKey")
//          }
//          return threads
//      }
// 3. Test: place an old-format file on disk, launch, verify migration + load.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Current schema versions for critical persistence files.
/// See the contract above for when and how to bump these.
public enum SchemaVersion {
    /// Schema version for threads.json (array of MagentThread).
    public static let threads: Int = 1
    /// Schema version for settings.json (AppSettings).
    public static let settings: Int = 1
}

/// Versioned envelope wrapping any Codable payload on disk.
/// Files are stored as: {"schemaVersion": N, "data": <payload>}
public struct VersionedEnvelope<T: Codable>: Codable {
    public var schemaVersion: Int
    public var data: T

    public init(schemaVersion: Int, data: T) {
        self.schemaVersion = schemaVersion
        self.data = data
    }
}

/// Describes a persistence file that failed to load.
public struct PersistenceLoadFailure: Sendable {
    public let fileName: String
    public let filePath: URL
    public let reason: FailureReason

    public enum FailureReason: Sendable {
        /// File exists but could not be decoded into the expected Swift type.
        case decodeFailed(String)
        /// File was written by a newer app version with a higher schema version.
        case incompatibleVersion(fileVersion: Int, appVersion: Int)
    }

    public var localizedDescription: String {
        switch reason {
        case .decodeFailed(let detail):
            return "Could not decode \(fileName): \(detail)"
        case .incompatibleVersion(let fileVersion, let appVersion):
            return "\(fileName) uses schema v\(fileVersion), but this app only supports up to v\(appVersion)"
        }
    }
}

/// Outcome of loading a critical persistence file.
public enum LoadOutcome<T> {
    /// Successfully loaded and decoded.
    case loaded(T)
    /// File does not exist on disk (first launch or manually deleted). Use defaults.
    case fileNotFound
    /// File exists but could not be decoded or is incompatible.
    case decodeFailed(PersistenceLoadFailure)
}

/// Thrown when a save is attempted on a write-blocked file (pending user decision after load failure).
public struct PersistenceWriteBlockedError: Error, LocalizedError {
    public let fileName: String
    public var errorDescription: String? {
        "Writes blocked for \(fileName) — pending user decision after load failure"
    }
}

/// Migration closures keyed by source version number.
/// Each closure transforms the raw JSON payload (Any from JSONSerialization) to the next version.
public typealias SchemaMigrations = [Int: (Any) throws -> Any]
