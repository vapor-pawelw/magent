import AppKit

/// `NSScrollView` subclass that suppresses overlay-scroller reveals that are
/// not driven by direct user interaction with this scroll view.
///
/// The sidebar and changes panel reload frequently in response to background
/// state (session-monitor polling, busy/idle transitions, rate-limit changes,
/// git-state refresh, etc.). Every `reloadData` re-tiles the scroll view and
/// re-issues `reflectScrolledClipView` to preserve scroll position, both of
/// which can flash overlay scrollers in. When the user is focused in another
/// app, seeing scrollers flicker in our background window is visually noisy
/// and unrelated to any intent of theirs.
///
/// Strategy:
/// - Treat scroller visibility as explicit policy: show only for a short window
///   after a local `scrollWheel` event, otherwise hide.
/// - Suppress AppKit reveal paths (`flashScrollers`, `reflectScrolledClipView`)
///   unless that interaction window is active.
/// - This prevents hover/focus/state-churn flashes (including Universal Control
///   pointer transitions) while keeping normal scroll feedback during real input.
final class NonFlashingScrollView: NSScrollView {
    private let interactionWindowSeconds: TimeInterval = 0.8
    private var lastUserScrollAt: Date?
    private var hideWorkItem: DispatchWorkItem?
    private var isApplyingInternalScrollerState = false
    private var preferredHasVerticalScroller = true
    private var preferredHasHorizontalScroller = false

    override var hasVerticalScroller: Bool {
        didSet {
            guard !isApplyingInternalScrollerState else { return }
            preferredHasVerticalScroller = hasVerticalScroller
            applyScrollerVisibilityPolicy()
        }
    }

    override var hasHorizontalScroller: Bool {
        didSet {
            guard !isApplyingInternalScrollerState else { return }
            preferredHasHorizontalScroller = hasHorizontalScroller
            applyScrollerVisibilityPolicy()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        lastUserScrollAt = Date()
        applyScrollerVisibilityPolicy()
        super.scrollWheel(with: event)
        scheduleAutoHide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScrollerVisibilityPolicy()
    }

    override func flashScrollers() {
        guard shouldRevealScrollers else { return }
        super.flashScrollers()
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        // Always reflect clip-view changes so NSScrollView can keep document tiling
        // and geometry in sync during programmatic scroll/restoration paths.
        // Scroller visibility is still controlled by applyScrollerVisibilityPolicy().
        applyScrollerVisibilityPolicy()
    }

    private var shouldRevealScrollers: Bool {
        guard let lastUserScrollAt else { return false }
        return Date().timeIntervalSince(lastUserScrollAt) <= interactionWindowSeconds
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyScrollerVisibilityPolicy()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interactionWindowSeconds, execute: work)
    }

    private func applyScrollerVisibilityPolicy() {
        let shouldShow = shouldRevealScrollers
        setScrollers(
            vertical: preferredHasVerticalScroller && shouldShow,
            horizontal: preferredHasHorizontalScroller && shouldShow
        )
    }

    private func setScrollers(vertical: Bool, horizontal: Bool) {
        isApplyingInternalScrollerState = true
        hasVerticalScroller = vertical
        hasHorizontalScroller = horizontal
        isApplyingInternalScrollerState = false
    }
}
