# Sidebar Row Stability

## User-Facing Behavior

- Selecting a thread should not change the sidebar width.
- Selecting a thread should not make a multiline thread row grow or shrink.
- Task descriptions should keep the same wrapping/height while selection state changes.
- All thread rows should occupy the same visual height as the two-line description layout, even when a thread only renders one line of text.
- Pin, rate-limit, and completion markers should stay visually aligned, with pin always rightmost.

## Implementation Notes

- Keep the main split view structure stable: swap detail content inside a persistent container instead of removing and re-adding split-view items.
- Preserve the sidebar width during detail-content swaps with `SplitViewController.preserveSidebarWidthDuringContentChange(...)`.
- Route thread-row height through `ThreadCell.uniformSidebarRowHeight()` so every thread row derives the reserved two-line layout height from the cell's actual fonts, line counts, marker sizes, and vertical insets.
- Keep description text style stable for description rows (semibold) so wrapping does not change with unread-selection state transitions.
- Reserve a fixed status-marker slot in trailing row layout (14 pt) and keep pin as the rightmost marker. This prevents marker visibility toggles from changing available text width.
- Refit outline column width on sidebar-width changes (`sizeLastColumnToFit`) but avoid per-layout `noteHeightOfRows(...)` invalidation, which caused visible resize lag/flicker.

## Gotchas

- Do not key sidebar row-height math off `hasUnreadAgentCompletion` or other selection-sensitive flags unless the visible layout is guaranteed to stay identical before and after selection.
- Do not reintroduce separate "compact" and "description" thread row heights. Keeping a single measured height for all `MagentThread` rows prevents compact rows from jumping when text, selection, or marker state changes.
- A split-view width fix alone is not sufficient. The sidebar can look like it is resizing when the real bug is row-height changes or trailing-marker width churn inside cells.
