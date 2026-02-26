import Cocoa
import GhosttyKit

/// Singleton managing the ghostty_app_t instance and runtime callbacks.
@MainActor
public final class GhosttyAppManager {

    public static let shared = GhosttyAppManager()

    public private(set) var app: ghostty_app_t?
    private var isInitialized = false
    private var displayLink: CVDisplayLink?
    private var surfaceCount = 0

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

        // Create and finalize config
        guard let config = ghostty_config_new() else {
            Self.log("config_new returned nil")
            return
        }
        Self.log("config created")
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        let diagCount = ghostty_config_diagnostics_count(config)
        Self.log("config finalized, diagnostics: \(diagCount)")
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(config, i)
            if let msg = diag.message {
                Self.log("  diag[\(i)]: \(String(cString: msg))")
            }
        }

        // Create runtime config with callbacks (top-level functions,
        // naturally nonisolated since this module has no default actor isolation)
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        app = ghostty_app_new(&runtimeConfig, config)
        Self.log("app created: \(app != nil)")
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
}

// MARK: - C callbacks
// All Ghostty and CVDisplayLink callbacks run on background threads.
// They are naturally nonisolated as top-level functions in a module
// without SWIFT_DEFAULT_ACTOR_ISOLATION.

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
    default:
        return false
    }
}

private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    Task { @MainActor in
        let string = NSPasteboard.general.string(forType: .string) ?? ""
        string.withCString { _ in
            // Full implementation would track pending clipboard requests per surface
        }
    }
}

private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ str: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    // Auto-confirm clipboard reads for now
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard let content, count > 0 else { return }
    let first = content.pointee
    if let data = first.data {
        let text = String(cString: data)
        Task { @MainActor in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
