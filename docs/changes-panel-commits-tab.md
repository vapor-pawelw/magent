# Changes Panel — Commits Tab

## User Behavior

- The selected main thread always keeps the bottom-left sidebar panel visible, even when there are no dirty files. Its `COMMITS` tab starts with the 10 most recent `HEAD` commits, newest first.
- For non-main threads, the bottom-left sidebar panel is shown only when there are visible file entries or branch commits to show. Clean branches with no commits ahead of base hide the panel entirely.
- When a thread has one or more commits available for the panel, a `COMMITS (n)` tab appears next to `CHANGES (n)` in the bottom-left sidebar panel.
- Clicking `COMMITS` switches the panel content to a commit list, newest first. Each row shows:
  - **Short hash** (monospaced, dimmed) — left side
  - **Commit subject** — right, truncated if long
  - Tooltip with full `hash subject\nauthor · date`
- When more commits exist beyond the current page, the commit list ends with `Load More Commits`, which appends the next 10 commits.
- Clicking `CHANGES` while it is the active tab opens the inline diff viewer (existing behavior). Clicking `CHANGES` when `COMMITS` is active switches back to the file list.
- The `ⓘ` color-legend button is hidden while the `COMMITS` tab is active (it only applies to the `CHANGES` file list).

## Implementation

- `BranchCommit` struct in `Packages/MagentModules/Sources/MagentModels/GitTypes.swift` — holds `shortHash`, `subject`, `authorName`, `date`.
- `GitService.commitLog(worktreePath:baseBranch:limit:skip:)` in `Packages/MagentModules/Sources/GitCore/GitService.swift` pages non-main branch commits with `git log <base>..HEAD`.
- `GitService.recentCommitLog(worktreePath:limit:skip:)` feeds the main-thread panel from `git log HEAD`, independent of branch divergence.
- `DiffPanelView` (`Magent/Views/ThreadList/DiffPanelView.swift`) was refactored from a single `headerButton` to a `tabBarStack` with `changesTabButton` and `commitsTabButton`. Active tab is tracked by `activeTab: DiffPanelTab`. `rebuildRows()` rebuilds the `stackView` contents based on the active tab.
- `ThreadListViewController` tracks per-thread commit page size in `diffPanelCommitLimitByThreadId`, seeded at 10 and increased by 10 from `DiffPanelView.onLoadMoreCommits`.
- `refreshDiffPanel(for:)` in `ThreadListViewController+SidebarActions.swift` now fetches entries and commits in parallel (`async let`) before calling `diffPanelView.update(with:commits:hasMoreCommits:forceVisible:worktreePath:branchName:baseBranch:)`.

## Gotchas

- `commitLog` uses `git log <base>..HEAD`, not `git log --ancestry-path`, so merge commits are included. This is intentional — it mirrors what a developer would see with `git log`.
- The unit separator `\u{1F}` (ASCII Unit Separator) is used to delimit fields within each line. Using a common delimiter like `|` would break on commit subjects containing pipes.
- `BranchCommit` and `commitLog` must be `public` because `GitCore` and `MagentModels` are separate Swift package targets — the app target accesses them via `MagentCore`.
- The main thread does not use branch-relative commit history for this panel. It intentionally shows recent `HEAD` commits even when the project default branch matches the current checkout.
- When the active tab is `COMMITS` and the panel refreshes to an empty commit set, `DiffPanelView` falls back to `CHANGES` before hiding the tab.
- Keyboard navigation (`↑`/`↓` arrow keys) is guarded to only operate in the `CHANGES` tab; `keyDown` passes through to super when on the `COMMITS` tab.
