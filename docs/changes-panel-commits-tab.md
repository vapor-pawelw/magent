# Changes Panel — Commits Tab

## User Behavior

- When a non-main thread has **more than one commit** ahead of its base branch, a `COMMITS (n)` tab appears next to `CHANGES (n)` in the bottom-left sidebar panel.
- Clicking `COMMITS` switches the panel content to a commit list, newest first. Each row shows:
  - **Short hash** (monospaced, dimmed) — left side
  - **Commit subject** — right, truncated if long
  - Tooltip with full `hash subject\nauthor · date`
- Clicking `CHANGES` while it is the active tab opens the inline diff viewer (existing behavior). Clicking `CHANGES` when `COMMITS` is active switches back to the file list.
- The `ⓘ` color-legend button is hidden while the `COMMITS` tab is active (it only applies to the `CHANGES` file list).
- When the branch has 0 or 1 commit the `COMMITS` tab is not shown at all.

## Implementation

- `BranchCommit` struct in `Packages/MagentModules/Sources/MagentModels/GitTypes.swift` — holds `shortHash`, `subject`, `authorName`, `date`.
- `GitService.commitLog(worktreePath:baseBranch:)` in `Packages/MagentModules/Sources/GitCore/GitService.swift` — runs `git log <base>..HEAD --format=<sep-delimited> --date=short` using unit-separator `\u{1F}` to avoid collisions with commit message content.
- `DiffPanelView` (`Magent/Views/ThreadList/DiffPanelView.swift`) was refactored from a single `headerButton` to a `tabBarStack` with `changesTabButton` and `commitsTabButton`. Active tab is tracked by `activeTab: DiffPanelTab`. `rebuildRows()` rebuilds the `stackView` contents based on the active tab.
- `refreshDiffPanel(for:)` in `ThreadListViewController+SidebarActions.swift` now fetches entries and commits in parallel (`async let`) before calling `diffPanelView.update(with:commits:worktreePath:branchName:baseBranch:)`.

## Gotchas

- `commitLog` uses `git log <base>..HEAD`, not `git log --ancestry-path`, so merge commits are included. This is intentional — it mirrors what a developer would see with `git log`.
- The unit separator `\u{1F}` (ASCII Unit Separator) is used to delimit fields within each line. Using a common delimiter like `|` would break on commit subjects containing pipes.
- `BranchCommit` and `commitLog` must be `public` because `GitCore` and `MagentModels` are separate Swift package targets — the app target accesses them via `MagentCore`.
- The `COMMITS` tab is hidden (not just disabled) when commit count ≤ 1. If the active tab was `COMMITS` when an update reduces commit count to ≤ 1, the tab is auto-reset to `CHANGES` before hiding.
- Keyboard navigation (`↑`/`↓` arrow keys) is guarded to only operate in the `CHANGES` tab; `keyDown` passes through to super when on the `COMMITS` tab.
- Keep the tab-bar buttons (`changesTabButton`, `commitsTabButton`) on low horizontal hugging/compression resistance and truncate their titles. If those controls keep the default resistance, making `COMMITS (n)` visible can raise the sidebar's effective minimum width and block normal divider dragging.
