# Changes Panel File Actions

## User Behavior

- In the sidebar `CHANGES` panel, single-clicking a file still selects it and opens the inline diff viewer for that path.
- Double-clicking a file opens the file with the system default macOS app.
- Right-clicking a file opens a context menu with `Show in Finder`.

## Implementation Notes

- Row interactions are implemented in `Magent/Views/ThreadList/DiffPanelView.swift` (`DiffFileRowView` + `DiffPanelView` callbacks).
- The panel needs the selected thread's `worktreePath` to resolve `FileDiffEntry.relativePath` into a real file URL; this is passed from `ThreadListViewController+SidebarActions.refreshDiffPanel(for:)`.
- `GitService` diff/status commands force `core.quotePath=false` so sidebar entries use stable, unquoted relative paths even when filenames contain spaces or other characters Git would C-escape by default.
- Opening files uses `NSWorkspace.shared.open(url)`.
- Revealing files in Finder uses `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Missing files (for example deleted paths still listed in diff stats) show a warning banner instead of failing silently.

## Gotcha

- Right-click selection must not call the same path as left-click selection. Left-click posts `magentShowDiffViewer`, while right-click should only update row highlight and show the menu. This avoids unexpectedly opening/changing the inline diff while using context actions.
- Rename paths from `git diff --numstat` can use brace syntax (for example `src/{old => new}.swift`) that does not match patch headers (`src/new.swift`). Normalize to the new/current path before wiring `FileDiffEntry.relativePath` into viewer scroll/expand lookups.
- Inline diff section identity must come from normalized patch metadata (`rename to`, `+++`, `---`, or parsed `diff --git` tokens). Do not derive it by splitting raw headers on the literal string `" b/"`, because quoted paths, binary diffs, and filenames containing that substring can make the viewer expand the wrong file.
- When scrolling to a section after `expandFile`, always call `view.layoutSubtreeIfNeeded()` before reading section frame coordinates. AppKit's layout cycle runs asynchronously, so frames inside a `DispatchQueue.main.async` block can still be zero or stale (fresh creation) or reflect pre-toggle constraint state (existing viewer). Without the forced layout pass, `section.convert(bounds, to: sectionsStackView)` returns wrong coordinates and the scroll always lands at the wrong file. Use `view` (not just `sectionsStackView`) so that `viewDidLayout` fires and `updateContentWidth` sets correct text heights before the scroll target is computed.
