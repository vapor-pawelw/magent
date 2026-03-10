# Settings Categories

## User-facing behavior

- App-wide preferences stay in `Settings > General`.
- Thread-focused preferences now live in `Settings > Threads`.
- `General` currently owns update controls, terminal overlay visibility toggles, and the environment-variable reference used by startup injection settings.
- `Threads` owns thread naming defaults, thread sections, startup injection fields, and the review prompt.
- Section color editing now reuses a single system color picker per settings screen, so switching to another section keeps the earlier section's custom dot color intact instead of resetting it.
- Debug-only features may still appear in Settings during local development, but they should be clearly annotated with `Debug builds only` and fully hidden from release builds.

## What Changed In This Thread

- Added a new `Threads` sidebar category in the settings window.
- Moved thread-related controls out of the crowded `General` pane into a dedicated controller.
- Kept terminal overlay toggles and environment-variable help in `General`, with the update section at the top and environment-variable help at the bottom.
- Tightened section color picker ownership in both section editors so only one shared picker is active and changing focus between rows does not write the new color back into the previously edited section.

## Implementation Notes

- Category registration and the sidebar/detail controller wiring live in `Magent/Views/Settings/SettingsViewController.swift`.
- `Magent/Views/Settings/SettingsGeneralViewController.swift` is intentionally limited to app-level preferences.
- `Magent/Views/Settings/SettingsThreadsViewController.swift` owns thread-scoped preferences, and `Magent/Views/Settings/SettingsThreadsViewController+Sections.swift` owns the thread-sections table behavior.
- Project overrides use the parallel section editor in `Magent/Views/Settings/SettingsProjectsViewController.swift` and `Magent/Views/Settings/SettingsProjectsViewController+Sections.swift`.
- Both section editors use `NSColorPanel.shared`, so they must set the active `sectionId` and temporarily detach target/action before assigning `panel.color`, then restore the callback after the programmatic update.

## Gotchas

- Keep `General` and `Threads` split by user mental model, not by which `AppSettings` fields happen to sit near each other in the model.
- If a setting affects terminal chrome globally across all threads, keep it in `General` even if it is only visible from thread UI.
- Thread-sections editing logic moved with the `Threads` controller; avoid reintroducing section-table actions into `SettingsGeneralViewController`.
- `NSColorPanel.shared` is process-wide. Programmatically setting its color can synchronously fire the current action, so if you do not clear/rebind the target around that assignment, the previously edited section can absorb the new color change.
- When a feature is release-gated behind a `FEATURE_*` flag, hide its sidebar category/card entirely in release builds instead of showing disabled controls that cannot work.
