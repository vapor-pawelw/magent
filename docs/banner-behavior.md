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

## Current Non-Dismissible Progress Examples

- Update installation in `UpdateService.installUpdate(...)`
- Worktree recreation progress in `SplitViewController.handleMissingWorktreeSelection(...)`
- tmux restart/recovery progress in `ThreadManager.restartTmuxAndRecoverSessions()`
- Jira status transition progress in `ThreadListViewController.showJiraTransitionProgressBanner()`
