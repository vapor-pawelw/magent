import Cocoa
import MagentCore

// MARK: - Notification

extension Notification.Name {
    static let magentKeyBindingsDidChange = Notification.Name("magentKeyBindingsDidChange")
}

// MARK: - NSEvent.ModifierFlags → KeyModifiers

extension KeyModifiers {
    static func from(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result = KeyModifiers()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }
}

extension KeyBinding {
    var menuModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}
