# Worktree Branch Tracking

## User Behavior

- For non-main threads, Magent now treats the branch currently checked out in the worktree as the source of truth.
- After first-prompt auto-rename, `magent-cli auto-rename-thread`, `magent-cli rename-branch`, or any manual `git checkout` / `git switch`, the sidebar and `CHANGES` footer should show the new branch without requiring the user to accept a mismatch banner.
- The main thread still keeps its separate "expected branch" behavior based on the project's configured default branch.

## Implementation Notes

- `ThreadManager.refreshBranchStates()` updates `actualBranch` for all threads, but for non-main threads it also persists `branchName = actualBranch` when Git reports a different checked-out branch.
- Branch-mismatch UI remains meaningful only for the main thread. Non-main worktrees now adopt the current branch instead of treating that state as drift.
- Worktree discovery in `ThreadManager.syncThreadsWithWorktrees(for:)` must seed `branchName` from `git branch --show-current` rather than assuming the directory name or rename symlink matches the checked-out branch.
- The sidebar diff footer is fed from the latest thread-manager snapshot, not from a stale `MagentThread` captured before rename/switch operations completed.

## Changed In This Thread

- Fixed stale `thread.branchName` after auto-rename and branch switches.
- Fixed `CHANGES` footer branch labels so they refresh from live thread state after rename/switch operations.
- Fixed imported/recovered worktrees to record their real checked-out branch on discovery.

## Gotchas

- Thread name, worktree directory basename, and git branch are no longer interchangeable. Rename symlinks intentionally let the thread name differ from the real worktree path, and manual branch switches can make the branch differ from both.
- When refreshing UI after rename or branch changes, resolve the current thread again from `ThreadManager.threads` by `id` before reading `branchName` or `actualBranch`. Using the pre-refresh `MagentThread` snapshot can leave footer/tooltips one update behind.

## Base Branch Detection (Dynamic)

Base branch is no longer stored as a fixed string per thread. Instead, `GitService.detectBaseBranch(worktreePath:currentBranch:)` walks the decorated commit history (`git log --simplify-by-decoration`) to find the nearest `origin/*` ancestor, excluding the current branch's own remote tracking ref. The result is cached in `WorktreeMetadata` keyed by the branch name it was detected for (`detectedFor`). The cache is stale when `detectedFor != thread.currentBranch`, triggering re-detection automatically.

`resolveBaseBranch(for:)` reads the cache first, then falls back to `project.defaultBranch` → `thread.baseBranch` → `"main"`. This means the changes panel and delivery check always use an accurate base branch even after branch switches inside the worktree.

## hasEverDoneWork Flag

`MagentThread.hasEverDoneWork` is a persisted, monotonic (write-once) flag set the first time a thread's worktree becomes dirty **or** has commits ahead of its detected base branch — on any branch. It gates `showArchiveSuggestion`, ensuring brand-new untouched worktrees are never suggested for archiving.

Migration for threads created before this field existed: `refreshDeliveredStates` checks whether the stored `forkPointCommit` differs from the current HEAD; if so, work was done before the flag existed and it is set retroactively.

The `forkPointCommit` in `WorktreeMetadata` is still recorded at worktree creation time and is used solely for migration. Once `hasEverDoneWork` is set for a thread, `forkPointCommit` is never consulted again.
