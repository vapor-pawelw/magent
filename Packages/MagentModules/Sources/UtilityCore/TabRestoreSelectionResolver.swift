import Foundation

public enum TabRestoreSelectionResolver {
    public static func resolveInitialTerminalIndex(
        orderedSessions: [String],
        threadId: UUID,
        defaultsThreadId: UUID?,
        defaultsIdentifier: String?,
        lastSelectedIdentifier: String?,
        magentBusySessions: Set<String>
    ) -> Int {
        let defaultsIndex: Int? = {
            guard defaultsThreadId == threadId, let defaultsIdentifier else { return nil }
            return orderedSessions.firstIndex(of: defaultsIdentifier)
        }()

        let lastSelectedIndex: Int? = {
            guard let lastSelectedIdentifier else { return nil }
            return orderedSessions.firstIndex(of: lastSelectedIdentifier)
        }()

        // During new-tab creation, `lastSelectedIdentifier` can intentionally move
        // ahead of UserDefaults. Prefer it to avoid a transient bounce back.
        if let lastSelectedIdentifier,
           let lastSelectedIndex,
           magentBusySessions.contains(lastSelectedIdentifier) {
            return lastSelectedIndex
        }

        if let defaultsIndex {
            return defaultsIndex
        }

        if let lastSelectedIndex {
            return lastSelectedIndex
        }

        return 0
    }
}
