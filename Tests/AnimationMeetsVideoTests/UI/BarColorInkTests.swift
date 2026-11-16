import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The ink on a bar a person colored (docs/bar-colors.md, "Ink"): white or
/// black, whichever reads, at 4.5:1 or better whatever the color.
@MainActor
@Suite struct BarColorInkTests {
    private func better(_ color: BarColor, selected: Bool, enabled: Bool = true, over surface: Design.InkSurface) -> Double {
        let contrast = Design.inkContrast(on: color, selected: selected, enabled: enabled, over: surface)
        return max(contrast.white, contrast.black)
    }

    @Test(arguments: [Design.InkSurface.track, .rail], [false, true])
    func everyPresetHoldsFourAndAHalf(surface: Design.InkSurface, selected: Bool) {
        for preset in BarColor.presets {
            #expect(better(preset.color, selected: selected, over: surface) >= 4.5, "\(preset.name)")
            #expect(better(preset.color, selected: selected, enabled: false, over: surface) >= 4.5, "\(preset.name), off")
        }
    }

    /// The worst case for either ink is a mid luminance, so a sweep of
    /// grays covers any color at all.
    @Test(arguments: [Design.InkSurface.track, .rail])
    func aSweepOfGraysHoldsFourAndAHalf(surface: Design.InkSurface) {
        for level in stride(from: 0, through: 255, by: 5) {
            let gray = BarColor(red: UInt8(level), green: UInt8(level), blue: UInt8(level))
            #expect(better(gray, selected: false, over: surface) >= 4.5, "\(gray.hex)")
            #expect(better(gray, selected: true, over: surface) >= 4.5, "\(gray.hex) selected")
        }
    }

    @Test func paleColorsTakeBlackAndDarkOnesWhite() {
        #expect(Design.ink(on: BarColor(0xFED2CD), selected: false, over: .track) == .black)
        #expect(Design.ink(on: BarColor(0x17501D), selected: false, over: .track) == .white)
        // No color of its own: as before.
        #expect(Design.ink(on: nil, selected: false, over: .track) == Design.textOnColor)
    }
}
