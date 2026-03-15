# Settings Categories

## User-facing behavior

- App-wide preferences stay in `Settings > General`.
- Terminal-specific preferences now live in `Settings > Terminal`.
- Thread-focused preferences now live in `Settings > Threads`.
- `General` currently owns update controls, archive defaults, and the environment-variable reference used by startup injection settings.
- `Terminal` owns app/terminal light-dark appearance, the "Don't override agent color theme" toggle, Ghostty mouse-wheel override behavior, and terminal overlay visibility toggles.
- `Threads` owns thread naming defaults, thread sections, recently archived thread restore history, startup injection fields, and the review prompt.
- Section color editing now reuses a single system color picker per settings screen, so switching to another section keeps the earlier section's custom dot color intact instead of resetting it.
- Debug-only features may still appear in Settings during local development, but they should be clearly annotated with `Debug builds only` and fully hidden from release builds.
- A dedicated `Debug` sidebar category exists in debug builds only (`#if DEBUG`). It currently exposes "Reset Onboarding State" (clears `isConfigured` and offers to relaunch) and "Relaunch App". Add new developer utilities here rather than sprinkling ad-hoc debug actions into other panes.

## What Changed In Recent Threads

### Debug category (improve-onboarding thread)
- Added a `Debug` sidebar category visible only in `#if DEBUG` builds: `SettingsDebugViewController.swift`.
- Actions: "Reset Onboarding State" (clears `isConfigured`, offers immediate relaunch) and "Relaunch App".
- Wired into `SettingsSplitViewController` with `#if DEBUG` guards on the VC declaration, `setupDetailContainer`, and `showCategoryContent`.

### Settings categories split (previous thread)
- Added a new `Threads` sidebar category in the settings window.
- Added a new `Terminal` sidebar category in the settings window.
- Moved thread-related controls out of the crowded `General` pane into a dedicated controller.
- Moved terminal overlay toggles out of `General` and into `Terminal`, alongside appearance and wheel-behavior controls.
- Added one shared appearance setting that drives both AppKit chrome and the embedded Ghostty terminal.
- Tightened section color picker ownership in both section editors so only one shared picker is active and changing focus between rows does not write the new color back into the previously edited section.
- Added a `Recently Archived` card to `Settings > Threads` that lists up to 10 archived threads and provides inline restore actions.

## Implementation Notes

- Category registration and the sidebar/detail controller wiring live in `Magent/Views/Settings/SettingsViewController.swift`.
- `Magent/Views/Settings/SettingsGeneralViewController.swift` is intentionally limited to app-level preferences.
- `Magent/Views/Settings/SettingsTerminalViewController.swift` owns terminal-scoped preferences and posts `magentSettingsDidChange` so open windows update immediately.
- `Magent/Views/Settings/SettingsThreadsViewController.swift` owns thread-scoped preferences, and `Magent/Views/Settings/SettingsThreadsViewController+Sections.swift` owns the thread-sections table behavior.
- The recently archived list reads from persisted threads, sorts by `archivedAt`, and listens for a shared archive-state notification so it refreshes while Settings is open.
- Project overrides use the parallel section editor in `Magent/Views/Settings/SettingsProjectsViewController.swift` and `Magent/Views/Settings/SettingsProjectsViewController+Sections.swift`.
- Both section editors use `NSColorPanel.shared`, so they must set the active `sectionId` and temporarily detach target/action before assigning `panel.color`, then restore the callback after the programmatic update.
- App appearance is applied centrally from `AppDelegate`: `NSApp.appearance` controls the AppKit chrome, and Ghostty receives the matching light/dark preference through `GhosttyAppManager`.

## Appearance Mode Switch Gotchas

When appearance changes (`NSApp.appearance` is reassigned), CALayer `backgroundColor` and `borderColor` set as `CGColor` do **not** auto-update — they are fixed values baked in at assignment time. Views that rely on asset-catalog colors for their layer must re-resolve inside `viewDidChangeEffectiveAppearance` using:

```swift
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
        layer?.backgroundColor = NSColor(resource: .appBackground).cgColor
    }
}
```

Without `performAsCurrentDrawingAppearance`, calling `.cgColor` on a dynamic `NSColor` may resolve against the previous (wrong) appearance. See `SettingsSectionCardView` and `AppBackgroundView` (in `ThreadDetailViewController.swift`) for reference implementations.

For views whose appearance cannot be caught via `viewDidChangeEffectiveAppearance` (e.g. `NSViewController` subclasses, which do not have this hook), use a dedicated `NSView` subclass as the backing view and override the hook there.

## Gotchas

- Keep `General` and `Threads` split by user mental model, not by which `AppSettings` fields happen to sit near each other in the model.
- Terminal-visible preferences belong in `Terminal`, even when they affect all threads globally.
- Thread-sections editing logic moved with the `Threads` controller; avoid reintroducing section-table actions into `SettingsGeneralViewController`.
- `NSColorPanel.shared` is process-wide. Programmatically setting its color can synchronously fire the current action, so if you do not clear/rebind the target around that assignment, the previously edited section can absorb the new color change.
- When a feature is release-gated behind a `FEATURE_*` flag, hide its sidebar category/card entirely in release builds instead of showing disabled controls that cannot work.
- The app appearance selector is the source of truth for both AppKit and the embedded terminal. Do not add a separate terminal-only light/dark selector unless the product deliberately supports mixed chrome/terminal appearance.
- The "Don't override agent color theme" checkbox (`AppSettings.preserveAgentColorTheme`) gates three things: (1) the Claude settings JSON (`/tmp/magent-claude-hooks.json`) won't include `theme`/`terminalTheme` keys, (2) Claude won't get `TERM=screen COLORTERM=` prepended in light mode, and (3) Codex won't get `-c tui.theme="ansi"` in light mode. The Claude hooks settings cache key includes a `-notheme` suffix when the toggle is on, so the file is regenerated correctly when the setting changes between sessions.
