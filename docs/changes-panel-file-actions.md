# Changes Panel File Actions

## User Behavior

- In the sidebar `CHANGES` panel, single-clicking a file still selects it and opens the inline diff viewer for that path.
- Added directories in the `CHANGES` panel now render with a folder icon, a trailing slash in the label, and a full-path tooltip on hover so they are easier to distinguish from files.
- The `CHANGES` panel `ⓘ` legend popover keeps consistent padding around every row instead of letting the first rows sit flush against the popover edge.
- Selecting inline diff text now supports the standard `Cmd+C` shortcut and copies the selected text to the macOS clipboard.
- Left-clicking an image preview inside the inline diff opens a larger overlay above the full thread view with a darkened background; clicking anywhere or pressing Escape dismisses it.
- Double-clicking a file opens the file with the system default macOS app.
- Right-clicking a file opens a context menu with `Copy Filename`, `Show in Finder`, and (for non-committed files) `Stage`, `Unstage`, or `Discard Changes`. Directory rows also show the stage/unstage/discard options when applicable. The `DiffFileRowView.workingStatus` property is set from `FileDiffEntry.workingStatus` in `makeEntryRow`; stage/unstage calls `GitService.shared.stageFile`/`unstageFile` then fires `onRefreshRequested` to reload the panel. Discard prompts a warning alert first, then uses `GitService.shared.discardFile(...)` to reset tracked paths or remove untracked paths. On success, the file is removed from the list immediately via `optimisticallyRemoveFile(path:)` before the async git refresh runs — so the row disappears without waiting for the next refresh cycle. The async refresh still follows to confirm final state, and if a manual refresh is already running the discard queues one follow-up pass so the panel does not stay stale.

## Implementation Notes

- File rows display the filename first (in status color, 11pt) followed by the directory path (gray, 10pt, smaller). Directory path is truncated from the leading side with `…` if the total exceeds 50 characters, prioritizing filename visibility. Truncation mode is `byTruncatingTail` so the filename is always visible.
- Row interactions are implemented in `Magent/Views/ThreadList/DiffPanelView.swift` (`DiffFileRowView` + `DiffPanelView` callbacks).
- The panel needs the selected thread's `worktreePath` to resolve `FileDiffEntry.relativePath` into a real file URL; this is passed from `ThreadListViewController+SidebarActions.refreshDiffPanel(for:)`.
- File entries from `parseDiffEntries` are sorted by `FileWorkingStatus.sortOrder` (untracked 0 → unstaged 1 → staged 2 → committed 3), then alphabetically by `relativePath` within each group. This applies to all views: commit detail, uncommitted, and ALL CHANGES.
- `GitService` diff/status commands force `core.quotePath=false` so sidebar entries use stable, unquoted relative paths even when filenames contain spaces or other characters Git would C-escape by default.
- Opening files uses `NSWorkspace.shared.open(url)`.
- Revealing files in Finder uses `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Missing files (for example deleted paths still listed in diff stats) show a warning banner instead of failing silently.
- Discard is only available for rows whose `workingStatus` is not `.committed`. Tracked staged/unstaged rows are reset to `HEAD` with `git restore --staged --worktree`; untracked rows are removed with `git clean -fd`. Committed rows intentionally have no discard action.
- Directory detection is UI-side in `DiffPanelView`: treat a path as a directory when it ends in `/` or resolves to a directory under the selected worktree path. Untracked directory rows can otherwise look identical to files because Git status reports them as plain paths.
- Image zoom is implemented as a separate overlay in `ThreadDetailViewController+DiffViewer.swift`, not by resizing the inline diff section. `InlineDiffViewController` only forwards click events from image views upward.
- The legend popover in `DiffPanelView.makeLegendViewController()` should use explicit container-to-stack inset constraints for padding. Relying on `NSStackView.edgeInsets` alone can render inconsistently in AppKit popovers.

## Scroll-sync: CHANGES tab follows diff viewer

When the inline diff viewer is open, the CHANGES tab selection automatically tracks the file shown in the sticky header as the user scrolls. This is one-directional: scrolling the diff updates the sidebar selection; clicking a file in the sidebar still scrolls the diff to that file as before.

**Implementation**: `InlineDiffViewController.applyStickyHeader(_:)` posts `magentDiffViewerScrolledToFile` (with `filePath` in userInfo) only when the sticky section actually changes (identity comparison on `currentStickySection`). `DiffPanelView` observes this via a selector-based `addObserver` and calls `syncSelectionFromDiffViewer(filePath:)`, which only updates the two affected rows (deselect previous, select new) rather than iterating all rows — avoiding layer thrashing on large diffs. `scrollToVisible` is intentionally not called from this path because triggering file-list scroll during diff scroll causes layout jank.

**Gotcha**: Use the selector-based `addObserver(_:selector:name:object:)` form rather than the closure-based `addObserver(forName:object:queue:using:)` form. The closure form stores a non-Sendable `NSObjectProtocol` token that cannot be accessed from a nonisolated `deinit`, and the closure itself requires `MainActor.assumeIsolated` to call `@MainActor`-isolated methods. The selector form sidesteps both issues.

## Gotcha

- Right-click selection must not call the same path as left-click selection. Left-click posts `magentShowDiffViewer`, while right-click should only update row highlight and show the menu. This avoids unexpectedly opening/changing the inline diff while using context actions.
- Directory rows must not post `magentShowDiffViewer`. Main-thread working-tree status can surface newly added directories that have no meaningful unified diff target, so the row should stay Finder-oriented instead of pretending it is a file diff anchor.
- Rename paths from `git diff --numstat` can use brace syntax (for example `src/{old => new}.swift`) that does not match patch headers (`src/new.swift`). Normalize to the new/current path before wiring `FileDiffEntry.relativePath` into viewer scroll/expand lookups.
- Inline diff section identity must come from normalized patch metadata (`rename to`, `+++`, `---`, or parsed `diff --git` tokens). Do not derive it by splitting raw headers on the literal string `" b/"`, because quoted paths, binary diffs, and filenames containing that substring can make the viewer expand the wrong file.
- When scrolling to a section after `expandFile`, always call `view.layoutSubtreeIfNeeded()` before reading section frame coordinates. AppKit's layout cycle runs asynchronously, so frames inside a `DispatchQueue.main.async` block can still be zero or stale (fresh creation) or reflect pre-toggle constraint state (existing viewer). Without the forced layout pass, `section.convert(bounds, to: sectionsStackView)` returns wrong coordinates and the scroll always lands at the wrong file. Use `view` (not just `sectionsStackView`) so that `viewDidLayout` fires and `updateContentWidth` sets correct text heights before the scroll target is computed.
- When revealing a diff section by rect, call `scrollToVisible` on the document view (`sectionsStackView`), not on `scrollView.contentView`. The section rect is converted into document-view coordinates, and asking the clip view to reveal that rect mixes coordinate spaces and can leave the viewer on the wrong file.
- Image diff sections must recompute their height whenever the inline diff viewport width changes. A one-time size calculation based on initial bounds can leave only the top of the image visible after layout settles. Cap rendered height against the visible diff pane (instead of letting it scale to the image's full width-fit height) so very tall assets do not turn into multi-screen previews.
- Keep image enlargement separate from inline image sizing. Changing section height on click would perturb the `expandFile`/`scrollToVisible` geometry used by `CHANGES` file selection; the overlay approach preserves section frames so scroll-to-file keeps landing on the correct diff block.
- The zoom overlay should attach to the window content view when available, not the diff view itself, so the dimmed backdrop covers the rest of the app and the animation can expand from the tapped image into full-window coordinates.
- Inline diff text blocks should use a dedicated `NSTextView` subclass that claims first responder on mouse selection and handles `Cmd+C` locally when text is selected. Relying on the surrounding view hierarchy to route `copy:` is brittle because the thread detail view also hosts terminal surfaces with their own keyboard handling.
