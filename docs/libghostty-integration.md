# libghostty Integration Guide

## Building GhosttyKit.xcframework

Source: https://github.com/ghostty-org/ghostty

**Zig version requirements (strict):**
- Ghostty 1.0.x / 1.1.x: Zig 0.13.0
- Ghostty 1.2.x: Zig 0.14.1

**Build command (native macOS only):**
```bash
zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework -Dxcframework-target=native
```

Output: `macos/GhosttyKit.xcframework`

**Full build (all platforms):**
```bash
zig build -Doptimize=ReleaseFast -Dapp-runtime=none -Demit-xcframework
```
Produces macOS universal + iOS arm64 + iOS Simulator arm64 slices.

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

Magent is macOS-only, so use the native macOS path:
- Use `GHOSTTY_PLATFORM_MACOS` with `NSView`.

## Reference Implementation

The Ghostty macOS app source is the definitive reference:
- `macos/Sources/Ghostty/` — App lifecycle, config
- `macos/Sources/Features/Terminal/` — Surface/terminal view implementation
