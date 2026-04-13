# Building from Source

## Prerequisites

- **Xcode 26+**
- **[mise](https://mise.jdx.dev/)** — tool version manager (installs Tuist)
- **Zig 0.15.2** (managed via `mise`)

## Build

`Libraries/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a` is intentionally local-only and not tracked in git.

```bash
git clone git@github.com:vapor-pawelw/mAgent.git
cd magent

# Install local toolchain (tuist + zig)
mise install

# Build GhosttyKit.xcframework into Libraries/ (required for first build)
./scripts/bootstrap-ghosttykit.sh

# Generate the Xcode project
mise x -- tuist install
mise x -- tuist generate --no-open

# Build via Xcode
open Magent.xcworkspace
# Or build from command line:
xcodebuild build -workspace Magent.xcworkspace -scheme Magent -configuration Release
```

The source repository is public at `vapor-pawelw/mAgent`.

## Rebuild + Relaunch (Debug)

Use the helper script for local iteration. It always:
- rebuilds the app
- kills running `Magent` only after a successful build (single-instance safe)
- relaunches the newly built Debug app

```bash
./scripts/rebuild-and-relaunch.sh
```

Optional overrides:

```bash
MAGENT_SCHEME=Magent MAGENT_CONFIGURATION=Debug MAGENT_APP_NAME=Magent ./scripts/rebuild-and-relaunch.sh
```

## Relaunch (No Rebuild)

Use this script to kill and relaunch the existing Debug build without rebuilding.
It only triggers a build if no binary exists in DerivedData.

```bash
./scripts/relaunch.sh
```

Accepts the same `MAGENT_SCHEME`, `MAGENT_CONFIGURATION`, and `MAGENT_APP_NAME` env overrides as `rebuild-and-relaunch.sh`.

## Archive Thread Workflow Helper

Use the helper script when you want to merge the current thread branch into its base branch and then archive the thread in one flow:

```bash
./scripts/archive-current-thread.sh
```

Useful options:

```bash
# Keep main worktree clean from Local Sync copy-back
./scripts/archive-current-thread.sh --skip-local-sync

# Skip pushing base branch (local-only flow)
./scripts/archive-current-thread.sh --no-push

# Preview actions without modifying git/thread state
./scripts/archive-current-thread.sh --dry-run
```

The script intentionally does not perform changelog/docs decisions; handle those in the agent workflow before running the script.
It always attempts `--ff-only` first and automatically falls back to a non-ff merge commit if branches have diverged.

## Build Notes

- Two post-build script phases run on every build:
  - `scripts/embed-changelog.sh` — copies `CHANGELOG.md` into the app bundle's Resources, writes the short git commit hash to `BUILD_COMMIT`, and sets `CFBundleVersion` to the git commit count (incremental build number). The app reads this bundled changelog for the "Changelog…" menu item and the launch-time "What's New" window.
  - `scripts/sync-version-from-tag.sh` — patches `CFBundleShortVersionString` in the built Info.plist to match the latest git tag (e.g. `v1.5.4` → `1.5.4`). This keeps debug builds in sync with the latest release version automatically. The CI release workflow performs an equivalent `sed` patch on `Project.swift` before building, so this script is a no-op there.
- `./scripts/bootstrap-ghosttykit.sh` builds Ghostty from the repo's pinned default ref. If local `Libraries/GhosttyKit.xcframework` drifts to another Ghostty ref, rerun the bootstrap script before building to realign the C headers and Swift bridge.
- `Packages/MagentModules` contains local SwiftPM modules consumed through `Tuist/Package.swift`. If package dependencies change, rerun `mise x -- tuist install` before `mise x -- tuist generate --no-open`.
- After adding or removing Swift files, run `mise x -- tuist generate --no-open` before `xcodebuild` so the generated workspace includes the current source list.

## Local Feature Flags

- Release-gated local features use dedicated `FEATURE_*` active compilation conditions in `Project.swift`.
- Add the flag only to the configurations that should expose the feature. The current example is `FEATURE_JIRA_SYNC`, which is enabled for `Debug` and omitted from `Release`.
- Gate feature-specific app behavior behind that flag instead of deleting the code. Release builds should hide the related UI and skip the related automation/background work.
- If a feature still appears anywhere in Settings while it is debug-only, annotate the title or nearby copy with `Debug builds only` so developers can see immediately that the feature is not shipping yet.

## First Run

1. Launch mAgent
2. Add your repositories in Settings
3. Choose your default agent (Claude, Codex, or custom)
4. Create your first thread
