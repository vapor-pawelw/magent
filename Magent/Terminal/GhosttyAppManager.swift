import Cocoa
import GhosttyKit

/// Singleton managing the ghostty_app_t instance and runtime callbacks.
final class GhosttyAppManager {

    static let shared = GhosttyAppManager()

    private(set) var app: ghostty_app_t?
    private var isInitialized = false
    private var displayLink: CVDisplayLink?
    private var surfaceCount = 0

    // MARK: - Initialization

    func initialize() {
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

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                GhosttyAppManager.wakeupCallback(userdata)
            },
            action_cb: { app, target, action in
                GhosttyAppManager.actionCallback(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyAppManager.readClipboardCallback(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, str, state, request in
                GhosttyAppManager.confirmReadClipboardCallback(userdata, str: str, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, count, confirm in
                GhosttyAppManager.writeClipboardCallback(userdata, location: location, content: content, count: count, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyAppManager.closeSurfaceCallback(userdata, processAlive: processAlive)
            }
        )

        app = ghostty_app_new(&runtimeConfig, config)
        Self.log("app created: \(app != nil)")
    }

    static func log(_ msg: String) {
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

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
        tickCount += 1
        if tickCount <= 3 || tickCount == 60 {
            Self.log("tick #\(tickCount)")
        }
    }

    // MARK: - Display Link

    func surfaceDidAppear() {
        surfaceCount += 1
        Self.log("surfaceDidAppear: count=\(surfaceCount)")
        startDisplayLinkIfNeeded()
    }

    func surfaceDidDisappear() {
        surfaceCount = max(0, surfaceCount - 1)
        if surfaceCount == 0 {
            stopDisplayLink()
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userdata -> CVReturn in
            let mgr = Unmanaged<GhosttyAppManager>.fromOpaque(userdata!).takeUnretainedValue()
            DispatchQueue.main.async { mgr.tick() }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Callbacks

    private static func wakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            GhosttyAppManager.shared.tick()
        }
    }

    private static func actionCallback(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return true

        case GHOSTTY_ACTION_RING_BELL:
            return true

        case GHOSTTY_ACTION_PWD:
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            return true

        default:
            return false
        }
    }

    private static func readClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async {
            let string = NSPasteboard.general.string(forType: .string) ?? ""
            string.withCString { _ in
                // Full implementation would track pending clipboard requests per surface
            }
        }
    }

    private static func confirmReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        str: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        // Auto-confirm clipboard reads for now
    }

    private static func writeClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard let content, count > 0 else { return }
        let first = content.pointee
        if let data = first.data {
            let text = String(cString: data)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private static func closeSurfaceCallback(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttySurfaceClosed,
                object: nil,
                userInfo: ["processAlive": processAlive]
            )
        }
    }
}

extension Notification.Name {
    static let ghosttySurfaceClosed = Notification.Name("ghosttySurfaceClosed")
}
