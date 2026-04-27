import Foundation

public enum TerminalCorruptionHeuristics {
    public static func hasRepeatedTailBlock(in pane: String) -> Bool {
        var lines = pane
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        guard lines.count >= 20 else { return false }

        let maxBlockSize = min(56, lines.count / 2)
        guard maxBlockSize >= 8 else { return false }

        for blockSize in stride(from: maxBlockSize, through: 8, by: -1) {
            let leftStart = lines.count - (blockSize * 2)
            let rightStart = lines.count - blockSize
            guard leftStart >= 0, rightStart > leftStart else { continue }

            let left = Array(lines[leftStart..<rightStart])
            let right = Array(lines[rightStart..<lines.count])
            guard left == right else { continue }

            let meaningful = right.filter { !$0.isEmpty }
            guard meaningful.count >= 6 else { continue }
            guard Set(meaningful).count >= 3 else { continue }

            let promptOnly = meaningful.allSatisfy { line in
                line.hasPrefix("›") || line.hasPrefix("❯")
            }
            guard !promptOnly else { continue }
            return true
        }
        return false
    }
}
