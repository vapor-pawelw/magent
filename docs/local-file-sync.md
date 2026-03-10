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
- Existing destination in new worktree: overwritten for configured path contents
- If sync-in fails, thread creation rolls back by removing the newly created worktree

## Archive Behavior

Before removing a thread worktree, Magent can merge configured paths for that thread back into the project repo root.

- Merge-back is enabled by default.
- It can be disabled globally in Settings -> General -> Archive (`Sync Local Sync Paths back to main worktree on archive`).
- For CLI archive, `--skip-local-sync` disables merge-back for that specific archive command.
- Only paths currently listed in project `Local Sync Paths` are eligible for merge-back.

- Missing source path in thread worktree: skipped
- Files unchanged in the thread since creation are skipped (no copy-back)
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

Interactive archive (UI) offers:

- `Override` (current conflict only)
- `Override All` (all remaining conflicts in this archive)
- `Ignore` (skip current conflict)
- `Cancel Archive` (abort archive)

Non-interactive archive flows skip conflicting targets by default (no destructive overwrite prompt).

## Force Archive

When local sync fails for a non-conflict reason, UI archive offers `Force Archive`, and CLI archive supports `--force`.

- Force archive continues archiving even if local sync cannot complete
- Conflicting overwrite targets are still skipped in non-interactive flows
- Force archive never makes local sync destructive; it only allows archive to continue with a warning

## Error Feedback

When sync fails, user-visible error text includes the failing repo-relative path (for example `docs/api/new-file.md`) so users can quickly identify and fix the problematic entry or file.
