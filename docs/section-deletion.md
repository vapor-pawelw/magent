# Section Deletion

This thread changed how section deletion works in both global Settings and per-project section overrides.

## User-Facing Behavior

- Users can delete any non-default section from Settings.
- The current default section does not show a trash icon.
- Changing the default section on the same screen updates which row can be deleted immediately.
- Deleting a section no longer requires it to be empty first.
- The confirmation alert warns that threads in the deleted section will be moved to the current default section and shows the number of affected threads.
- Project override sections follow the same rule, including the `Inherit global` default option.

## Implementation Notes

- Global section deletion is handled in `SettingsGeneralViewController+Sections.swift`.
- Project override deletion is handled in `SettingsProjectsViewController+Sections.swift`.
- The trash icon visibility is table-row state, not static setup. Row rendering must compare each row against the effective default section every reload.
- `defaultSectionChanged()` now reloads the sections table in both settings screens so the default row's delete affordance updates immediately.
- Thread reassignment uses shared helpers in `ThreadManager+SectionOrdering.swift`:
  - `threadsAssigned(...)` computes the threads effectively belonging to a section
  - `reassignThreadsAssigned(...)` rewrites those threads to the fallback/default section before the section is removed
- IPC section deletion in `IPCCommandHandler+Sections.swift` uses the same reassignment rules so CLI deletion matches the Settings UI.

## Gotchas

- Global section deletion must not sweep up threads from projects that use custom section overrides. Those projects are out of scope for global section membership and reassignment.
- Effective membership matters more than stored `thread.sectionId`. A thread with an unknown section ID may still currently belong to the default section and therefore count toward the move warning.
- For project overrides, the undeletable row is the effective default returned by `settings.defaultSection(for:)`, not only `project.defaultSectionId`. When the project inherits global default, the inherited row must still hide the trash icon and reject deletion.
