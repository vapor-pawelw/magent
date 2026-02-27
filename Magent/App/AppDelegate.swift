import Cocoa
import GhosttyBridge
import UserNotifications

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

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
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        Task { await TmuxService.shared.applyGlobalSettings() }
        coordinator = AppCoordinator()
        coordinator?.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ThreadManager.shared.startSessionMonitor()
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Keep monitor alive in background so completion notifications still fire.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}
