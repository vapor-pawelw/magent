# Worktree Branch Tracking

## User Behavior

- Each thread has an expected branch (`branchName`). For main threads this is the project's default branch; for non-main threads it is the branch created with the worktree (updated only by explicit rename operations).
- The branch mismatch banner appears for **all** threads (main and non-main) when the worktree's actual checked-out branch differs from the expected one. The user can "Accept" (update the expected branch) or "Switch back" (checkout the expected branch).
- After first-prompt auto-rename, `magent-cli auto-rename-thread`, or `magent-cli rename-branch`, the rename code sets `branchName` directly — no mismatch.
- If a thread branch is renamed via Magent and other threads in the same project use that branch as their base branch, those dependent threads are retargeted automatically to the new branch name. This includes both creation-time base branches and later explicit overrides.
- Manual `git checkout` / `git switch` inside the terminal **will** show the mismatch banner. The user must explicitly accept or switch back.

## Implementation Notes

- `ThreadManager.refreshBranchStates()` updates `actualBranch` for all threads. It does **not** auto-update `branchName` — the poller only detects mismatch, never silently resolves it.
- `branchName` is updated only by: thread creation (phase 2), rename operations (`ThreadManager+Rename`), or the user clicking "Accept" on the mismatch banner (`acceptActualBranch`).
- Branch rename also retargets sibling threads whose stored `thread.baseBranch` or cached `WorktreeMetadata.detectedBaseBranch` still reference the old branch name. This keeps stacked-thread diffs and archive readiness pointed at the renamed parent instead of falling back to the project default.
- Worktree discovery in `ThreadManager.syncThreadsWithWorktrees(for:)` must seed `branchName` from `git branch --show-current` rather than assuming the directory name or rename symlink matches the checked-out branch.
- The sidebar diff footer is fed from the latest thread-manager snapshot, not from a stale `MagentThread` captured before rename/switch operations completed.

## History

- Initial: auto-synced `branchName` from actual checked-out branch for non-main threads.
- Current: `branchName` is never auto-updated by the poller. Branch mismatch banner shown for all threads. Base branch is explicit-only (no auto-detection).

## Gotchas

- Thread name and worktree directory basename are always identical (names are permanent). The git branch can differ after rename operations or manual `git checkout` / `git switch`.
- When refreshing UI after rename or branch changes, resolve the current thread again from `ThreadManager.threads` by `id` before reading `branchName` or `actualBranch`. Using the pre-refresh `MagentThread` snapshot can leave footer/tooltips one update behind.
- `WorktreeMetadata.detectedFor` is a legacy field — no longer written or consumed. Retained only for Codable backward compatibility with existing cache files on disk.

## Base Branch Resolution (Explicit)

Base branch is **never auto-detected** from git history. It is set during thread creation and only changes via explicit user action (context menu, CLI `set-base-branch`, or "Use PR target" button).

`resolveBaseBranch(for:)` priority:
1. **Manual override** — `WorktreeMetadata.detectedBaseBranch` in the worktree cache (written by context menu, CLI, or PR target action).
2. **Creation-time value** — `thread.baseBranch` (set during `createThread` from the explicit `--base-branch` flag or project default).
3. **Project default** — `project.defaultBranch`.
4. **Hardcoded fallback** — `"main"`.

Steps 1 and 2 strip the `origin/` prefix via `stripRemotePrefix(_:)` before returning, since callers compare the result against local branch names (e.g. `thread.currentBranch`). `setBaseBranch(_:for:)` also normalizes on write.

### Missing base branch recovery

During the delivery polling cycle, the resolved base branch is validated via `git rev-parse --verify`. If the ref does not exist (both bare name and `origin/`-prefixed form are checked), the base branch is reset to the project default. The old base branch name is persisted in `WorktreeMetadata.baseBranchResetFrom` so a warning banner can be shown when the user selects the thread — even across app restarts. The banner is shown once per reset; acknowledging it (or dismissing it) clears `baseBranchResetFrom` from both memory and disk.

`GitService.detectBaseBranch(worktreePath:currentBranch:)` still exists in GitService but is no longer called from the polling loop or resolution path.

### Manual Base Branch Override

The changes panel footer shows branch info on two lines: the current branch on line 1, and `⤷ <base>` on line 2 where `<base>` is a clickable button. All `origin/` prefixes are stripped for display (both in the footer and in the branch selection menu); internal values retain the full ref. Clicking the base branch button opens a menu of ancestor branches (produced by `GitService.listAncestorBranches`). The menu is listed with the farthest ancestor at the top and the closest at the bottom, matching the upward pop direction from the bottom-left anchor. The current base is check-marked. Selecting a different branch writes it into `WorktreeMetadata.detectedBaseBranch` via `ThreadManager.setBaseBranch(_:for:)`, which immediately updates the diff panel.

The menu always includes an "Other…" item (below a separator) that opens an alert with an `NSComboBox` pre-filled with the current base branch. The combo box lists all local and remote branches sorted by most-recent committer date, with auto-completion enabled. This serves as a fallback when the desired target branch is not in the ancestor list.

`listAncestorBranches` scopes its search to `merge-base(HEAD, defaultBranch)..HEAD` — only branches whose remote refs appear on commits between the fork point and HEAD are listed. The default branch (`origin/main` or equivalent) is always appended as the last option even when its tip has diverged from the merge-base commit. This prevents unrelated historical branches (merged into main long ago) from cluttering the picker.

### PR/MR Target Branch Mismatch

`PullRequestInfo.baseBranch` now captures the PR/MR target branch (`baseRefName` on GitHub, `target_branch` on GitLab). When viewing a non-main thread with an open PR whose target differs from the app's resolved base branch, a mismatch banner appears with a "Use PR target" button. Accepting stores `"origin/<prTarget>"` as the base branch override (same cache path as manual override above) and clears the banner.

The comparison normalizes by stripping `origin/` prefixes, since the app stores base branches with the prefix but PR APIs return bare branch names.

## hasEverDoneWork Flag

`MagentThread.hasEverDoneWork` is a persisted, monotonic (write-once) flag set the first time a thread's worktree becomes dirty **or** has commits ahead of its detected base branch — on any branch. It gates `showArchiveSuggestion`, ensuring brand-new untouched worktrees are never suggested for archiving.

`showArchiveSuggestion` treats work as delivered when `isFullyDelivered` is true (local git: no commits ahead of base, accounting for cherry-picks). The archive icon will not appear until the local base branch has been updated (e.g. via `git fetch`), even if the remote PR is already merged.

Migration for threads created before this field existed: `refreshDeliveredStates` checks whether the stored `forkPointCommit` differs from the current HEAD; if so, work was done before the flag existed and it is set retroactively.

The `forkPointCommit` in `WorktreeMetadata` is still recorded at worktree creation time and is used solely for migration. Once `hasEverDoneWork` is set for a thread, `forkPointCommit` is never consulted again.
