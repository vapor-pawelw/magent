import Foundation

public enum CreatedTerminalTabPlacement: Equatable, Sendable {
    case alreadyPresent(index: Int)
    case replacePending(index: Int)
    case append
}

public enum CreatedTerminalTabReconciler {
    public static func resolvePlacement(
        createdSessionName: String,
        displaySlots: [String?],
        pendingIndex: Int
    ) -> CreatedTerminalTabPlacement {
        if let existingIndex = displaySlots.firstIndex(where: { $0 == createdSessionName }) {
            return .alreadyPresent(index: existingIndex)
        }

        if pendingIndex >= 0,
           pendingIndex < displaySlots.count,
           let slotValue = displaySlots[pendingIndex],
           slotValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .replacePending(index: pendingIndex)
        }

        return .append
    }
}
