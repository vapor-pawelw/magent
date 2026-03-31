# Section Management (Deletion & Renaming)

## Deletion

### User-Facing Behavior

- Users can delete any non-default section from Settings **or from the sidebar right-click context menu**.
- The current default section does not show a trash icon in Settings and is rejected in the sidebar menu with a banner.
- Changing the default section on the same screen updates which row can be deleted immediately.
- Deleting a section no longer requires it to be empty first.
- Empty sections (0 threads) are deleted immediately without any confirmation dialog.
- Non-empty sections show a confirmation alert warning that threads will be moved to the current default section, with the number of affected threads.
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

## Section Assignment at Thread Creation

### User-Facing Behavior

- The "New Thread" sheet includes a **Section picker** row (same label+popup style as the Project picker), shown whenever the target project has sections enabled and at least one visible section.
- The picker pre-selects the project's **default section** (resolved via `AppSettings.defaultSection(for:)` — project override → inherited global default → first visible section).
- Each item shows a **colored dot** (10 pt circle, using `colorDotImage`) to the left of the section name, matching the dot appearance in sidebar section headers.
- When the **Project picker** changes, the Section picker rebuilds immediately to show the correct sections for the newly selected project, and hides if that project has sections disabled.
- If sections are disabled for a project (`shouldUseThreadSections` returns false) or the project has no visible sections, the Section picker row is hidden entirely.

### Implementation Notes

- `AgentLaunchSheetConfig` carries `sectionsByProjectId: [UUID: [ThreadSection]]` and `defaultSectionIdByProjectId: [UUID: UUID]`, populated in `presentNewThreadSheet` by iterating `settings.projects`.
- `AgentLaunchSheetResult` carries `selectedSectionId: UUID?`.
- `populateSectionPicker(for:)` rebuilds picker items and toggles `sectionPickerRow?.isHidden` based on whether the project has entries in `sectionsByProjectId`.
- The selected section ID flows through `ThreadListViewController.createThread(requestedSectionId:)` → `ThreadManager.createThread(requestedSectionId:)`, where it overrides `settings.defaultSection(for:)` for both the pending thread (phase 1) and the final thread (phase 2).

### Gotchas

- `section.color` is `@MainActor` on `ThreadSection`. Calling it from AppKit UI setup (which always runs on the main thread) is safe, but care must be taken if this code is ever moved to a background context.
- The section picker row is created unconditionally during `setupUI` for `newThread` scope, then hidden/shown by `populateSectionPicker`. This means the row exists in the stack even when empty — always check `sectionPickerRow?.isHidden` state rather than whether the view is in the stack.

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

---

## Keep Alive (Shield)

### User-Facing Behavior

- Right-click a section header → "Keep Alive" / "Remove Keep Alive" toggles section-level eviction protection.
- When enabled, a cyan shield icon (`shield.righthalf.filled`, 12×12) appears in the section header between the name/badge and the disclosure button.
- All threads in a keep-alive section are protected from idle auto-eviction and manual session cleanup, regardless of per-thread or per-session keep-alive markers.
- Enabling keep-alive on a section immediately recovers any dead or evicted sessions in that section's threads.

### Implementation Notes

- `ThreadSection.isKeepAlive: Bool` is persisted in settings JSON, backward-compatible (defaults to `false` via `decodeIfPresent`).
- `SidebarSection.isKeepAlive` mirrors the model value and is set when building sidebar data in `ThreadListViewController`.
- `ThreadManager.toggleSectionKeepAlive(projectId:sectionId:)` in `ThreadManager+SessionCleanup.swift` handles the toggle, respecting project-override vs global section routing.
- Eviction protection is checked in two places:
  - `ThreadManager+IdleEviction.swift` pre-computes a flat `Set<UUID>` of keep-alive section IDs from both global and project-level sections for efficient per-session lookup.
  - `ThreadManager+SessionCleanup.isSessionProtected(_:in:settings:)` uses `settings.sections(for:)` per-thread for manual cleanup protection.
- `IPCSectionInfo.isKeepAlive` exposes the flag in CLI `list-sections` output.
- Posts both `.magentSectionsDidChange` (triggers sidebar `reloadData()`) and `.magentKeepAliveChanged` (with `sectionId` in userInfo).

### Gotchas

- `isSessionProtected` has two overloads: a convenience one that loads settings internally (for single-call sites) and a `settings:`-parameterized one (for loops). Always use the parameterized version in tight loops (`collectCleanupCandidates`, `cleanupIdleSessions`, `protectedSessionCount`) to avoid N×M JSON deserialization.
- Section-level keep-alive is independent of thread-level keep-alive. A thread can have its own keep-alive toggled off while still being protected by section-level keep-alive. The thread cell shield icon only reflects thread-level state; section-level protection is indicated by the section header shield.
- `toggleSectionKeepAlive` routes writes to project override or global sections using the same pattern as section deletion/rename: check `settings.projects[i].threadSections != nil`. A global section ID passed for a project with overrides is a silent no-op — the project's section list is authoritative.
