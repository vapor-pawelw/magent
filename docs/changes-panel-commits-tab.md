# Changes Panel — COMMITS Tab and Commit Selection

## User Behavior

- The selected main thread always keeps the bottom-left sidebar panel visible, even when there are no dirty files.
- For non-main threads, the panel is shown only when there are dirty files or branch commits; clean branches with no commits ahead of base hide the panel entirely.
- **COMMITS is the left-most (default) tab.** It contains an "Uncommitted" row at the top only when the working tree has uncommitted changes; when clean, the row is hidden entirely. If uncommitted changes exist, the "Uncommitted" row is pre-selected.
- Below "Uncommitted" (or at the top when clean), the COMMITS tab lists branch commits newest-first. Each row shows:
  - **Short hash** (monospaced, dimmed) — left side
  - **Commit subject** — right side, wraps up to 3 lines
  - Tooltip with full `hash subject\nauthor · date`
- When more commits exist beyond the current page, the list ends with `Load More Commits` (+10 per tap).
- **Single-clicking "Uncommitted"** selects it (highlighted). The ALL CHANGES tab is independent and always shows the full branch diff.
- **Single-clicking a commit** selects it (highlighted). The ALL CHANGES tab is independent and unaffected by commit selection.
- **Double-tapping "Uncommitted" or any commit row** enters **commit detail mode** (see below).
- The **ALL CHANGES** tab (right tab) always shows all files changed in the branch (merge-base to working tree, including both committed and uncommitted changes). It is independent of which commit is selected in the COMMITS tab. Clicking a file opens the inline diff viewer showing the branch diff vs. base.
- A small refresh button sits in the panel's top-right corner next to the `ⓘ` legend button. Tapping it manually refreshes branch state, dirty status, delivery/base-branch-derived git state, and then reloads the panel's commits and changes without resetting the current tab or pagination.
- The `ⓘ` color-legend button is hidden while the COMMITS tab is active.

### Commit Detail Mode

Double-tapping a row in the COMMITS tab enters an inline detail mode:
- The tab bar (COMMITS / CHANGES) is hidden and replaced by a header row: **`‹ Back`** button + commit title (e.g. `abc123 — Fix the bug`, or `Uncommitted changes`).
- The file list shows **only files for that commit** (loaded fresh: `commitDiffStats` for a commit hash, `workingTreeDiffStats` for "Uncommitted").
- Clicking a file opens the diff viewer scoped to that context:
  - Commit detail: shows `git show <hash>` diff (same as single-click CHANGES flow).
  - Uncommitted detail: forces working-tree-only diff (ignores base branch), via `forceWorkingTreeDiff: true`.
- **Back**: tapping `‹ Back` exits detail mode, returns to COMMITS tab, and closes the diff viewer.
- **Thread change**: `DiffPanelView.update()` and `clear()` both call `resetCommitDetailMode()`, which exits detail mode without posting a hide-viewer notification (the panel teardown handles that).
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
- `uncommittedEntries: [FileDiffEntry]` — working-tree entries loaded on thread selection (vs HEAD, uncommitted only). Used to decide whether the "Uncommitted" row is shown and its file count.
- `allBranchEntries: [FileDiffEntry]` — full branch diff (merge-base to working tree, including committed + uncommitted changes). Fetched via `GitService.diffStats(worktreePath:baseBranch:)` for non-main threads; for main threads, equals `uncommittedEntries`.
- `commitEntries: [FileDiffEntry]` — populated by `updateCommitEntries(hash:entries:subject:)` after async load. Used only for commit detail mode.
- `selectedCommitHash: String?` — `nil` = "Uncommitted" selected; non-nil = a commit hash. Reset to `nil` on `update()` unless `preserveSelection: true` is passed. `activeTab` is also preserved whenever `preserveSelection: true`, regardless of whether a commit hash is selected.
- `activeEntries` computed property returns `allBranchEntries` (always the full branch diff, independent of commit selection).
- `onCommitSelected: ((String?) -> Void)?` — fires on single-click; nil = Uncommitted.
- `onCommitDoubleTapped: ((String?, String) -> Void)?` — fires on double-click; args are (hash or nil, display title). Controller loads entries and calls `enterCommitDetailMode`.
- `onRefreshRequested: (() -> Void)?` — fires when the user taps the top-right refresh button.
- `updateCommitEntries(hash:entries:subject:)` — called by controller; only applies if `selectedCommitHash == hash` to avoid stale updates from cancelled async loads.
- `enterCommitDetailMode(hash:title:entries:)` — public; hides tab bar, shows commit detail header + file list.
- `resetCommitDetailMode()` — private; restores tab bar, clears detail state. Called from `clear()`, `update()`, and `backButtonTapped()`.
- `rebuildCommitDetailRows()` — builds file rows from `commitDetailEntries`; called by `rebuildRows()` when `isInCommitDetailMode`.
- `isInCommitDetailMode`, `commitDetailHash`, `commitDetailEntries`, `commitDetailHeaderView`, `backButton`, `commitDetailTitleLabel` — detail-mode state and UI.
- `setRefreshInProgress(_:)` disables and dims the refresh button while a manual refresh task is running.
- `rebuildCommitsRows()` — always hides `commitContextLabel`, then adds the "Uncommitted" `CommitRowView` only if `uncommittedEntries` is non-empty, then commits, then "Load More".
- `update(preserveSelection:)` — when `true`, always preserves `activeTab`. If a commit hash is selected and still exists in the new commit list, also preserves `selectedCommitHash`, clears `commitEntries`, and fires `onCommitSelected` to reload them. If `selectedCommitHash` is `nil` (user is on ALL CHANGES tab), the tab is still preserved so a background refresh doesn't yank the user back to COMMITS. Hides `commitContextLabel` via `rebuildCommitsRows()`. Used by background/polling refreshes (agent completion, load-more); thread-switch calls pass `false`.
- `rebuildChangesRows()` — always hides `commitContextLabel`, shows `allBranchEntries` file rows or "No changes in this branch" empty state. Independent of commit selection.
- `CommitRowView` — selectable NSView subclass (like `DiffFileRowView`) with `isSelected` highlight. Uses `"__uncommitted__"` as a sentinel hash for the Uncommitted row's `updateCommitRowSelectionAppearance`.

### Branch Info Footer
- Branch info at the bottom of the panel uses a two-line vertical layout: line 1 is the current branch name (`branchInfoLabel`), line 2 is a `⤷` arrow (`baseLineLabel`) followed by the clickable base branch button (`baseBranchButton`).
- `origin/` prefixes are stripped for display in both the footer and the base branch selection menu; internal values (`representedObject`) retain the full ref.
- `updateBranchInfo(branchName:baseBranch:)` handles the stripping and layout visibility.

### Controller Layer
- `ThreadListViewController.onCommitSelected` is wired in `ThreadListViewController.swift` setup.
- `ThreadListViewController.onRefreshRequested` is wired in `ThreadListViewController.swift` setup.
- `handleCommitSelected(_:)` in `ThreadListViewController+SidebarActions.swift` — launches async task to call `GitService.commitDiffStats`, then calls `diffPanelView.updateCommitEntries`. Guard: `selectedThreadID == thread.id` to drop stale results.
- `manuallyRefreshSelectedThreadGitState()` in `ThreadListViewController+SidebarActions.swift` guards against overlapping taps, runs `refreshBranchStates()`, `refreshDirtyStates()`, and `refreshDeliveredStates()`, then calls `refreshDiffPanel(resetPagination:false, preserveSelection:true)` for the still-selected thread.
- `ThreadListViewController.diffPanelCommitLimitByThreadId` and `diffPanelCommitPageSize` drive pagination as before.

### Controller Layer (Commit Detail)
- `handleCommitDoubleTapped(_:title:)` in `ThreadListViewController+SidebarActions.swift` — loads entries async (`commitDiffStats` or `workingTreeDiffStats`) then calls `diffPanelView.enterCommitDetailMode`.

### Diff Viewer
- `showDiffViewer(scrollToFile:commitHash:forceWorkingTreeDiff:)` in `ThreadDetailViewController+DiffViewer.swift` accepts an optional `commitHash` and `forceWorkingTreeDiff` flag.
- `currentDiffCommitHash: String?` on `ThreadDetailViewController` tracks what the open viewer is showing. If it differs from the requested `commitHash` (or `forceWorkingTreeDiff` changed), the viewer is closed and rebuilt.
- `currentDiffForceWorkingTree: Bool` — set when opening a diff for the "Uncommitted" detail mode; causes `refreshDiffViewerIfVisible()` and `showDiffViewer` to use `workingTreeDiffContent/Stats` instead of branch diff.
- `refreshDiffViewerIfVisible()` skips refresh when `currentDiffCommitHash != nil` (commit diffs are static); respects `currentDiffForceWorkingTree` to determine which diff to refresh.
- `hideDiffViewer()` resets both `currentDiffCommitHash` and `currentDiffForceWorkingTree` to nil/false.
- The `magentShowDiffViewer` notification carries an optional `"commitHash"` key, or `"mode": "uncommitted"` (from uncommitted detail mode file selection), set by `DiffPanelView.selectFile()`.

## Gotchas

- **Background refresh and sidebar reloads must not reset selection or tab**: `refreshDiffPanel` is called on agent completion, load-more, and after structural sidebar reloads — not only on explicit thread-switch. Pass `preserveSelection: true` in all cases where the thread did not change. This includes the case where `selectedCommitHash == nil` (user is on the CHANGES tab with "Uncommitted" selected) — without `preserveSelection: true`, the tab would reset to `.commits` on every background refresh.
- **Manual refresh must refresh thread git metadata before reloading panel content**: the refresh button is intended to update branch labels and dirty/delivered state immediately, not just rerun `diffStats`. Run `refreshBranchStates()`, `refreshDirtyStates()`, and `refreshDeliveredStates()` before `refreshDiffPanel(...)`, and keep `preserveSelection: true` / `resetPagination: false` so a manual sync behaves like a non-destructive background refresh.
- **`outlineViewSelectionDidChange` must be suppressed during `reloadData()`**: NSOutlineView fires `outlineViewSelectionDidChange` mid-reload when rows are shuffled (e.g. via `bumpThreadToTopOfSection`). The previously-selected row index can temporarily map to a different thread, making `selectionChanged = true` and causing a `preserveSelection: false` refresh — which resets the panel. The handler is now guarded by `guard !isReloadingData else { return }`. Since `outlineViewSelectionDidChange` is suppressed during `reloadData()`, `threadManager(didUpdateThreads:)` must explicitly call `refreshDiffPanel(for: selected, preserveSelection: true)` after a structural reload (not just `refreshDiffPanelContext`, which only updates labels and does not refresh panel content). In-place updates (non-structural) continue to use `refreshDiffPanelContext` as before.
- **`outlineViewSelectionDidChange` must not fire a second Task when the delegate already handles refresh**: When `selectionChanged = true`, the delegate calls `refreshDiffPanelForSelectedThread()` (no-preserve Task A). Do NOT also call `refreshDiffPanel` directly — that creates a redundant no-preserve Task B that can arrive after Task A and re-reset the panel. When `selectionChanged = false` (same thread re-selected programmatically), always call `refreshDiffPanel(preserveSelection: true)`.
- **`autoSelectFirst()` and `selectThread(byId:)` must not call the delegate for the same thread**: These methods call `recordSelectedThread` (sets `selectedThreadID`) then `outlineView.selectRowIndexes`, which fires `outlineViewSelectionDidChange` with `selectionChanged = false` → preserve Task B. If the delegate is also called unconditionally (→ no-preserve Task A), and Task A completes after Task B, the panel resets. Fix: check `isNewThread = selectedThreadID != thread.id` before `recordSelectedThread`, and only call the delegate when `isNewThread`.
- **`commitContextLabel` must be hidden in `rebuildCommitsRows()`**: the label is set in `rebuildChangesRows()` but only explicitly hidden in `commitsTabTapped()` and `clear()`. Adding `commitContextLabel.isHidden = true` at the top of `rebuildCommitsRows()` prevents the label from lingering when a background refresh switches the panel back to the COMMITS tab.

- **`uncommittedEntries` holds working-tree diff only (vs HEAD)**: the "Uncommitted" row count reflects only files not yet committed. The ALL CHANGES tab uses `allBranchEntries` (full branch diff from merge-base) which is a separate data source.
- **"Uncommitted" row is conditionally hidden**: When `uncommittedEntries` is empty (clean working tree), the row is not rendered. This is purely visual — `uncommittedEntries` is still stored and used for the count badge when non-empty.
- **`forceWorkingTreeDiff` must reload viewer when it changes**: The viewer reload guard checks both `currentDiffCommitHash` and `currentDiffForceWorkingTree`. Without the latter, switching between "Uncommitted" detail mode (force working-tree) and normal CHANGES tab (branch diff) would reuse the wrong diff content.
- **`resetCommitDetailMode()` does not post `magentHideDiffViewer`**: Cleanup on thread change (via `update()` / `clear()`) must not post hide-viewer — the thread-switch flow handles diff viewer lifecycle separately. Only `backButtonTapped()` posts the hide notification explicitly.
- **`selectCommit` closes the diff viewer softly**: `deselectFileWithoutHidingViewer()` updates the file row highlight but does not post `magentHideDiffViewer`. The viewer stays visible but its content becomes stale until the user clicks a file. This is intentional — force-closing the viewer on every commit tap would be jarring.
- **Stale `updateCommitEntries` guard**: async loads for commit stats must be guarded by `selectedCommitHash == hash`. If the user clicks two commits quickly, the second load may arrive first; the guard prevents the first (now-wrong) result from overwriting the correct one.
- **`commitDiffStats` passes an empty `statusMap`**: files in a committed diff are always `.committed` status (gray). There is no working-tree status to overlay.
- **`commitDiffContent` includes the commit message header**: `git show` output starts with the commit message block before the diff. `InlineDiffViewController` ignores non-diff lines gracefully, so no special stripping is needed.
- **Tab ordering**: `DiffPanelTab` enum now lists `.commits` before `.changes`. COMMITS is added to `tabBarStack` first. Tab-bar buttons use low hugging/compression resistance to prevent widening the sidebar.
- **`commitsTabButton.isHidden`**: set to `true` only when all entry sources (uncommitted, all-branch, commits) are empty and `forceVisible` is false (i.e., the panel itself is hidden). When the panel is visible, COMMITS is always shown even if the "Uncommitted" row is hidden (clean working tree).
- Keyboard navigation (`↑`/`↓`) is guarded to the CHANGES tab; the key event passes through to super from COMMITS.
- `BranchCommit`, `commitLog`, and new `commitDiffStats`/`commitDiffContent` must be `public` because `GitCore` and `MagentModels` are separate Swift package targets.
- **Task generation counter prevents stale no-preserve tasks from overwriting preserve tasks**: `refreshDiffPanel` increments `diffPanelRefreshGeneration[thread.id]` before each `Task` spawn and captures the current value. The `Task` checks `diffPanelRefreshGeneration[thread.id] == capturedGeneration` inside `MainActor.run` before calling `update()`. If a newer call arrived while the git I/O was in-flight, the result is discarded. Without this, a slow initial-selection task (no-preserve, resets `activeTab`) could complete after a faster background-refresh task (preserve, keeps `activeTab`), causing the tab to reset.
- **Background refresh callers must pass `resetPagination: false`**: The three callers that use `preserveSelection: true` — `outlineViewSelectionDidChange` (same-thread path), `threadManager(_:didUpdateThreads:)` structural reload, and `agentCompletionDetected` — must also pass `resetPagination: false`. Using the default `resetPagination: true` resets the commit limit to `diffPanelCommitPageSize` (10) on every background refresh, which shrinks the fetched commit list. If the selected commit hash was beyond position 10 (because the user loaded more pages or an agent added new commits at HEAD), `hashStillExists` becomes `false` and `selectedCommitHash` is reset to `nil` — showing "Uncommitted" unexpectedly.
