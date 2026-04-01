# Local File Sync Paths

Per-project `Local Sync Paths` let users keep selected local-only files/directories synchronized between thread worktrees. By default, sync targets the worktree that owns the thread's base branch (enabling stacked worktree chains). When no sibling thread owns the base branch, sync falls back to the project repo root.

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

## Sync Target Resolution

The sync target is resolved via `ThreadManager.resolveBaseBranchSyncTarget(for:project:)`:

1. Resolve the thread's base branch (detected override → stored baseBranch → project default → "main")
2. Find the first active (non-archived) sibling thread in the same project whose `currentBranch` matches the base branch
3. If found → sync with that sibling's worktree path
4. If not found → fall back to `project.repoPath`

A second overload `resolveBaseBranchSyncTarget(baseBranch:excludingThreadId:projectId:project:)` is used during thread creation when the thread model is not yet fully formed.

## Thread Creation Behavior

After `git worktree add`, Magent copies each configured path from the resolved sync target (base branch worktree or project root) into the new worktree.

The thread also stores a snapshot of that normalized path list at creation time. Later project setting changes only affect newly created threads.

When forking a thread (Fork Thread), the new thread's sync snapshot is built by merging the source thread's snapshot with the current project paths: source paths still present in the project config are kept, removed paths are filtered out, and any new project paths are appended. This ensures the fork inherits the source thread's sync state while staying consistent with the current project configuration.

- Missing source path in sync target: skipped
- After thread creation, Magent shows a warning banner listing any configured sync paths that were missing in the source
- Existing destination in new worktree: overwritten for configured path contents
- Directory entries are materialized as directories during sync-in, including empty folders and trees that only contain empty subdirectories
- If sync-in fails, thread creation rolls back by removing the newly created worktree

## Manual Resync

When a project has configured `Local Sync Paths` and at least one other active worktree in that project, Magent shows a top-bar resync button (↺). The current worktree is never offered as a target.

Non-main threads use a quick-action menu first:

**Default click** — syncs with the base branch's worktree (or project root as fallback):

- **`<base-worktree> → <this-worktree>`**: copies from the resolved sync target into this thread
- **`<this-worktree> → <base-worktree>`**: pushes from this worktree into the resolved sync target

When no sibling thread owns the base branch, labels show "Project" (e.g. `Project → primeape`).

**Option-click** — always syncs with the main repo regardless of base branch:

- **`Project → <this-worktree>`**: copies from the project repo root into this thread
- **`<this-worktree> → Project`**: pushes from this worktree to the project repo root

When there are more than two active worktrees in the project, the quick-action menu also includes **`Other…`**, which opens a manual picker. When only one other worktree exists, `Other…` is hidden since the direct menu items already cover it.

- Direction selector: `Sync into this worktree` or `Sync from this worktree`
- Worktree selector: `NSComboBox` listing every other non-bare git worktree in the repo, including the main worktree when the current thread is not main
- Default target: the same resolved base-branch sync target used by the quick menu when present; otherwise the first available other worktree

The main worktree skips the quick-action menu entirely and opens this manual picker directly, so manual sync behavior is consistent across all worktrees.

The button stays hidden when the project has no Local Sync Paths configured, or when there is no second active worktree in the project to sync against. Visibility is re-evaluated when settings or thread lists change, so it appears automatically once both conditions are true. While sync is running the button is replaced by a spinner and a persistent non-dismissible banner with a spinner is shown (e.g. "Syncing Local Paths from main repo…"). The banner is replaced by the success/warning/error result banner when the operation completes, or dismissed on cancellation. Both directions run filesystem work (recursive copy, hashing) via `@concurrent` methods on the concurrent thread pool so the UI stays responsive during large syncs. Only conflict alert presentation hops back to the main actor.

### Sync Target → Worktree

- Uses the thread's snapshotted path list, filtered to paths still configured on the project
- Prompts before overwriting conflicting files/directories already present in the thread worktree
- Supports `Override`, `Override All`, `Ignore`, and `Cancel`
- Shows a warning banner with missing repo-relative source paths instead of failing the resync
- Materializes directory entries in the thread worktree, including empty directories
- Holding Option changes `Override` to `Override All` and `Ignore` to `Ignore All` for the rest of that run

### Worktree → Sync Target

- Uses the same snapshotted+filtered path list as the Sync Target → Worktree direction
- Files unchanged in the thread since the last baseline (set at creation or last inbound sync) are skipped
- Prompts before overwriting conflicting files/directories in the target (same conflict UX as archive)
- Additive and non-destructive: intermediate directories created only when a file is actually copied; never deletes destination files absent in the thread

## Archive Behavior

Before removing a thread worktree, Magent can merge configured paths for that thread back into the resolved sync target (base branch worktree or project root).

- Merge-back is enabled by default.
- It can be disabled globally in Settings -> General -> Archive (`Sync Local Sync Paths back to main worktree on archive`).
- For CLI archive, `--skip-local-sync` disables merge-back for that specific archive command.
- Only paths currently listed in project `Local Sync Paths` are eligible for merge-back.

- Missing source path in thread worktree: skipped
- Files unchanged in the thread since creation are skipped (no copy-back)
- Archive merge-back sync methods are `@concurrent`, running filesystem work on the concurrent pool so the UI stays responsive
- For UI callers (`force:true`, `awaitLocalSync:false`), the sync is deferred to a fire-and-forget background task — the thread disappears from the sidebar immediately. Sync failures show a warning banner if the app is still running.
- For IPC/CLI callers (`awaitLocalSync:true`), the sync is awaited so the result/warning can be returned in the response.
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

Interactive archive/resync (UI) shows a conflict alert. The button layout differs by conflict type:

**Text file conflicts** (both sides are text files):

- `Resolve in Merge Tool` (primary, only when `git config merge.tool` is set) — creates a temporary git repo with a real staged merge conflict and runs `git mergetool`, which correctly invokes whatever tool the user has configured (opendiff, vimdiff, meld, custom commands, etc.). If the user resolves and quits, the result is applied and the alert is dismissed. If the user quits without resolving, the alert re-appears.
- `Agentic Merge` — aborts the file-by-file sync loop and opens a new agent tab with a structured prompt that delegates the entire sync operation to the agent for intelligent conflict resolution. It prefers the project's default agent, but if that agent currently has an active tracked rate limit Magent falls back to the first other enabled agent without one. If every enabled agent is rate-limited, it still opens with the default agent.
- `Cancel Archive` / `Cancel` (abort entire operation)

**Binary/structural conflicts** (binary files, file-blocks-directory, directory-blocks-file):

- `Override` (current conflict only)
- `Ignore` (skip current conflict)
- `Agentic Merge` — same as above, including the default-agent rate-limit fallback behavior.
- `Cancel Archive` / `Cancel` (abort entire operation)
- Holding Option changes `Override` to `Override All` and `Ignore` to `Ignore All` for the rest of that sync run

Binary detection: files are considered binary if the first 8 KB contain a null byte.

### Merge Tool Implementation

The merge tool integration creates a throwaway git repository in `/tmp/magent-merge-*` with:
- A base commit containing a placeholder file
- An "ours" branch with the destination file content
- A "theirs" branch with the source file content
- A real `git merge` that produces a conflict

This allows `git mergetool` to handle all tool-specific invocation logic (environment variables, temp file naming conventions, exit code handling) regardless of tool type. The user's `merge.tool` and any custom `mergetool.<name>.cmd` are read from the project repo's git config and propagated to the temp repo. Tool names are validated against `[a-zA-Z0-9_-]+` to prevent config key injection.

Non-interactive archive flows skip conflicting targets by default (no destructive overwrite prompt).

## Force Archive

When local sync fails for a non-conflict reason, UI archive offers `Force Archive`, and CLI archive supports `--force`.

- Force archive continues archiving even if local sync cannot complete
- Conflicting overwrite targets are still skipped in non-interactive flows
- Force archive never makes local sync destructive; it only allows archive to continue with a warning

## Error Feedback

When sync fails, user-visible error text includes the failing repo-relative path (for example `docs/api/new-file.md`) so users can quickly identify and fix the problematic entry or file.
