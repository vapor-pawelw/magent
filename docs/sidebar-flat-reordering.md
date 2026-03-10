# Sidebar Flat Reordering

This thread changed flat-sidebar behavior so projects whose section grouping is disabled behave like one combined section for ordering, while each thread keeps its stored section assignment for when grouping is turned back on again.

## User-Facing Behavior

- When `Group threads by sections in the sidebar` is off, regular threads in a project behave like they belong to one giant section.
- New unpinned threads are created at the bottom of the visible unpinned list, regardless of their stored section.
- Auto-reorder-on-completion moves a finished thread to the top of its visible pin group in flat mode, matching sectioned-mode semantics.
- Users can drag regular threads within a project to reorder them in flat mode.
- Dragging still respects the pinned/unpinned split used by the flat list:
  - pinned threads can only move within the pinned block
  - unpinned threads can only move within the unpinned block
- Flat-mode reordering does not rewrite the thread's stored section, so re-enabling section grouping restores the thread under its original section.

## Implementation Notes

- `ThreadListViewController.reloadData()` now renders flat projects by applying the normal thread sorter to the project's regular threads directly, instead of flattening by hidden section order first.
- `ThreadManager+SectionOrdering.swift` centralizes the distinction between:
  - section-scoped ordering when sections are enabled
  - project-wide ordering when sections are disabled
- `assignThreadToBottomOfVisiblePinGroup(...)` is used by thread creation, section moves, and pin toggles so flat-mode ordering stays consistent across lifecycle events.
- `bumpThreadToTopOfSection(...)` now uses the same project-wide ordering scope in flat mode, so agent completions rise within the visible pin group without needing to move sections.
- `ThreadListViewController+DataSource.swift` handles flat-list drops on `SidebarProject` by computing the insertion index within the visible pin group and calling `reorderThreadInVisibleProjectList(...)`.
- Persistence still uses the existing `displayOrder` field; there is still no separate flat-order storage model.

## Gotchas

- In flat mode, treat "ordering scope" and "stored section" as separate concepts. Ordering is project-wide, but `sectionId` must stay untouched unless the user explicitly moves the thread between visible sections.
- Keep flat drag validation project-scoped. Cross-project drops are not supported in the sidebar.
- Preserve the pinned/unpinned boundary in both validation and accept-drop handling, otherwise the visible flat list and persisted `displayOrder` groups diverge.
- If you reintroduce section-order flattening for hidden sections, creation/completion/manual reorder behavior will disagree again because lifecycle code now assumes flat mode is one combined section.
