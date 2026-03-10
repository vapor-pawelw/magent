# Archive Restore Banner

## User-facing behavior

- Archiving a non-main thread now shows a 5-second in-app banner instead of relying on archive-entry-point-specific banners.
- The banner includes the archived thread's name, task description, project, branch, base branch, Jira key, tab count, worktree path, and any archive warning text.
- The same banner appears whether archive was triggered from the UI or via `magent-cli archive-thread`.
- The banner exposes a `Restore` action that recreates the archived worktree, returns the thread to the sidebar, and navigates back to it.
- `Settings > Threads` also shows up to 10 recently archived threads with inline `Restore` buttons, so the same restore flow stays available after the archive banner expires.

## Implementation notes

- `ThreadManager.archiveThread(...)` owns the archive banner. Callers should not show a second success or warning banner for completed archives, because that replaces the shared archive banner and breaks CLI/UI parity.
- Archive now clears persisted session-specific state (`tmuxSessionNames`, agent-session maps, pinned tabs, selected tab, tab names, submitted prompt history) before saving the archived thread record.
- `ThreadManager.restoreArchivedThread(id:)` recreates the worktree from the saved branch/base-branch metadata, unarchives the persisted thread, re-adds it to the active thread list, and posts a navigation notification back to the restored thread.
- Restore intentionally does not recreate all previous tmux tabs. The restored thread comes back with clean persisted session state, and the first live session is recreated lazily when the thread is opened.
- Archived threads now persist `archivedAt`, which is used to sort the Threads-settings history card by actual archive time instead of relying on thread creation order or JSON array order.

## What changed in this thread

- Centralized archive completion UI in `ThreadManager+ThreadLifecycle.swift`.
- Added a restore path for archived threads so the archive banner action can undo an archive immediately.
- Removed duplicate archive-warning banners from the thread detail and thread-list context-menu flows so both UI archive and CLI archive show the same final banner.
- Ensured fallback session registration assigns a default first-tab label after restore/session reset.
- Added a Threads-settings history card that lists recent archived threads and reuses the same restore path as the banner action.
- Added persisted archive timestamps so recent archived-thread ordering stays stable across relaunches and worktree-sync auto-archive paths.
- Fixed archived threads being wiped from disk on every active-thread save: added `PersistenceService.saveActiveThreads(_:)` and migrated all `saveThreads(threads)` call sites to it across all `ThreadManager` extensions.
- Polished the Settings recently-archived row UI: each row now shows the thread's SF Symbol icon, rows are separated by `NSBox` dividers, and rows have vertical padding with center-Y alignment.

## Gotchas

- **Use `saveActiveThreads` for active-only saves.** `ThreadManager` keeps only non-archived threads in its in-memory `threads` array. Calling `PersistenceService.saveThreads(threads)` with that list overwrites `threads.json` with active-only data and silently wipes all archived threads from disk. Always call `PersistenceService.saveActiveThreads(_:)` instead — it merges the incoming active list with the existing archived threads on disk before writing. Archive/restore flows that already build a complete `allThreads` array should continue to call `saveThreads(allThreads)` directly.
- If a new active thread already reuses the archived thread's name, restore currently fails with the normal duplicate-name path rather than silently renaming the restored thread.
