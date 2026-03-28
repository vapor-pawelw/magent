# Local File Sync Paths

Per-project `Local Sync Paths` let users keep selected local-only files/directories synchronized between the main repo worktree and thread worktrees.

Typical use cases:

- gitignored local docs generated during agent work
- large local build artifacts you want available across worktrees (for example `libghostty.a`)

## Configuration

- Scope: project-level setting
- Input format: line-separated repo-relative paths
- Supported entries: files and directories
- Normalization:
  - trims whitespace
  - removes leading `./`
  - rejects empty, `..`, or `~` paths
  - deduplicates entries

## Thread Creation Behavior

After `git worktree add`, Magent copies each configured path from the project repo root into the new worktree.

The thread also stores a snapshot of that normalized path list at creation time. Later project setting changes only affect newly created threads.

- Missing source path in repo root: skipped
- After thread creation, Magent shows a warning banner listing any configured sync paths that were missing in the source repo
- Existing destination in new worktree: overwritten for configured path contents
- Directory entries are materialized as directories during sync-in, including empty folders and trees that only contain empty subdirectories
- If sync-in fails, thread creation rolls back by removing the newly created worktree

## Manual Resync

Non-main threads expose a top-bar resync button (↺) that, when clicked, shows a direction menu:

- **Project → Worktree**: copies the thread's eligible local sync paths from the main repo worktree into the thread
- **Worktree → Project**: pushes local sync paths from the thread worktree back to the main repo (same merge logic as archive sync-back, but on demand)

**Option-click** changes the menu to sync against the base branch's worktree instead of the project root:

- **Base Worktree → Worktree**: copies from the sibling thread whose `currentBranch` matches this thread's resolved base branch
- **Worktree → Base Worktree**: pushes from this worktree into the base branch's worktree

Base branch resolution uses the same priority as the changes panel footer (`⤷ <base>`): detected remote branch → stored baseBranch → project default → "main". If no sibling thread is checked out on the resolved base branch, a warning banner is shown and the normal Project menu appears instead.

The button is hidden when the project has no Local Sync Paths configured (re-evaluates when settings change, so it appears automatically after paths are added). While sync is running the button is replaced by a spinner and a persistent non-dismissible banner with a spinner is shown (e.g. "Syncing Local Paths from main repo…"). The banner is replaced by the success/warning/error result banner when the operation completes, or dismissed on cancellation. Both directions run filesystem work (recursive copy, hashing) via `@concurrent` methods on the concurrent thread pool so the UI stays responsive during large syncs. Only conflict alert presentation hops back to the main actor.

### Project → Worktree

- Uses the thread's snapshotted path list, filtered to paths still configured on the project
- Prompts before overwriting conflicting files/directories already present in the thread worktree
- Supports `Override`, `Override All`, `Ignore`, and `Cancel`
- Shows a warning banner with missing repo-relative source paths instead of failing the resync
- Materializes directory entries in the thread worktree, including empty directories
- Holding Option changes `Override` to `Override All` and `Ignore` to `Ignore All` for the rest of that run

### Worktree → Project

- Uses the same snapshotted+filtered path list as the Project → Worktree direction
- Files unchanged in the thread since the last baseline (set at creation or last Project → Worktree sync) are skipped
- Prompts before overwriting conflicting files/directories in the main repo (same conflict UX as archive)
- Additive and non-destructive: intermediate directories created only when a file is actually copied; never deletes destination files absent in the thread

## Archive Behavior

Before removing a thread worktree, Magent can merge configured paths for that thread back into the project repo root.

- Merge-back is enabled by default.
- It can be disabled globally in Settings -> General -> Archive (`Sync Local Sync Paths back to main worktree on archive`).
- For CLI archive, `--skip-local-sync` disables merge-back for that specific archive command.
- Only paths currently listed in project `Local Sync Paths` are eligible for merge-back.

- Missing source path in thread worktree: skipped
- Files unchanged in the thread since creation are skipped (no copy-back)
- Archive merge-back sync methods are `@concurrent`, running filesystem work on the concurrent pool so the UI stays responsive while the thread row is marked as archiving
- Merge-back is additive and non-destructive:
  - directory entries are processed recursively
  - intermediate directories are created only when at least one child file is being copied
  - nested destination directories are merged per-file (never wholesale replaced)
  - never deletes destination files/directories that are absent in the thread worktree
  - creates directories only as needed for copied files
  - only touches files/directories covered by configured paths

Repo root should become dirty only when a listed path actually syncs back (for example overwrite accepted in conflict prompt or destination missing and file copied).

This preserves files created in the main repo while a thread was active.

Thread snapshots still protect against retroactive additions: paths added after a thread was created are not applied to that existing thread during archive.

## Conflict Handling

Conflicts are detected when merge-back would overwrite existing destination data, including:

- different file already exists at destination
- destination file blocks a directory that must exist
- destination directory blocks a file that must exist

### Conflict Prompt

Interactive archive/resync (UI) shows a conflict alert with the following buttons:

- `Resolve in Merge Tool` (primary, text file conflicts only, only when opendiff is available) — opens FileMerge with the two file versions. If the user saves a resolution and quits, the result is applied and the alert is dismissed. If the user quits without resolving, the alert re-appears. Only `opendiff` (FileMerge, ships with Xcode command line tools) is supported — other merge tools require git's backend-specific launch logic which cannot be replicated outside a real git merge context
- `Override` (current conflict only)
- `Ignore` (skip current conflict)
- `Show Diff` (text file conflicts only) — opens a modal panel with a unified diff color-coded with green/red foreground text and subtle tinted backgrounds (matching `InlineDiffViewController` colors), labeled with "Worktree:" / "Project:" prefixes so the origin of each side is clear. Context lines use `labelColor` for dark mode readability. After closing the diff panel the conflict alert re-presents for the user to choose.
- `Cancel Archive` / `Cancel` (abort entire operation)
- Holding Option changes `Override` to `Override All` and `Ignore` to `Ignore All` for the rest of that sync run

Binary detection: files are considered binary if the first 8 KB contain a null byte; the Show Diff button is hidden for binary files and for non-file conflicts (file-blocks-directory, directory-blocks-file).

Non-interactive archive flows skip conflicting targets by default (no destructive overwrite prompt).

## Force Archive

When local sync fails for a non-conflict reason, UI archive offers `Force Archive`, and CLI archive supports `--force`.

- Force archive continues archiving even if local sync cannot complete
- Conflicting overwrite targets are still skipped in non-interactive flows
- Force archive never makes local sync destructive; it only allows archive to continue with a warning

## Error Feedback

When sync fails, user-visible error text includes the failing repo-relative path (for example `docs/api/new-file.md`) so users can quickly identify and fix the problematic entry or file.
