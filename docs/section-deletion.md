# Section Management (Deletion & Renaming)

## Deletion

### User-Facing Behavior

- Users can delete any non-default section from Settings.
- The current default section does not show a trash icon.
- Changing the default section on the same screen updates which row can be deleted immediately.
- Deleting a section no longer requires it to be empty first.
- The confirmation alert warns that threads in the deleted section will be moved to the current default section and shows the number of affected threads.
- Project override sections follow the same rule, including the `Inherit global` default option.

### Implementation Notes

- Global section deletion is handled in `SettingsGeneralViewController+Sections.swift`.
- Project override deletion is handled in `SettingsProjectsViewController+Sections.swift`.
- The trash icon visibility is table-row state, not static setup. Row rendering must compare each row against the effective default section every reload.
- `defaultSectionChanged()` now reloads the sections table in both settings screens so the default row's delete affordance updates immediately.
- Thread reassignment uses shared helpers in `ThreadManager+SectionOrdering.swift`:
  - `threadsAssigned(...)` computes the threads effectively belonging to a section
  - `reassignThreadsAssigned(...)` rewrites those threads to the fallback/default section before the section is removed
- IPC section deletion in `IPCCommandHandler+Sections.swift` uses the same reassignment rules so CLI deletion matches the Settings UI.

### Gotchas

- Global section deletion must not sweep up threads from projects that use custom section overrides. Those projects are out of scope for global section membership and reassignment.
- Effective membership matters more than stored `thread.sectionId`. A thread with an unknown section ID may still currently belong to the default section and therefore count toward the move warning.
- For project overrides, the undeletable row is the effective default returned by `settings.defaultSection(for:)`, not only `project.defaultSectionId`. When the project inherits global default, the inherited row must still hide the trash icon and reject deletion.

---

## Renaming

### User-Facing Behavior

- **Sidebar**: Double-click a section name to enter inline rename mode; right-clicking a section header shows a "Rename Section" context menu item.
- **Settings → Threads**: Double-click any section name in the sections table to edit it inline.
- **Settings → Projects**: Double-click any section name in the per-project sections table to edit it inline.
- In all inline-rename surfaces: Enter confirms, Escape cancels (restores original name).
- Empty names and duplicate names (case-insensitive) are rejected with an error alert/banner.

### Implementation Notes

**Sidebar (`ThreadListViewController`)**
- `outlineViewDoubleClicked(_:)` detects double-click on the section name hit area (via `sectionHeaderHitArea(_:)`) and calls `beginRenamingSection(...)`.
- A single-click on a section header is deliberately debounced (`scheduleSectionNameToggle`) so the first click of a double-click does not toggle section expand/collapse. The pending toggle is cancelled when a double-click is confirmed.
- Active drag sessions now suppress section/project header disclosure entirely, so dragging a thread across the sidebar cannot expand/collapse headers until the pointer is released and the next real click occurs.
- `activeSectionRename` tuple (`projectId`, `sectionId`, `originalName`) tracks the in-progress rename. Row rendering shows an inline `NSTextField` (identified by `sectionInlineRenameFieldIdentifier`) in place of the static label when `activeSectionRename` matches.
- `finishSectionRename(commit:)` validates and persists via `persistSectionRename(...)`, posts `magentSectionsDidChange` on success, or shows a banner on failure and re-focuses the field.
- `persistSectionRename(...)` handles both project-scoped sections (`settings.projects[i].threadSections`) and global sections (`settings.threadSections`) with duplicate-name guards.

**Settings → Threads (`SettingsThreadsViewController+Sections.swift`)**
- `sectionTableDoubleClicked(_:)` / `beginInlineRename(for:)` / `finishInlineRename(commit:)` implement the same pattern.
- Active rename tracked by `activeInlineRenameSectionId`.
- Cell layout embeds a hidden `NSTextField` (tag `sectionInlineRenameFieldTag = 104`) alongside the label (tag `sectionNameLabelTag = 103`). The active rename row swaps visibility between them.

**Settings → Projects (`SettingsProjectsViewController+TableDelegate.swift`)**
- Mirror of the Threads settings implementation, using tags 203/204 and `projectSortedSections` state.
- After a successful rename, also calls `refreshDefaultSectionPopup(for:)` so the default section popup stays in sync.

### Gotchas

- The sidebar uses `NSUserInterfaceItemIdentifier` to identify the inline rename field (not integer tags), matching the existing pattern in that file.
- The single-click toggle debouce key (`sectionToggleKey(projectId:sectionId:)`) must be cancelled before starting a rename so the section doesn't collapse immediately after the rename field appears.
- Keep drag-session gating at the outline-view layer as well as the section-name toggle path. Project headers can still auto-disclose through AppKit unless `shouldExpandItem` / `shouldCollapseItem` are blocked during drag.
- Rename persistence reads fresh settings from disk (`persistence.loadSettings()`) rather than the in-memory copy to avoid clobbering concurrent mutations.
