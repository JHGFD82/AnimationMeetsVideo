import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The colors a person gives bars (docs/bar-colors.md, "Model").
@Suite struct BarColorTests {
    @Test func hexReadsAndWrites() throws {
        let color = try #require(BarColor(hex: "#3db8d0"))
        #expect(color == BarColor(red: UInt8(0x3D), green: 0xB8, blue: 0xD0))
        #expect(color.hex == "#3DB8D0")
        #expect(BarColor(hex: color.hex) == color)
    }

    @Test(arguments: ["", "#", "#12", "3DB8D0", "#3DB8D", "#3DB8D00", "#3DB8DG", "##3DB8D", "#+DB8D0"])
    func badHexIsRefused(_ text: String) {
        #expect(BarColor(hex: text) == nil)
    }

    @Test func sixtyFourPresetsAllDifferentEightByEight() {
        #expect(BarColor.presetRows.count == 8)
        #expect(BarColor.presetRows.allSatisfy { $0.count == 8 })
        let colors = BarColor.presets.map(\.color)
        #expect(Set(colors).count == 64)
        #expect(Set(BarColor.presets.map(\.name)).count == 64)
        #expect(BarColor.presetRows[0][0].name == "Red 1")
        #expect(BarColor.presetRows[6][7].name == "Pink 7")
        #expect(BarColor.presetRows[7][7].name == "Gray 8")
        #expect(BarColor.presetRows[0][0].color.hex == "#FED2CD")
    }

    @Test func aPresetIsNamedAndAnyOtherColorIsItsHex() {
        #expect(BarColor(0x05A7A7).name == "Teal 4")
        #expect(BarColor(0x123456).name == "#123456")
    }

    @Test func luminanceAndContrastAreWCAGs() {
        #expect(BarColor(0xFFFFFF).luminance == 1)
        #expect(BarColor(0x000000).luminance == 0)
        #expect(abs(BarColor.contrast(1, 0) - 21) < 1e-9)
        // Mid grey: 0x777777 is the darkest grey white text holds 4.5:1 on.
        #expect(BarColor.contrast(1, BarColor(0x777777).luminance) >= 4.47)
    }

    @Test func channelsRoundToTheNearestByte() {
        #expect(BarColor(red: 1.0, green: 0.5, blue: -1) == BarColor(red: UInt8(255), green: 128, blue: 0))
    }
}
