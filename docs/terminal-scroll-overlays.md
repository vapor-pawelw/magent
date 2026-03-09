# Terminal Scroll Overlays

## User-facing behavior

- The terminal exposes two floating scroll affordances above the Ghostty surface:
  - a bottom-right draggable pill with page-up, page-down, and jump-to-bottom controls
  - a bottom-left `Scroll to bottom` pill that appears only after the user scrolls meaningfully away from live output
- Both overlays share the same idle/hover treatment: semi-transparent at rest, more opaque on hover.
- Both overlays default to 48 pt of bottom clearance so they sit above the terminal edge and prompt area instead of feeling flush to the bottom.
- The standalone `Scroll to bottom` pill fades and slides in when shown, then fades and slides back out when hidden.

## Implementation notes

- Shared visual constants for terminal overlays live in `TerminalOverlayStyle` inside `Magent/Views/Terminal/TerminalScrollOverlayView.swift`. Keep the standalone pill and the multi-action scroll controls aligned through that shared style instead of duplicating colors/alpha values in separate views.
- The standalone pill is implemented as `TerminalScrollToBottomPillButton`, not as an ad hoc `NSButton`, so it can own its own hover tracking, pill geometry, and content padding (`8` vertical, `16` horizontal).
- The show/hide motion for the standalone pill is animation-only: keep its Auto Layout constraints pinned to the final resting position and animate only the layer's Y translation. The current travel distance is 24 pt below the resting position.

## Gotchas

- Keep terminal overlays attached to `terminalContainer` and re-added above terminal surfaces after lazy tab creation; otherwise Ghostty's metal-backed surface can render over them. See `docs/libghostty-integration.md`.
- Avoid using constraint changes for the standalone pill's entrance/exit animation. Constraint-driven movement would couple layout state to transient animation state and can leave the pill in the wrong resting position if visibility toggles rapidly.
