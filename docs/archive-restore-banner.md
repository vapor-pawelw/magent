# Archive Restore Banner

## User-facing behavior

- Archiving a non-main thread now shows a 5-second in-app banner instead of relying on archive-entry-point-specific banners.
- The banner leads with the task description (or thread name) in a larger bold font so the key identity is immediately clear, with branch and worktree folder shown on a secondary monospace line below.
- Secondary details (project, base branch, Jira key, tab count, full worktree path) are available in a collapsible "More Info" section rather than displayed all at once.
- The same banner structure appears for both archive and restore operations.
- Any archive warning is shown in yellow beneath the branch/worktree line.
- The same banner appears whether archive was triggered from the UI or via `magent-cli archive-thread`.
- The banner exposes a `Restore` action that recreates the archived worktree, returns the thread to the sidebar, and navigates back to it.
- `Settings > Threads` also shows up to 10 recently archived threads with inline `Restore` buttons, so the same restore flow stays available after the archive banner expires.
- A dedicated `archivebox` toolbar button in the top-right (next to the Settings gear) opens a compact popover listing up to 10 recently archived threads with one-click Restore actions — no need to open Settings for quick restores.
- Recently archived popover rows show branch/worktree metadata (using the same branch/worktree mismatch rule as sidebar thread rows) plus project/archive-date context under the title.

## Implementation notes

- `ThreadManager.archiveThread(...)` owns the archive banner. Callers should not show a second success or warning banner for completed archives, because that replaces the shared archive banner and breaks CLI/UI parity.
- Archive now clears persisted session-specific state (`tmuxSessionNames`, agent-session maps, pinned tabs, selected tab, tab names, submitted prompt history) before saving the archived thread record.
- `ThreadManager.restoreArchivedThread(id:)` recreates the worktree from the saved branch/base-branch metadata, unarchives the persisted thread, re-adds it to the active thread list, and posts a navigation notification back to the restored thread.
- Restore intentionally does not recreate all previous tmux tabs. The restored thread comes back with clean persisted session state, and the first live session is recreated lazily when the thread is opened.
- Archived threads now persist `archivedAt`, which is used to sort the Threads-settings history card by actual archive time instead of relying on thread creation order or JSON array order.
- The archive and restore banners use `NSAttributedString` passed via `BannerManager.show(attributedMessage:...)`. `BannerConfig` accepts an optional `attributedMessage`; `BannerView` applies it to `messageLabel.attributedStringValue` when present, falling back to `stringValue`/`message` for plain-text callers. The attributed layout is: header label (11pt) / title (14pt semibold) / branch · worktree-folder (11pt monospace) / optional warning line (12pt medium). Foreground colors are intentionally omitted from the attributed string so the shared banner renderer can supply its own high-contrast text color for the fixed tinted banner background.
- Archive/restore banner copy now relies on the shared banner renderer to normalize paragraph style to leading alignment. Keep the banner headline as passive label text rather than selectable text-editing content, otherwise AppKit can flip the multi-line attributed message into centered/selectable behavior after interaction and break timeout/dismiss affordances.

## What changed in the gastly thread (archive banner emphasis)

- Archive and restore banners now use `NSAttributedString` to emphasize description, branch, and worktree; secondary metadata moved to a collapsible "More Info" section.
- Added `attributedMessage: NSAttributedString?` to `BannerConfig` and a matching `show(attributedMessage:...)` overload to `BannerManager`.
- Replaced `archivedThreadBannerMessage` / `restoredThreadBannerMessage` (plain String) with `archivedThreadBannerAttributedMessage` / `restoredThreadBannerAttributedMessage` (NSAttributedString) + `archivedThreadBannerDetails` for the collapsible section.

## What changed in previous threads

- Centralized archive completion UI in `ThreadManager+ThreadLifecycle.swift`.
- Added a restore path for archived threads so the archive banner action can undo an archive immediately.
- Removed duplicate archive-warning banners from the thread detail and thread-list context-menu flows so both UI archive and CLI archive show the same final banner.
- Ensured fallback session registration assigns a default first-tab label after restore/session reset.
- Added a Threads-settings history card that lists recent archived threads and reuses the same restore path as the banner action.
- Added persisted archive timestamps so recent archived-thread ordering stays stable across relaunches and worktree-sync auto-archive paths.
- Fixed archived threads being wiped from disk on every active-thread save: added `PersistenceService.saveActiveThreads(_:)` and migrated all `saveThreads(threads)` call sites to it across all `ThreadManager` extensions.
- Polished the Settings recently-archived row UI: each row now shows the thread's SF Symbol icon, rows are separated by `NSBox` dividers, and rows have vertical padding with center-Y alignment.
- Added `RecentlyArchivedPopoverViewController` — a compact popover (360pt wide, ≤480pt tall) that replicates the recently-archived list with symmetric 12pt horizontal padding (leading = trailing), auto-refreshes on `magentArchivedThreadsDidChange`, and is shown from a new `archivebox` toolbar button in `SplitViewController`.
- Wired a second toolbar item (`recentlyArchivedToolbarItemId`) in `SplitViewController`'s `NSToolbarDelegate` between `.flexibleSpace` and the existing Settings item.

## What changed in the top-bar-light-mode thread

- Removed semantic `labelColor`/`secondaryLabelColor` foreground attributes from the archive/restore banner attributed text so the shared banner view can keep consistent contrast in both Light and Dark mode.
- Banner rendering now owns text/icon contrast for fixed-color banners, which avoids unreadable archive/restore banner text after an appearance switch.
- Archive/restore banner text now stays leading-aligned after click/hover interaction instead of snapping to centered layout.

## What changed in the combusken thread (non-blocking archive)

- Archive is now fully non-blocking from the user's perspective. Clicking Archive immediately shows an "Archiving…" overlay on the thread's sidebar row and returns focus to the app; the thread disappears when the operation completes.
- Removed all pre-archive confirmation dialogs (agent busy warning, uncommitted-changes/unmerged-commits warning, local-sync-failure force-archive dialog). These previously stalled the UI for a git-status check before anything happened.
- `threadArchiveThread` now uses `force: true` from both UI call sites so local file sync failures become a warning in the archive banner rather than a blocking dialog.
- `MagentThread` has a new transient field `isArchiving: Bool` (not persisted). `ThreadManager` exposes `markThreadArchiving(id:)` and `clearThreadArchivingState(id:)`. The latter is called via a `defer` block in `archiveThread` so the overlay is always removed on failure.
- The non-interactive local-sync merge-back phase now runs in a detached worker before archive completion, so large Local Sync Paths no longer freeze the app while the row stays in its archiving state.
- The archiving overlay now belongs to `AlwaysEmphasizedRowView`, not `ThreadCell`, so the tint/spinner covers the full selected row bounds instead of only the cell content area.
- `ThreadManager.archiveThread` shows the archive banner immediately after the UI state is updated, then fires remaining cleanup (tmux kills, worktree removal, symlink sweep, stale-session sweep) in a background `Task`. Tmux sessions are killed concurrently via `withTaskGroup`.

## What changed in the bidoof thread (archive cleanup globs)

- Per-project "Archive Cleanup Globs" setting: line-separated glob patterns for files/directories to delete from the worktree before `git worktree remove`. Configured in project settings, stored as `Project.archiveCleanupGlobs`.
- Deletion runs inside the existing detached cleanup task (after tmux kill, before worktree remove) via `ThreadManager.deleteMatchingGlobs(_:in:)`.
- Uses POSIX `glob(3)` with `GLOB_BRACE` only — no `GLOB_TILDE` (prevents `~` expansion outside worktree).
- Every matched path is resolved via `URL.resolvingSymlinksInPath()` and validated to be inside the worktree base path before deletion. Paths that escape the worktree are logged and skipped.
- Normalization (`Project.normalizeArchiveCleanupGlobs`) rejects absolute paths, `~` prefixes, and `..` traversal at save time.

## What changed in the infernape thread (stale data after suspension points)

- `archiveThread`: settings are now reloaded via `persistence.loadSettings()` after the `persistArchiveState` await instead of reusing the pre-suspension capture. The stale reference was used for the banner project name and the detached cleanup task.
- `restoreArchivedThread`: `allThreads` is reloaded and the archived index re-located by ID after the worktree-creation awaits, preventing stale-index overwrites if concurrent archive/restore modified persistence in the meantime. The second write-back (after `bumpThreadToTopOfSection`) also uses a fresh index lookup instead of reusing the earlier one.
- Removed a redundant `Task { @MainActor }` wrapper around `BannerManager.shared.show(...)` in `showArchivedThreadBanner` — `ThreadManager` is already main-actor-isolated, so the wrapper only deferred the banner to a later run-loop tick.

## Gotchas

- **Use `saveActiveThreads` for active-only saves.** `ThreadManager` keeps only non-archived threads in its in-memory `threads` array. Calling `PersistenceService.saveThreads(threads)` with that list overwrites `threads.json` with active-only data and silently wipes all archived threads from disk. Always call `PersistenceService.saveActiveThreads(_:)` instead — it merges the incoming active list with the existing archived threads on disk before writing. Archive/restore flows that already build a complete `allThreads` array should continue to call `saveThreads(allThreads)` directly.
- If a new active thread already reuses the archived thread's name, restore currently fails with the normal duplicate-name path rather than silently renaming the restored thread.
