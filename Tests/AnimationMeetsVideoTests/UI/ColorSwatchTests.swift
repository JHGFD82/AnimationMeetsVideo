import AppKit
import Testing
@testable import AnimationMeetsVideo

/// A menu's color swatches are drawn in their own colors: a menu draws a
/// template in its text color, so every swatch would be alike.
@MainActor
@Suite struct ColorSwatchTests {
    /// The swatch's middle, as the screen's color management leaves it.
    private func middle(_ image: NSImage) throws -> (Double, Double, Double) {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    @Test func eachSwatchIsItsOwnColorNotATemplate() throws {
        let colors = [BarColor(0xDF6862), BarColor(0x05A7A7), BarColor(0xFF2DC8), BarColor(0xF2C230)]
        for color in colors {
            let image = ColorSwatch.image(color)
            #expect(!image.isTemplate)
            let drawn = try middle(image)
            // Nearer its own color than any other's (color management
            // shifts it a little, never that far).
            func distance(_ other: BarColor) -> Double {
                let c = other.components
                return hypot(hypot(drawn.0 - c.red, drawn.1 - c.green), drawn.2 - c.blue)
            }
            let nearest = colors.min { distance($0) < distance($1) }
            #expect(nearest == color, "\(color.hex) drew as \(drawn)")
            #expect(distance(color) < 0.2, "\(color.hex) drew as \(drawn)")
        }
    }
}
