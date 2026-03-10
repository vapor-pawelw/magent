# Hidden Threads

Hidden threads let users keep inactive work visible without archiving it.

## User-facing behavior

- Non-main thread context menus expose `Hide` / `Unhide` directly under `Pin` / `Unpin`.
- Hidden threads stay in the sidebar, but sort to the bottom of their section or flat project list.
- Hidden rows render dimmed so they read as deprioritized rather than active.
- Pinning and hiding are mutually exclusive:
  - pinning a hidden thread unhides it
  - hiding a pinned thread unpins it
- CLI support mirrors the UI:
  - `magent-cli hide-thread --thread <name>`
  - `magent-cli unhide-thread --thread <name>`
- IPC thread status includes `isSidebarHidden` so external tooling can reflect the same state.

## Implementation details

- Thread persistence stores the state on `MagentThread.isSidebarHidden`.
- Sidebar ordering is modeled as three explicit groups via `ThreadSidebarListState`:
  - `pinned`
  - `visible`
  - `hidden`
- Group ordering is always `pinned`, then normal visible threads, then hidden threads.
- In-section `displayOrder` remains local to a single group; reorder logic must not collapse hidden threads back into the normal unpinned group.
- New-thread placement and cross-section moves route through the same bottom-of-group helper so hidden-state behavior stays consistent after reloads and moves.

## Gotchas

- Do not treat `!isPinned` as equivalent to the normal visible group anymore. Hidden threads are also unpinned.
- Drag/drop validation must enforce all three group boundaries, not just pinned vs. unpinned.
- Main threads should never expose or accept the hidden state.
- The dimmed appearance is applied at the cell level only. Selection background still comes from the row view, which keeps the selected state legible.

## Changes in this thread

- Added persisted hidden-thread state and three-group sidebar ordering.
- Added right-click hide/unhide actions and matching CLI commands.
- Added dimmed hidden-row rendering plus IPC/doc/changelog updates.
