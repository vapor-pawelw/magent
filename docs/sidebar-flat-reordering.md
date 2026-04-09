# Sidebar Flat Reordering

This thread changed flat-sidebar behavior so projects whose section grouping is disabled behave like one combined section for ordering, while each thread keeps its stored section assignment for when grouping is turned back on again.

## User-Facing Behavior

- When `Group threads by sections in the sidebar` is off, regular threads in a project behave like they belong to one giant section.
- New unpinned threads are created at the bottom of the visible unpinned list, regardless of their stored section.
- Auto-reorder-on-completion moves a finished thread to the top of its visible pin group in flat mode, matching sectioned-mode semantics.
- Users can drag regular threads within a project to reorder them in flat mode.
- Drag-hovering over project or section headers while reordering does not expand/collapse them; disclosure stays click-only.
- Dragging still respects the pinned/unpinned split used by the flat list:
  - pinned threads can only move within the pinned block
  - unpinned threads can only move within the unpinned block
- The sidebar now renders a visual separator between pinned, normal, and hidden thread groups. That divider is present even when section grouping is off, but it does not change any ordering rules.
- Flat-mode reordering does not rewrite the thread's stored section, so re-enabling section grouping restores the thread under its original section.

## Implementation Notes

- `ThreadListViewController.reloadData()` now renders flat projects by applying the normal thread sorter to the project's regular threads directly, instead of flattening by hidden section order first.
- `ThreadManager+SectionOrdering.swift` centralizes the distinction between:
  - section-scoped ordering when sections are enabled
  - project-wide ordering when sections are disabled
- `assignThreadToBottomOfVisiblePinGroup(...)` is used by thread creation, section moves, and pin toggles so flat-mode ordering stays consistent across lifecycle events.
- `bumpThreadToTopOfSection(...)` now uses the same project-wide ordering scope in flat mode, so agent completions rise within the visible pin group without needing to move sections.
- `ThreadListViewController+DataSource.swift` handles flat-list drops on `SidebarProject` by computing the insertion index within the visible pin group and calling `reorderThreadInVisibleProjectList(...)`.
- `SidebarSection.items` interleaves `SidebarGroupSeparator` rows between thread groups for rendering. Section drop validation/reorder code must convert raw outline indices back to thread-only indices before comparing group boundaries or calling `reorderThread(...)`.
- `SidebarOutlineView` tracks local/destination drag state so `shouldSelectItem`, `shouldExpandItem`, and `shouldCollapseItem` can suppress header disclosure while a drag is active.
- Persistence still uses the existing `displayOrder` field; there is still no separate flat-order storage model.
- **Drag-time reload deferral**: `reloadData()` checks `SidebarOutlineView.isDragInteractionActive` at the top and returns early (setting `pendingReloadAfterDrag = true`) for background-triggered reloads that fire during a drag (e.g. tmux state polling, busy-state changes). The `draggingSession endedAt` delegate flushes the pending reload after the drag ends. Reloads triggered by `acceptDrop` itself are allowed through via the `isInsideAcceptDrop` flag, which is set for the duration of the accept-drop call.
- **Cross-project drop blocking in sectioned mode**: `validateDrop` guards section drops with `section.projectId == thread.projectId` in addition to the existing check in `validateFlatProjectDrop`. `acceptDrop` has the same guard so a malformed drop cannot move a thread across projects.

## Gotchas

- In flat mode, treat "ordering scope" and "stored section" as separate concepts. Ordering is project-wide, but `sectionId` must stay untouched unless the user explicitly moves the thread between visible sections.
- Keep flat drag validation project-scoped. Cross-project drops are not supported in the sidebar — both `validateFlatProjectDrop` (flat mode) and `validateDrop` (sectioned mode) enforce same-project checks.
- Preserve the pinned/unpinned boundary in both validation and accept-drop handling, otherwise the visible flat list and persisted `displayOrder` groups diverge.
- Do not reintroduce hover-driven disclosure while a mouse drag is active. Header expand/collapse is intentionally click-only so drag reordering does not mutate sidebar structure mid-gesture.
- If you reintroduce section-order flattening for hidden sections, creation/completion/manual reorder behavior will disagree again because lifecycle code now assumes flat mode is one combined section.
- Do not call `reloadData()` unconditionally in response to `ThreadManagerDelegate` callbacks during a drag. The drag-deferral mechanism (`pendingReloadAfterDrag` / `isInsideAcceptDrop`) must stay in place — bypassing it causes visible section expand/collapse flicker. The accept-drop path uses `isInsideAcceptDrop = true` to force through exactly the one reload it needs.
