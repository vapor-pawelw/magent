import Cocoa
import GhosttyKit

public enum GhosttyEmbeddedAppearanceMode: Sendable {
    case system
    case light
    case dark
}

public enum GhosttyEmbeddedMouseWheelBehavior: Sendable {
    case magentDefaultScroll
    case inheritGhosttyGlobal
    case allowAppsToCapture
}

public struct GhosttyEmbeddedPreferences: Sendable {
    public var appearanceMode: GhosttyEmbeddedAppearanceMode
    public var mouseWheelBehavior: GhosttyEmbeddedMouseWheelBehavior

    public init(
        appearanceMode: GhosttyEmbeddedAppearanceMode = .system,
        mouseWheelBehavior: GhosttyEmbeddedMouseWheelBehavior = .magentDefaultScroll
    ) {
        self.appearanceMode = appearanceMode
        self.mouseWheelBehavior = mouseWheelBehavior
    }
}

/// Singleton managing the ghostty_app_t instance and runtime callbacks.
@MainActor
public final class GhosttyAppManager {

    public static let shared = GhosttyAppManager()

    public private(set) var app: ghostty_app_t?
    public var focusedSurface: ghostty_surface_t?
    private var isInitialized = false
    private var displayLink: CVDisplayLink?
    private var surfaceCount = 0
    private var pendingSyntheticPasteText: String?
    private var retainedConfigs: [ghostty_config_t] = []
    private var registeredSurfaces: [Int: ghostty_surface_t] = [:]
    private var embeddedPreferences = GhosttyEmbeddedPreferences()

    // MARK: - Initialization

    public func initialize() {
        guard !isInitialized else { return }
        isInitialized = true

        // Ensure PATH includes Homebrew so tmux/git are available in spawned shells
        if let existingPath = ProcessInfo.processInfo.environment["PATH"] {
            if !existingPath.contains("/opt/homebrew/bin") {
                setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:" + existingPath, 1)
            }
        } else {
            setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
        }

        // Global init
        let initResult = ghostty_init(0, nil)
        Self.log("init result: \(initResult), HOME=\(ProcessInfo.processInfo.environment["HOME"] ?? "nil")")

        guard let config = buildConfig(for: embeddedPreferences, logContext: "initial", effectiveAppearance: NSApp.effectiveAppearance) else {
            return
        }
        retainedConfigs.append(config)

        // Create runtime config with callbacks (top-level functions,
        // naturally nonisolated since this module has no default actor isolation)
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = ghosttyWakeupCallback
        runtimeConfig.action_cb = ghosttyActionCallback
        runtimeConfig.read_clipboard_cb = ghosttyReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback
        runtimeConfig.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtimeConfig.close_surface_cb = ghosttyCloseSurfaceCallback

        app = ghostty_app_new(&runtimeConfig, config)
        Self.log("app created: \(app != nil)")
        applyAppearanceMode()
    }

    public static func log(_ msg: String) {
        let line = "[\(Date())] [Ghostty] \(msg)\n"
        let path = "/tmp/magent-ghostty.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    private var tickCount = 0

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
        tickCount += 1
        if tickCount <= 3 || tickCount == 60 {
            Self.log("tick #\(tickCount)")
        }
    }

    // MARK: - Display Link

    public func surfaceDidAppear() {
        surfaceCount += 1
        Self.log("surfaceDidAppear: count=\(surfaceCount)")
        startDisplayLinkIfNeeded()
    }

    public func surfaceDidDisappear() {
        surfaceCount = max(0, surfaceCount - 1)
        if surfaceCount == 0 {
            stopDisplayLink()
        }
    }

    /// Routes explicit text through Ghostty's clipboard paste action
    /// so bracketed-paste behavior matches normal Cmd+V.
    public func pasteText(_ text: String, on surface: ghostty_surface_t?) -> Bool {
        guard let surface, !text.isEmpty else { return false }
        pendingSyntheticPasteText = text
        let action = "paste_from_clipboard"
        let handled = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
        if !handled {
            pendingSyntheticPasteText = nil
        }
        return handled
    }

    public func consumeSyntheticPasteText() -> String? {
        let text = pendingSyntheticPasteText
        pendingSyntheticPasteText = nil
        return text
    }

    public func registerSurface(
        _ surface: ghostty_surface_t?,
        effectiveAppearance: NSAppearance? = nil
    ) {
        guard let surface else { return }
        registeredSurfaces[Int(bitPattern: surface)] = surface
        // Apply the current preferences immediately so the surface doesn't default to dark.
        // Mirrors what applyEmbeddedPreferences does for already-registered surfaces.
        if let config = retainedConfigs.last {
            applyConfig(config, to: surface, effectiveAppearance: effectiveAppearance)
        }
    }

    public func unregisterSurface(_ surface: ghostty_surface_t?) {
        guard let surface else { return }
        registeredSurfaces.removeValue(forKey: Int(bitPattern: surface))
    }

    public func applyEmbeddedPreferences(
        _ preferences: GhosttyEmbeddedPreferences,
        effectiveAppearance: NSAppearance? = nil
    ) {
        embeddedPreferences = preferences
        guard let app else { return }
        guard let config = buildConfig(for: preferences, logContext: "update", effectiveAppearance: effectiveAppearance) else { return }
        retainedConfigs.append(config)
        ghostty_app_update_config(app, config)
        // Apply color scheme AFTER config update so the API call isn't overridden by
        // whatever window-theme the config resolved (which may default to dark).
        let colorScheme = resolvedColorScheme(for: effectiveAppearance)
        ghostty_app_set_color_scheme(app, colorScheme)
        for surface in registeredSurfaces.values {
            applyConfig(config, to: surface, effectiveAppearance: effectiveAppearance)
        }
    }

    func reloadEmbeddedConfig(soft: Bool, for surface: ghostty_surface_t? = nil) {
        let logContext = soft ? "reload-config-soft" : "reload-config"
        if let surface {
            let effectiveAppearance = effectiveAppearance(for: surface)
            guard let config = buildConfig(
                for: embeddedPreferences,
                logContext: "\(logContext)-surface",
                effectiveAppearance: effectiveAppearance
            ) else {
                return
            }
            retainedConfigs.append(config)
            applyConfig(config, to: surface, effectiveAppearance: effectiveAppearance)
            return
        }

        applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance: NSApp.effectiveAppearance)
    }

    public func refreshAppearanceIfNeeded() {
        // Re-apply full preferences so existing surfaces pick up the updated color scheme.
        // Pass NSApp.effectiveAppearance so system mode correctly resolves light vs dark.
        applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance: NSApp.effectiveAppearance)
    }

    public func refreshAppearance(using effectiveAppearance: NSAppearance?) {
        // Rebuild the full config (not just the color scheme API call) since the override
        // config may need to change background/foreground for system mode in light OS.
        applyEmbeddedPreferences(embeddedPreferences, effectiveAppearance: effectiveAppearance)
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        CVDisplayLinkSetOutputCallback(displayLink, displayLinkCallback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Notification Names

    public static let ghosttySurfaceClosed = Notification.Name("ghosttySurfaceClosed")
    public static let ghosttyScrollbarUpdated = Notification.Name("ghosttyScrollbarUpdated")

    private func buildConfig(
        for preferences: GhosttyEmbeddedPreferences,
        logContext: String,
        effectiveAppearance: NSAppearance? = nil
    ) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            Self.log("\(logContext): config_new returned nil")
            return nil
        }

        Self.log("\(logContext): config created")
        ghostty_config_load_default_files(config)
        if let overridePath = writeOverrideConfig(for: preferences, effectiveAppearance: effectiveAppearance) {
            overridePath.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }
        ghostty_config_finalize(config)

        let diagCount = ghostty_config_diagnostics_count(config)
        Self.log("\(logContext): config finalized, diagnostics: \(diagCount)")
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let msg = diag.message {
                Self.log("  diag[\(i)]: \(String(cString: msg))")
            }
        }

        return config
    }

    private func writeOverrideConfig(
        for preferences: GhosttyEmbeddedPreferences,
        effectiveAppearance: NSAppearance? = nil
    ) -> String? {
        var lines: [String] = []

        // Keep Magent's embedded terminal chrome-free until we add an app-level toggle.
        lines.append("scrollbar = never")

        // Bake the color scheme into the config so Ghostty uses it when processing
        // app/surface config updates, rather than defaulting to dark.
        //
        // NOTE: ghostty_surface_set_color_scheme only triggers a color reload when the
        // conditional state changes. The conditional state defaults to .light, so calling
        // set_color_scheme(LIGHT) is always a no-op. Without explicit background/foreground
        // overrides, the terminal always renders with ghostty's default dark background
        // (#282c34) unless the user has a paired theme (e.g. theme = OneLight:OneDark).
        // Writing background/foreground here ensures light mode works out of the box.
        // Users who prefer different light colors can override background/foreground in
        // their ~/.config/ghostty/config — our override is loaded after theirs, so to
        // keep custom colors, users should NOT rely on this default and instead configure
        // a paired theme (theme = MyLight:MyDark) which works via conditional state.
        let resolvedScheme = resolvedColorScheme(for: effectiveAppearance)
        switch preferences.appearanceMode {
        case .light:
            lines.append("window-theme = light")
            lines.append("background = #ffffff")
            lines.append("foreground = #000000")
        case .dark:
            lines.append("window-theme = dark")
        case .system:
            lines.append("window-theme = auto")
            // When the OS is in light mode, ghostty's default dark background (#282c34)
            // would still show dark. Override to match the OS light appearance.
            if resolvedScheme == GHOSTTY_COLOR_SCHEME_LIGHT {
                lines.append("background = #ffffff")
                lines.append("foreground = #000000")
            }
        }

        switch preferences.mouseWheelBehavior {
        case .magentDefaultScroll:
            lines.append("mouse-reporting = false")
        case .inheritGhosttyGlobal:
            break
        case .allowAppsToCapture:
            lines.append("mouse-reporting = true")
        }

        guard !lines.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("magent-ghostty-overrides.config")
        let contents = lines.joined(separator: "\n") + "\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            Self.log("failed to write override config: \(error.localizedDescription)")
            return nil
        }
    }

    private func applyAppearanceMode(using effectiveAppearance: NSAppearance? = nil) {
        guard let app else { return }
        let colorScheme = resolvedColorScheme(for: effectiveAppearance)
        Self.log("applyAppearanceMode: scheme=\(colorScheme.rawValue) (0=light,1=dark) mode=\(embeddedPreferences.appearanceMode)")
        ghostty_app_set_color_scheme(app, colorScheme)
        for surface in registeredSurfaces.values {
            ghostty_surface_set_color_scheme(surface, colorScheme)
            ghostty_surface_draw(surface)
        }
    }

    private func applyConfig(
        _ config: ghostty_config_t,
        to surface: ghostty_surface_t,
        effectiveAppearance: NSAppearance?
    ) {
        let colorScheme = resolvedColorScheme(for: effectiveAppearance)
        ghostty_surface_update_config(surface, config)
        ghostty_surface_set_color_scheme(surface, colorScheme)
        ghostty_surface_draw(surface)
    }

    private func effectiveAppearance(for surface: ghostty_surface_t) -> NSAppearance? {
        guard let userData = ghostty_surface_userdata(surface) else { return nil }
        let surfaceView = Unmanaged<TerminalSurfaceView>.fromOpaque(userData).takeUnretainedValue()
        return surfaceView.effectiveAppearance
    }

    private func resolvedColorScheme(for effectiveAppearance: NSAppearance? = nil) -> ghostty_color_scheme_e {
        switch embeddedPreferences.appearanceMode {
        case .system:
            return currentSystemColorScheme(for: effectiveAppearance)
        case .light:
            return GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark:
            return GHOSTTY_COLOR_SCHEME_DARK
        }
    }

    private func currentSystemColorScheme(for effectiveAppearance: NSAppearance?) -> ghostty_color_scheme_e {
        let appearance = (effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }
}

// MARK: - C callbacks
// All Ghostty and CVDisplayLink callbacks run on background threads.
// They are naturally nonisolated as top-level functions in a module
// without SWIFT_DEFAULT_ACTOR_ISOLATION.

/// Wraps a raw pointer so it can be sent across isolation boundaries.
private struct SendableRawPointer: @unchecked Sendable {
    public let pointer: UnsafeMutableRawPointer?
}

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    Task { @MainActor in
        GhosttyAppManager.shared.tick()
    }
}

private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE,
         GHOSTTY_ACTION_CELL_SIZE,
         GHOSTTY_ACTION_RENDERER_HEALTH,
         GHOSTTY_ACTION_MOUSE_SHAPE,
         GHOSTTY_ACTION_MOUSE_VISIBILITY,
         GHOSTTY_ACTION_RING_BELL,
         GHOSTTY_ACTION_PWD,
         GHOSTTY_ACTION_OPEN_URL:
        return true
    case GHOSTTY_ACTION_SCROLLBAR:
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        let surfaceAddr = Int(bitPattern: target.target.surface)
        let scrollbar = action.action.scrollbar
        Task { @MainActor in
            NotificationCenter.default.post(
                name: GhosttyAppManager.ghosttyScrollbarUpdated,
                object: nil,
                userInfo: [
                    "surfaceAddr": surfaceAddr,
                    "total": scrollbar.total,
                    "offset": scrollbar.offset,
                    "len": scrollbar.len,
                ]
            )
        }
        return true
    case GHOSTTY_ACTION_RELOAD_CONFIG:
        let soft = action.action.reload_config.soft
        switch target.tag {
        case GHOSTTY_TARGET_APP:
            Task { @MainActor in
                GhosttyAppManager.shared.reloadEmbeddedConfig(soft: soft)
            }
            return true
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return false }
            Task { @MainActor in
                GhosttyAppManager.shared.reloadEmbeddedConfig(soft: soft, for: surface)
            }
            return true
        default:
            return false
        }
    case GHOSTTY_ACTION_CONFIG_CHANGE:
        return true
    default:
        return false
    }
}

private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    let wrappedState = SendableRawPointer(pointer: state)
    Task { @MainActor in
        guard let surface = GhosttyAppManager.shared.focusedSurface else { return }
        let string = GhosttyAppManager.shared.consumeSyntheticPasteText()
            ?? NSPasteboard.general.string(forType: .string)
            ?? ""
        string.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, wrappedState.pointer, true)
        }
    }
}

private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ str: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    let copiedStr: String? = str.map { String(cString: $0) }
    let wrappedState = SendableRawPointer(pointer: state)
    Task { @MainActor in
        guard let surface = GhosttyAppManager.shared.focusedSurface else { return }
        if let copiedStr {
            copiedStr.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, wrappedState.pointer, true)
            }
        } else {
            ghostty_surface_complete_clipboard_request(surface, nil, wrappedState.pointer, true)
        }
    }
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard let content, count > 0 else { return }

    // Prefer text/plain when available, otherwise fall back to first item.
    let entries = UnsafeBufferPointer(start: content, count: count)
    let selectedEntry = entries.first { entry in
        guard let mime = entry.mime else { return false }
        return String(cString: mime).lowercased().contains("text/plain")
    } ?? entries.first

    guard let selectedEntry,
          let dataPtr = selectedEntry.data else { return }

    let text = String(cString: dataPtr)
    Task { @MainActor in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if confirm {
            GhosttyAppManager.log("clipboard write confirmed for location \(location.rawValue)")
        }
    }
}

private func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    Task { @MainActor in
        NotificationCenter.default.post(
            name: GhosttyAppManager.ghosttySurfaceClosed,
            object: nil,
            userInfo: ["processAlive": processAlive]
        )
    }
}

private func displayLinkCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ userdata: UnsafeMutableRawPointer?
) -> CVReturn {
    let mgr = Unmanaged<GhosttyAppManager>.fromOpaque(userdata!).takeUnretainedValue()
    Task { @MainActor in
        mgr.tick()
    }
    return kCVReturnSuccess
}
