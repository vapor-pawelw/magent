import Cocoa
import Darwin
import GhosttyBridge
import UserNotifications
import MagentCore

@objc(AppDelegate)
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var coordinator: AppCoordinator?
    private var ipcServer: IPCSocketServer?
    private var systemAppearanceObserver: NSObjectProtocol?

    private var knownWorktreePaths: [String] {
        ThreadManager.shared.threads.map(\.worktreePath)
    }

    private var knownWorktreesBasePaths: [String] {
        PersistenceService.shared.loadSettings().projects.map { $0.resolvedWorktreesBasePath() }
    }

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

    private struct ThreadActionContext {
        let thread: MagentThread?
        let presentingWindow: NSWindow?
        let contextThreadId: UUID?
    }

    private func activeThreadActionContext() -> ThreadActionContext {
        let window = NSApp.keyWindow ?? NSApp.mainWindow

        if let threadPopout = window?.windowController as? ThreadPopoutWindowController {
            let thread = ThreadManager.shared.threads.first(where: { $0.id == threadPopout.threadId })
            return ThreadActionContext(
                thread: thread,
                presentingWindow: window,
                contextThreadId: threadPopout.threadId
            )
        }

        if let tabPopout = window?.windowController as? TabPopoutWindowController {
            let thread = ThreadManager.shared.threads.first(where: { $0.id == tabPopout.threadId })
            return ThreadActionContext(
                thread: thread,
                presentingWindow: window,
                contextThreadId: tabPopout.threadId
            )
        }

        let split = coordinator?.mainSplitViewController()
        let thread = split?.selectedThreadForContextRouting()
        return ThreadActionContext(
            thread: thread,
            presentingWindow: window,
            contextThreadId: thread?.id
        )
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
        let runningInstances: [NSRunningApplication]
        if let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty {
            runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        } else {
            runningInstances = []
        }
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
        ContextExporter.cleanupExpiredContextFiles(
            worktreePaths: knownWorktreePaths,
            worktreesBasePaths: knownWorktreesBasePaths
        )
        applyAppAppearanceAndTerminalPreferences()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged(_:)),
            name: .magentSettingsDidChange,
            object: nil
        )
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
        showCurrentVersionChangelogIfNeeded()

        let server = IPCSocketServer()
        self.ipcServer = server
        Task { await server.start() }
        Task { @MainActor in
            await UpdateService.shared.checkForUpdatesOnLaunchIfEnabled()
            UpdateService.shared.startPeriodicUpdateChecks()
        }
        AgentModelsService.shared.refreshOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.persistMainWindowFrame()
        UpdateService.shared.stopPeriodicUpdateChecks()
        NotificationCenter.default.removeObserver(self, name: .magentSettingsDidChange, object: nil)
        if let systemAppearanceObserver {
            DistributedNotificationCenter.default().removeObserver(systemAppearanceObserver)
            self.systemAppearanceObserver = nil
        }
        let server = ipcServer
        Task { await server?.stop() }

        // Clean up any leftover ephemeral context transfer files
        ContextExporter.cleanupAllContextFiles(
            worktreePaths: knownWorktreePaths,
            worktreesBasePaths: knownWorktreesBasePaths
        )
        ThreadManager.shared.cleanupManagedZdotdir()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyAppAppearanceAndTerminalPreferences()
        ThreadManager.shared.startSessionMonitor()
        let hasVisibleAppWindow = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized
        }
        if !hasVisibleAppWindow {
            coordinator?.showMainWindow()
            DispatchQueue.main.async {
                PopoutWindowManager.shared.revealAllWindowsWithoutFocus()
            }
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        coordinator?.refreshMainWindowForScreenChanges()
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Keep monitor alive in background so completion notifications still fire.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PopoutWindowManager.shared.beginApplicationTermination()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showMainWindow()
        return true
    }

    @objc private func handleSettingsChanged(_ notification: Notification) {
        applyAppAppearanceAndTerminalPreferences()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: String(localized: .AppStrings.appMenuAbout(appDisplayName)),
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: .AppStrings.appMenuSettings), action: #selector(openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Changelog…", action: #selector(openChangelog(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: String(localized: .AppStrings.appMenuQuit(appDisplayName)),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Thread menu
        let threadMenuItem = NSMenuItem()
        let threadMenu = NSMenu(title: "Thread")
        threadMenu.addItem(withTitle: "New Thread", action: #selector(requestNewThreadFromActiveContext(_:)), keyEquivalent: "")
        threadMenu.addItem(withTitle: "Fork Thread", action: #selector(requestForkThreadFromActiveContext(_:)), keyEquivalent: "")
        threadMenu.addItem(.separator())
        let aiRenameItem = threadMenu.addItem(withTitle: "AI Rename…", action: #selector(requestAIRenameFromActiveContext(_:)), keyEquivalent: "r")
        aiRenameItem.keyEquivalentModifierMask = [.command, .shift]
        threadMenuItem.submenu = threadMenu
        mainMenu.addItem(threadMenuItem)

        // View menu (sidebar toggle — uses NSSplitViewController.toggleSidebar:
        // so AppKit handles the "Hide Sidebar" / "Show Sidebar" title swap).
        // Shortcut handling lives in SplitViewController.handleKeyEvent so the
        // user can rebind it from Settings; the menu item itself shows no key
        // equivalent, matching how other configurable shortcuts are presented.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            withTitle: "Hide Sidebar",
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: ""
        )
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

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

    private func showCurrentVersionChangelogIfNeeded() {
        let version = ((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return }

        var settings = PersistenceService.shared.loadSettings()
        guard settings.lastShownChangelogVersion != version else { return }
        guard ChangelogWindowController.showCurrentVersionChangelog(version: version) else { return }

        settings.lastShownChangelogVersion = version
        do {
            try PersistenceService.shared.saveSettings(settings)
        } catch {
            NSLog("[AppDelegate] Failed to persist lastShownChangelogVersion: %@", String(describing: error))
        }
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
        // Pass the resolved appearance for system mode so the override config can include
        // correct background/foreground colors when the OS is in light mode.
        GhosttyAppManager.shared.applyEmbeddedPreferences(
            GhosttyEmbeddedPreferences(
                appearanceMode: terminalAppearance,
                mouseWheelBehavior: mouseWheelBehavior
            ),
            effectiveAppearance: appAppearance ?? NSApp.effectiveAppearance
        )

        // Apply tmux mouse settings for the active wheel-scroll behavior.
        // This is idempotent — safe to call at startup and on every settings change.
        let behavior = settings.terminalMouseWheelBehavior
        Task { await TmuxService.shared.applyMouseWheelScrollSettings(behavior: behavior) }

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

    @objc func requestNewThreadFromActiveContext(_ sender: Any?) {
        guard let split = coordinator?.mainSplitViewController() else {
            NSSound.beep()
            return
        }
        let context = activeThreadActionContext()
        split.requestNewThread(contextThread: context.thread, presentingWindow: context.presentingWindow)
    }

    @objc func requestForkThreadFromActiveContext(_ sender: Any?) {
        guard let split = coordinator?.mainSplitViewController() else {
            NSSound.beep()
            return
        }
        let context = activeThreadActionContext()
        split.requestNewThreadFromBranch(contextThread: context.thread, presentingWindow: context.presentingWindow)
    }

    @objc func requestAIRenameFromActiveContext(_ sender: Any?) {
        guard let split = coordinator?.mainSplitViewController() else {
            NSSound.beep()
            return
        }
        let context = activeThreadActionContext()
        split.requestAIRename(contextThread: context.thread, presentingWindow: context.presentingWindow)
    }

    func handleNewTabShortcutFromActiveContext() -> Bool {
        guard let split = coordinator?.mainSplitViewController() else { return false }
        let context = activeThreadActionContext()
        return split.performNewTabShortcut(contextThreadId: context.contextThreadId)
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]

        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let commitHash = Self.loadBundleFile("BUILD_COMMIT")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCommit = commitHash != nil && commitHash != "unknown" && commitHash?.isEmpty == false

        let versionSuffix = hasCommit ? " (\(commitHash ?? "unknown"))" : ""
        options[.version] = "Build \(buildNumber)\(versionSuffix)"

        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func loadBundleFile(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil)
                ?? Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @objc private func openChangelog(_ sender: Any?) {
        ChangelogWindowController.showChangelog()
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
            var info: [String: Any] = [
                "threadId": threadId,
                "revealSidebarIfHidden": true,
            ]
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
