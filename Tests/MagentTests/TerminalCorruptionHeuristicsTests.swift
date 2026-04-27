import Foundation
import Testing
import MagentCore

@Suite
struct TerminalCorruptionHeuristicsTests {

    @Test
    func detectsRepeatedTailBlocks() {
        let block = [
            "Reading files...",
            "Applying patch to session",
            "Updated 3 files",
            "Running build",
            "Build succeeded",
            "Next step: tests",
            "Done",
            "› ",
        ]
        let prefix = [
            "Older output line 1",
            "Older output line 2",
            "Older output line 3",
            "Older output line 4",
        ]
        let pane = (prefix + block + block).joined(separator: "\n")

        #expect(TerminalCorruptionHeuristics.hasRepeatedTailBlock(in: pane))
    }

    @Test
    func ignoresPromptOnlyRepeats() {
        let pane = [
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
            "› ",
        ].joined(separator: "\n")

        #expect(!TerminalCorruptionHeuristics.hasRepeatedTailBlock(in: pane))
    }

    @Test
    func ignoresNonRepeatedTail() {
        let pane = [
            "line 1",
            "line 2",
            "line 3",
            "line 4",
            "line 5",
            "line 6",
            "line 7",
            "line 8",
            "line 9",
            "line 10",
            "line 11",
            "line 12",
            "line 13",
            "line 14",
            "line 15",
            "line 16",
            "line 17",
            "line 18",
            "line 19",
            "line 20",
        ].joined(separator: "\n")

        #expect(!TerminalCorruptionHeuristics.hasRepeatedTailBlock(in: pane))
    }
}
