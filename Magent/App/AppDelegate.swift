import Cocoa
import GhosttyBridge

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enforce single instance — activate existing and terminate this one
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if let existing = runningInstances.first(where: { $0 != .current }) {
            existing.activate()
            let alert = NSAlert()
            alert.messageText = "Magent is already running"
            alert.informativeText = "Only one instance of Magent can run at a time. The existing window has been brought to front."
            alert.alertStyle = .informational
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        GhosttyAppManager.shared.initialize()
        Task { await TmuxService.shared.applyGlobalSettings() }
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ThreadManager.shared.startSessionMonitor()
    }

    func applicationWillResignActive(_ notification: Notification) {
        ThreadManager.shared.stopSessionMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
