import Cocoa
import GhosttyBridge
import UserNotifications

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var coordinator: AppCoordinator?
    private var ipcServer: IPCSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install crash diagnostics handler
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[CRASH] Uncaught exception: %@", exception)
            NSLog("[CRASH] Reason: %@", exception.reason ?? "unknown")
            NSLog("[CRASH] Stack: %@", exception.callStackSymbols.joined(separator: "\n"))
        }

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

        CrashReportingService.initialize()
        setupMainMenu()
        GhosttyAppManager.shared.initialize()
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        Task { await TmuxService.shared.applyGlobalSettings() }
        coordinator = AppCoordinator()
        coordinator?.start()

        let server = IPCSocketServer()
        self.ipcServer = server
        Task { await server.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let server = ipcServer
        Task { await server?.stop() }

        // Clean up any leftover ephemeral context transfer files
        let worktreePaths = ThreadManager.shared.threads.map(\.worktreePath)
        ContextExporter.cleanupAllContextFiles(worktreePaths: worktreePaths)
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

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Magent", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Magent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cut/Copy/Paste/Select All in text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings(_ sender: Any?) {
        NotificationCenter.default.post(name: .magentOpenSettings, object: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let settings = PersistenceService.shared.loadSettings()
        var options: UNNotificationPresentationOptions = []
        if settings.showSystemBanners {
            options.formUnion([.banner, .list])
        }
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Bring existing window to front
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)

        // Navigate to the thread/tab that triggered this notification
        if let threadIdString = userInfo["threadId"] as? String,
           let threadId = UUID(uuidString: threadIdString) {
            var info: [String: Any] = ["threadId": threadId]
            if let sessionName = userInfo["sessionName"] as? String {
                info["sessionName"] = sessionName
            }
            NotificationCenter.default.post(
                name: .magentNavigateToThread,
                object: nil,
                userInfo: info
            )
        }

        completionHandler()
    }
}
