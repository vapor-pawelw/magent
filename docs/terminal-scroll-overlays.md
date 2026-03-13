# Terminal Scroll Overlays

## User-facing behavior

- The terminal exposes two floating scroll affordances above the Ghostty surface:
  - a bottom-right draggable pill with page-up, page-down, and jump-to-bottom controls
  - a bottom-left `Scroll to bottom` pill that appears only after the user scrolls meaningfully away from live output
- The draggable bottom-right controls keep the shared semi-transparent idle treatment and become more opaque on hover.
- The standalone bottom-left `Scroll to bottom` pill stays fully opaque at rest, has no hover fade, and keeps an 8 pt gap between the arrow icon and label.
- Both overlays default to 48 pt of bottom clearance so they sit above the terminal edge and prompt area instead of feeling flush to the bottom.
- The standalone `Scroll to bottom` pill fades and slides in when shown, then fades and slides back out when hidden. Its visibility animation should remain smooth even if Ghostty emits repeated near-identical scrollbar updates while the pill is transitioning.

## Implementation notes

- Shared visual constants for terminal overlays live in `TerminalOverlayStyle` inside `Magent/Views/Terminal/TerminalScrollOverlayView.swift`. Keep the standalone pill and the multi-action scroll controls aligned through that shared style instead of duplicating colors/alpha values in separate views.
- The standalone pill is implemented as `TerminalScrollToBottomPillButton`, not as an ad hoc `NSButton`, so it can own its own pill geometry, explicit icon/title spacing, and content padding (`8` vertical, `16` horizontal).
- The show/hide motion for the standalone pill is animation-only: keep its Auto Layout constraints pinned to the final resting position and animate only the layer's Y translation. The current travel distance is 24 pt below the resting position.
- Visibility changes for the standalone pill should be state-gated in the controller so repeated show/hide requests do not restart the animation while the current transition is still in flight.

## Scroll-to-bottom mechanics

Both the overlay jump-to-bottom button and the FAB pill go through `scrollCurrentTerminal(.bottom)` in `ThreadDetailViewController+Actions.swift`:

1. `TmuxService.scrollToBottom()` — sends `tmux send-keys -X cancel` to exit copy-mode.
2. 80 ms sleep — allows tmux to redraw the live pane and extend Ghostty's scrollback.
3. `bindingAction("scroll_to_bottom")` on the target surface — scrolls Ghostty's own viewport to the new bottom, ensuring the live output is visible.

The Ghostty scroll **must happen after** the tmux redraw, not before. Calling it first (while still in copy-mode) causes Ghostty to land at the old "bottom" before tmux appends the fresh live-pane frame; the content then appears near the top of the viewport.

The surface is resolved by `sessionName` at execution time (via `thread.tmuxSessionNames.firstIndex(of:)`), not by the index captured before the async work, since tabs may be closed or reordered during the 80 ms delay.

## Mouse event absorption

`TerminalScrollOverlayView` overrides `mouseDown`, `mouseDragged`, and `mouseUp` with empty implementations to prevent mouse events from escaping the overlay. Without this, clicks in the inset padding around the three buttons fall through the responder chain and reach the Ghostty surface, which starts a text selection.

The `TerminalScrollToBottomPillButton` FAB does not need the same treatment because its `mouseUp` override gives AppKit a reason to track the event pair within the view, which implicitly prevents propagation.

## Gotchas

- Keep terminal overlays attached to `terminalContainer` and re-added above terminal surfaces after lazy tab creation; otherwise Ghostty's metal-backed surface can render over them. See `docs/libghostty-integration.md`.
- Avoid using constraint changes for the standalone pill's entrance/exit animation. Constraint-driven movement would couple layout state to transient animation state and can leave the pill in the wrong resting position if visibility toggles rapidly.
- Do not call `bindingAction("scroll_to_bottom")` before `TmuxService.scrollToBottom()` resolves. Ghostty's scrollback grows when tmux redraws after exiting copy-mode, so a premature Ghostty scroll anchors to a stale bottom and the fresh live-pane content ends up off-screen.
- `TerminalScrollOverlayView` must absorb mouse events (override `mouseDown/Dragged/Up` to do nothing). The NSButton children handle their own events; without absorbing container-level events the inset padding areas leak clicks to the terminal.
