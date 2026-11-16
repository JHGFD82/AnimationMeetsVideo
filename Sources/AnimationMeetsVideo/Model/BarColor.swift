import Foundation

/// A color a person gave a bar (a clip, a section, the loop region), as it
/// is saved: sRGB, 8 bits a channel. A bar without one is drawn in its
/// default tone. See docs/bar-colors.md.
struct BarColor: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 0xRRGGBB.
    init(_ value: UInt32) {
        self.init(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    /// From channels in 0...1, each rounded to the nearest of 256 steps.
    init(red: Double, green: Double, blue: Double) {
        func byte(_ value: Double) -> UInt8 { UInt8((value.clamped(between: 0, and: 1) * 255).rounded()) }
        self.init(red: byte(red), green: byte(green), blue: byte(blue))
    }

    /// "#3DB8D0", in either case; nil unless it is `#` and six hex digits.
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#" else { return nil }
        let digits = hex.dropFirst()
        guard digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    /// "#3DB8D0": uppercase, as it is saved.
    var hex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    /// The channels in 0...1.
    var components: (red: Double, green: Double, blue: Double) {
        (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }

    /// Relative luminance (WCAG), for choosing the ink on a bar.
    var luminance: Double {
        let c = components
        return Self.luminance(red: c.red, green: c.green, blue: c.blue)
    }

    /// Relative luminance (WCAG) of sRGB channels in 0...1.
    static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio (WCAG) of two luminances, 1 to 21.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: Presets

    struct Preset: Identifiable, Hashable, Sendable {
        /// "Red 1" (lightest) to "Red 7" (darkest), "Gray 1" to "Gray 8":
        /// for VoiceOver and the swatch's tooltip.
        let name: String
        let color: BarColor
        var id: BarColor { color }
    }

    /// Eight hues at seven lightnesses, made at even steps of OKLCH
    /// lightness, and a row of grays: eight rows of eight, light to dark,
    /// as the menu draws them. None is a bar's default tone.
    static let presetRows: [[Preset]] = {
        let hues = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
        let rows: [[UInt32]] = [
            [0xFED2CD, 0xFED4B9, 0xEADEB2, 0xC6E9C6, 0xB0EBEA, 0xC9E0FE, 0xE3D6FE, 0xFECEE4],
            [0xFFABA3, 0xF7B385, 0xD8C477, 0x9BD69C, 0x6CD9D8, 0x9DC7FE, 0xCEB6FC, 0xF6A9CD],
            [0xF28881, 0xE99355, 0xC5A93B, 0x73C076, 0x03C3C3, 0x70ADFB, 0xB897F0, 0xE887B6],
            [0xDF6862, 0xD67523, 0xAC9008, 0x4EA954, 0x05A7A7, 0x4C94EC, 0xA17ADF, 0xD4679F],
            [0xC34F4B, 0xB85F05, 0x907904, 0x33903C, 0x068C8C, 0x337BD0, 0x8962C5, 0xB94F87],
            [0x9A3936, 0x8F4802, 0x6F5C01, 0x207029, 0x086B6C, 0x215DA5, 0x6A499B, 0x913968],
            [0x6E2826, 0x673200, 0x4F4100, 0x17501D, 0x024D4D, 0x174276, 0x4B346F, 0x68284A],
        ]
        let grays: [UInt32] = [0xEEEEEE, 0xD1D1D1, 0xB4B4B4, 0x989898, 0x7D7D7D, 0x636363, 0x4A4A4A, 0x333333]
        let hued = rows.enumerated().map { row, values in
            values.enumerated().map { column, value in
                Preset(name: "\(hues[column]) \(row + 1)", color: BarColor(value))
            }
        }
        let gray = grays.enumerated().map { index, value in Preset(name: "Gray \(index + 1)", color: BarColor(value)) }
        return hued + [gray]
    }()

    static let presets: [Preset] = presetRows.flatMap { $0 }

    /// The preset's name when this color is one, else its hex.
    var name: String {
        Self.presets.first { $0.color == self }?.name ?? hex
    }
}
