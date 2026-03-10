# Sidebar Row Stability

## User-Facing Behavior

- Selecting a thread should not change the sidebar width.
- Selecting a thread should not make a multiline thread row grow or shrink.
- Task descriptions should keep the same wrapping/height while selection state changes.
- All thread rows should occupy the same visual height as the two-line description layout, even when a thread only renders one line of text.
- Pin, rate-limit, and completion markers should stay visually aligned, with pin always rightmost.
- Periodic sidebar refreshes should not scroll the thread list back to the top while the user is reading older rows.

## Implementation Notes

- Keep the main split view structure stable: swap detail content inside a persistent container instead of removing and re-adding split-view items.
- Preserve the sidebar width during detail-content swaps with `SplitViewController.preserveSidebarWidthDuringContentChange(...)`.
- Route thread-row height through `ThreadCell.uniformSidebarRowHeight()` so every thread row derives the reserved two-line layout height from the cell's actual fonts, line counts, marker sizes, and vertical insets.
- Keep description text style stable for description rows (semibold) so wrapping does not change with unread-selection state transitions.
- Reserve a fixed status-marker slot in trailing row layout (14 pt) and keep pin as the rightmost marker. This prevents marker visibility toggles from changing available text width.
- Refit outline column width on sidebar-width changes (`sizeLastColumnToFit`) but avoid per-layout `noteHeightOfRows(...)` invalidation, which caused visible resize lag/flicker.
- `ThreadListViewController.reloadData()` rebuilds the full outline tree during periodic thread/session refreshes, so it must capture and restore the `NSScrollView` clip-view origin around `outlineView.reloadData()` to preserve browsing position.

## Gotchas

- Do not key sidebar row-height math off `hasUnreadAgentCompletion` or other selection-sensitive flags unless the visible layout is guaranteed to stay identical before and after selection.
- Do not reintroduce separate "compact" and "description" thread row heights. Keeping a single measured height for all `MagentThread` rows prevents compact rows from jumping when text, selection, or marker state changes.
- A split-view width fix alone is not sufficient. The sidebar can look like it is resizing when the real bug is row-height changes or trailing-marker width churn inside cells.
- Reloading the outline without restoring scroll position will look like a spontaneous jump-to-top bug, especially because session-monitor updates fire every few seconds even when the user is not interacting with the sidebar.
- **Trailing icons can appear flush to the edge on first launch** — this is a transient initial-layout-pass timing issue (frames settle on first resize) and not a constraint logic bug. It does not recur after the first sidebar resize or window layout pass. Do not mistake it for a regression introduced by unrelated changes to views anchored below the outline view (e.g. `DiffPanelView`).
- **Do not constrain `DiffPanelView`'s internal `stackView` to `scrollView.contentView` anchors** — the clip-view frame is managed internally by `NSScrollView` and mixing auto layout constraints into that chain causes the outline view's trailing markers to momentarily snap to the wrong position and fail to track sidebar resize drag. Constrain to the `scrollView` frame anchors instead (leading/trailing), and use `.defaultLow` horizontal compression resistance on any variable-width labels inside document-view rows to prevent them from pushing the scroll view wider.
