import Cocoa
import MagentCore

final class BannerManager {

    static let shared = BannerManager()

    private struct ContainerRef {
        weak var view: BannerOverlayView?
    }

    private var containers: [ContainerRef] = []
    private var currentBanner: BannerView?
    private var dismissTimer: Timer?
    private var topConstraint: NSLayoutConstraint?

    func registerContainer(_ view: BannerOverlayView) {
        pruneContainers()
        if !containers.contains(where: { $0.view === view }) {
            containers.append(ContainerRef(view: view))
        }
    }

    func unregisterContainer(_ view: BannerOverlayView) {
        containers.removeAll { $0.view === view || $0.view == nil }
    }

    /// Legacy API retained for callers that installed the first (main-window) container.
    /// New callers should use `registerContainer` / `unregisterContainer`.
    func setContainer(_ view: BannerOverlayView) {
        registerContainer(view)
    }

    private func pruneContainers() {
        containers.removeAll { $0.view == nil }
    }

    /// Pick the best container to show a banner in. Prefer the one whose window
    /// is currently key (so banners appear on the popout the user is looking at);
    /// fall back to any main/visible window; finally fall back to the first.
    private func preferredContainer() -> BannerOverlayView? {
        pruneContainers()
        let live = containers.compactMap { $0.view }
        if let keyMatch = live.first(where: { $0.window?.isKeyWindow == true }) {
            return keyMatch
        }
        if let mainMatch = live.first(where: { $0.window?.isMainWindow == true }) {
            return mainMatch
        }
        if let visible = live.first(where: { $0.window?.isVisible == true }) {
            return visible
        }
        return live.first
    }

    func show(
        message: String,
        style: BannerStyle = .info,
        duration: TimeInterval? = 3.0,
        isDismissible: Bool = true,
        showsSpinner: Bool = false,
        actions: [BannerAction] = [],
        details: String? = nil,
        detailsCollapsedTitle: String? = nil,
        detailsExpandedTitle: String? = nil
    ) {
        showOnMain(config: BannerConfig(
            message: message,
            style: style,
            duration: duration,
            isDismissible: isDismissible,
            showsSpinner: showsSpinner,
            actions: actions,
            details: details,
            detailsCollapsedTitle: detailsCollapsedTitle,
            detailsExpandedTitle: detailsExpandedTitle
        ))
    }

    func show(
        attributedMessage: NSAttributedString,
        style: BannerStyle = .info,
        duration: TimeInterval? = 3.0,
        isDismissible: Bool = true,
        showsSpinner: Bool = false,
        actions: [BannerAction] = [],
        details: String? = nil,
        detailsCollapsedTitle: String? = nil,
        detailsExpandedTitle: String? = nil
    ) {
        showOnMain(config: BannerConfig(
            attributedMessage: attributedMessage,
            style: style,
            duration: duration,
            isDismissible: isDismissible,
            showsSpinner: showsSpinner,
            actions: actions,
            details: details,
            detailsCollapsedTitle: detailsCollapsedTitle,
            detailsExpandedTitle: detailsExpandedTitle
        ))
    }

    func dismissCurrent() {
        dismissAnimated()
    }

    // MARK: - Private

    private func showOnMain(config: BannerConfig) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Dismiss any existing banner immediately
        if currentBanner != nil {
            removeBannerImmediately()
        }

        guard let container = preferredContainer() else { return }

        let banner = BannerView(config: config)
        banner.onDismiss = { [weak self] in
            self?.dismissAnimated()
        }
        banner.onUserInteraction = { [weak self] in
            self?.resetDismissTimer(duration: config.duration)
        }

        container.addSubview(banner)

        let top = banner.topAnchor.constraint(equalTo: container.topAnchor, constant: -50)
        topConstraint = top

        NSLayoutConstraint.activate([
            top,
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])

        container.layoutSubtreeIfNeeded()
        currentBanner = banner

        // Animate slide down
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            top.animator().constant = 8
        }

        // Auto-dismiss timer
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let duration = config.duration {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.dismissAnimated()
                }
            }
        }
    }

    private func dismissAnimated() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let banner = currentBanner else { return }

        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            banner.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                banner.removeFromSuperview()
                if self?.currentBanner === banner {
                    self?.currentBanner = nil
                    self?.topConstraint = nil
                }
            }
        })
    }

    private func resetDismissTimer(duration: TimeInterval?) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let duration else { return }
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissAnimated()
            }
        }
    }

    private func removeBannerImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissTimer?.invalidate()
        dismissTimer = nil
        currentBanner?.removeFromSuperview()
        currentBanner = nil
        topConstraint = nil
    }
}
