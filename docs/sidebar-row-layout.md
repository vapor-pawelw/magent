# Sidebar Row Layout

This thread refined the left-rail and spacing rules for project headers, section rows, and the main thread row in the sidebar.

## User-Facing Behavior

- Project headers no longer show the accent bar.
- The `Main worktree` row now carries the accent bar instead.
- The `Main worktree` row uses:
  - line 1: `Main worktree`
  - line 2: current branch name when available
- Regular thread rows use a three-line vertical stack:
  - line 1 (primary): task description when set; otherwise the branch name
  - line 2 (secondary / `subtitleLabel`): branch · worktree when a description is shown; worktree only when no description and the worktree name differs from the branch; hidden otherwise
  - line 3 (PR/ticket row): individual `jiraTicketLabel` + `jiraStatusBadge` + dot separator + `prNumberLabel` + `prStatusBadge`, composed in a horizontal stack with `detachesHiddenViews`. Each element is independently hideable. Status badges are `StatusBadgeView` pills showing Jira status (color from API `statusCategory.key`) and PR status (Open/Draft/Merged/Closed/Approved/Changes Requested — derived from `ReviewDecision` enum and lifecycle state). Badges gated by `AppSettings.showJiraStatusBadges` / `showPRStatusBadges`. Ticket display gated by `AppSettings.jiraTicketDetectionEnabled`.
- All thread rows have the same uniform height regardless of whether secondary/PR lines are populated; the three-row vertical stack is center-aligned in the row. The icon vertically aligns to the visible lines only — when only a single line is shown, the icon is centered on that line.
- Section headers and the main-thread labels share the same leading text rail.
- Threads inside sections keep their extra indentation level relative to top-level rows.
- Project separators sit closer to the following repo name, while the first repo still keeps a visible gap from the very top of the sidebar.
- The global `Add repo` button lives in its own dedicated top row above the outline view. Sidebar content starts below that row, so project headers and thread rows never overlap the button.
- All sidebar elements (thread status markers, section disclosure buttons, project `+` button, separators) share a consistent trailing-edge inset controlled by `sidebarTrailingInset`.
- The archive icon (`archivebox.fill`) appears in the same right-aligned trailing area as the busy spinner, completion dot, and rate-limit icons. It is independent: it can show alongside the completion dot (e.g. work delivered and agent just finished). The archive icon is hidden while the agent is busy or waiting for input. Clicking the archive button must **not** select the row — `SidebarOutlineView.mouseDown` intercepts clicks that land on the archive button and fires the action directly without calling `super`, preventing NSOutlineView from processing the click as a row selection. `shouldSelectItem` also returns `false` for threads with `isArchiving == true` as a safety net.

## Implementation Notes

- Shared rails live in `ThreadListViewController`:
  - `sidebarToolbarRowHeight` reserves the dedicated top row that holds the global `Add repo` button.
  - `projectSpacerDividerLeadingInset` is the base left rail for separators.
  - `sidebarRowLeadingInset` reuses that rail for section dots, main-row accent bar, and top-level thread geometry.
  - `projectHeaderTitleLeadingInset` is the slightly inset text rail used by repo titles.
  - `sidebarTrailingInset` is the single trailing-edge constant used by all sidebar elements: thread marker stack, text-only trailing fallback, section disclosure button, project `+` button, and separators. `projectDisclosureTrailingInset` and `projectSpacerDividerTrailingInset` both derive from it.
- `ThreadListViewController+DataSource.swift` uses `threadLeadingOffset(for:in:)` to cancel AppKit outline indentation for level-1 rows while preserving extra indentation for threads nested inside sections.
- `ThreadCell` owns the main-row accent bar and toggles it only for `configureAsMain(...)`.
- The archiving overlay is owned by `AlwaysEmphasizedRowView`, not `ThreadCell`, so the tint and spinner cover the full row bounds (matching the selection highlight) including selected rows.
- `durationLabel` is a 9pt monospaced-digit `NSTextField` pinned to the bottom-right corner of the cell (3pt bottom inset, standard trailing inset). It is **not** part of the trailing marker stack — it is positioned absolutely so it sits below the center-aligned status icons. Color is `secondaryLabelColor` at 0.4 alpha. Shows the elapsed time since the last debounced busy/non-busy transition (e.g. "<1m", "5m", "2h", "3d"). A 30-second `Timer` refreshes the text while visible. Gated by `AppSettings.showBusyStateDuration` (default: true). The debounce (1 second) prevents sub-second state flickers from resetting the timestamp. `busyStateSince` is persisted across relaunches.
- The trailing marker stack is flat: `[prTF, jiraIV, archiveBtn, spinner, rateLimitIV, completionIV, pinIV]`. There is no `statusSlot` container. All items are direct children of the stack, and `detachesHiddenViews = true` handles spacing automatically. Spinner, rateLimitIV, and completionIV remain mutually exclusive (only one active-state icon at a time); archiveBtn is managed independently and can appear alongside any of them. The spinner activates on `thread.isAnyBusy` (= `hasAgentBusy || hasMagentBusy`), covering both agent working state and Magent's own setup/injection work. Tooltip reads "Setting up..." when only Magent is busy, "Agent working" otherwise. `jiraIV` is wired but currently always hidden (reserved for `FEATURE_JIRA_SYNC` debug use); ticket detection shows the key on line 3 instead.
- The main-thread leading stack uses `detachesHiddenViews = true` so hiding the row icon does not leave phantom horizontal spacing.
- `signEmojiLabel` is a bold 9pt `NSTextField` positioned just to the left of the thread icon via auto-layout (`trailingAnchor` to `imageView.leadingAnchor + 1`). It is **not** part of the horizontal stack, so it does not affect indentation or spacing. Hidden for main-thread rows and when `signEmoji` is `nil`. Sign options that define a `tintColor` (e.g. priority arrows `↑`/`↓`) apply that color to the label's `textColor`; on emphasized/selected rows, the label switches to `.white` to match the rest of the row palette. The tint color lookup is via `ThreadListViewController.signEmojiTintColor(for:)`.

## Gotchas

- When displaying branch and worktree names together (e.g. `branch · worktree`), always check for equality first — if they are the same, show the name once. `ThreadCell` and `RecentlyArchivedPopoverViewController` already do this; `SettingsThreadsViewController` was fixed to match.
- Do not treat AppKit outline indentation as the final visual layout. `NSOutlineView` still applies its own level offset before the cell's constraints run, so top-level rows need explicit compensation.
- Keep the main-row accent bar aligned to `sidebarRowLeadingInset - outlineIndentationPerLevel`; otherwise it drifts away from the section-dot rail.
- If you change the main-row copy again, preserve the two-line structure unless you also revisit `heightOfRowByItem`.
- The uniform row height formula in `ThreadCell.uniformSidebarRowHeight` reserves space for `maxDescriptionLines` of description font plus **2** metadata lines (secondary + PR). If you add a fourth line you must update that formula accordingly.
- The PR/ticket row (`prRow`) contains `[jiraTicketTF, jiraBadge, dotSep, prNumTF, prBadge]` with `detachesHiddenViews = true` and `spacing = 3`. Each element is independently hidden based on data availability and settings. `syncRowVisibility()` hides the entire row when both Jira and PR labels are hidden.
- `jiraTicketLabel` and `prNumberLabel` use `.controlAccentColor` so they stand out from secondary metadata text. Status badges use `StatusBadgeView` (8pt font in sidebar) with darkened colors for white-text legibility.
- Never merge branch/worktree and PR/ticket into one secondary line. Ticket and PR info belongs exclusively on line 3 (the PR row).
- Do not anchor the outline scroll view directly to the sidebar root view's top edge. It must stay below the dedicated toolbar row so repo/thread content cannot overlap the global `Add repo` button again.
