import Cocoa
import Darwin
import GhosttyBridge
import UserNotifications
import MagentCore

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var coordinator: AppCoordinator?
    private var ipcServer: IPCSocketServer?
    private var settingsObserver: NSObjectProtocol?
    private var systemAppearanceObserver: NSObjectProtocol?

    private func isLiveNonZombieProcess(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }

        var info = kinfo_proc()
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let mibCount = u_int(mib.count)
        var size = MemoryLayout<kinfo_proc>.stride

        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            withUnsafeMutablePointer(to: &info) { infoPointer in
                sysctl(
                    mibPointer.baseAddress,
                    mibCount,
                    infoPointer,
                    &size,
                    nil,
                    0
                )
            }
        }

        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else {
            return false
        }

        return info.kp_proc.p_stat != UInt8(SZOMB)
    }

    private var appDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
           !bundleName.isEmpty {
            return bundleName
        }
        return ProcessInfo.processInfo.processName
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install crash diagnostics handler
        NSSetUncaughtExceptionHandler { exception in
            NSLog("[CRASH] Uncaught exception: %@", exception)
            NSLog("[CRASH] Reason: %@", exception.reason ?? "unknown")
            NSLog("[CRASH] Stack: %@", exception.callStackSymbols.joined(separator: "\n"))
        }

        // Enforce single instance — activate existing and terminate this one.
        // This avoids "already running" modal interruptions when a notification
        // tap triggers an app-open attempt while Magent is already running.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        if let existing = runningInstances.first(where: {
            $0.processIdentifier != currentPID
                && !$0.isTerminated
                && isLiveNonZombieProcess($0.processIdentifier)
        }) {
            _ = existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        CrashReportingService.initialize()
        setupMainMenu()
        GhosttyAppManager.shared.initialize()
        applyAppAppearanceAndTerminalPreferences()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .magentSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppAppearanceAndTerminalPreferences()
            }
        }
        systemAppearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemAppearanceChanged()
            }
        }
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        Task { await TmuxService.shared.applyGlobalSettings() }
        ThreadManager.shared.ensureManagedZdotdir()
        coordinator = AppCoordinator()
        coordinator?.start()

        let server = IPCSocketServer()
        self.ipcServer = server
        Task { await server.start() }
        Task { @MainActor in
            await UpdateService.shared.checkForUpdatesOnLaunchIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
            self.systemAppearanceObserver = nil
        }
        let server = ipcServer
        Task { await server?.stop() }

        // Clean up any leftover ephemeral context transfer files
        let worktreePaths = ThreadManager.shared.threads.map(\.worktreePath)
        ContextExporter.cleanupAllContextFiles(worktreePaths: worktreePaths)
        ThreadManager.shared.cleanupManagedZdotdir()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyAppAppearanceAndTerminalPreferences()
        ThreadManager.shared.startSessionMonitor()
        coordinator?.showMainWindow()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        coordinator?.showMainWindow()
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Keep monitor alive in background so completion notifications still fire.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showMainWindow()
        return true
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: .AppStrings.appMenuAbout(appDisplayName)),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: .AppStrings.appMenuSettings), action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: .AppStrings.appMenuQuit(appDisplayName)),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables Cut/Copy/Paste/Select All in text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: .AppStrings.appMenuEdit))
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuUndo), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuRedo), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: .AppStrings.appMenuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func applyAppAppearanceAndTerminalPreferences() {
        let settings = PersistenceService.shared.loadSettings()
        let appAppearance: NSAppearance?

        switch settings.appAppearanceMode {
        case .system:
            appAppearance = nil
        case .light:
            appAppearance = NSAppearance(named: .aqua)
        case .dark:
            appAppearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appAppearance

        let terminalAppearance: GhosttyEmbeddedAppearanceMode
        switch settings.appAppearanceMode {
        case .system:
            terminalAppearance = .system
        case .light:
            terminalAppearance = .light
        case .dark:
            terminalAppearance = .dark
        }

        let mouseWheelBehavior: GhosttyEmbeddedMouseWheelBehavior
        switch settings.terminalMouseWheelBehavior {
        case .magentDefaultScroll:
            mouseWheelBehavior = .magentDefaultScroll
        case .inheritGhosttyGlobal:
            mouseWheelBehavior = .inheritGhosttyGlobal
        case .allowAppsToCapture:
            mouseWheelBehavior = .allowAppsToCapture
        }

        // Apply terminal preferences BEFORE refreshing window appearances so that
        // any viewDidChangeEffectiveAppearance calls triggered by the window refresh
        // see the already-updated embeddedPreferences and resolve the correct color scheme.
        GhosttyAppManager.shared.applyEmbeddedPreferences(
            GhosttyEmbeddedPreferences(
                appearanceMode: terminalAppearance,
                mouseWheelBehavior: mouseWheelBehavior
            )
        )

        refreshWindowAppearances(using: appAppearance)
    }

    private func refreshWindowAppearances(using appearance: NSAppearance?) {
        for window in NSApp.windows {
            window.appearance = appearance
            window.invalidateShadow()
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
        }
    }

    private func handleSystemAppearanceChanged() {
        guard PersistenceService.shared.loadSettings().appAppearanceMode == .system else { return }
        GhosttyAppManager.shared.refreshAppearanceIfNeeded()
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
        coordinator?.showMainWindow()
        if coordinator == nil {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { $0.canBecomeKey && !$0.isMiniaturized })
                ?? NSApp.windows.first
            window?.makeKeyAndOrderFront(nil)
        }

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
