# Banner Behavior

## Contract

- Timed banners (`duration != nil`) are always user-dismissible. They must show a top-right `X` and support swipe-to-dismiss in any direction.
- Persistent informational or warning banners (`duration == nil`) should usually be user-dismissible with the same `X` and swipe affordances.
- Persistent in-flight progress banners should usually be non-dismissible unless the same progress state is visible elsewhere in the UI.
- Explicit-action-required banners may also be non-dismissible when we intentionally need the user to respond through banner actions instead of hiding the state.

## Implementation Notes

- `BannerView` owns the shared dismissal affordances. `BannerConfig.allowsUserDismissal` treats timed banners as user-dismissible even if a caller forgets to opt in explicitly.
- Swipe dismissal is attached only when `allowsUserDismissal` is true. The gesture dismisses after a short drag threshold in any direction.
- Call sites that represent long-running progress or forced-action states must pass `isDismissible: false` explicitly so they do not inherit the timed-banner affordances by accident.
- **Hit-testing gotcha**: `BannerOverlayView` sits inside a flipped `NSSplitView` but is itself unflipped. Its `hitTest(_:)` override must convert the incoming point from superview coordinates, then convert again into each child subview's coordinate system while walking subviews front-to-back. If you skip either step, banner buttons can look correct but stop receiving clicks.

## Current Non-Dismissible Progress Examples

- Update installation in `UpdateService.installUpdate(...)`
- Worktree recreation progress in `SplitViewController.handleMissingWorktreeSelection(...)`
- tmux restart/recovery progress in `ThreadManager.restartTmuxAndRecoverSessions()`
- Jira status transition progress in `ThreadListViewController.showJiraTransitionProgressBanner()`

## Current Non-Dismissible Action-Required Examples

- Pending prompt injection — info-style banner on a tab waiting for agent readiness, with "Inject Now" to bypass polling
  It should clear only after the prompt itself is pasted/submitted, or when the flow transitions into the initial-prompt failure banner.
- Initial prompt injection failure — warning-style banner on the affected tab, with "Inject Prompt", "Copy Prompt", and "Already Injected" actions
