# Changes Panel File Actions

## User Behavior

- In the sidebar `CHANGES` panel, single-clicking a file still selects it and opens the inline diff viewer for that path.
- The `CHANGES` panel `ⓘ` legend popover keeps consistent padding around every row instead of letting the first rows sit flush against the popover edge.
- Selecting inline diff text now supports the standard `Cmd+C` shortcut and copies the selected text to the macOS clipboard.
- Left-clicking an image preview inside the inline diff opens a larger overlay above the full thread view with a darkened background; clicking anywhere or pressing Escape dismisses it.
- Double-clicking a file opens the file with the system default macOS app.
- Right-clicking a file opens a context menu with `Show in Finder`.

## Implementation Notes

- Row interactions are implemented in `Magent/Views/ThreadList/DiffPanelView.swift` (`DiffFileRowView` + `DiffPanelView` callbacks).
- The panel needs the selected thread's `worktreePath` to resolve `FileDiffEntry.relativePath` into a real file URL; this is passed from `ThreadListViewController+SidebarActions.refreshDiffPanel(for:)`.
- `GitService` diff/status commands force `core.quotePath=false` so sidebar entries use stable, unquoted relative paths even when filenames contain spaces or other characters Git would C-escape by default.
- Opening files uses `NSWorkspace.shared.open(url)`.
- Revealing files in Finder uses `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Missing files (for example deleted paths still listed in diff stats) show a warning banner instead of failing silently.
- Image zoom is implemented as a separate overlay in `ThreadDetailViewController+DiffViewer.swift`, not by resizing the inline diff section. `InlineDiffViewController` only forwards click events from image views upward.
- The legend popover in `DiffPanelView.makeLegendViewController()` should use explicit container-to-stack inset constraints for padding. Relying on `NSStackView.edgeInsets` alone can render inconsistently in AppKit popovers.

## Gotcha

- Right-click selection must not call the same path as left-click selection. Left-click posts `magentShowDiffViewer`, while right-click should only update row highlight and show the menu. This avoids unexpectedly opening/changing the inline diff while using context actions.
- Rename paths from `git diff --numstat` can use brace syntax (for example `src/{old => new}.swift`) that does not match patch headers (`src/new.swift`). Normalize to the new/current path before wiring `FileDiffEntry.relativePath` into viewer scroll/expand lookups.
- Inline diff section identity must come from normalized patch metadata (`rename to`, `+++`, `---`, or parsed `diff --git` tokens). Do not derive it by splitting raw headers on the literal string `" b/"`, because quoted paths, binary diffs, and filenames containing that substring can make the viewer expand the wrong file.
- When scrolling to a section after `expandFile`, always call `view.layoutSubtreeIfNeeded()` before reading section frame coordinates. AppKit's layout cycle runs asynchronously, so frames inside a `DispatchQueue.main.async` block can still be zero or stale (fresh creation) or reflect pre-toggle constraint state (existing viewer). Without the forced layout pass, `section.convert(bounds, to: sectionsStackView)` returns wrong coordinates and the scroll always lands at the wrong file. Use `view` (not just `sectionsStackView`) so that `viewDidLayout` fires and `updateContentWidth` sets correct text heights before the scroll target is computed.
- When revealing a diff section by rect, call `scrollToVisible` on the document view (`sectionsStackView`), not on `scrollView.contentView`. The section rect is converted into document-view coordinates, and asking the clip view to reveal that rect mixes coordinate spaces and can leave the viewer on the wrong file.
- Image diff sections must recompute their height whenever the inline diff viewport width changes. A one-time size calculation based on initial bounds can leave only the top of the image visible after layout settles. Cap rendered height against the visible diff pane (instead of letting it scale to the image's full width-fit height) so very tall assets do not turn into multi-screen previews.
- Keep image enlargement separate from inline image sizing. Changing section height on click would perturb the `expandFile`/`scrollToVisible` geometry used by `CHANGES` file selection; the overlay approach preserves section frames so scroll-to-file keeps landing on the correct diff block.
- The zoom overlay should attach to the window content view when available, not the diff view itself, so the dimmed backdrop covers the rest of the app and the animation can expand from the tapped image into full-window coordinates.
- Inline diff text blocks should use a dedicated `NSTextView` subclass that claims first responder on mouse selection and handles `Cmd+C` locally when text is selected. Relying on the surrounding view hierarchy to route `copy:` is brittle because the thread detail view also hosts terminal surfaces with their own keyboard handling.
