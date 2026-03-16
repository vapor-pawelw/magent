# Section Management (Deletion & Renaming)

## Deletion

### User-Facing Behavior

- Users can delete any non-default section from Settings **or from the sidebar right-click context menu**.
- The current default section does not show a trash icon in Settings and is rejected in the sidebar menu with a banner.
- Changing the default section on the same screen updates which row can be deleted immediately.
- Deleting a section no longer requires it to be empty first.
- The confirmation alert warns that threads in the deleted section will be moved to the current default section and shows the number of affected threads.
- Project override sections follow the same rule, including the `Inherit global` default option.

### Implementation Notes

- Global section deletion is handled in `SettingsGeneralViewController+Sections.swift`.
- Project override deletion is handled in `SettingsProjectsViewController+Sections.swift`.
- **Sidebar deletion** is handled by `deleteSectionFromMenu(_:)` in `ThreadListViewController+ContextMenu.swift`. It reads fresh settings from disk, applies the same guard (count > 1, not default), reassigns threads, then writes back to either project override or global sections depending on which is active.
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
- **Sidebar deletion must route to the correct section store**: check `settings.projects[i].threadSections != nil` to determine whether to write to the project override or to `settings.threadSections`. Writing to the project index unconditionally when the project has no override would silently create a per-project copy of global sections.

---

## Adding & Color

### User-Facing Behavior

- **Sidebar**: Right-click any section header → "Add Section…" prompts for a name and inserts the new section immediately below the right-clicked section. Sections further down have their `sortOrder` shifted up by 1.
- **Sidebar**: Right-click any section header → "Change Color…" opens the system NSColorPanel. The color updates live as the slider moves (applied on each `projectSectionColorChanged` callback).
- **Sidebar**: Sections can be reordered by drag and drop directly in the sidebar. Dragging a section header within the project reorders the section by updating `sortOrder` values in settings and posting `.magentSectionsDidChange`.
- **Settings → Projects**: Color dot button in the sections table opens NSColorPanel for the same live-update flow.
- Duplicate names (case-insensitive) are rejected with a banner.

### Implementation Notes

- `addSectionFromMenu(_:)` in `ThreadListViewController+ContextMenu.swift` detects project-vs-global routing the same way as delete: `settings.projects[i].threadSections != nil`. It reads `sectionId` from the context menu's `representedObject` to find the insertion point, shifts `sortOrder` for all later sections, then inserts the new section at `insertAfterOrder + 1`.
- **Sidebar section drag & drop** is implemented in `ThreadListViewController+DataSource.swift`. `SidebarSection` items write their UUID to a custom `NSPasteboard.PasteboardType.magentSectionId` pasteboard type (separate from the `.string` type used for threads). The outline view must register both types via `registerForDraggedTypes([.string, .magentSectionId])`. `validateDrop` redirects ON-section hover proposals to the parent `SidebarProject` at the hovered section's child index, then validates that the drop falls within the section-only range of the project's children. `acceptDrop` removes the source section, inserts it at the destination, and reassigns `sortOrder` for all sections sequentially (0, 1, 2, …), routing writes to the project override or global sections as appropriate.
- `changeSectionColorFromMenu(_:)` stores the target in `contextMenuSectionColorTarget: (projectId, sectionId)?` on `ThreadListViewController`, sets `self` as NSColorPanel target/action, then brings the panel forward.
- `sectionContextMenuColorChanged(_:)` handles incremental color panel callbacks and calls `reloadData()` so the sidebar dot updates live.
- `ThreadSection.randomColorHex()` picks from `ThreadSection.colorPalette` (10 Apple system colors).

### Gotchas

- NSColorPanel is a shared singleton. Always call `panel.setTarget(nil); panel.setAction(nil)` before reassigning target/action to avoid stale callbacks firing on the wrong controller.
- **Section drag type must be registered**: `outlineView.registerForDraggedTypes` must include `.magentSectionId` in addition to `.string`. If only `.string` is registered, the OS silently rejects all section drops before `validateDrop` is ever called — the drag "works" visually but no drop target is ever accepted.
- `contextMenuSectionColorTarget` is never explicitly cleared — it is harmless if stale since `sectionContextMenuColorChanged` does nothing if the section is not found. But if the Settings color picker is opened after the sidebar picker, the Settings controller replaces the panel's target/action, so sidebar color callbacks naturally stop.

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
