# libghostty Integration Guide

## Building GhosttyKit.xcframework

Source: https://github.com/ghostty-org/ghostty

Pinned default ref for this repo bootstrap script: `v1.3.1`.

## Version Upgrade Checklist

When upgrading Ghostty to a new version, update **all three** of these in the same commit:

1. **`scripts/bootstrap-ghosttykit.sh`** — default value of `GHOSTTY_REF` (line: `GHOSTTY_REF="${GHOSTTY_REF:-vX.Y.Z}"`)
2. **`scripts/rebuild-and-relaunch.sh`** — default value of `PINNED_GHOSTTY_REF` (line: `PINNED_GHOSTTY_REF="${MAGENT_GHOSTTY_REF:-vX.Y.Z}"`)
3. **`docs/libghostty-integration.md`** — the "Pinned default ref" line above and the Zig version table below (if the required Zig version changed)

The release workflow (`.github/workflows/release.yml`) calls `bootstrap-ghosttykit.sh` without a `--ref` argument, so it automatically picks up the default. No changes needed there unless the build flags change.

After bumping, rebuild locally and verify that `Libraries/GhosttyKit.xcframework/.ghostty-ref` matches the new version:
```bash
./scripts/bootstrap-ghosttykit.sh
cat Libraries/GhosttyKit.xcframework/.ghostty-ref   # should print the new ref
```

Also check whether any C API signatures changed (especially callback types — see the per-version notes below) and update `GhosttyBridge` accordingly.

**Zig version requirements (strict):**
- Ghostty 1.0.x / 1.1.x: Zig 0.13.0
- Ghostty 1.2.x: Zig 0.14.1
- Ghostty 1.3.x: Zig 0.15.2

**Project bootstrap command (recommended):**
```bash
./scripts/bootstrap-ghosttykit.sh
```

To build a different Ghostty ref:
```bash
GHOSTTY_REF=v1.3.1 ./scripts/bootstrap-ghosttykit.sh
```

**Build command used by bootstrap script:**
```bash
zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework -Dxcframework-target=universal
```

Output: `macos/GhosttyKit.xcframework` (includes `macos-arm64_x86_64/libghostty.a`).

When bootstrapping Magent, the installed copy under `Libraries/GhosttyKit.xcframework`
is trimmed back to the macOS slice only. Ghostty 1.3.0's upstream "universal"
xcframework includes iOS slices too, but Magent does not consume or track them.

Note: for older refs that still point `iterm2_themes` at removed GitHub release assets, `./scripts/bootstrap-ghosttykit.sh` retries automatically: it first runs a normal build, and if it fails with the known `ghostty-themes.tgz` `404`, it rewrites that dependency to the maintained Ghostty mirror URL/hash and rebuilds once.

**Full build (all platforms):**
```bash
zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework
```
Produces macOS universal + iOS arm64 + iOS Simulator arm64 slices.

## Repository Policy

`libghostty.a` is intentionally not committed to this repository.  
`./scripts/bootstrap-ghosttykit.sh` is the canonical way to populate `Libraries/GhosttyKit.xcframework` in local dev and CI.

If the local `GhosttyKit.xcframework` was rebuilt from a different Ghostty ref, rerun `./scripts/bootstrap-ghosttykit.sh` with the repo's pinned default ref before building Magent. The Swift bridge code tracks the pinned embedding API and can fail to compile against a newer local header set.

## Xcode Integration

1. Copy `GhosttyKit.xcframework` into project
2. Add to target's Frameworks, Libraries, Embedded Content → **"Do Not Embed"** (static lib)
3. `import GhosttyKit` in Swift — module.modulemap enables this

## C API Overview

### Opaque Handles
```c
ghostty_app_t       // Application instance
ghostty_config_t    // Configuration
ghostty_surface_t   // Terminal surface (one per terminal view)
ghostty_inspector_t // Debug inspector
```

### Lifecycle
```c
ghostty_init(argc, argv)          // Global init
ghostty_config_new()              // Create config
ghostty_config_finalize(config)   // Finalize config
ghostty_app_new(&runtime_cfg, config)  // Create app
ghostty_surface_new(app, &surface_cfg) // Create terminal surface
ghostty_app_tick(app)             // Drive event loop
ghostty_surface_draw(surface)     // Trigger render frame
```

### Surface Configuration
```c
typedef struct {
  ghostty_platform_e platform_tag;  // MACOS or IOS
  ghostty_platform_u platform;      // { nsview: void* } or UIView for iOS
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  // ... env vars, initial_input, context
} ghostty_surface_config_s;
```

### Required Runtime Callbacks
```c
typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  wakeup_cb          // Signal to pump event loop
  action_cb          // Handle ~60 action types
  read_clipboard_cb  // returns bool (since v1.3.1; was void in v1.3.0)
  confirm_read_clipboard_cb
  write_clipboard_cb
  close_surface_cb
} ghostty_runtime_config_s;
```

**`read_clipboard_cb` return type** (changed in v1.3.1): The callback must return `bool` — return `true` if the clipboard read was accepted/initiated, `false` to decline. Magent always returns `true` since we always dispatch the async read.

### Metal Rendering
libghostty manages Metal rendering internally. The host app only:
1. Passes an NSView pointer (macOS) or UIView pointer (iOS) in surface config
2. Calls `ghostty_surface_set_size()` on resize (pass backing pixel size)
3. Calls `ghostty_surface_set_content_scale()` when DPI changes
4. Calls `ghostty_surface_set_display_id()` when screen changes
5. Calls `ghostty_app_tick()` + `ghostty_surface_draw()` in response to wakeup

**Critical: `CAMetalLayer.isOpaque` must be `true`.**  The macOS window server performs compositor-level hit testing before delivering mouse events to the application. If the `CAMetalLayer` region appears transparent (between drawables, during surface re-creation, or when the GPU is busy), the window server routes mouse events to the window behind instead of to our window — making the terminal unresponsive to clicks while non-Metal UI (sidebar, tabs) continues working. Setting `isOpaque = true` in `makeBackingLayer()` prevents this.

## Platform Selection

mAgent is macOS-only, so use the native macOS path:
- Use `GHOSTTY_PLATFORM_MACOS` with `NSView`.

## Embedded Config Layering

Magent's embedded terminal should keep Ghostty's global user config, then layer Magent-owned overrides for the specific terminal behaviors exposed in Settings.

- Load Ghostty defaults/user config first with `ghostty_config_load_default_files(...)`.
- Apply Magent's explicit overrides afterwards from a generated config file so user Ghostty settings still work for everything else.
- Keep overrides narrow and intentional. Current embedded overrides are settings-driven behaviors such as wheel capture policy, plus a temporary `scrollbar = never` override so embedded terminals stay chrome-free while Magent relies on its own scroll affordances. Do not blanket-disable user Ghostty config again unless Magent stops exposing those options itself.
- Keep tmux `pane-scrollbars` disabled in the embedder startup path. Even with Ghostty forced to `scrollbar = never`, tmux's own character-cell scrollbar renders inside the terminal and is visually indistinguishable from a Ghostty scrollbar regression to users.

## Reference Implementation

The Ghostty macOS app source is the definitive reference:
- `macos/Sources/Ghostty/` — App lifecycle, config
- `macos/Sources/Features/Terminal/` — Surface/terminal view implementation

## Color Scheme Update Order

When the user changes the app appearance setting, `GhosttyAppManager.applyEmbeddedPreferences` must call `ghostty_app_set_color_scheme` and `ghostty_surface_set_color_scheme` **after** `ghostty_app_update_config` / `ghostty_surface_update_config`. The config update can reset the internal color scheme to dark (Ghostty's default when no theme is configured); setting the scheme after overrides that.

The correct order in `applyEmbeddedPreferences`:
1. `ghostty_app_update_config(app, config)` — apply new config (may reset scheme to dark)
2. `ghostty_app_set_color_scheme(app, newColorScheme)` — override scheme at app level
3. Per registered surface: `ghostty_surface_update_config(surface, config)` then `ghostty_surface_set_color_scheme(surface, newColorScheme)` then `ghostty_surface_draw(surface)`

`refreshAppearanceIfNeeded()` and `refreshAppearance(using:)` both call `applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance:)` rather than just the color scheme API alone, so the override config (which includes background/foreground) is rebuilt on every appearance change.

## window-theme Does NOT Change Terminal Colors

**Critical gotcha**: `window-theme = light/dark` in ghostty config only affects the **window chrome** (title bar appearance, scrollbar style). It does **not** change the terminal background or text colors. In Magent's embedded terminal this matters only indirectly right now because the generated override config also forces `scrollbar = never`.

`ghostty_surface_set_color_scheme(LIGHT)` is a **no-op** for newly created surfaces. The reason: ghostty's internal `ConditionalState` defaults to `.light`, so the `colorSchemeCallback` guard (`if current == new: return`) fires immediately and the config is never reloaded. Even when it does fire, without conditional theme blocks in the user's ghostty config (e.g. `[os-theme = light] { background = white }`), there is nothing to reload — ghostty's hardcoded default background is `#282c34` (dark) regardless of the color scheme.

## Background/Foreground Must Be Overridden for Light Mode

**Rule**: Write explicit `background` and `foreground` into the Magent override config whenever the resolved appearance is light. Without this, the terminal always renders dark.

Current override values written by `writeOverrideConfig`:
```
# Light mode (.light or .system when OS is light):
window-theme = light    # (or auto for system mode)
background = #ffffff
foreground = #000000

# Dark mode (.dark or .system when OS is dark):
window-theme = dark     # (or auto for system mode)
# no background/foreground override — ghostty's default #282c34 is already dark
```

**Users with paired themes**: If a user configures `theme = OneLight:OneDark` in `~/.config/ghostty/config`, Magent's `background = #ffffff` override will still win (the override config is loaded after user config). For users who want to use ghostty's paired theme mechanism, the correct approach is to use `.system` mode in Magent and let the host OS appearance drive the conditional state switch.

## Existing Surface Refresh Contract

Updating the app-level Ghostty color scheme is not sufficient on its own for already-open tabs.

- After resolving the new light/dark scheme, also call `ghostty_surface_set_color_scheme(surface, colorScheme)` for every registered surface.
- Follow that with `ghostty_surface_draw(surface)` (not `ghostty_surface_refresh`) so the terminal redraws immediately rather than waiting for the next CVDisplayLink tick. `refresh` only schedules a redraw; `draw` forces it now.
- Keep the AppKit side in sync too: when Magent changes `NSApp.appearance`, invalidate existing windows/content views so terminal-adjacent chrome (top bar buttons, overlay pills, TOC panel) re-resolves its dynamic colors in the same turn.

## New Surface Registration Contract

`applyEmbeddedPreferences` is called at launch and settings-change time, but surfaces are created lazily — after the first call there are no registered surfaces to iterate. A newly created surface inherits the app's initial (dark) defaults unless explicitly updated.

**Rule**: `registerSurface` must immediately apply the full current state to the new surface, mirroring what `applyEmbeddedPreferences` does for already-registered surfaces:
1. `ghostty_surface_update_config(surface, retainedConfigs.last)` — push the current config (window-theme, mouse-wheel policy etc.)
2. `ghostty_surface_set_color_scheme(surface, resolvedColorScheme(for: effectiveAppearance))` — override with the current light/dark scheme (after config, not before)
3. `ghostty_surface_draw(surface)` — trigger an immediate redraw (not `refresh`, which only schedules one)

Skipping `update_config` here causes new panes to start dark even when Light mode is active, because the surface only sees the app-level config that was current at `ghostty_surface_new` time.

**`effectiveAppearance` parameter**: `registerSurface` accepts an optional `NSAppearance?` which is the calling view's `effectiveAppearance`. This ensures new surfaces get the correct scheme even in scenarios where the view's effective appearance differs from `NSApp.effectiveAppearance` (e.g., per-window appearance overrides). Always pass `effectiveAppearance` from `TerminalSurfaceView` at surface-creation time.

## `reload_config` Callback Contract

**Do NOT respond to `GHOSTTY_ACTION_RELOAD_CONFIG` by calling back into Ghostty's config machinery.** Just return `true` to acknowledge it.

### Why ignoring it is correct

In v1.3.1, Ghostty fires `GHOSTTY_ACTION_RELOAD_CONFIG` as a side effect of `ghostty_surface_update_config` and `ghostty_app_update_config` — i.e. every time we apply a config update. If we respond to RELOAD_CONFIG by rebuilding and re-applying the config (which calls `ghostty_surface_update_config` again), it immediately fires another RELOAD_CONFIG. This creates an infinite feedback loop that saturates the main thread with config rebuilds and completely freezes the app.

This was the root cause of the severe performance regression introduced by the v1.3.1 binary. The loop produced hundreds of `reload-config-surface` calls per second, all on the main thread.

Magent manages its own config lifecycle explicitly: config is applied via `applyEmbeddedPreferences` (on settings change, appearance change, or launch). There is no need to re-apply config in response to a Ghostty-initiated reload signal.

Treat `GHOSTTY_ACTION_CONFIG_CHANGE` as handled (return `true`) as well, without acting on it.

### Override config file watcher gotcha

Ghostty v1.3.1 also watches every file loaded via `ghostty_config_load_file`. Since `writeOverrideConfig` writes to a temp file that was loaded at surface creation, **do not overwrite the file on every `buildConfig` call** — this triggers the file watcher, which fires RELOAD_CONFIG, which (if we were naively handling it) would rewrite the file again.

Mitigation: `writeOverrideConfig` memoizes the last-written content and skips the write when content is unchanged. Combined with ignoring RELOAD_CONFIG, this eliminates the loop entirely.

## Appearance Update Ordering in AppDelegate

`AppDelegate.applyAppAppearanceAndTerminalPreferences` does four things in order:
1. Sets `NSApp.appearance` to the new value.
2. Calls `GhosttyAppManager.shared.applyEmbeddedPreferences(...)` to update the embedded terminal color scheme and ghostty mouse-reporting config.
3. Dispatches `TmuxService.shared.applyMouseWheelScrollSettings(behavior:)` in a `Task` to configure tmux mouse support for the selected wheel behavior.
4. Calls `refreshWindowAppearances(using:)` which sets each window's `appearance` and forces layout/display.

**Rule**: `applyEmbeddedPreferences` **must** be called **before** `refreshWindowAppearances`. Setting window appearances (step 3) can synchronously trigger `viewDidChangeEffectiveAppearance` on `TerminalSurfaceView` instances (via `layoutSubtreeIfNeeded` / `displayIfNeeded`), which calls `refreshAppearance(using:)`. If `embeddedPreferences` has not yet been updated at that point, `resolvedColorScheme` uses the stale appearance mode and may set the wrong color scheme on all surfaces. `applyEmbeddedPreferences` then runs after the refresh and corrects it — but the intermediate wrong state can cause terminals to remain dark or miss the update entirely.

## Settings Notification Ordering Contract

`magentSettingsDidChange` is observed both by `AppDelegate` and by open `ThreadDetailViewController` instances.

**How wheel-scroll behavior is applied (two-layer approach)**:
- **Ghostty layer** (`mouse-reporting`): Both `magentDefaultScroll` and `allowAppsToCapture` set `mouse-reporting = true` so scroll events reach tmux. `inheritGhosttyGlobal` leaves ghostty's mouse-reporting unchanged.
- **tmux layer** (`applyMouseWheelScrollSettings`): `magentDefaultScroll` binds `WheelUpPane`/`WheelDownPane` to always enter copy-mode (history-only, never passed to apps) and uses single-line `scroll-up`/`scroll-down` steps per wheel event (no `-N` multiplier). `allowAppsToCapture` removes those bindings so tmux's default behavior applies (apps that request mouse get the events). Both non-inherit options enable `set -g mouse on`. Changes are applied from `AppDelegate` via an async `Task`.
- **Per-event scroll cap** (`TerminalSurfaceView.scrollWheel`): Wheel delta sent to `ghostty_surface_mouse_scroll` is clamped to `±5` lines on the Y axis so one wheel action cannot jump farther than five lines through history.
- **Discrete wheel normalization** (`TerminalSurfaceView.scrollWheel`): For non-precision devices (physical mouse wheels), normalize raw deltas to `-1/0/1` per axis before forwarding to Ghostty. Also treat no-phase wheel packets (`event.phase == []` and `event.momentumPhase == []`) as discrete even when AppKit marks them as "precise". Additionally, treat coarse integral packets (for example `±15` per notch) as discrete even when phases are present, because some mice still emit notch-style wheel data through that code path. Ghostty applies internal scaling, so forwarding those raw values can still cause oversized history jumps even with tmux single-step bindings.
- **Surface recreation**: `ThreadDetailViewController.handleSettingsChanged(_:)` recreates `TerminalSurfaceView` instances when the behavior changes so surfaces pick up the new ghostty config. It must call `GhosttyAppManager.shared.applyEmbeddedPreferences(...)` first so `retainedConfigs.last` is current when `registerSurface` runs on the new surfaces.
- **tmux terminal capabilities**: Every tmux server bootstrap path must advertise Magent's required `terminal-features` entries before clients attach. Today that means `TmuxService.applyGlobalSettings()`, `TmuxService.createSession(...)` when `new-session` auto-starts a lazy server, and the `ThreadDetailViewController` attach-or-create shell fallback. The required entries include RGB for Magent's supported client TERM patterns (`xterm*`, `tmux*`, `screen*`, `ghostty*`, `alacritty*`, `foot*`, `wezterm*`) plus `xterm*:hyperlinks`. Without the RGB entries, tmux reports only 256 colours to Ghostty-backed clients, which flattens dark-mode Codex/Claude rendering even though Ghostty itself supports truecolor.

**Rule**: The app-level settings observer must apply Ghostty prefs synchronously on the notification, not bounce through a later `Task`, so other same-turn observers do not race ahead and recreate surfaces with stale `embeddedPreferences`.

## System Appearance Change Contract

Beyond the manual settings toggle, terminals must also react when macOS switches the system appearance (e.g., the user flips Dark/Light in System Settings, or per-window appearance changes).

**Rule**: `TerminalSurfaceView` overrides `viewDidChangeEffectiveAppearance()` and calls `GhosttyAppManager.shared.refreshAppearance(using: effectiveAppearance)`, followed by `ghostty_surface_draw(surface)` on the surface directly. `refreshAppearance` calls `applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance:)` which rebuilds the override config (including background/foreground for light mode) and updates all registered surfaces. The explicit `draw` call on the originating surface ensures the change is visually applied immediately, rather than waiting for the next CVDisplayLink tick.

Without this hook, the terminal stays in the old scheme until the user manually re-toggles the Appearance setting.

## Implicit Animation Suppression on Tab Switch

`TerminalSurfaceView` is backed by `CAMetalLayer`. Toggling `isHidden` or adding/removing layer-backed views from the hierarchy can trigger implicit Core Animation transitions (bounds, position, opacity) that visually manifest as content slowly scrolling down from the top of the terminal.

**Rule**: Wrap visibility toggling and subview insertion/removal of `TerminalSurfaceView` instances in `CATransaction.begin()` / `CATransaction.setDisableActions(true)` / `CATransaction.commit()`. This is done in `selectPreparedTab()` in `ThreadDetailViewController+TabBar.swift`.

## Overlay Z-Order Contract (mAgent)

When terminal overlays are enabled (for example, the prompt Table of Contents or the scroll controls pill), they must remain visible above terminal content during tab switches and session view recreation.

### Critical gotcha: overlays must be added to `terminalContainer`, not the parent `view`

`TerminalSurfaceView` uses `CAMetalLayer` for rendering. Metal content does **not** composite correctly with NSViews that are siblings of the Metal view's container — i.e. views added to `view` (the parent of `terminalContainer`) do not render above the Metal surface, even if they appear later in the subview array.

**Rule**: Any overlay that must float above the terminal must be added directly to `terminalContainer` (the same container that hosts `TerminalSurfaceView` instances), not to the view controller's root `view`.

**Bring-to-front after lazy tab add**: Terminal views are added lazily on first tab selection. After adding a new `TerminalSurfaceView` to `terminalContainer`, call `addSubview(_:positioned:above:relativeTo: nil)` on every overlay to keep them on top. See `bringPromptTOCOverlayToFront()` and `bringScrollOverlaysToFront()` in `ThreadDetailViewController+PromptTOC.swift` and `ThreadDetailViewController+ScrollFAB.swift`.

## Overlay Appearance Contract

Terminal overlays must respond to appearance changes the same way the surrounding terminal chrome does.

- Do not hard-code a permanently dark overlay palette for controls that remain visible in Light mode.
- Overlay views that draw their own layers should update those colors from `viewDidChangeEffectiveAppearance()`.
- This applies to the scroll-controls pill, the floating `Scroll to bottom` pill, and the Prompt TOC panel/header/resize affordance.

## Surface Lifecycle: close_surface_cb Limitation and Tab-Close Contract

**Critical gotcha**: `ghostty_runtime_close_surface_cb` has the signature:
```c
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool)
```
The `void*` is the **app**'s userdata (i.e. `GhosttyAppManager`) — **there is no surface parameter**. The callback fires when the process inside Ghostty dies, but the host cannot determine which surface triggered it from the callback alone. Magent's `ghosttyCloseSurfaceCallback` just posts an internal `ghosttySurfaceClosed` notification that nobody observes.

**Rule**: Never rely on `close_surface_cb` for surface cleanup. If a Ghostty surface is not freed before `ghostty_app_tick` runs, the tick will crash on the zombie surface (use-after-free).

**Display-link callback safety**: `CVDisplayLink` output callbacks should treat their `userdata` pointer as optional and return early when it is missing. Startup/teardown races can leave the callback invoked with null userdata; force-unwrapping that pointer in the callback crashes before Magent can recover.

### The IPC close-tab path

When a tab is closed via the IPC path (`magent-cli close-tab` → `IPCCommandHandler` → `threadManager.removeTab`), the tmux session is killed by the model layer — **`removeFromSuperview()` is never called on the `TerminalSurfaceView`**. Without `removeFromSuperview`, `viewDidMoveToWindow(nil)` never fires, `destroySurface()` is never called, and `ghostty_surface_free` is never called. `CVDisplayLink` continues firing `ghostty_app_tick` against the zombie surface, causing a crash.

### Fix: magentTabWillClose notification — must fire BEFORE killSession

`removeTabBySessionName` (which is `@MainActor`) posts `.magentTabWillClose` **before** calling `tmux.killSession()`:
```swift
// 1. Destroy surface synchronously (no await yet)
NotificationCenter.default.post(
    name: .magentTabWillClose,
    object: nil,
    userInfo: ["threadId": threadId, "sessionName": sessionName]
)
// 2. Now safe to kill the tmux session (async, suspends MainActor)
try? await tmux.killSession(name: sessionName)
```
Because `NotificationCenter.post` is synchronous, `ThreadDetailViewController.handleTabWillCloseNotification` runs to completion (calling `removeFromSuperview()` → `destroySurface()` → `ghostty_surface_free`) before any `await` suspension point.

**Why ordering matters**: `killSession` is `async` and suspends the MainActor. While suspended, the terminal process exits and `DispatchQueue.main.async` callbacks (including display-link ticks → `ghostty_app_tick`) can run. If the surface hasn't been freed yet, the tick crashes on the zombie surface. Posting the notification before the first `await` ensures the surface is destroyed while still holding the MainActor synchronously.

**Post-await re-resolution**: After `killSession` returns, the thread array may have shifted (concurrent closes, archive, etc.). The method re-resolves the thread by ID (`threads.firstIndex(where: { $0.id == closingThreadId })`) instead of using the stale pre-await index.

This pattern works for both paths:
- **GUI path** (`closeTab(at:)` → `removeTab`): notification fires synchronously and handles all UI cleanup. The `Task` completion block only syncs the local `thread` copy.
- **IPC path** (`IPCCommandHandler.closeTab` → `removeTab`): notification fires synchronously and is the only cleanup trigger — no UI code in the IPC call chain.

**Rule**: Any code path that kills a tmux session (and thus kills the process inside a Ghostty surface) must ensure `ghostty_surface_free` is called **before the first `await`** in the same `@MainActor` method. The `magentTabWillClose` notification exists precisely for code paths that don't have direct access to the view hierarchy.

**Terminal-view cache surface preservation:** `ReusableTerminalViewCache.store()` sets `preserveSurfaceOnDetach = true` on the `TerminalSurfaceView` before calling `removeFromSuperview()`. This prevents `viewDidMoveToWindow(nil)` from calling `destroySurface()`, so the live Ghostty surface survives while cached. When the view is re-attached to a window, `preserveSurfaceOnDetach` is cleared automatically and the existing surface continues rendering — no session restart. If the cached view is evicted (or deallocated without re-attachment), `deinit` cleans up the preserved surface.

**Tab-close cache eviction rule:** closing a tab can happen while that thread is not currently visible (or via IPC), so no `ThreadDetailViewController` may exist to remove/evict the view. In `removeTabBySessionName`, always evict the closing session from `ReusableTerminalViewCache` *before* `tmux.killSession`. Otherwise a detached cached surface can still hold a live PTY and libghostty may terminate the process when the PTY closes.

## Link Opening and Hover (GHOSTTY_ACTION_OPEN_URL / GHOSTTY_ACTION_MOUSE_OVER_LINK)

Ghostty fires two actions for link interaction:

- `GHOSTTY_ACTION_MOUSE_OVER_LINK` — hover events; `action.action.mouse_over_link.url` and `.len` give the OSC 8 URL (empty string when leaving a link).
- `GHOSTTY_ACTION_OPEN_URL` — user activated a link (e.g. Cmd+click in ghostty); `action.action.open_url.url` and `.len`.

Both require `copiedGhosttyString(pointer, length:)` to read the C string safely:
- If `length > 0`, copy exactly that many bytes (avoids relying on a null terminator).
- Otherwise fall back to `String(cString:)`.
- Return `nil` for empty strings so callers get a proper optional.

**Hover flow in `GhosttyAppManager`**: `setHoveredLink(_:surfaceAddress:)` looks up the `TerminalSurfaceView` via the registered surface map and calls `surfaceView.setHoveredLink(urlString)`.

**`TerminalSurfaceView` link detection priority** (highest to lowest):
1. **Ghostty-native** (`HoveredLinkSource.ghostty`): set by `GHOSTTY_ACTION_MOUSE_OVER_LINK`; never overridden by lower-priority sources.
2. **Rendered word** (`HoveredLinkSource.renderedWord`): `ghostty_surface_quicklook_word` returns the word under the cursor; run through `NSDataDetector` to check if it is a URL.
3. **Visible pane** (`HoveredLinkSource.visiblePane`): after a 45 ms debounce, query `TmuxService.visibleOpenableURL(sessionName:xFraction:yFraction:)` which runs `tmux capture-pane -N` and scans the target row ±1 for URLs.

`refreshHoveredLink(at:)` is called on every mouse move/enter/key event. When the mouse leaves the bounds, `setHoveredLink(nil)` is called unconditionally.

**Cmd+click open flow** (two independent paths):
- *Direct* (link already detected): `mouseDown` records `pendingLinkOpenURL`; `mouseUp` confirms both Cmd is still held and the cursor is still on the same URL, then calls `GhosttyAppManager.shared.openURL`.
- *tmux fallback* (no ghostty/rendered-word link): `mouseDown` records `pendingCommandClick`; `mouseUp` asynchronously calls `TmuxService.recentMouseOpenableURL(sessionName:)`, which reads the tmux server-scoped user option `@magent_last_mouse`. The option is rewritten by the `MouseDown1Pane` binding via `set-option -gqF` — a fork-free, in-process tmux command, deliberately chosen instead of `run-shell -b` so per-click mouse handling cannot spawn `/bin/sh` children that tmux's SIGCHLD reaper may leave as defunct/zombie processes under high-frequency clicking. This covers plain-text URLs not reported by ghostty.

**Embedded right-click policy:** `TerminalSurfaceView` intentionally swallows right mouse down/up events after updating cursor position (`sendMousePos`) and does not forward them to `ghostty_surface_mouse_button` or AppKit super handlers. This keeps embedded terminals menu-free (no Ghostty native context menu and no AppKit fallback menu).

**tmux terminal-features prerequisites**: On startup and on every lazy tmux-server bootstrap path, Magent must ensure its required `terminal-features` entries are present before attaching the client. This preserves truecolor (`*:RGB` for Magent's supported client TERM patterns) and OSC 8 links (`xterm*:hyperlinks`) for embedded Ghostty sessions.

**Link hover overlay**: `TerminalSurfaceView` contains a `PassthroughVisualEffectView` pill anchored 12pt from the bottom center. It animates in (80 ms) on link hover and out (120 ms) on clear. `PassthroughVisualEffectView` returns `nil` from `hitTest` so it never intercepts mouse events.
