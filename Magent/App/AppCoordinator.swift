import Cocoa

final class AppCoordinator {

    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("MagentMainWindow")
    private static let offScreenRecoveryDelay: TimeInterval = 1.0

    private var window: NSWindow?
    private let persistence = PersistenceService.shared
    private var pendingOffScreenRecovery: DispatchWorkItem?

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
        let restoredFrame = window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        if !restoredFrame {
            window.center()
        }
        ensureWindowIsVisibleOnCurrentScreens(window)
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
                ThreadManager.shared.startSessionMonitor()

                // Warn about projects with invalid paths
                let invalidProjects = settings.projects.filter { !$0.isValid }
                if !invalidProjects.isEmpty {
                    await MainActor.run {
                        let names = invalidProjects.map(\.name).joined(separator: ", ")
                        BannerManager.shared.show(
                            message: String(localized: .AppStrings.projectInvalidPathsWarning(names)),
                            style: .warning,
                            isDismissible: true,
                            actions: [BannerAction(title: String(localized: .CommonStrings.commonSettings)) {
                                NotificationCenter.default.post(name: .magentOpenSettings, object: nil)
                            }]
                        )
                    }
                }
            }
        }
    }

    func showMainWindow() {
        guard let window else { return }
        ensureWindowIsVisibleOnCurrentScreens(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func presentConfiguration(over viewController: NSViewController) {
        let configVC = ConfigurationViewController()
        configVC.onComplete = {
            Task {
                await ThreadManager.shared.restoreThreads()
                ThreadManager.shared.startSessionMonitor()
            }
        }
        viewController.presentAsSheet(configVC)
    }

    private func ensureWindowIsVisibleOnCurrentScreens(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let currentFrame = window.frame
        if !isCompletelyOffScreen(currentFrame, visibleFrames: visibleFrames) {
            pendingOffScreenRecovery?.cancel()
            pendingOffScreenRecovery = nil
            return
        }

        // Display topology can still be settling right after launch/activation.
        // Re-check after a short delay before moving the window.
        pendingOffScreenRecovery?.cancel()
        let recoveryWorkItem = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.recoverOffScreenWindowIfNeeded(window)
        }
        pendingOffScreenRecovery = recoveryWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.offScreenRecoveryDelay, execute: recoveryWorkItem)
    }

    private func recoverOffScreenWindowIfNeeded(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let currentFrame = window.frame
        guard isCompletelyOffScreen(currentFrame, visibleFrames: visibleFrames) else { return }

        let targetVisibleFrame = preferredVisibleFrame(for: currentFrame, visibleFrames: visibleFrames)
        var adjustedFrame = currentFrame
        adjustedFrame.size.width = min(max(adjustedFrame.size.width, window.minSize.width), targetVisibleFrame.width)
        adjustedFrame.size.height = min(max(adjustedFrame.size.height, window.minSize.height), targetVisibleFrame.height)
        adjustedFrame.origin.x = clamp(
            adjustedFrame.origin.x,
            min: targetVisibleFrame.minX,
            max: targetVisibleFrame.maxX - adjustedFrame.width
        )
        adjustedFrame.origin.y = clamp(
            adjustedFrame.origin.y,
            min: targetVisibleFrame.minY,
            max: targetVisibleFrame.maxY - adjustedFrame.height
        )

        window.setFrame(adjustedFrame, display: true)
    }

    private func isCompletelyOffScreen(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
        !visibleFrames.contains {
            let intersection = frame.intersection($0)
            return !intersection.isNull && intersection.area > 0
        }
    }

    private func preferredVisibleFrame(for frame: NSRect, visibleFrames: [NSRect]) -> NSRect {
        if let containingFrame = visibleFrames.first(where: { $0.contains(frame.center) }) {
            return containingFrame
        }

        let bestIntersection = visibleFrames.max {
            frame.intersection($0).area < frame.intersection($1).area
        }
        if let bestIntersection, frame.intersection(bestIntersection).area > 0 {
            return bestIntersection
        }

        return NSScreen.main?.visibleFrame ?? visibleFrames[0]
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else { return minValue }
        return Swift.max(minValue, Swift.min(value, maxValue))
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
