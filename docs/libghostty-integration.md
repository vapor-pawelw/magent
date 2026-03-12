# libghostty Integration Guide

## Building GhosttyKit.xcframework

Source: https://github.com/ghostty-org/ghostty

Pinned default ref for this repo bootstrap script: `v1.3.0`.

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
GHOSTTY_REF=v1.3.0 ./scripts/bootstrap-ghosttykit.sh
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
  read_clipboard_cb
  confirm_read_clipboard_cb
  write_clipboard_cb
  close_surface_cb
} ghostty_runtime_config_s;
```

### Metal Rendering
libghostty manages Metal rendering internally. The host app only:
1. Passes an NSView pointer (macOS) or UIView pointer (iOS) in surface config
2. Calls `ghostty_surface_set_size()` on resize (pass backing pixel size)
3. Calls `ghostty_surface_set_content_scale()` when DPI changes
4. Calls `ghostty_surface_set_display_id()` when screen changes
5. Calls `ghostty_app_tick()` + `ghostty_surface_draw()` in response to wakeup

## Platform Selection

mAgent is macOS-only, so use the native macOS path:
- Use `GHOSTTY_PLATFORM_MACOS` with `NSView`.

## Embedded Config Layering

Magent's embedded terminal should keep Ghostty's global user config, then layer Magent-owned overrides for the specific terminal behaviors exposed in Settings.

- Load Ghostty defaults/user config first with `ghostty_config_load_default_files(...)`.
- Apply Magent's explicit overrides afterwards from a generated config file so user Ghostty settings still work for everything else.
- Keep overrides narrow and intentional. Current embedded overrides are settings-driven behaviors such as wheel capture policy, plus a temporary `scrollbar = never` override so embedded terminals stay chrome-free while Magent relies on its own scroll affordances. Do not blanket-disable user Ghostty config again unless Magent stops exposing those options itself.

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

## Appearance Update Ordering in AppDelegate

`AppDelegate.applyAppAppearanceAndTerminalPreferences` does three things in order:
1. Sets `NSApp.appearance` to the new value.
2. Calls `GhosttyAppManager.shared.applyEmbeddedPreferences(...)` to update the embedded terminal color scheme.
3. Calls `refreshWindowAppearances(using:)` which sets each window's `appearance` and forces layout/display.

**Rule**: `applyEmbeddedPreferences` **must** be called **before** `refreshWindowAppearances`. Setting window appearances (step 3) can synchronously trigger `viewDidChangeEffectiveAppearance` on `TerminalSurfaceView` instances (via `layoutSubtreeIfNeeded` / `displayIfNeeded`), which calls `refreshAppearance(using:)`. If `embeddedPreferences` has not yet been updated at that point, `resolvedColorScheme` uses the stale appearance mode and may set the wrong color scheme on all surfaces. `applyEmbeddedPreferences` then runs after the refresh and corrects it — but the intermediate wrong state can cause terminals to remain dark or miss the update entirely.

## System Appearance Change Contract

Beyond the manual settings toggle, terminals must also react when macOS switches the system appearance (e.g., the user flips Dark/Light in System Settings, or per-window appearance changes).

**Rule**: `TerminalSurfaceView` overrides `viewDidChangeEffectiveAppearance()` and calls `GhosttyAppManager.shared.refreshAppearance(using: effectiveAppearance)`, followed by `ghostty_surface_draw(surface)` on the surface directly. `refreshAppearance` calls `applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance:)` which rebuilds the override config (including background/foreground for light mode) and updates all registered surfaces. The explicit `draw` call on the originating surface ensures the change is visually applied immediately, rather than waiting for the next CVDisplayLink tick.

Without this hook, the terminal stays in the old scheme until the user manually re-toggles the Appearance setting.

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
