import Cocoa

final class AppCoordinator {

    private var window: NSWindow?
    private let persistence = PersistenceService.shared

    func start() {
        let settings = persistence.loadSettings()

        let splitVC = SplitViewController()

        // Default size: 75% of screen. setFrameAutosaveName restores the previous
        // session's size/position on subsequent launches automatically.
        let screenFrame = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let w = screenFrame.width * 0.75
        let h = screenFrame.height * 0.75

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 800, height: 500)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = splitVC

        // This saves/restores the window frame across launches.
        // On first launch (no saved frame), it uses the contentRect above.
        window.setFrameAutosaveName("MagentMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Add banner overlay above all content
        if let contentView = window.contentView {
            let bannerOverlay = BannerOverlayView()
            bannerOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bannerOverlay)
            NSLayoutConstraint.activate([
                bannerOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
                bannerOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bannerOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                bannerOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
            BannerManager.shared.setContainer(bannerOverlay)
        }

        if !settings.isConfigured {
            presentConfiguration(over: splitVC)
        } else {
            Task {
                await ThreadManager.shared.restoreThreads()
            }
        }
    }

    func presentConfiguration(over viewController: NSViewController) {
        let configVC = ConfigurationViewController()
        configVC.onComplete = { [weak viewController] in
            viewController?.dismiss(nil)
            Task {
                await ThreadManager.shared.restoreThreads()
            }
        }
        viewController.presentAsSheet(configVC)
    }
}
