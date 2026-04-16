# Banner Behavior

## Contract

- Timed banners (`duration != nil`) are always user-dismissible. They must show a top-right `X` and support swipe-to-dismiss in any direction.
- Persistent informational or warning banners (`duration == nil`) should usually be user-dismissible with the same `X` and swipe affordances.
- Persistent in-flight progress banners should usually be non-dismissible unless the same progress state is visible elsewhere in the UI.
- Explicit-action-required banners may also be non-dismissible when we intentionally need the user to respond through banner actions instead of hiding the state.

## Implementation Notes

- `BannerView` owns the shared dismissal affordances. `BannerConfig.allowsUserDismissal` treats timed banners as user-dismissible even if a caller forgets to opt in explicitly.
- Swipe dismissal is attached only when `allowsUserDismissal` is true. The gesture dismisses after a short drag threshold in any direction.
- **Gesture gotcha**: any banner swipe recognizer must set `delaysPrimaryMouseButtonEvents = false`. Leaving the default delay in place can make action buttons and the top-right `X` feel dead because the pan recognizer holds the click while deciding whether a drag is starting.
- **Control-hit gotcha**: the banner swipe recognizer must also refuse to begin when the initial pointer-down lands on an interactive descendant (`NSButton`, details scroller/text view, etc.). Otherwise dismissible banners can still steal clicks from their own actions even with delayed mouse events disabled.
- Call sites that represent long-running progress or forced-action states must pass `isDismissible: false` explicitly so they do not inherit the timed-banner affordances by accident.
- **Hit-testing gotcha**: `BannerOverlayView.hitTest(_:)` receives the point in its superview's coordinate space. Since the overlay fills its parent from origin (0,0), this equals the overlay's own coordinate space. Pass the point **directly** to `subview.hitTest(point)` — do NOT convert into each child's local coordinate space first. `NSView.hitTest` expects the point in the receiver's *superview's* coords (i.e., the overlay's coords); converting via `subview.convert(point, from: self)` produces a double-conversion that shifts the point out of the banner's frame in non-flipped containers (like `terminalContainer`), silently dropping clicks.
- **Transparent-titlebar gotcha**: banner overlay/views/buttons must override `mouseDownCanMoveWindow` to `false`. With Magent's transparent title bar, top-edge banner clicks can otherwise be treated as window-drag gestures even when hit-testing is correct.
- **Global-hosting gotcha**: app-wide top banners must be hosted on the window theme-frame parent above `contentView` when available, not inside `contentView` itself. In transparent-titlebar windows, the titlebar/theme frame can sit above `contentView` in the event path and make a visibly rendered banner untappable unless the overlay is mounted there.
- **Header layout gotcha**: `BannerView`'s `messageLabel` must stay constrained between fixed-size leading/trailing accessory columns with lower horizontal hugging/compression resistance than those accessory containers. The accessory columns also need explicit height/centerY constraints; otherwise the `X`/icon can render outside a zero-height wrapper and stop receiving clicks even though they are visible.
- **Embedded-banner gotcha**: banners shown over a terminal tab should be mounted inside a dedicated `BannerOverlayView` that sits above the terminal content, not added directly to `terminalContainer`. Ghostty and other floating terminal overlays can otherwise retake frontmost position and steal banner clicks.
- **Multi-window routing**: `BannerManager.shared` keeps a weak-ref list of registered overlays (`registerContainer(_:)` / `unregisterContainer(_:)`). `show(...)` picks the overlay whose window is currently key, falling back to main/visible/first. Any new window type that can host user-initiated work (pop-out thread/tab windows, future auxiliary windows) must install its own `BannerOverlayView` and register it, or errors surfaced from that window's flows will be shown in an invisible main window instead.

## Current Non-Dismissible Progress Examples

- Update installation in `UpdateService.installUpdate(...)`
- Worktree recreation progress in `SplitViewController.handleMissingWorktreeSelection(...)`
- tmux restart/recovery progress in `ThreadManager.restartTmuxAndRecoverSessions()`
- Jira status transition progress in `ThreadListViewController.showJiraTransitionProgressBanner()`

## Current Non-Dismissible Action-Required Examples

- Pending prompt injection — info-style banner on a tab waiting for agent readiness, with "Inject Now" to bypass polling
  It should clear only after the prompt itself is pasted/submitted, or when the flow transitions into the initial-prompt failure banner.
- Initial prompt injection failure — warning-style banner on the affected tab, with "Inject Prompt", "Copy Prompt", and "Already Injected" actions
