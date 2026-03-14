import Cocoa
import GhosttyKit

private final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

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
    private let linkHoverOverlay = PassthroughVisualEffectView()
    private let linkHoverLabel = NSTextField(labelWithString: "")

    /// Called when user presses Cmd+C. Host app should copy tmux buffer to system clipboard.
    public var onCopy: (() -> Void)?
    /// Called when user submits a line with Return (best-effort local keystroke tracking).
    public var onSubmitLine: ((String) -> Void)?
    /// Called after the user scrolls the terminal surface.
    public var onScroll: (() -> Void)?
    /// Returns a tmux-reported openable URL under the most recent mouse click for this view's session.
    public var resolveTmuxMouseOpenableURL: (() -> String?)?
    /// Resolves a visible URL near the current mouse position using normalized pane coordinates.
    public var resolveTmuxVisibleOpenableURL: ((_ xFraction: Double, _ yFraction: Double) async -> String?)?

    private var currentInputLine = ""
    private var hoveredLinkSource: HoveredLinkSource?
    private var hoveredLinkURL: String?
    private var pendingLinkOpenURL: String?
    private var pendingCommandClick = false
    private var hoverProbeSerial = 0
    private var hoverProbeTask: Task<Void, Never>?
    private static let supportedDropTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .png,
        .tiff,
        .string,
    ]
    private static let shellPathUnescapedCharset = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._/:"
    )
    private enum HoveredLinkSource {
        case ghostty
        case visiblePane
    }

    override public var acceptsFirstResponder: Bool { true }

    public init(workingDirectory: String, command: String? = nil) {
        self.workingDirectory = workingDirectory
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        registerForDraggedTypes(Self.supportedDropTypes)
        configureLinkHoverOverlay()
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

    public func createSurface() {
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

        surface = ghostty_surface_new(app, &config)
        GhosttyAppManager.log("surface created: \(surface != nil), bounds: \(bounds)")

        if surface != nil {
            GhosttyAppManager.shared.registerSurface(surface, effectiveAppearance: effectiveAppearance)
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

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        GhosttyAppManager.shared.refreshAppearance(using: effectiveAppearance)
        // Force an immediate draw (not just a refresh request) so the color scheme
        // change is visible without waiting for the next CVDisplayLink tick.
        ghostty_surface_draw(surface)
    }

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            destroySurface()
        }
    }

    private func destroySurface() {
        if let surface {
            GhosttyAppManager.shared.unregisterSurface(surface)
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
            // Capture pasted text for prompt tracking – ghostty sends paste content
            // directly to the PTY, bypassing keyDown per-character events, so
            // currentInputLine would otherwise miss it.
            if let pasted = NSPasteboard.general.string(forType: .string) {
                appendToCurrentInputLine(pasted)
            }
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
        captureSubmittedLineIfNeeded(from: event)

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
        sendCurrentMousePos(mods: mods)
        refreshHoveredLinkForCurrentMouseLocation()
    }

    private func captureSubmittedLineIfNeeded(from event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76 || event.characters == "\r"
        if isReturnKey {
            let hasOnlyShift = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            guard hasOnlyShift, !event.modifierFlags.contains(.shift) else { return }
            let submitted = currentInputLine.trimmingCharacters(in: .whitespacesAndNewlines)
            currentInputLine.removeAll(keepingCapacity: true)
            if !submitted.isEmpty {
                onSubmitLine?(submitted)
            }
            return
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if !currentInputLine.isEmpty {
                currentInputLine.removeLast()
            }
            return
        }

        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
        guard let chars = event.characters, !chars.isEmpty else { return }
        guard chars.unicodeScalars.allSatisfy({
            guard $0.value >= 0x20 else { return false }
            return !($0.value >= 0xF700 && $0.value <= 0xF8FF)
        }) else { return }

        currentInputLine.append(chars)
        if currentInputLine.count > 600 {
            currentInputLine = String(currentInputLine.suffix(600))
        }
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
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override public func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: hoveredLinkURL == nil ? .arrow : .pointingHand)
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePos(event)
        refreshHoveredLink(at: convert(event.locationInWindow, from: nil))
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelHoverProbe()
        setHoveredLink(nil)
    }

    override public func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updateCursorForCurrentMouseLocation()
    }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePos(event)
        refreshHoveredLink(at: convert(event.locationInWindow, from: nil))
        pendingCommandClick = shouldAttemptCommandLinkOpen(with: event)
        if shouldHandleDirectLinkOpen(with: event) {
            pendingLinkOpenURL = hoveredLinkURL
            return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override public func mouseUp(with event: NSEvent) {
        sendMousePos(event)
        refreshHoveredLink(at: convert(event.locationInWindow, from: nil))
        if let pendingLinkOpenURL {
            self.pendingLinkOpenURL = nil
            pendingCommandClick = false
            if shouldHandleDirectLinkOpen(with: event), hoveredLinkURL == pendingLinkOpenURL {
                GhosttyAppManager.shared.openURL(pendingLinkOpenURL)
            }
            return
        }
        let mods = Self.ghosttyMods(event.modifierFlags)
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)

        if pendingCommandClick,
           let url = resolveTmuxMouseOpenableURL?(),
           shouldAttemptCommandLinkOpen(with: event) {
            GhosttyAppManager.shared.openURL(url)
        }
        pendingCommandClick = false
    }

    override public func mouseDragged(with event: NSEvent) {
        if pendingLinkOpenURL != nil {
            pendingLinkOpenURL = nil
            pendingCommandClick = false
            return
        }
        if pendingCommandClick {
            pendingCommandClick = false
        }
        sendMousePos(event)
    }

    override public func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
        refreshHoveredLink(at: convert(event.locationInWindow, from: nil))
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard let surface else { return super.rightMouseDown(with: event) }
        sendMousePos(event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseDown(with: event)
        }
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard let surface else { return super.rightMouseUp(with: event) }
        sendMousePos(event)
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
        sendMousePos(event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = mouseButton(for: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = mouseButton(for: event.buttonNumber)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    private func sendMousePos(_ event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        sendMousePos(at: pos, mods: Self.ghosttyMods(event.modifierFlags))
    }

    private func sendCurrentMousePos(mods: ghostty_input_mods_e) {
        guard let window else { return }
        let pos = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(pos) else { return }
        sendMousePos(at: pos, mods: mods)
    }

    private func sendMousePos(at pos: NSPoint, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        // Ghostty expects y=0 at top, NSView has y=0 at bottom
        let x = pos.x
        let y = bounds.height - pos.y
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    private func shouldAttemptCommandLinkOpen(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        guard !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else { return false }
        let pos = convert(event.locationInWindow, from: nil)
        return bounds.contains(pos)
    }

    private func shouldHandleDirectLinkOpen(with event: NSEvent) -> Bool {
        guard hoveredLinkURL != nil else { return false }
        return shouldAttemptCommandLinkOpen(with: event)
    }

    private func refreshHoveredLinkForCurrentMouseLocation() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        refreshHoveredLink(at: point)
    }

    private func refreshHoveredLink(at point: NSPoint) {
        guard bounds.contains(point) else {
            cancelHoverProbe()
            if hoveredLinkSource != .ghostty {
                applyHoveredLink(nil, source: nil)
            }
            return
        }

        scheduleHoverProbe(at: point)
    }

    // Debounced probe: waits 45 ms after the last mouse move, then falls back to a tmux
    // visible-pane scan for URLs that Ghostty's native OSC 8 detection didn't catch.
    // ghostty_surface_quicklook_word is intentionally NOT called here — calling Ghostty
    // C API from a MainActor.run block inside a background Task deadlocks against
    // ghostty_app_tick, which also needs the main actor. Ghostty's own MOUSE_OVER_LINK
    // callback (setHoveredLink) handles the rendered-word/OSC 8 case natively.
    private func scheduleHoverProbe(at point: NSPoint) {
        hoverProbeTask?.cancel()
        hoverProbeSerial += 1
        let probeSerial = hoverProbeSerial
        let xFraction = bounds.width > 0 ? Double(point.x / bounds.width) : 0
        let yFromTop = bounds.height > 0 ? Double((bounds.height - point.y) / bounds.height) : 0
        let resolveTmux = resolveTmuxVisibleOpenableURL

        hoverProbeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled else { return }

            // If Ghostty already detected a link natively, the tmux probe is moot.
            let shouldSkip = await MainActor.run { [weak self] () -> Bool in
                guard let self, self.hoverProbeSerial == probeSerial else { return true }
                return self.hoveredLinkSource == .ghostty
            }
            guard !shouldSkip else { return }

            // tmux visible-pane fallback for URLs Ghostty didn't detect via OSC 8.
            guard let resolveTmux else {
                await MainActor.run { [weak self] in
                    guard let self, self.hoverProbeSerial == probeSerial else { return }
                    if self.hoveredLinkSource == .visiblePane {
                        self.applyHoveredLink(nil, source: nil)
                    }
                }
                return
            }

            let url = await resolveTmux(xFraction, yFromTop)
            await MainActor.run { [weak self] in
                guard let self, self.hoverProbeSerial == probeSerial else { return }
                if self.hoveredLinkSource == .ghostty { return }
                let source: HoveredLinkSource? = url == nil ? nil : .visiblePane
                self.applyHoveredLink(url, source: source)
            }
        }
    }

    private func cancelHoverProbe() {
        hoverProbeTask?.cancel()
        hoverProbeTask = nil
        hoverProbeSerial += 1
    }

    private func mouseButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: GHOSTTY_MOUSE_LEFT
        case 1: GHOSTTY_MOUSE_RIGHT
        case 2: GHOSTTY_MOUSE_MIDDLE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override public func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event)

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
        onScroll?()
    }

    // MARK: - Drag and Drop

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canHandleDrop(sender.draggingPasteboard) ? .copy : []
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canHandleDrop(sender.draggingPasteboard) ? .copy : []
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canHandleDrop(sender.draggingPasteboard)
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        window?.makeFirstResponder(self)
        return handleDrop(sender.draggingPasteboard)
    }

    private func canHandleDrop(_ pasteboard: NSPasteboard) -> Bool {
        !droppedFileURLs(from: pasteboard).isEmpty
            || hasDroppedImagePayload(in: pasteboard)
            || (pasteboard.string(forType: .string)?.isEmpty == false)
    }

    private func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
        let fileURLs = droppedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            let text = fileURLs
                .map(\.path)
                .map(Self.shellEscapePathForPaste)
                .joined(separator: "\n") + "\n"
            return pasteDroppedText(text)
        }

        if let imageURL = droppedImageTemporaryURL(from: pasteboard) {
            return pasteDroppedText(Self.shellEscapePathForPaste(imageURL.path) + "\n")
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return pasteDroppedText(text)
        }

        return false
    }

    private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects
            .compactMap { $0 as? NSURL }
            .map { $0 as URL }
            .filter(\.isFileURL)
    }

    private func hasDroppedImagePayload(in pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private func droppedImageTemporaryURL(from pasteboard: NSPasteboard) -> URL? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("magent-dropped-images", isDirectory: true)

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            GhosttyAppManager.log("drop image: failed to create temp dir: \(error)")
            return nil
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = String(UUID().uuidString.prefix(8))
        let url = tempDir.appendingPathComponent("dropped-image-\(timestamp)-\(suffix).png")

        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            GhosttyAppManager.log("drop image: failed to write temp image: \(error)")
            return nil
        }
    }

    /// Invokes a named ghostty binding action on this surface (e.g. "scroll_to_bottom").
    @discardableResult
    public func bindingAction(_ actionName: String) -> Bool {
        guard let surface else { return false }
        return actionName.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(actionName.utf8.count))
        }
    }

    private func pasteDroppedText(_ text: String) -> Bool {
        guard let surface, !text.isEmpty else { return false }

        appendToCurrentInputLine(text)
        if GhosttyAppManager.shared.pasteText(text, on: surface) {
            return true
        }

        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
        return true
    }

    private func appendToCurrentInputLine(_ text: String) {
        currentInputLine.append(text)
        if currentInputLine.count > 600 {
            currentInputLine = String(currentInputLine.suffix(600))
        }
    }

    private func configureLinkHoverOverlay() {
        linkHoverOverlay.translatesAutoresizingMaskIntoConstraints = false
        linkHoverOverlay.blendingMode = .withinWindow
        linkHoverOverlay.material = .hudWindow
        linkHoverOverlay.state = .active
        linkHoverOverlay.isHidden = true
        linkHoverOverlay.alphaValue = 0
        linkHoverOverlay.wantsLayer = true
        linkHoverOverlay.layer?.cornerRadius = 10
        linkHoverOverlay.layer?.cornerCurve = .continuous

        linkHoverLabel.translatesAutoresizingMaskIntoConstraints = false
        linkHoverLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        linkHoverLabel.lineBreakMode = .byTruncatingMiddle
        linkHoverLabel.maximumNumberOfLines = 1
        linkHoverLabel.textColor = .labelColor

        linkHoverOverlay.addSubview(linkHoverLabel)
        addSubview(linkHoverOverlay)

        NSLayoutConstraint.activate([
            linkHoverOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            linkHoverOverlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            linkHoverOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            linkHoverOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            linkHoverOverlay.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.75),

            linkHoverLabel.leadingAnchor.constraint(equalTo: linkHoverOverlay.leadingAnchor, constant: 12),
            linkHoverLabel.trailingAnchor.constraint(equalTo: linkHoverOverlay.trailingAnchor, constant: -12),
            linkHoverLabel.topAnchor.constraint(equalTo: linkHoverOverlay.topAnchor, constant: 7),
            linkHoverLabel.bottomAnchor.constraint(equalTo: linkHoverOverlay.bottomAnchor, constant: -7),
        ])
    }

    public func setHoveredLink(_ urlString: String?) {
        let normalizedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextURL = normalizedURL?.isEmpty == false ? normalizedURL : nil
        applyHoveredLink(nextURL, source: nextURL == nil ? nil : .ghostty)
    }

    private func applyHoveredLink(_ nextURL: String?, source: HoveredLinkSource?) {
        let normalizedSource = nextURL == nil ? nil : source
        guard hoveredLinkURL != nextURL || hoveredLinkSource != normalizedSource else { return }
        hoveredLinkURL = nextURL
        hoveredLinkSource = normalizedSource
        toolTip = nextURL
        updateLinkHoverOverlay(for: nextURL)
        window?.invalidateCursorRects(for: self)
        updateCursorForCurrentMouseLocation()
    }

    private func updateLinkHoverOverlay(for urlString: String?) {
        let visible = urlString != nil
        if let urlString {
            linkHoverLabel.stringValue = urlString
        }

        if visible == !linkHoverOverlay.isHidden {
            return
        }

        if visible {
            linkHoverOverlay.isHidden = false
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.08 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            linkHoverOverlay.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            if !visible {
                self.linkHoverOverlay.isHidden = true
            }
        }
    }

    private func updateCursorForCurrentMouseLocation() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        (hoveredLinkURL == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    private static func shellEscapePathForPaste(_ path: String) -> String {
        guard !path.isEmpty else { return "''" }

        if path.unicodeScalars.allSatisfy({ shellPathUnescapedCharset.contains($0) }) {
            return path
        }

        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
