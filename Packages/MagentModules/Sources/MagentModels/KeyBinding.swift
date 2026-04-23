import Foundation

public enum KeyBindingAction: String, Codable, Sendable, CaseIterable {
    case newThread
    case newThreadFromBranch
    case newTab
    case closeTab
    case reopenLastClosedTab
    case refreshWebTab
    case hardRefreshWebTab
    case popOutThread
    case detachTab
    case toggleSidebar

    public var displayName: String {
        switch self {
        case .newThread: "New Thread"
        case .newThreadFromBranch: "Fork Thread"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .reopenLastClosedTab: "Reopen Closed Tab"
        case .refreshWebTab: "Refresh Web Tab"
        case .hardRefreshWebTab: "Hard Refresh Web Tab"
        case .popOutThread: "Pop Out Thread"
        case .detachTab: "Detach Tab"
        case .toggleSidebar: "Toggle Sidebar"
        }
    }

    public var defaultBinding: KeyBinding {
        switch self {
        case .newThread: KeyBinding(keyCode: 45, modifiers: [.command]) // Cmd+N
        case .newThreadFromBranch: KeyBinding(keyCode: 45, modifiers: [.command, .shift]) // Cmd+Shift+N
        case .newTab: KeyBinding(keyCode: 17, modifiers: [.command]) // Cmd+T
        case .closeTab: KeyBinding(keyCode: 13, modifiers: [.command]) // Cmd+W
        case .reopenLastClosedTab: KeyBinding(keyCode: 17, modifiers: [.command, .shift]) // Cmd+Shift+T
        case .refreshWebTab: KeyBinding(keyCode: 15, modifiers: [.command]) // Cmd+R
        case .hardRefreshWebTab: KeyBinding(keyCode: 15, modifiers: [.command, .shift]) // Cmd+Shift+R
        case .popOutThread: KeyBinding(keyCode: 31, modifiers: [.command, .shift]) // Cmd+Shift+O
        case .detachTab: KeyBinding(keyCode: 2, modifiers: [.command, .shift]) // Cmd+Shift+D
        case .toggleSidebar: KeyBinding(keyCode: 1, modifiers: [.command, .control]) // Cmd+Ctrl+S
        }
    }
}

public struct KeyBinding: Codable, Sendable, Equatable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The lowercase character for use as an NSMenuItem keyEquivalent.
    public var menuKeyEquivalent: String {
        Self.keyCodeName(keyCode).lowercased()
    }

    public var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("^") }
        if modifiers.contains(.option) { parts.append("\u{2325}") }
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }
        parts.append(Self.keyCodeName(keyCode))
        return parts.joined()
    }

    private static func keyCodeName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "\u{21A9}" // Return
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "\u{21E5}" // Tab
        case 49: return "\u{2423}" // Space
        case 50: return "`"
        case 51: return "\u{232B}" // Delete
        case 53: return "\u{238B}" // Escape
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "\u{2190}" // Left
        case 124: return "\u{2192}" // Right
        case 125: return "\u{2193}" // Down
        case 126: return "\u{2191}" // Up
        default: return "Key\(keyCode)"
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public var rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyBindingSettings: Codable, Sendable, Equatable {
    public var overrides: [String: KeyBinding]

    public init(overrides: [String: KeyBinding] = [:]) {
        self.overrides = overrides
    }

    public func binding(for action: KeyBindingAction) -> KeyBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    public mutating func setBinding(_ binding: KeyBinding, for action: KeyBindingAction) {
        overrides[action.rawValue] = binding
    }

    public mutating func resetBinding(for action: KeyBindingAction) {
        overrides.removeValue(forKey: action.rawValue)
    }

    public func isCustomized(_ action: KeyBindingAction) -> Bool {
        guard let override = overrides[action.rawValue] else { return false }
        return override != action.defaultBinding
    }
}
