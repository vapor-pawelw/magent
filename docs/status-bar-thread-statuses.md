# Status Bar Thread Statuses

This doc covers the aggregate thread-status controls in the bottom status bar.

## User-facing behavior

- The left side of the bottom status bar shows aggregate thread counts for `busy`, `waiting`, `done`, and `rate-limited` when any threads currently match those states.
- Each aggregate status is clickable. Clicking one opens a compact popover that looks like a tooltip and shows up to the 3 most recently added matching threads.
- Clicking a thread row in that popover dismisses it and navigates directly to that thread. When Magent can still identify a tab/session that is currently responsible for that status, navigation also opens that tab (for example the first unread completed tab for `done`, or the first waiting/busy/rate-limited tab for those statuses).
- The popover is ordered so the newest matching thread sits closest to the mouse cursor. Because the popover opens above the bottom status bar, that means the newest row is rendered at the bottom.
- The sync label on the right side shows "Synced X ago" with a tooltip explaining what is synced (PR status from GitHub, plus Jira ticket info when any project has Jira sync enabled). Right-clicking the sync label offers "Refresh Now".
- The rate-limit label on the right side shows active rate-limit countdowns. Right-clicking it offers "Lift Limit Now" and "Lift + Ignore Current Messages" per agent (Claude/Codex).
- Only the aggregate thread-status items on the left are clickable for navigation.

## Implementation details

- `StatusBarView` owns the aggregate status buttons, the per-status popover, and the ordering state used by the popover rows.
- The popover is capped at 3 rows. Selection routes through the existing `.magentNavigateToThread` notification instead of adding a second navigation path.
- Session targeting is intentionally best-effort and non-persistent. `StatusBarView` resolves the first matching session from the thread's current in-memory state at click time and passes it through `.magentNavigateToThread`; if no matching session still exists, navigation falls back to thread-only selection.
- `done` ordering is persistent because unread completion state already survives relaunch via `MagentThread.unreadCompletionSessions`, and its ordering timestamp comes from persisted `MagentThread.lastAgentCompletionAt`.
- `busy`, `waiting`, and `rate-limited` ordering is in-memory only. Their "added at" timestamps are tracked inside `StatusBarView` for the current app run and reset on relaunch because those statuses themselves are transient.

## Gotchas

- Preserve the mixed persistence model: only `done` ordering should survive relaunch. Do not persist `busy` / `waiting` / `rate-limited` tooltip ordering unless those underlying states also become persisted first.
- When choosing the 3 rows to show, sort by newest-added first, take the latest 3, then reverse them for display so the newest row ends up bottom-most near the status-bar anchor.
- Keep the popover scoped to the left-side aggregate status items. The right-side sync/rate-limit controls already use menus and manual actions and should not be converted to the thread-row tooltip behavior.
