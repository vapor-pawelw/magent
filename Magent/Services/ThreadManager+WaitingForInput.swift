import Foundation
import MagentCore

// All waiting-for-input detection logic lives in SessionLifecycleService (Phase 4).
extension ThreadManager {

    func checkForWaitingForInput() async {
        await sessionLifecycleService.checkForWaitingForInput()
    }
}
