import Cocoa

nonisolated struct ThreadSection: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Int
    var isDefault: Bool
    var isVisible: Bool

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        sortOrder: Int,
        isDefault: Bool = false,
        isVisible: Bool = true
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.isVisible = isVisible
    }

    @MainActor
    var color: NSColor {
        NSColor(hex: colorHex) ?? .systemGray
    }

    static let colorPalette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF",
        "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#00C7BE",
    ]

    static func randomColorHex() -> String {
        colorPalette.randomElement() ?? "#007AFF"
    }

    static func defaults() -> [ThreadSection] {
        [
            ThreadSection(name: "TODO", colorHex: "#007AFF", sortOrder: 0, isDefault: true),
            ThreadSection(name: "In Progress", colorHex: "#FF9500", sortOrder: 1, isDefault: true),
            ThreadSection(name: "Reviewing", colorHex: "#AF52DE", sortOrder: 2, isDefault: true),
            ThreadSection(name: "Done", colorHex: "#34C759", sortOrder: 3, isDefault: true),
        ]
    }
}

// MARK: - NSColor Hex Extensions

extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.hasPrefix("#") ? String(hexSanitized.dropFirst()) : hexSanitized

        guard hexSanitized.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        self.init(
            red: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
