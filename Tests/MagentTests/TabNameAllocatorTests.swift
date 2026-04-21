import Foundation
import Testing

@Suite
struct TabNameAllocatorTests {

    // MARK: - allocate: no conflict

    @Test
    func requestedNameIsReturnedAsIsWhenNoConflict() {
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Terminal"],
            counters: [:]
        )
        #expect(result.displayName == "Codex")
        #expect(result.counterUpdate == nil)
    }

    @Test
    func emptyRequestedNameFallsBackToTab() {
        let result = TabNameAllocator.allocate(
            requestedName: "   ",
            usedNames: [],
            counters: [:]
        )
        #expect(result.displayName == "Tab")
    }

    @Test
    func requestedNameIsTrimmedBeforeUse() {
        let result = TabNameAllocator.allocate(
            requestedName: "  Claude  ",
            usedNames: [],
            counters: [:]
        )
        #expect(result.displayName == "Claude")
    }

    // MARK: - allocate: conflict requires suffixing

    @Test
    func conflictAppendsFirstAvailableSuffix() {
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Codex"],
            counters: [:]
        )
        #expect(result.displayName == "Codex-1")
        #expect(result.counterUpdate == TabNameAllocator.CounterUpdate(normalizedBase: "codex", suffix: 1))
    }

    @Test
    func conflictIsCaseInsensitive() {
        let result = TabNameAllocator.allocate(
            requestedName: "codex",
            usedNames: ["CODEX"],
            counters: [:]
        )
        #expect(result.displayName == "codex-1")
    }

    @Test
    func conflictBumpsPastAllExistingSuffixes() {
        // "Codex" and "Codex-2" already used — first free slot is 3, not 2.
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Codex", "Codex-2"],
            counters: [:]
        )
        #expect(result.displayName == "Codex-3")
        #expect(result.counterUpdate?.suffix == 3)
    }

    @Test
    func conflictRespectsMonotonicCounterEvenWhenEarlierSuffixesAreFree() {
        // Counter is 5 (remembered from a tab that was renamed away). Even though
        // "Codex-2" is free, the counter must not regress — next allocation is 6.
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Codex"],
            counters: ["codex": 5]
        )
        #expect(result.displayName == "Codex-6")
        #expect(result.counterUpdate?.suffix == 6)
    }

    @Test
    func uniqueNameSeedsCounterFromMaxObservedSuffix() {
        // No conflict on "Codex" itself, but "Codex-4" exists, so the counter for
        // "codex" must advance to 4 so the next conflict allocates -5, not -2.
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Codex-4"],
            counters: [:]
        )
        #expect(result.displayName == "Codex")
        #expect(result.counterUpdate == TabNameAllocator.CounterUpdate(normalizedBase: "codex", suffix: 4))
    }

    @Test
    func uniqueNameDoesNotRegressAnExistingHigherCounter() {
        let result = TabNameAllocator.allocate(
            requestedName: "Codex",
            usedNames: ["Codex-2"],
            counters: ["codex": 10]
        )
        #expect(result.displayName == "Codex")
        // Counter stays at 10; no update needed (seededCounter = max(10, 2, 0) = 10).
        #expect(result.counterUpdate == nil)
    }

    @Test
    func requestedNameWithSuffixSeedsCounterToThatSuffix() {
        // User requested "Codex-7" and it's free — counter advances to 7 so
        // the next conflicting allocation starts from -8.
        let result = TabNameAllocator.allocate(
            requestedName: "Codex-7",
            usedNames: [],
            counters: [:]
        )
        #expect(result.displayName == "Codex-7")
        #expect(result.counterUpdate == TabNameAllocator.CounterUpdate(normalizedBase: "codex", suffix: 7))
    }

    // MARK: - Multi-word base names

    @Test
    func multiWordBaseNamesPreserveHyphensInBase() {
        // "Claude-Sonnet" has no trailing integer, so it's the whole base.
        // On conflict the first suffix is -1.
        let result = TabNameAllocator.allocate(
            requestedName: "Claude-Sonnet",
            usedNames: ["Claude-Sonnet"],
            counters: [:]
        )
        #expect(result.displayName == "Claude-Sonnet-1")
        #expect(result.counterUpdate?.normalizedBase == "claude-sonnet")
    }

    // MARK: - splitSuffix edge cases

    @Test
    func splitSuffixExtractsTrailingInteger() {
        let (base, suffix) = TabNameAllocator.splitSuffix("Codex-7")
        #expect(base == "Codex")
        #expect(suffix == 7)
    }

    @Test
    func splitSuffixReturnsNilWhenTrailingIsNotAnInteger() {
        let (base, suffix) = TabNameAllocator.splitSuffix("Codex-alpha")
        #expect(base == "Codex-alpha")
        #expect(suffix == nil)
    }

    @Test
    func splitSuffixReturnsNilForNameWithNoHyphen() {
        let (base, suffix) = TabNameAllocator.splitSuffix("Codex")
        #expect(base == "Codex")
        #expect(suffix == nil)
    }

    @Test
    func splitSuffixTreatsEmptyBaseAsNoSuffix() {
        // "-5" should not be treated as base="" suffix=5 — that'd break when used
        // as a counter key.
        let (base, suffix) = TabNameAllocator.splitSuffix("-5")
        #expect(base == "-5")
        #expect(suffix == nil)
    }

    @Test
    func splitSuffixSplitsOnLastHyphenForDoubleHyphenNames() {
        // "Codex--3" splits into ["Codex", "", "3"]; the last segment is "3"
        // (non-negative), so base becomes "Codex-" and suffix is 3. This is the
        // intentional "last hyphen" split behavior, not a negative-value case.
        let (base, suffix) = TabNameAllocator.splitSuffix("Codex--3")
        #expect(base == "Codex-")
        #expect(suffix == 3)
    }

    @Test
    func splitSuffixHandlesMultipleHyphensInBase() {
        let (base, suffix) = TabNameAllocator.splitSuffix("My-Cool-Tab-12")
        #expect(base == "My-Cool-Tab")
        #expect(suffix == 12)
    }
}
