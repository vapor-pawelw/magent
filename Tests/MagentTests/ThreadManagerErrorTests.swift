import Foundation
import Testing
import MagentCore

@Suite
struct ThreadManagerErrorTests {

    @Test
    func invalidNameUsesStandardMessage() {
        #expect(ThreadManagerError.invalidName.errorDescription == "Invalid name. Name must not be empty or contain slashes.")
    }

    @Test
    func dirtyWorktreeMessageIncludesPathAndCLIForceWarning() {
        let error = ThreadManagerError.dirtyWorktree(worktreePath: "/repo/feature")
        let description = error.errorDescription ?? ""
        #expect(description.contains("/repo/feature"))
        // CLI --force is intentionally refused for dirty worktrees; the message must say so
        // so future changes don't accidentally relax the contract documented in AGENTS.md.
        #expect(description.contains("CLI --force does not bypass dirty-worktree safety"))
    }

    @Test
    func nameGenerationFailedAppendsDiagnosticWhenProvided() {
        let withDiagnostic = ThreadManagerError.nameGenerationFailed(diagnostic: "claude exited 1")
        #expect(withDiagnostic.errorDescription == "Could not generate a thread name. claude exited 1")
    }

    @Test
    func nameGenerationFailedFallsBackToGenericAdviceWhenDiagnosticIsNil() {
        let withoutDiagnostic = ThreadManagerError.nameGenerationFailed(diagnostic: nil)
        let description = withoutDiagnostic.errorDescription ?? ""
        #expect(description.hasPrefix("Could not generate a thread name."))
        #expect(description.contains("Claude or Codex"))
    }

    @Test
    func worktreePathConflictListsAllConflictingNames() {
        let error = ThreadManagerError.worktreePathConflict(["alpha", "beta", "gamma"])
        let description = error.errorDescription ?? ""
        #expect(description.contains("alpha, beta, gamma"))
    }

    @Test
    func localSyncAgenticOperationCasesAreDistinct() {
        let a: LocalSyncAgenticOperation = .syncSourceToDestination
        let b: LocalSyncAgenticOperation = .reconcileBothWays
        #expect(a != b)
    }
}

extension LocalSyncAgenticOperation: Equatable {
    public static func == (lhs: LocalSyncAgenticOperation, rhs: LocalSyncAgenticOperation) -> Bool {
        switch (lhs, rhs) {
        case (.syncSourceToDestination, .syncSourceToDestination),
             (.reconcileBothWays, .reconcileBothWays):
            return true
        default:
            return false
        }
    }
}
