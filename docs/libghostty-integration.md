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
- Keep overrides narrow and intentional. Current embedded overrides are settings-driven behaviors such as wheel capture policy; do not blanket-disable user Ghostty config again unless Magent stops exposing those options itself.

## Reference Implementation

The Ghostty macOS app source is the definitive reference:
- `macos/Sources/Ghostty/` — App lifecycle, config
- `macos/Sources/Features/Terminal/` — Surface/terminal view implementation

## Overlay Z-Order Contract (mAgent)

When terminal overlays are enabled (for example, the prompt Table of Contents or the scroll controls pill), they must remain visible above terminal content during tab switches and session view recreation.

### Critical gotcha: overlays must be added to `terminalContainer`, not the parent `view`

`TerminalSurfaceView` uses `CAMetalLayer` for rendering. Metal content does **not** composite correctly with NSViews that are siblings of the Metal view's container — i.e. views added to `view` (the parent of `terminalContainer`) do not render above the Metal surface, even if they appear later in the subview array.

**Rule**: Any overlay that must float above the terminal must be added directly to `terminalContainer` (the same container that hosts `TerminalSurfaceView` instances), not to the view controller's root `view`.

**Bring-to-front after lazy tab add**: Terminal views are added lazily on first tab selection. After adding a new `TerminalSurfaceView` to `terminalContainer`, call `addSubview(_:positioned:above:relativeTo: nil)` on every overlay to keep them on top. See `bringPromptTOCOverlayToFront()` and `bringScrollOverlaysToFront()` in `ThreadDetailViewController+PromptTOC.swift` and `ThreadDetailViewController+ScrollFAB.swift`.
