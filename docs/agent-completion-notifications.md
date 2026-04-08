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
- The shared completion-processing path is also used by synthetic Codex completions generated from the session monitor's busy→idle transition, so unread dots, notifications, auto-reorder, and auto-rename stay aligned across completion sources.
- After processing completion events, the shared completion path also triggers auto-rename for threads that haven't been renamed yet (`!didAutoRenameFromFirstPrompt`). This covers threads not currently displayed (no `ThreadDetailViewController`). See `prompt-toc-parser.md` § "Three auto-rename trigger paths" for details.
- A Dock bounce is requested only when a thread transitions from `hasUnreadAgentCompletion == false` to `true`, which avoids repeated bounces for additional unread tabs in the same thread.
- Dock badge updates are centralized in `ThreadManager.updateDockBadge()`.
- The Dock badge uses thread count, not unread session count, so it matches the sidebar's thread-level completion affordance.
- The Dock completion setting is persisted as `AppSettings.showDockBadgeAndBounceForUnreadCompletions`.
- Toggling the setting in Notifications refreshes the Dock badge immediately instead of waiting for the next completion event.

## Completion sources

- **Claude**: completion events are appended to `/tmp/magent-agent-completion-events.log` by the Magent-injected Claude Stop hook. The app consumes them via `TmuxService.consumeAgentCompletionSessions()`.
- **Codex**: completion is synthesized when the session monitor sees a Codex session transition from busy to an idle prompt, as long as the session is not waiting for input and is not rate-limited.

- **Atomic consume**: The consume path uses `mv` (atomic on same filesystem) to move the log to a `.consuming` temp path, then reads and deletes it. This avoids the race condition where `cat file; : > file` could lose events appended between read and truncation.
- **No startup truncation**: the completion log is never truncated pre-emptively. Claude events accumulated while the app was closed are consumed by `ThreadManager` at launch via `consumeAgentCompletionSessions()` → `applyStartupCompletionSessions()`.
- **1-second per-session cooldown**: `recentBellBySession` deduplicates rapid completion signals on the same session (within 1 second). This protects against duplicate Claude hook events and against synthetic Codex completion colliding with any future fallback source.
- **Codex busy→idle fallback**: If a Codex session was previously marked busy and later becomes idle at the Codex prompt without entering waiting-for-input, Magent treats that transition as completion even if no BEL was emitted. This covers Codex turns that finish silently.
- **Legacy rollback switch**: `TmuxService.legacyAgentBellPipeEnabled` re-enables the old tmux `pipe-pane` watcher path if completion regressions appear. Leave it `false` by default; `ensureBellPipes()` will detach any old Magent agent pipes from upgraded sessions while the legacy flag is off.

## Gotchas

- Do not re-expand the Dock badge count to include `waitingForInputSessions`; the Dock badge is intentionally scoped to finished unread work only.
- Do not gate the Dock badge/bounce toggle on macOS notification permission. Dock behavior should remain available even when system notification banners are disabled or denied.
- Keep Dock-side effects routed through the existing completion state. Adding a second unread-tracking path will drift from the sidebar and tab indicators.
- Keep the Codex fallback transition-based, not unconditional idle detection. Re-firing completion on every idle poll would recreate dots and notifications after the user already read the thread.
- The `paneContentShowsEscToInterrupt` regex for the `· esc to interrupt` pattern must **not** use a `$` end-of-line anchor. Claude's status bar now appends additional context after the phrase (e.g. `· esc to interrupt                  7% until auto-compact`), so anchoring to end-of-line causes the busy check to silently miss those lines.
- If you need to roll back quickly, flip `TmuxService.legacyAgentBellPipeEnabled` to `true`. That is the intended one-line revert path for this change.

## What changed in this thread

- Claude completion continues to use the injected Stop hook, but tmux `pipe-pane` bell watchers are now disabled by default.
- Codex completion attention is now synthesized from the session monitor's busy→idle transition instead of a tmux bell pipe.
- The legacy tmux bell-pipe path remains behind `TmuxService.legacyAgentBellPipeEnabled` as a one-line rollback switch.

## Per-Session Tracking

- Completion is tracked per-session: `unreadCompletionSessions` set on the thread. `hasUnreadAgentCompletion` checks `!unreadCompletionSessions.isEmpty`.
- Tab-level green dots react via `magentAgentCompletionDetected` notification. Selecting a tab calls `markSessionCompletionSeen(threadId:sessionName:)` to clear individual sessions.
- Do not reintroduce tmux `pipe-pane` completion watchers by default. The legacy path is retained only behind `TmuxService.legacyAgentBellPipeEnabled`. `ensureBellPipes()` now serves as upgrade cleanup when the legacy flag is off.
