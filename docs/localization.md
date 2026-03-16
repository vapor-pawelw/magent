# Localization

## Current Setup

- User-facing strings are being moved into split string catalogs under `Magent/Resources/`.
- Catalogs are grouped by domain (`AppStrings`, `CommonStrings`, `ConfigurationStrings`, `JiraStrings`, `NotificationStrings`, `SettingsStrings`, `ThreadStrings`, `UpdateStrings`) instead of one large `Localizable.xcstrings`.
- `Project.swift` enables string-catalog symbol generation with `STRING_CATALOG_GENERATE_SYMBOLS = YES` and includes all `*.xcstrings` as resources.

## Usage

- Prefer generated catalog symbols over raw string keys.
- In call sites, use the shorthand form `String(localized: .ThreadStrings.someKey)` rather than spelling out `LocalizedStringResource`.
- When an API accepts `String`, resolve the resource at the call site with `String(localized:)`.
- If an API accepts `LocalizedStringResource` directly, pass the generated symbol directly.

## Isolation Constraint

- This target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Xcode-generated string-symbol files inherit that default isolation, so generated members like `.CommonStrings.commonOk` are main-actor isolated in the `Magent` target.
- Do not call generated string symbols from `nonisolated` model/service code in this target.
- For nonisolated code, localize at the `@MainActor` UI boundary and pass plain `String` values inward only when needed.

## Clean Way To Use Symbols From Nonisolated Code

- If nonisolated code must access generated symbols directly, move the string catalogs into a separate localization target/module built with nonisolated default isolation.
- Import that module from the app target. Imported generated members keep the isolation of the module that produced them.
- Avoid hacks such as patching generated files, `MainActor.assumeIsolated`, or `nonisolated(unsafe)` wrappers around generated symbols.

## Notes From This Thread

- The old helper-based approach (`L10n.tr`) was removed.
- The current style uses generated catalog symbols directly, with split catalogs for clarity.
- A large first slice of app chrome, onboarding, notifications, update UI, and thread/tab actions now uses catalog-backed strings, but there are still many hard-coded strings left in settings, thread list UI, Prompt TOC, diff UI, and related flows.

## Remaining Untranslated Strings Snapshot

- As of 2026-03-09, a strict scan of UI/runtime code found 183 remaining hard-coded user-facing string occurrences (144 unique literal templates).
- As of 2026-03-16, three `SettingsCategory` titles (`terminal`, `appearance`, `debug`) were moved from hard-coded literals to `CommonStrings.xcstrings` entries.
- Treat counts as approximate debt snapshots; they include a few borderline items such as technical labels, placeholders like `claude`, and short diff/status labels.
- Largest remaining hotspots:
  - `Magent/Views/Settings/SettingsProjectsViewController+DetailPane.swift`
  - `Magent/Views/Settings/SettingsGeneralViewController.swift`
  - `Magent/Views/Settings/SettingsProjectsViewController+Actions.swift`
  - `Magent/Views/Settings/SettingsProjectsViewController+Sections.swift`
  - `Magent/Views/Settings/SettingsJiraViewController.swift`
  - `Magent/Views/ThreadList/ThreadCell.swift`
- If continuing the migration, start with Settings screens first; they contain the highest concentration of remaining user-visible literals.
