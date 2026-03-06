# Local File Sync Paths

Per-project `Local Sync Paths` let users keep selected local-only files/directories synchronized between the main repo worktree and thread worktrees.

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

Before removing a thread worktree, Magent merges each snapshotted path for that thread back into the project repo root.

- Missing source path in thread worktree: skipped
- Files unchanged in the thread since creation are skipped (no copy-back)
- Merge-back is additive and non-destructive:
  - never deletes destination files/directories that are absent in the thread worktree
  - creates directories when needed
  - only touches files/directories covered by configured paths

This preserves files created in the main repo while a thread was active.

Because archive uses the thread's own snapshot, paths added to project settings after a thread was created are not applied retroactively to that existing thread.

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
