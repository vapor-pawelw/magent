# Local SwiftPM Modules

This repo now uses a local SwiftPM package at `Packages/MagentModules` for shared non-UI code.

## Current target graph

- `MagentCore`
  - app-facing facade target; re-exports the internal package targets used by the app
- `MagentModels`
  - shared domain models and DTOs
- `ShellInfra`
  - shell execution and quoting primitives
- `GitCore`
  - git/worktree services
- `TmuxCore`
  - tmux session services and naming
- `JiraCore`
  - Jira/acli integration
- `IPCCore`
  - IPC request/response contracts and agent guidance text
- `PersistenceCore`
  - JSON/file-backed persistence with schema versioning, startup validation, and write-blocking for corrupted files
- `UtilityCore`
  - remaining shared non-UI helpers
- `GhosttyBridge`
  - SwiftPM wrapper around `Libraries/GhosttyKit.xcframework`

## What changed in the `local-spm-modules` thread

- Moved shared models, services, and utilities out of the app target into `Packages/MagentModules`.
- Replaced the old Tuist `GhosttyBridge` target with a local package product.
- Narrowed the app target source list in `Project.swift` so AppKit UI, `ThreadManager`, update flow, banners, and IPC server/handler orchestration stay in the app target.
- Split the initial `MagentCore` package target into focused internal targets, while keeping `MagentCore` as the only package product the app imports.

## Why the split stops here for now

The app target still owns most AppKit UI because that code depends heavily on:

- generated asset symbols such as `NSColor(resource: .textSecondary)`
- generated string-catalog symbols such as `String(localized: .ThreadStrings...)`

Those generated APIs are tied to the app target/resources. Moving AppKit views/controllers into package targets without first introducing package-safe theme/localization wrappers creates unnecessary friction.

## Gotchas

- Keep `MagentCore` as a facade target. It is intentionally thin and should mainly re-export lower-level internal targets so the app does not need a long import list.
- When creating a new internal package target, declare its dependencies explicitly in `Packages/MagentModules/Package.swift`. Xcode's dependency scanner will warn if a target relies on a transitive import by accident.
- Most package types needed `public` visibility once they crossed target boundaries. If a refactor starts failing with "initializer is inaccessible due to internal protection level", check model/value type initializers first.
- `GhosttyBridge/ImGuiShims.c` is now part of the package target. If Ghostty bridge sources move again, keep that C shim with the bridge target or the link can fail.
- After changing package target membership or moving Swift files between targets, run:

```bash
mise x -- tuist install
mise x -- tuist generate --no-open
mise x -- tuist build Magent
```

## Good next steps

- Extract pure thread-domain logic out of `ThreadManager` into package targets, leaving the app target with orchestration and UI-facing glue.
- Introduce theme/localization wrapper APIs if you want to move AppKit feature UI into SwiftPM targets later.
