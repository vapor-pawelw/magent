# Agent Completion Notifications

This doc covers how Magent surfaces unread agent completions outside the main UI.

## User-facing behavior

- The sidebar and tab bar still use the existing green completion dot for unread finished work.
- When the app is not foregrounded and a thread gets its first unread completion, the Dock icon requests informational attention (bounce).
- The Dock badge shows the number of non-archived threads that currently have unread completions.
- Waiting-for-input state does not contribute to the Dock badge.
- Users can disable the Dock bounce and badge behavior in `Settings > Notifications` without disabling completion banners, sounds, or auto-reorder.
- The "Move completed threads to top" toggle appears in both `Settings > Notifications` (Agent Completion card) and `Settings > Threads` (Sidebar card).

## Implementation details

- Completion detection still enters through `ThreadManager.checkForAgentCompletions()`.
- After processing bell events, `checkForAgentCompletions` also triggers auto-rename for threads that haven't been renamed yet (`!didAutoRenameFromFirstPrompt`). This covers threads not currently displayed (no `ThreadDetailViewController`). See `prompt-toc-parser.md` § "Three auto-rename trigger paths" for details.
- A Dock bounce is requested only when a thread transitions from `hasUnreadAgentCompletion == false` to `true`, which avoids repeated bounces for additional unread tabs in the same thread.
- Dock badge updates are centralized in `ThreadManager.updateDockBadge()`.
- The Dock badge uses thread count, not unread session count, so it matches the sidebar's thread-level completion affordance.
- The Dock completion setting is persisted as `AppSettings.showDockBadgeAndBounceForUnreadCompletions`.
- Toggling the setting in Notifications refreshes the Dock badge immediately instead of waiting for the next completion event.

## Bell event consumption

Bell events are written by per-session Perl pipe-pane scripts to `/tmp/magent-agent-completion-events.log`. The app consumes them via `TmuxService.consumeAgentCompletionSessions()`.

- **Atomic consume**: The consume path uses `mv` (atomic on same filesystem) to move the log to a `.consuming` temp path, then reads and deletes it. This avoids the race condition where `cat file; : > file` could lose events appended between read and truncation.
- **No startup truncation**: `configureBellMonitoring()` only `touch`es the event log — it never truncates. Events accumulated while the app was closed are consumed by `ThreadManager` at launch via `consumeAgentCompletionSessions()` → `applyStartupCompletionSessions()`.
- **1-second per-session cooldown**: `recentBellBySession` deduplicates rapid bells on the same session (within 1 second). This is intentional — Claude's Stop hook can also append completion events, so without this cooldown, a single completion could produce duplicate notifications.

## Gotchas

- Do not re-expand the Dock badge count to include `waitingForInputSessions`; the Dock badge is intentionally scoped to finished unread work only.
- Do not gate the Dock badge/bounce toggle on macOS notification permission. Dock behavior should remain available even when system notification banners are disabled or denied.
- Keep Dock-side effects routed through the existing completion state. Adding a second unread-tracking path will drift from the sidebar and tab indicators.
- The `paneContentShowsEscToInterrupt` regex for the `· esc to interrupt` pattern must **not** use a `$` end-of-line anchor. Claude's status bar now appends additional context after the phrase (e.g. `· esc to interrupt                  7% until auto-compact`), so anchoring to end-of-line causes the busy check to silently miss those lines.

## What changed in this thread

- Fixed non-atomic event log consumption: replaced `cat file; : > file` with `mv` + read + delete to prevent race-condition event loss.
- Fixed startup-reset race: `applyGlobalSettings()` no longer truncates the event log before `ThreadManager` can consume accumulated events.
- Removed the now-unused `resetEventLog` parameter from `configureBellMonitoring()`.
