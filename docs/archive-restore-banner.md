# Archive Restore Banner

## User-facing behavior

- Archiving a non-main thread now shows a 5-second in-app banner instead of relying on archive-entry-point-specific banners.
- The banner includes the archived thread's name, task description, project, branch, base branch, Jira key, tab count, worktree path, and any archive warning text.
- The same banner appears whether archive was triggered from the UI or via `magent-cli archive-thread`.
- The banner exposes a `Restore` action that recreates the archived worktree, returns the thread to the sidebar, and navigates back to it.

## Implementation notes

- `ThreadManager.archiveThread(...)` owns the archive banner. Callers should not show a second success or warning banner for completed archives, because that replaces the shared archive banner and breaks CLI/UI parity.
- Archive now clears persisted session-specific state (`tmuxSessionNames`, agent-session maps, pinned tabs, selected tab, tab names, submitted prompt history) before saving the archived thread record.
- `ThreadManager.restoreArchivedThread(id:)` recreates the worktree from the saved branch/base-branch metadata, unarchives the persisted thread, re-adds it to the active thread list, and posts a navigation notification back to the restored thread.
- Restore intentionally does not recreate all previous tmux tabs. The restored thread comes back with clean persisted session state, and the first live session is recreated lazily when the thread is opened.

## What changed in this thread

- Centralized archive completion UI in `ThreadManager+ThreadLifecycle.swift`.
- Added a restore path for archived threads so the archive banner action can undo an archive immediately.
- Removed duplicate archive-warning banners from the thread detail and thread-list context-menu flows so both UI archive and CLI archive show the same final banner.
- Ensured fallback session registration assigns a default first-tab label after restore/session reset.

## Gotchas

- `PersistenceService.saveThreads(...)` writes the full `threads.json` payload. Restore code must merge changes into the persisted archived-thread array instead of saving only the active in-memory `threads` list.
- If a new active thread already reuses the archived thread's name, restore currently fails with the normal duplicate-name path rather than silently renaming the restored thread.
