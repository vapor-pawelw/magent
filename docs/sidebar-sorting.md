# Sidebar Sorting

This thread added context-menu sorting for project headers and section headers in the sidebar.

## User-Facing Behavior

- Right-clicking a section header or repo header shows a `Sort` submenu.
- Sorting is available by:
  - description
  - branch name
  - priority
  - last activity
- Holding `Option` while the menu is open switches the action to descending order.
- Sorting respects the existing sidebar buckets:
  - pinned threads never move below unpinned threads
  - hidden threads stay in the hidden bucket
- Right-clicking a section sorts only that section.
- Right-clicking a repo header sorts every section in that project independently.
- When section grouping is disabled, the project behaves like one combined container for sorting.

## Implementation Notes

- Sorting rewrites `displayOrder` inside each sidebar bucket instead of flattening the bucket model.
- The section-level action only touches threads in the targeted section.
- The repo-level action iterates visible sections in project order so each section keeps its own ordering.
- `ThreadSortCriteria` is the shared criteria enum used by the context-menu actions and the thread manager helpers.

## Gotchas

- Do not sort pinned/visible/hidden threads together. The bucket split is part of the UI contract.
- Do not reorder section headers themselves when sorting the repo header. Only the threads inside each section should change order.
- Hidden threads should remain hidden even when a project-level sort is requested.
