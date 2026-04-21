import Foundation

// MARK: - TabNameAllocator

/// Pure logic for allocating a unique tab display name.
///
/// Pulled out of `ThreadManager+TabManagement` so the suffix-counter bookkeeping
/// can be tested in isolation — historically a source of subtle bugs around tab
/// renames reusing stale suffixes and counters resetting to zero.
enum TabNameAllocator {

    struct Result: Equatable {
        /// The allocated display name to use for the new/renamed tab.
        let displayName: String
        /// When non-nil, the caller must persist this counter for `base`.
        /// `nil` means the counter does not need to change.
        let counterUpdate: CounterUpdate?
    }

    struct CounterUpdate: Equatable {
        let normalizedBase: String
        let suffix: Int
    }

    /// Allocate a unique display name for a new tab.
    ///
    /// - Parameters:
    ///   - requestedName: The user- or code-requested name. Whitespace is trimmed.
    ///     If empty after trimming, defaults to `"Tab"`.
    ///   - usedNames: The set of currently used display names in the thread. Case
    ///     preserved — normalization happens internally via lowercasing.
    ///   - counters: The per-base monotonic suffix counters currently persisted
    ///     on the thread, keyed by `normalizedBase`.
    static func allocate(
        requestedName: String,
        usedNames: [String],
        counters: [String: Int]
    ) -> Result {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmed.isEmpty ? "Tab" : trimmed
        let lowerUsedNames = Set(usedNames.map { $0.lowercased() })

        let (baseName, requestedSuffix) = splitSuffix(rawName)
        let normalizedBase = normalizeBase(baseName)
        let knownCounter = counters[normalizedBase] ?? 0
        let maxExistingSuffix = maxObservedSuffix(for: normalizedBase, usedNames: lowerUsedNames)

        if !lowerUsedNames.contains(rawName.lowercased()) {
            let seededCounter = max(knownCounter, maxExistingSuffix, requestedSuffix ?? 0)
            let update: CounterUpdate? = seededCounter > knownCounter
                ? CounterUpdate(normalizedBase: normalizedBase, suffix: seededCounter)
                : nil
            return Result(displayName: rawName, counterUpdate: update)
        }

        var suffix = max(knownCounter, maxExistingSuffix, requestedSuffix ?? 0) + 1
        var candidate = "\(baseName)-\(suffix)"
        while lowerUsedNames.contains(candidate.lowercased()) {
            suffix += 1
            candidate = "\(baseName)-\(suffix)"
        }

        return Result(
            displayName: candidate,
            counterUpdate: CounterUpdate(normalizedBase: normalizedBase, suffix: suffix)
        )
    }

    // MARK: - Helpers (internal for testing)

    /// Splits `Codex-3` into (`Codex`, 3). Returns `(name, nil)` when the trailing
    /// segment is not a non-negative integer, or when the segment *is* the whole
    /// name (`"-1"` → no base, leave as-is).
    static func splitSuffix(_ name: String) -> (base: String, suffix: Int?) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, let last = parts.last, let parsed = Int(last), parsed >= 0 else {
            return (name, nil)
        }
        let base = parts.dropLast().joined(separator: "-")
        guard !base.isEmpty else { return (name, nil) }
        return (base, parsed)
    }

    static func normalizeBase(_ base: String) -> String {
        base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func maxObservedSuffix(for normalizedBase: String, usedNames: Set<String>) -> Int {
        var maxSuffix = 0
        for lowerName in usedNames {
            let (base, suffix) = splitSuffix(lowerName)
            if normalizeBase(base) != normalizedBase { continue }
            if let suffix {
                maxSuffix = max(maxSuffix, suffix)
            } else {
                maxSuffix = max(maxSuffix, 0)
            }
        }
        return maxSuffix
    }
}
