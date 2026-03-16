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
  - line 3 (PR / `prSubtitleLabel`): PR/MR display label when a pull request is linked; hidden otherwise
- All thread rows have the same uniform height regardless of whether secondary/PR lines are populated; the three-row vertical stack is center-aligned in the row and rows without content on lower lines will have a little extra vertical padding.
- Section headers and the main-thread labels share the same leading text rail.
- Threads inside sections keep their extra indentation level relative to top-level rows.
- Project separators sit closer to the following repo name, while the first repo still keeps a visible gap from the very top of the sidebar.
- All sidebar elements (thread status markers, section disclosure buttons, project `+` button, separators) share a consistent trailing-edge inset controlled by `sidebarTrailingInset`.

## Implementation Notes

- Shared rails live in `ThreadListViewController`:
  - `projectSpacerDividerLeadingInset` is the base left rail for separators.
  - `sidebarRowLeadingInset` reuses that rail for section dots, main-row accent bar, and top-level thread geometry.
  - `projectHeaderTitleLeadingInset` is the slightly inset text rail used by repo titles.
  - `sidebarTrailingInset` is the single trailing-edge constant used by all sidebar elements: thread marker stack, text-only trailing fallback, section disclosure button, project `+` button, and separators. `projectDisclosureTrailingInset` and `projectSpacerDividerTrailingInset` both derive from it.
- `ThreadListViewController+DataSource.swift` uses `threadLeadingOffset(for:in:)` to cancel AppKit outline indentation for level-1 rows while preserving extra indentation for threads nested inside sections.
- `ThreadCell` owns the main-row accent bar and toggles it only for `configureAsMain(...)`.
- The main-thread leading stack uses `detachesHiddenViews = true` so hiding the row icon does not leave phantom horizontal spacing.

## Gotchas

- Do not treat AppKit outline indentation as the final visual layout. `NSOutlineView` still applies its own level offset before the cell's constraints run, so top-level rows need explicit compensation.
- Keep the main-row accent bar aligned to `sidebarRowLeadingInset - outlineIndentationPerLevel`; otherwise it drifts away from the section-dot rail.
- If you change the main-row copy again, preserve the two-line structure unless you also revisit `heightOfRowByItem`.
- The uniform row height formula in `ThreadCell.uniformSidebarRowHeight` reserves space for `maxDescriptionLines` of description font plus **2** metadata lines (secondary + PR). If you add a fourth line you must update that formula accordingly.
- `prSubtitleLabel` lives inside `prRow` (a horizontal `NSStackView` with a fixed-width transparent spacer matching the dirty-dot width, to align its text with `subtitleLabel`). Hiding `prSubtitleLabel` does not collapse `prRow` because `verticalStack.detachesHiddenViews` is false — the row simply shows invisible content. This is intentional: the uniform height already budgets for the line.
- Never merge branch/worktree and PR into one secondary line. The PR label belongs exclusively on line 3 (`prSubtitleLabel`).
- Top spacing before the first repo row is driven by `scrollViewTopConstraint` / `sidebarTopInset`, not by `NSScrollView.contentInsets`.
