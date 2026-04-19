import Foundation
import MagentCore

// All idle eviction logic lives in SessionLifecycleService (Phase 4).
extension ThreadManager {

    func evictIdleSessionsIfNeeded() async {
        await sessionLifecycleService.evictIdleSessionsIfNeeded()
    }
}
