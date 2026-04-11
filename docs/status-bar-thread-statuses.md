# Status Bar Thread Statuses

This doc covers the aggregate thread-status controls in the bottom status bar.

## User-facing behavior

- The left side of the bottom status bar shows aggregate thread counts for `busy`, `waiting`, `done`, and `rate-limited` when any threads currently match those states.
- When at least one thread is favorited, a dedicated `X favorites` control appears immediately after the session-count control, using a primary-color heart icon.
- Each aggregate status is clickable. Clicking one opens a compact popover that looks like a tooltip and shows up to the 3 most recently added matching threads.
- Clicking a thread row in that popover dismisses it and navigates directly to that thread. When Magent can still identify a tab/session that is currently responsible for that status, navigation also opens that tab (for example the first unread completed tab for `done`, or the first waiting/busy/rate-limited tab for those statuses).
- The popover is ordered so the newest matching thread sits closest to the mouse cursor. Because the popover opens above the bottom status bar, that means the newest row is rendered at the bottom.
- In the `done` popover, each row shows a trailing checkmark button that marks that thread as read without navigating away. The list refreshes immediately to keep showing the newest 3 unread completed threads.
- Marking rows as read from the `done` popover keeps the popover open and refreshes its content in place, so users can clear multiple rows quickly.
- While the `done` popover is open, the status-bar `done` count updates immediately after each mark-as-read action.
- Using the `done` popover footer `Mark All as Read` action updates the status bar immediately too; if that clears all done threads, the popover closes right away.
- The `done` popover also includes a footer button, `Mark All as Read`, below the thread rows.
- Right-clicking the status-bar `done` item opens a context menu with a single action: `Mark All as Read`.
- Clicking `X favorites` opens a favorites popover (same visual style as `done`) listing all favorite threads in chronological favorite order.
- Navigating to a thread from the favorites popover now mirrors the sidebar jump-capsule behavior: if the thread row is offscreen, the sidebar scrolls smoothly to center it and applies the same brief row pulse.
- Favorites popover rows include a trailing remove action (`heart.slash.circle`) that removes that thread from favorites without navigating.
- The favorites popover does not show `Mark All`/`Read` controls.
- When the favorites cap is reached, the favorites popover shows an inline limit hint (`10/10`).
- A session count indicator on the right side shows the number of active tmux sessions (formatted as `live/total` when some are suspended, or just `total` when all are live). Clicking it opens a popover with a breakdown of live, suspended, protected (busy/waiting/shielded/pinned), and total sessions, plus a "Close N idle sessions" button that kills all non-protected live sessions. Clicking the button shows a confirmation alert listing which threads/tabs will be affected (scrollable, grouped by thread). Tab metadata is preserved — sessions are lazily recreated when the user selects the tab.
- The sync label on the right side shows "Synced X ago" with a tooltip explaining what is synced (PR status from GitHub, plus Jira ticket info when any project has Jira sync enabled). When the latest sync fails, that same tooltip also includes the last failure reason, and right-clicking the sync label shows the last failure lines above "Refresh Now".
- The rate-limit label on the right side shows active rate-limit countdowns. Right-clicking it offers "Lift Limit Now" and "Lift + Ignore Current Messages" per agent (Claude/Codex).
- Only the aggregate thread-status items on the left are clickable for navigation.

## Implementation details

- `StatusBarView` owns the aggregate status buttons, the per-status popover, and the ordering state used by the popover rows.
- The popover is capped at 3 rows. Selection routes through the existing `.magentNavigateToThread` notification instead of adding a second navigation path.
- Session targeting is intentionally best-effort and non-persistent. `StatusBarView` resolves the first matching session from the thread's current in-memory state at click time and passes it through `.magentNavigateToThread`; if no matching session still exists, navigation falls back to thread-only selection.
- `done` ordering is persistent because unread completion state already survives relaunch via `MagentThread.unreadCompletionSessions`, and its ordering timestamp comes from persisted `MagentThread.lastAgentCompletionAt`.
- `busy`, `waiting`, and `rate-limited` ordering is in-memory only. Their "added at" timestamps are tracked inside `StatusBarView` for the current app run and reset on relaunch because those statuses themselves are transient.
- Favorites ordering uses persisted `MagentThread.favoritedAt` (fallback `createdAt`) and is not capped to 3 rows like status summaries.
- Favorites row selection posts `.magentNavigateToThread` with `centerInSidebar = true`; `SplitViewController` consumes that hint to suppress immediate `scrollRowToVisible` and call `ThreadListViewController.centerAndPulseThreadRow(byId:)`.
- While a status popover is visible, `StatusBarView` avoids rebuilding the status-button stack (to preserve the popover anchor) and updates existing button counts in place.
- If a read action clears the currently open status entirely (for example, `done` goes to zero after `Mark All as Read`), `StatusBarView` must close that popover and rebuild the status-button stack immediately so stale `done` UI does not linger.

## Gotchas

- Preserve the mixed persistence model: only `done` ordering should survive relaunch. Do not persist `busy` / `waiting` / `rate-limited` tooltip ordering unless those underlying states also become persisted first.
- When choosing the 3 rows to show, sort by newest-added first, take the latest 3, then reverse them for display so the newest row ends up bottom-most near the status-bar anchor.
- Keep the popover scoped to the left-side aggregate status items. The right-side sync/rate-limit controls already use menus and manual actions and should not be converted to the thread-row tooltip behavior.
- Keep favorites as a separate left-side control (not part of the `ThreadStatusSummaryKind` button stack) so opening/refreshing status popovers does not accidentally remove the favorites anchor view.
- Keep sync failure details sourced from the most recent sync runner output rather than inventing independent UI-only error state, so hover text and the sync context menu stay in sync.
- For the `done` popover row-level mark-read button, suppress row navigation when the click lands inside the button hit area. Otherwise the click can both mark as read and navigate, which is surprising and can race popover refresh.
- Keep popover content rows at a fixed width. The popover width is constant; description text may wrap up to two lines, but content must never change the popover width while rows are being marked read.
