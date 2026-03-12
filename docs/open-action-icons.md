# Open Action Icons

## User Behavior

- The top-right thread toolbar buttons and their matching right-click menu actions now use the same visual icon source for `Open in Finder` and pull-request / open-PR actions.
- `Open in Finder` in thread context menus uses the real Finder app icon instead of a generic folder symbol.
- Pull-request actions in thread context menus use the same hosting-provider icon as the top-right PR button when Magent knows the remote provider; otherwise they fall back to the existing generic external-link symbol.
- When Magent can detect an existing PR/MR for the current branch, toolbar and menu actions open the direct PR/MR web page instead of a host-specific filtered listing page.
- The `CHANGES` panel file context menu now uses the Finder app icon for `Show in Finder` so Finder-related actions look consistent everywhere in the app.
- PR/MR metadata is populated during startup restore and refreshed on the session monitor, so sidebar labels and open actions should not wait for a long idle period after launch.

## Implementation Notes

- Shared icon generation lives in `Magent/Utilities/OpenActionIcons.swift`.
- Finder actions use `NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")` so menus and toolbar buttons stay aligned with the system Finder icon.
- Pull-request actions resolve their icon from `GitHostingProvider` and reuse the same provider artwork for both toolbar buttons and menus.
- Direct PR/MR opening should prefer `ThreadManager.resolvePullRequestURL(for:)` or `GitService.fetchPullRequest(...)` before falling back to provider listing URLs. This keeps GitLab actions on the actual MR page when `glab` can resolve the branch.
- GitHub's provider mark still gets a light rounded badge so it remains readable in dark appearances.

## Gotchas

- The app target uses an explicit source allowlist in `Project.swift`, not a blanket `Magent/Utilities/**` glob. Adding a new utility file requires adding it to the `sources` array or the app target will compile without seeing it.
- When adding new "open" actions that mirror an existing toolbar button, route them through `OpenActionIcons` instead of duplicating one-off `NSWorkspace` / `NSImage(named:)` code. That keeps menus and buttons visually in sync and avoids provider-specific styling drift.
- Do not assume periodic PR/MR refresh alone will populate `pullRequestInfo` quickly enough for launch-time UI. Keep startup restore triggering a PR/MR sync, and keep direct-open actions able to resolve the live PR/MR URL on demand.
