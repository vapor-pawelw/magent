import Foundation

public enum TabStructureRebuildGate {
    public static func shouldRunSetupTabsAfterStructureChange(
        localAutoSwitchTabCreationsInFlight: Int
    ) -> Bool {
        localAutoSwitchTabCreationsInFlight <= 0
    }
}
