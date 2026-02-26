import Cocoa
import GhosttyKit

/// NSView subclass that hosts a ghostty terminal surface with Metal rendering.
public final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {

    public private(set) var surface: ghostty_surface_t?
    private let workingDirectory: String
    private let command: String?

    // Keep C strings alive for the lifetime of the surface
    private var cWorkingDirectory: UnsafeMutablePointer<CChar>?
    private var cCommand: UnsafeMutablePointer<CChar>?

    // Text input
    private var markedText = NSMutableAttributedString()

    /// Called when user presses Cmd+C. Host app should copy tmux buffer to system clipboard.
    public var onCopy: (() -> Void)?

    override public var acceptsFirstResponder: Bool { true }

    public init(workingDirectory: String, command: String? = nil) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {}

    // MARK: - Layer

    override public func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return layer
    }

    // MARK: - Surface Lifecycle

    func createSurface() {
        guard surface == nil else { return }
        guard let app = GhosttyAppManager.shared.app else {
            GhosttyAppManager.log("createSurface: app is nil, skipping")
            return
        }
        GhosttyAppManager.log("createSurface: wd=\(workingDirectory), cmd=\(command ?? "nil"), bounds=\(bounds)")

        cWorkingDirectory = strdup(workingDirectory)
        if let command {
            cCommand = strdup(command)
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        config.font_size = 0
        config.working_directory = UnsafePointer(cWorkingDirectory)
        config.command = UnsafePointer(cCommand)
        config.env_vars = nil
        config.env_var_count = 0
        config.initial_input = nil
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        surface = ghostty_surface_new(app, &config)
        GhosttyAppManager.log("surface created: \(surface != nil), bounds: \(bounds)")

        if surface != nil {
            updateSurfaceSize()
            ghostty_surface_set_focus(surface, true)
            GhosttyAppManager.shared.focusedSurface = surface
        }
    }

    // MARK: - Layout & Rendering

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        GhosttyAppManager.log("viewDidMoveToWindow: window=\(window != nil), surface=\(surface != nil)")
        if window != nil && surface == nil {
            createSurface()
        }
        if window != nil {
            updateSurfaceSize()
            GhosttyAppManager.shared.surfaceDidAppear()
        } else {
            GhosttyAppManager.shared.surfaceDidDisappear()
            destroySurface()
        }
    }

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            destroySurface()
        }
    }

    private func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
        if let cWorkingDirectory {
            free(cWorkingDirectory)
            self.cWorkingDirectory = nil
        }
        if let cCommand {
            free(cCommand)
            self.cCommand = nil
        }
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let widthPx = UInt32(bounds.width * scale)
        let heightPx = UInt32(bounds.height * scale)
        guard widthPx > 0 && heightPx > 0 else { return }

        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, widthPx, heightPx)
    }

    // MARK: - Focus

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
            GhosttyAppManager.shared.focusedSurface = surface
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
            if GhosttyAppManager.shared.focusedSurface == surface {
                GhosttyAppManager.shared.focusedSurface = nil
            }
        }
        return result
    }

    // MARK: - Keyboard Input

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        // Ctrl+/ → treat as Ctrl+_ (avoids macOS beep)
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "/" {
            if let syntheticEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: "_",
                charactersIgnoringModifiers: "_",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) {
                keyDown(with: syntheticEvent)
                return true
            }
        }

        // Ctrl+Return → pass through to keyDown (prevents default context menu)
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "\r" {
            keyDown(with: event)
            return true
        }

        // Cmd+V → pass to keyDown so ghostty handles paste via its keybindings
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            keyDown(with: event)
            return true
        }

        // Cmd+C → copy tmux buffer to system clipboard
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return true
        }

        return false
    }

    override public func keyDown(with event: NSEvent) {
        // Send key event to ghostty first. If ghostty consumed it, we're done.
        // If not, fall through to interpretKeyEvents for IME/dead key handling.
        let consumed = sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        if !consumed {
            interpretKeyEvents([event])
        }
    }

    override public func keyUp(with event: NSEvent) {
        _ = sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    // Prevents audible NSBeep for unhandled selectors (e.g. deleteWordBackward: from Ctrl+W)
    override public func doCommand(by selector: Selector) {}

    override public func flagsChanged(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)

        let action: ghostty_input_action_e
        switch event.keyCode {
        case 56, 60: // left/right shift
            action = mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        case 59, 62: // left/right control
            action = mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        case 58, 61: // left/right option
            action = mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        case 55, 54: // left/right command
            action = mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        default:
            return
        }

        guard let surface else { return }
        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: UInt32(event.keyCode),
            text: nil,
            unshifted_codepoint: 0,
            composing: false
        )
        _ = ghostty_surface_key(surface, keyEvent)
    }

    @discardableResult
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }

        let mods = Self.ghosttyMods(event.modifierFlags)
        let keycode = UInt32(event.keyCode)

        // Unshifted codepoint: the character this key produces with no modifiers applied.
        // Uses byApplyingModifiers([]) instead of charactersIgnoringModifiers because
        // the latter changes behavior with control pressed.
        var unshiftedCodepoint: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                unshiftedCodepoint = codepoint.value
            }
        }

        // Control and command never contribute to text translation
        let consumedMods = ghostty_input_mods_e(rawValue:
            mods.rawValue & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
        )

        // Build text for the key event. Ghostty handles control encoding internally,
        // so we strip control characters and return the unmodified character instead.
        let text: String? = {
            guard action != GHOSTTY_ACTION_RELEASE else { return nil }
            guard let characters = event.characters else { return nil }

            if characters.count == 1, let scalar = characters.unicodeScalars.first {
                // Control character (< 0x20): return the character without control applied
                if scalar.value < 0x20 {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                // PUA range (function keys like F1-F12): don't send as text
                if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                    return nil
                }
            }

            return characters
        }()

        var keyEvent = ghostty_input_key_s(
            action: action,
            mods: mods,
            consumed_mods: consumedMods,
            keycode: keycode,
            text: nil,
            unshifted_codepoint: unshiftedCodepoint,
            composing: false
        )

        // Only pass text if it's a printable character (Ghostty encodes control chars itself)
        if let text, !text.isEmpty,
           let firstByte = text.utf8.first, firstByte >= 0x20 {
            return text.withCString { ptr -> Bool in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        // Called by interpretKeyEvents for IME composition results / dead key output.
        // ghostty_surface_key() already handled normal typing, so this only fires
        // when interpretKeyEvents was invoked (i.e. ghostty didn't consume the key).
        guard let surface else { return }
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }

        guard !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }

        markedText.mutableString.setString("")
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? String {
            markedText.mutableString.setString(s)
        } else if let attr = string as? NSAttributedString {
            markedText.setAttributedString(attr)
        }
    }

    public func unmarkText() {
        markedText.mutableString.setString("")
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func markedRange() -> NSRange {
        if markedText.length > 0 {
            return NSRange(location: 0, length: markedText.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    public func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let windowFrame = window?.frame else { return .zero }
        let viewFrame = convert(bounds, to: nil)
        return NSRect(
            x: windowFrame.origin.x + viewFrame.origin.x,
            y: windowFrame.origin.y + viewFrame.origin.y,
            width: 0,
            height: 0
        )
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: - Mouse Input

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: frame,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let mods = Self.ghosttyMods(event.modifierFlags)
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override public func mouseUp(with event: NSEvent) {
        let mods = Self.ghosttyMods(event.modifierFlags)
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override public func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override public func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseDown(with: event)
        }
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseUp(with: event)
        }
    }

    override public func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = mouseButton(for: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = mouseButton(for: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // Ghostty expects y=0 at top, NSView has y=0 at bottom
        let x = pos.x
        let y = frame.height - pos.y
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    private func mouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        case 5: GHOSTTY_MOUSE_SIX
        case 6: GHOSTTY_MOUSE_SEVEN
        case 7: GHOSTTY_MOUSE_EIGHT
        case 8: GHOSTTY_MOUSE_NINE
        case 9: GHOSTTY_MOUSE_TEN
        case 10: GHOSTTY_MOUSE_ELEVEN
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas

        if precision {
            x *= 1
            y *= 1
        }

        // ghostty_input_scroll_mods_t is a packed bitfield:
        //   bit 0: precision flag (trackpad vs discrete mouse wheel)
        //   bits 1-3: momentum phase enum
        var scrollMods: Int32 = 0
        if precision { scrollMods |= 1 }

        let momentum: Int32 = switch event.momentumPhase {
        case .began:      1
        case .stationary: 2
        case .changed:    3
        case .ended:      4
        case .cancelled:  5
        case .mayBegin:   6
        default:          0
        }
        scrollMods |= momentum << 1

        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(scrollMods))
    }
}
