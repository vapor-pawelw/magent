# Update Flow

User-facing behavior:
- `General` settings owns update preferences and actions: the launch-check checkbox, manual `Check for Updates Now`, and an `Update to <version>` button when a newer release has already been detected.
- Launch-time update checks run only when `AppSettings.autoCheckForUpdates` is enabled.
- When no published release exists yet in `vapor-pawelw/magent-releases`, manual checks say there are no new releases instead of surfacing a raw GitHub `404`.
- When a newer version is found, Magent shows a persistent dismissible banner with `Update Now`, `Skip this version`, and a collapsed-by-default `Show Changes` control.
- Settings mirrors the same detected version and the same read-only changelog, using a fixed-height scrollable text area when expanded.
- `Skip this version` suppresses the launch/banner prompt for that exact version only. The skipped version still appears in Settings with an update button, and a newer version shows prompts again automatically.

Implementation details:
- `UpdateService` queries the public repo's release list (`/releases?per_page=10`) instead of `/releases/latest`.
- Release notes come from the GitHub release `body` and are passed through banner/settings UI as optional details text.
- Detected update state is kept in memory by `UpdateService` and broadcast with `magentUpdateStateChanged`, which `SettingsGeneralViewController` observes to refresh its update card.
- Skipped-version persistence lives in `AppSettings.skippedUpdateVersion`.
- For direct bundle installs, `UpdateService.installUpdate` does all the slow work in-app (download via `URLSession.download(for:)`, then DMG mount+ditto or ZIP unpack), showing progress banners at each phase. Only then is a minimal swap-only shell script launched (`writeSwapScript`), which just waits for the process to exit, `mv`s the prepared bundle into place, and calls `open`. The app terminates after 0.3 s.
- For both direct bundle installs and Homebrew installs, the updater clears `com.apple.quarantine` and `com.apple.provenance` from the prepared/final app bundle before relaunch. This is a defensive workaround for unsigned release artifacts that could otherwise install successfully but refuse Finder/LaunchServices launch until the user manually ran `xattr -cr /Applications/Magent.app`.
- For Homebrew installs, the original detached-script flow is kept: `brew upgrade --cask magent` runs after the app exits because Homebrew manages its own download, then the updater clears launch-blocking xattrs from `/Applications/Magent.app` before reopening it.

What changed in this thread (original):
- Reworked update checks so launch detection no longer auto-installs immediately.
- Added persistent in-app update banners with dismiss/skip/update actions and expandable release notes.
- Added Settings-side version status, update action, and expandable scrollable changelog display.
- Added skipped-version persistence and empty-release handling for the new public release-only repository.

What changed in this thread (jumpluff):
- Moved download + unpack into the app process so users see "Downloading…" / "Preparing update…" / "Installing…" banners instead of the app silently closing and making them wait.
- The background script is now a thin swap-only script (wait for exit → mv → open) with no network access.
- Homebrew path is unchanged.

What changed in this thread (magent-launch-crash):
- Added a quarantine/provenance scrub step for updated app bundles before relaunch in both the direct bundle-replacement path and the Homebrew path.
- This specifically avoids installs that appear broken until the user manually clears xattrs from `/Applications/Magent.app`.

Gotchas for future agents:
- Do not switch back to GitHub's `/releases/latest` endpoint unless you also handle its `404`-when-empty behavior. An empty public release repo is a valid state during setup.
- `skippedUpdateVersion` suppresses the banner for that version, not the underlying detected update state. Settings should continue to show the available version so the user can install it manually.
- If you change update UI state, keep the banner flow and `SettingsGeneralViewController` in sync through `UpdateService.pendingUpdateSummary` and `magentUpdateStateChanged` rather than duplicating fetch logic in the view.
- Until releases are properly signed/notarized, keep the updater-side `xattr` scrub in both relaunch flows. Replacing the app bundle without clearing `com.apple.quarantine` / `com.apple.provenance` can leave the fresh install launchable from Terminal but blocked in Finder/LaunchServices.
