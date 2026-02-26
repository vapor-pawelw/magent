import Cocoa

final class BannerManager {

    static let shared = BannerManager()

    private var containerView: BannerOverlayView?
    private var currentBanner: BannerView?
    private var dismissTimer: Timer?
    private var topConstraint: NSLayoutConstraint?

    func setContainer(_ view: BannerOverlayView) {
        containerView = view
    }

    func show(
        message: String,
        style: BannerStyle = .info,
        duration: TimeInterval? = 3.0,
        isDismissible: Bool = true,
        actions: [BannerAction] = []
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(config: BannerConfig(
                message: message,
                style: style,
                duration: duration,
                isDismissible: isDismissible,
                actions: actions
            ))
        }
    }

    // MARK: - Private

    private func showOnMain(config: BannerConfig) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Dismiss any existing banner immediately
        if currentBanner != nil {
            removeBannerImmediately()
        }

        guard let container = containerView else { return }

        let banner = BannerView(config: config)
        banner.onDismiss = { [weak self] in
            self?.dismissAnimated()
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
                self?.dismissAnimated()
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
            banner.removeFromSuperview()
            if self?.currentBanner === banner {
                self?.currentBanner = nil
                self?.topConstraint = nil
            }
        })
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
