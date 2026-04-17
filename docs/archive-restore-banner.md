# Archive Restore Banner

## User-facing behavior

- Archiving a non-main thread now shows a 5-second in-app banner instead of relying on archive-entry-point-specific banners.
- The banner leads with the task description (or thread name) in a larger bold font so the key identity is immediately clear, with branch and worktree folder shown on a secondary monospace line below.
- Secondary details (project, base branch, Jira key, tab count, full worktree path) are available in a collapsible "More Info" section rather than displayed all at once.
- The same banner structure appears for both archive and restore operations.
- Any archive warning is shown in yellow beneath the branch/worktree line.
- The same banner appears whether archive was triggered from the UI or via `magent-cli archive-thread`.
- The banner exposes a `Restore` action that recreates the archived worktree, returns the thread to the sidebar, and navigates back to it.
- **Destructive-archive safety.** Archiving is refused by default when the worktree is dirty (uncommitted/untracked changes). Archive runs `git worktree remove --force`, which deletes the worktree directory. The GUI surfaces a critical confirmation plus commit-message prompt (`Commit & Archive`) so users choose the exact commit message before forced archive. The CLI always refuses dirty worktrees (including with `--force`) until they are committed/stashed/discarded. See `docs/cli.md#archive-thread`.
- `Settings > Threads` also shows up to 10 recently archived threads with inline `Restore` buttons, so the same restore flow stays available after the archive banner expires.
- A dedicated `archivebox` toolbar button in the top-right (next to the Settings gear) opens a compact popover listing up to 10 recently archived threads with one-click Restore actions — no need to open Settings for quick restores.
- Recently archived popover rows show branch/worktree metadata (using the same branch/worktree mismatch rule as sidebar thread rows) plus project/archive-date context under the title.

## Implementation notes

- `ThreadManager.archiveThread(...)` owns the archive banner. Callers should not show a second success or warning banner for completed archives, because that replaces the shared archive banner and breaks CLI/UI parity.
- Archive now clears persisted session-specific state (`tmuxSessionNames`, agent-session maps, pinned tabs, selected tab, tab names, submitted prompt history) before saving the archived thread record.
- `ThreadManager.restoreArchivedThread(id:)` recreates the worktree from the saved branch/base-branch metadata, unarchives the persisted thread, re-adds it to the active thread list, and posts a navigation notification back to the restored thread.
- Restore intentionally does not recreate all previous tmux tabs. The restored thread comes back with clean persisted session state, and the first live session is recreated lazily when the thread is opened.
- Archived threads now persist `archivedAt`, which is used to sort the Threads-settings history card by actual archive time instead of relying on thread creation order or JSON array order.
- Worktree-sync archived-path suppression is time-bounded: archived paths are excluded from auto-discovery for 15 minutes after archive to avoid immediate re-import races while cleanup is still in flight.
- Archived-history retention is bounded per project during worktree sync: only the most recent 100 archived thread records are kept, preventing unbounded `threads.json` growth while preserving practical restore history.
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

## What changed in the recently-archived-list thread

- Fixed a regression in worktree sync that pruned archived records whenever their worktree directory was missing, which is the normal archived state after `git worktree remove`.
- Replaced permanent archived-path exclusion with a 15-minute suppression window after archive, so stale leftover directories do not re-import immediately but still become discoverable later if they remain on disk.
- Added per-project archived-history retention during sync: keep the newest 100 archived records and prune older ones.

## What changed in the top-bar-light-mode thread

- Removed semantic `labelColor`/`secondaryLabelColor` foreground attributes from the archive/restore banner attributed text so the shared banner view can keep consistent contrast in both Light and Dark mode.
- Banner rendering now owns text/icon contrast for fixed-color banners, which avoids unreadable archive/restore banner text after an appearance switch.
- Archive/restore banner text now stays leading-aligned after click/hover interaction instead of snapping to centered layout.

## What changed in the combusken thread (non-blocking archive)

- Archive is now fully non-blocking from the user's perspective. Clicking Archive immediately shows an "Archiving…" overlay on the thread's sidebar row and returns focus to the app; the thread disappears when the operation completes.
- Removed all pre-archive confirmation dialogs (agent busy warning, uncommitted-changes/unmerged-commits warning, local-sync-failure force-archive dialog). These previously stalled the UI for a git-status check before anything happened.
- UI archive retries now use `force: true` only after the user confirms `Commit & Archive` and provides a non-empty commit message (defaulted to `Uncommitted changes on <branch> (<worktree>)`). The same forced path keeps non-conflict local-sync failures as archive warnings instead of blocking dialogs.
- `MagentThread` has a new transient field `isArchiving: Bool` (not persisted). `ThreadManager` exposes `markThreadArchiving(id:)` and `clearThreadArchivingState(id:)`. The latter is called via a `defer` block in `archiveThread` so the overlay is always removed on failure.
- The non-interactive local-sync merge-back phase now runs in a detached worker before archive completion, so large Local Sync Paths no longer freeze the app while the row stays in its archiving state.
- The archiving overlay now belongs to `AlwaysEmphasizedRowView`, not `ThreadCell`, so the tint/spinner covers the full selected row bounds instead of only the cell content area.
- `ThreadManager.archiveThread` shows the archive banner immediately after the UI state is updated, then fires remaining cleanup (tmux kills, worktree removal, symlink sweep, stale-session sweep) in a background `Task`. Tmux sessions are killed concurrently via `withTaskGroup`.

## What changed in the infernape thread (stale data after suspension points)

- `archiveThread`: settings are now reloaded via `persistence.loadSettings()` after the `persistArchiveState` await instead of reusing the pre-suspension capture. The stale reference was used for the banner project name and the detached cleanup task.
- `restoreArchivedThread`: `allThreads` is reloaded and the archived index re-located by ID after the worktree-creation awaits, preventing stale-index overwrites if concurrent archive/restore modified persistence in the meantime. The second write-back (after `bumpThreadToTopOfSection`) also uses a fresh index lookup instead of reusing the earlier one.
- Removed a redundant `Task { @MainActor }` wrapper around `BannerManager.shared.show(...)` in `showArchivedThreadBanner` — `ThreadManager` is already main-actor-isolated, so the wrapper only deferred the banner to a later run-loop tick.

## What changed in the fix-banner-close-button thread

- The archive banner now inherits a shared `BannerView` header-layout fix that keeps long message text from overlapping the trailing accessory column.
- The top-right `X` on the archived-thread banner is clickable again, and the same shared fix also covers other banners rendered through `BannerManager`.

## Gotchas

- **Use `saveActiveThreads` for active-only saves.** `ThreadManager` keeps only non-archived threads in its in-memory `threads` array. Calling `PersistenceService.saveThreads(threads)` with that list overwrites `threads.json` with active-only data and silently wipes all archived threads from disk. Always call `PersistenceService.saveActiveThreads(_:)` instead — it merges the incoming active list with the existing archived threads on disk before writing. Archive/restore flows that already build a complete `allThreads` array should continue to call `saveThreads(allThreads)` directly.
- If a new active thread already reuses the archived thread's name, restore currently fails with the normal duplicate-name path rather than silently renaming the restored thread.
- **Cached ghostty surfaces must be evicted before tmux sessions are killed.** `ReusableTerminalViewCache` holds live `TerminalSurfaceView` instances with active PTY file descriptors. When the archive/delete cleanup task kills the tmux sessions, the PTY closes and libghostty calls `_exit()`, silently terminating the entire process with no signal, no crash report, and no `applicationWillTerminate` callback. Both `archiveThread` and `deleteThread` must call `ReusableTerminalViewCache.shared.evictSessions(thread.tmuxSessionNames)` before the cleanup task runs. Additionally, `showEmptyState` must skip caching when called from the archive/delete path (the sessions are about to die).
