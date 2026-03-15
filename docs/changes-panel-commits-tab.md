# Changes Panel — COMMITS Tab and Commit Selection

## User Behavior

- The selected main thread always keeps the bottom-left sidebar panel visible, even when there are no dirty files.
- For non-main threads, the panel is shown only when there are dirty files or branch commits; clean branches with no commits ahead of base hide the panel entirely.
- **COMMITS is the left-most (default) tab.** It always contains an "Uncommitted" row at the top (when the panel is visible), regardless of whether the working tree is dirty. The "Uncommitted" row is pre-selected.
- Below "Uncommitted", the COMMITS tab lists branch commits newest-first. Each row shows:
  - **Short hash** (monospaced, dimmed) — left side
  - **Commit subject** — right side, wraps up to 3 lines
  - Tooltip with full `hash subject\nauthor · date`
- When more commits exist beyond the current page, the list ends with `Load More Commits` (+10 per tap).
- **Selecting "Uncommitted"** shows the working-tree file list in the CHANGES tab (same as the original CHANGES behavior).
- **Selecting a commit** loads files changed in that commit via `git show --numstat`. The CHANGES tab then shows those files, and a subtitle label below the tab bar reads `from <hash> · <subject>`.
- Clicking a file in the CHANGES tab opens the inline diff viewer:
  - For "Uncommitted": shows the working-tree diff (or branch diff vs. base, depending on thread type).
  - For a selected commit: shows `git show <hash>` diff for that commit. If the viewer is already open with a different commit's diff, it is closed and reloaded.
- The `ⓘ` color-legend button is hidden while the COMMITS tab is active.
- Keyboard `↑`/`↓` navigation only operates in the CHANGES tab; it passes through to super from the COMMITS tab.

## Implementation

### Data Models
- `BranchCommit` in `Packages/MagentModules/Sources/MagentModels/GitTypes.swift` — `shortHash`, `subject`, `authorName`, `date`.

### GitService (GitCore)
- `commitLog(worktreePath:baseBranch:limit:skip:)` — non-main branch commits via `git log <base>..HEAD`.
- `recentCommitLog(worktreePath:limit:skip:)` — main-thread panel from `git log HEAD`.
- `commitDiffStats(worktreePath:commitHash:)` — per-file stats for a single commit via `git show --numstat --format= <hash>`. All files get `.committed` status.
- `commitDiffContent(worktreePath:commitHash:)` — full unified diff via `git show --no-color <hash>`.

### DiffPanelView
- `activeTab: DiffPanelTab` — `.commits` (default, left) or `.changes` (right). Tab enum order was flipped from the original: COMMITS is now first.
- `uncommittedEntries: [FileDiffEntry]` — always the working-tree/branch entries loaded on thread selection.
- `commitEntries: [FileDiffEntry]` — populated by `updateCommitEntries(hash:entries:subject:)` after async load.
- `selectedCommitHash: String?` — `nil` = "Uncommitted" selected; non-nil = a commit hash. Reset to `nil` on `update()` unless `preserveSelection: true` is passed and the hash still exists in `newCommits`.
- `activeEntries` computed property returns `uncommittedEntries` or `commitEntries` depending on selection.
- `onCommitSelected: ((String?) -> Void)?` — fires on row click; nil = Uncommitted.
- `updateCommitEntries(hash:entries:subject:)` — called by controller; only applies if `selectedCommitHash == hash` to avoid stale updates from cancelled async loads.
- `rebuildCommitsRows()` — always hides `commitContextLabel`, then adds the "Uncommitted" `CommitRowView` first, then commits, then "Load More".
- `update(preserveSelection:)` — when `true` and the selected commit still exists in the new commit list, keeps `selectedCommitHash` and `activeTab` unchanged, clears `commitEntries` and fires `onCommitSelected` to reload them, and hides `commitContextLabel` via `rebuildCommitsRows()`. Used by background/polling refreshes (agent completion, load-more); thread-switch calls pass `false`.
- `rebuildChangesRows()` — shows `commitContextLabel` when `selectedCommitHash != nil`, then file rows or empty state.
- `CommitRowView` — selectable NSView subclass (like `DiffFileRowView`) with `isSelected` highlight. Uses `"__uncommitted__"` as a sentinel hash for the Uncommitted row's `updateCommitRowSelectionAppearance`.

### Controller Layer
- `ThreadListViewController.onCommitSelected` is wired in `ThreadListViewController.swift` setup.
- `handleCommitSelected(_:)` in `ThreadListViewController+SidebarActions.swift` — launches async task to call `GitService.commitDiffStats`, then calls `diffPanelView.updateCommitEntries`. Guard: `selectedThreadID == thread.id` to drop stale results.
- `ThreadListViewController.diffPanelCommitLimitByThreadId` and `diffPanelCommitPageSize` drive pagination as before.

### Diff Viewer
- `showDiffViewer(scrollToFile:commitHash:)` in `ThreadDetailViewController+DiffViewer.swift` accepts an optional `commitHash`.
- `currentDiffCommitHash: String?` on `ThreadDetailViewController` tracks what the open viewer is showing. If it differs from the requested `commitHash`, the viewer is closed and rebuilt before opening the new one.
- `refreshDiffViewerIfVisible()` skips refresh when `currentDiffCommitHash != nil` (commit diffs are static).
- `hideDiffViewer()` resets `currentDiffCommitHash` to `nil`.
- The `magentShowDiffViewer` notification now carries an optional `"commitHash"` key in userInfo, set by `DiffPanelView.selectFile()`.

## Gotchas

- **Background refresh must not reset selection**: `refreshDiffPanel` is called on agent completion and load-more, not only on thread switch. Pass `preserveSelection: true` in those cases so the user's current commit/tab is preserved. Thread-switch calls (`outlineViewSelectionDidChange`) pass `false` (default) to reset cleanly.
- **`commitContextLabel` must be hidden in `rebuildCommitsRows()`**: the label is set in `rebuildChangesRows()` but only explicitly hidden in `commitsTabTapped()` and `clear()`. Adding `commitContextLabel.isHidden = true` at the top of `rebuildCommitsRows()` prevents the label from lingering when a background refresh switches the panel back to the COMMITS tab.

- **`selectCommit` closes the diff viewer softly**: `deselectFileWithoutHidingViewer()` updates the file row highlight but does not post `magentHideDiffViewer`. The viewer stays visible but its content becomes stale until the user clicks a file. This is intentional — force-closing the viewer on every commit tap would be jarring.
- **Stale `updateCommitEntries` guard**: async loads for commit stats must be guarded by `selectedCommitHash == hash`. If the user clicks two commits quickly, the second load may arrive first; the guard prevents the first (now-wrong) result from overwriting the correct one.
- **`commitDiffStats` passes an empty `statusMap`**: files in a committed diff are always `.committed` status (gray). There is no working-tree status to overlay.
- **`commitDiffContent` includes the commit message header**: `git show` output starts with the commit message block before the diff. `InlineDiffViewController` ignores non-diff lines gracefully, so no special stripping is needed.
- **Tab ordering**: `DiffPanelTab` enum now lists `.commits` before `.changes`. COMMITS is added to `tabBarStack` first. Tab-bar buttons use low hugging/compression resistance to prevent widening the sidebar.
- **`commitsTabButton.isHidden`**: set to `true` only when both entries and commits are empty and `forceVisible` is false (i.e., the panel itself is hidden). When the panel is visible, COMMITS is always shown even if there are no branch commits yet (the "Uncommitted" row is always present).
- Keyboard navigation (`↑`/`↓`) is guarded to the CHANGES tab; the key event passes through to super from COMMITS.
- `BranchCommit`, `commitLog`, and new `commitDiffStats`/`commitDiffContent` must be `public` because `GitCore` and `MagentModels` are separate Swift package targets.
