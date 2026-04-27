import Foundation

public enum NewTabSelectionResolver {
    public static func resolveLastSelectedIdentifier(
        currentIdentifier: String?,
        createdSessionIdentifier: String,
        shouldSwitchToCreatedTab: Bool
    ) -> String? {
        guard shouldSwitchToCreatedTab else {
            return currentIdentifier
        }

        let trimmedIdentifier = createdSessionIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else {
            return currentIdentifier
        }

        return trimmedIdentifier
    }
}
