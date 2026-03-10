# Settings Categories

## User-facing behavior

- App-wide preferences stay in `Settings > General`.
- Thread-focused preferences now live in `Settings > Threads`.
- `General` currently owns update controls, terminal overlay visibility toggles, and the environment-variable reference used by startup injection settings.
- `Threads` owns thread naming defaults, thread sections, startup injection fields, and the review prompt.

## What Changed In This Thread

- Added a new `Threads` sidebar category in the settings window.
- Moved thread-related controls out of the crowded `General` pane into a dedicated controller.
- Kept terminal overlay toggles and environment-variable help in `General`, with the update section at the top and environment-variable help at the bottom.

## Implementation Notes

- Category registration and the sidebar/detail controller wiring live in `Magent/Views/Settings/SettingsViewController.swift`.
- `Magent/Views/Settings/SettingsGeneralViewController.swift` is intentionally limited to app-level preferences.
- `Magent/Views/Settings/SettingsThreadsViewController.swift` owns thread-scoped preferences, and `Magent/Views/Settings/SettingsThreadsViewController+Sections.swift` owns the thread-sections table behavior.

## Gotchas

- Keep `General` and `Threads` split by user mental model, not by which `AppSettings` fields happen to sit near each other in the model.
- If a setting affects terminal chrome globally across all threads, keep it in `General` even if it is only visible from thread UI.
- Thread-sections editing logic moved with the `Threads` controller; avoid reintroducing section-table actions into `SettingsGeneralViewController`.
