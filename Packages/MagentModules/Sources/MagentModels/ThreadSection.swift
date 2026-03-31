import Cocoa

public nonisolated struct ThreadSection: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var sortOrder: Int
    public var isDefault: Bool
    public var isVisible: Bool
    public var isKeepAlive: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        sortOrder: Int,
        isDefault: Bool = false,
        isVisible: Bool = true,
        isKeepAlive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.isVisible = isVisible
        self.isKeepAlive = isKeepAlive
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, sortOrder, isDefault, isVisible, isKeepAlive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isKeepAlive = try container.decodeIfPresent(Bool.self, forKey: .isKeepAlive) ?? false
    }

    @MainActor
    public var color: NSColor {
        NSColor(hex: colorHex) ?? .systemGray
    }

    public static let colorPalette: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF",
        "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#00C7BE",
    ]

    public static func randomColorHex() -> String {
        colorPalette.randomElement() ?? "#007AFF"
    }

    public static func defaults() -> [ThreadSection] {
        [
            ThreadSection(name: "TODO", colorHex: "#007AFF", sortOrder: 0, isDefault: true),
            ThreadSection(name: "In Progress", colorHex: "#FF9500", sortOrder: 1, isDefault: true),
            ThreadSection(name: "Reviewing", colorHex: "#AF52DE", sortOrder: 2, isDefault: true),
            ThreadSection(name: "Done", colorHex: "#34C759", sortOrder: 3, isDefault: true),
        ]
    }
}

// MARK: - NSColor Hex Extensions

public extension NSColor {
    public convenience init?(hex: String) {
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

    public var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
