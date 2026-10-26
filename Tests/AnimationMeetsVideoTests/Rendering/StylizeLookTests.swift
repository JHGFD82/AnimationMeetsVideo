import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The Stylize looks of docs/effects-stylize.md, drawn on known pictures.
@Suite struct StylizeLookTests {
    static let ids = [
        "pixelate", "halftone", "crystallize", "oilPaint", "celShade", "findEdges", "emboss",
        "scanLines", "vhs", "oldFilm", "filmDamage", "strobe",
    ]

    private func kind(_ id: String) -> EffectKind { EffectKind(package: id) }

    private func draw(_ effects: [Effect], _ harness: CompositorHarness, at seconds: Double = 1) throws -> [SIMD4<Float>] {
        try harness.draw(
            [CompositorHarness.clip(track: 1, effects: effects, frame: harness.size)],
            at: CMTime(seconds: seconds, preferredTimescale: 600)
        )
    }

    /// A picture whose every pixel differs: red across, green down.
    private func gradient(_ width: Int = 32, _ height: Int = 32) throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: width, height: height))
        try harness.addPicture(track: 1) { x, y in SIMD4(Float(x), Float(y), 0.5, 1) }
        return harness
    }

    private func solid(_ color: SIMD4<Float>, _ width: Int = 32, _ height: Int = 32) throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: width, height: height))
        try harness.addSolid(track: 1, color)
        return harness
    }

    /// Black on the left half, white on the right.
    private func split(_ width: Int = 32, _ height: Int = 16) throws -> CompositorHarness {
        var harness = CompositorHarness(size: CGSize(width: width, height: height))
        try harness.addPicture(track: 1) { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1) }
        return harness
    }

    private func brightness(_ c: SIMD4<Float>) -> Float { (c.x + c.y + c.z) / 3 }

    @Test func theyShipInStylizeInTheirOrderAndCompile() {
        for id in Self.ids {
            let package = kind(id).definition.package
            #expect(package != nil, "\(id) ships")
            #expect(kind(id).category == .stylize, "\(id)")
            if let package { #expect(PackageKernels.problem(for: package) == nil, "\(id)") }
        }
        let stylize = EffectKind.all.filter { $0.category == .stylize }.map(\.rawValue)
        #expect(stylize == Self.ids)
    }

    @Test func atNoAmountEachLeavesThePictureAlone() throws {
        let h = try gradient(16, 16)
        let original = try draw([], h)
        for id in Self.ids {
            let effect = look(kind(id), ["amount": [0]])
            #expect(effect.isNoOp, "\(id)")
            #expect(try draw([effect], h) == original, "\(id)")
        }
    }

    @Test func pixelateMakesEvenCellsOfItsSize() throws {
        let h = try gradient()
        let drawn = try draw([look(kind("pixelate"), ["cellSize": [4]])], h)
        // Cells are laid out from the middle, 16, so they start at 0, 4, 8….
        for cy in 0..<8 {
            for cx in 0..<8 {
                let first = h.pixel(drawn, x: cx * 4, y: cy * 4)
                for y in cy * 4..<cy * 4 + 4 {
                    for x in cx * 4..<cx * 4 + 4 {
                        #expect(close(h.pixel(drawn, x: x, y: y), first, tolerance: 0.002), "cell \(cx), \(cy) at \(x), \(y)")
                    }
                }
            }
        }
        // And each is its own color, the average under it.
        #expect(!close(h.pixel(drawn, x: 0, y: 0), h.pixel(drawn, x: 4, y: 0), tolerance: 0.05))
        let original = try draw([], h)
        let average = (0..<4).flatMap { y in (0..<4).map { x in h.pixel(original, x: x, y: y) } }.reduce(.zero, +) / 16
        #expect(close(h.pixel(drawn, x: 1, y: 1), average, tolerance: 0.01))
    }

    @Test func hexagonsAreFewColors() throws {
        let h = try gradient()
        let drawn = try draw([look(kind("pixelate"), ["cellSize": [8]], choices: ["cellShape": "hexagons"])], h)
        let colors = Set(drawn.map { SIMD4<Int>(Int(($0.x * 200).rounded()), Int(($0.y * 200).rounded()), 0, 0) })
        // About 16 cells' worth over 32 × 32, far fewer than its pixels.
        #expect(colors.count < 40)
    }

    @Test func halftoneKeepsWhiteLightAndBlackDark() throws {
        for inks in ["mono", "cmyk"] {
            for pattern in ["dots", "lines"] {
                let effect = look(kind("halftone"), ["screenSize": [8]], choices: ["inks": inks, "screenPattern": pattern])
                let white = try draw([effect], try solid(SIMD4(1, 1, 1, 1)))
                let black = try draw([effect], try solid(SIMD4(0, 0, 0, 1)))
                #expect(white.allSatisfy { brightness($0) > 0.97 }, "white, \(inks) \(pattern)")
                #expect(black.allSatisfy { brightness($0) < 0.03 }, "black, \(inks) \(pattern)")
                // A light gray is ink and paper, not gray.
                let gray = try draw([effect], try solid(SIMD4(0.7, 0.7, 0.7, 1)))
                #expect(gray.contains { brightness($0) > 0.9 } && gray.contains { brightness($0) < 0.1 }, "gray, \(inks) \(pattern)")
            }
        }
    }

    @Test func embossOfAFlatPictureIsFlat() throws {
        let h = try solid(SIMD4(0.8, 0.3, 0.1, 1), 16, 16)
        let gray = try draw([look(kind("emboss"))], h)
        let first = gray[0]
        #expect(gray.allSatisfy { close($0, first, tolerance: 0.002) })
        #expect(abs(first.x - first.y) < 0.002 && abs(first.y - first.z) < 0.002)
        // Kept in color, a flat picture is as it was.
        let kept = try draw([look(kind("emboss"), choices: ["reliefColoring": "keep"])], h)
        #expect(kept.allSatisfy { close($0, SIMD4(0.8, 0.3, 0.1, 1), tolerance: 0.01) })
    }

    @Test func embossLightsTheEdgeThatFacesTheLight() throws {
        let h = try split()
        // Light from the left (180°): white's left edge faces it, so the
        // edge between black and white is lit; from the right, shaded.
        let drawn = try draw([look(kind("emboss"), ["lightAngle": [180], "reliefWidth": [1]])], h)
        let flat = h.pixel(drawn, x: 4, y: 8), edge = h.pixel(drawn, x: 16, y: 8)
        #expect(brightness(edge) > brightness(flat) + 0.2)
        let away = try draw([look(kind("emboss"), ["lightAngle": [0], "reliefWidth": [1]])], h)
        #expect(brightness(h.pixel(away, x: 16, y: 8)) < brightness(flat) - 0.2)
    }

    @Test func findEdgesDrawsDarkLinesOnPaper() throws {
        let h = try split()
        for style in ["colored", "pencil", "ink"] {
            let drawn = try draw([look(kind("findEdges"), choices: ["sketchStyle": style])], h)
            #expect(brightness(h.pixel(drawn, x: 4, y: 8)) > 0.97, "\(style) flat black is paper")
            #expect(brightness(h.pixel(drawn, x: 28, y: 8)) > 0.97, "\(style) flat white is paper")
            #expect(brightness(h.pixel(drawn, x: 16, y: 8)) < 0.3, "\(style) edge")
        }
    }

    @Test func celShadeBandsAGradientAndOutlinesEdges() throws {
        var h = CompositorHarness(size: CGSize(width: 64, height: 4))
        try h.addPicture(track: 1) { x, _ in SIMD4(Float(x), Float(x), Float(x), 1) }
        let drawn = try draw([look(kind("celShade"), ["shadeBands": [3], "outlineWidth": [0]])], h)
        let levels = Set(drawn.map { Int(($0.x * 20).rounded()) })
        // Three bands, and a few pixels on the steps between them.
        #expect(levels.count <= 8)
        let edges = try draw([look(kind("celShade"))], try split())
        let h2 = try split()
        #expect(brightness(h2.pixel(edges, x: 16, y: 8)) < 0.05)
        #expect(brightness(h2.pixel(edges, x: 28, y: 8)) > 0.9)
    }

    @Test func oilPaintKeepsFlatAreasAndEdges() throws {
        let flat = try solid(SIMD4(0.2, 0.6, 0.4, 1), 16, 16)
        #expect(try draw([look(kind("oilPaint"))], flat).allSatisfy { close($0, SIMD4(0.2, 0.6, 0.4, 1), tolerance: 0.005) })
        // Beside a hard edge, each side keeps its own color.
        let h = try split()
        let drawn = try draw([look(kind("oilPaint"), ["brushSize": [4]])], h)
        #expect(brightness(h.pixel(drawn, x: 14, y: 8)) < 0.05)
        #expect(brightness(h.pixel(drawn, x: 17, y: 8)) > 0.95)
    }

    @Test func crystallizeKeepsAFlatPictureAndBreaksAGradientIntoCells() throws {
        let flat = try solid(SIMD4(0.2, 0.6, 0.4, 1), 16, 16)
        #expect(try draw([look(kind("crystallize"))], flat).allSatisfy { close($0, SIMD4(0.2, 0.6, 0.4, 1), tolerance: 0.005) })
        let h = try gradient()
        let drawn = try draw([look(kind("crystallize"), ["crystalSize": [8]])], h)
        let colors = Set(drawn.map { SIMD2<Int>(Int(($0.x * 200).rounded()), Int(($0.y * 200).rounded())) })
        #expect(colors.count < 60)
        // Dots leave the background between them.
        let dots = try draw([look(kind("crystallize"), ["crystalSize": [8], "dotSize": [50]], choices: ["crystalStyle": "dots"])], h)
        #expect(dots.contains { close($0, SIMD4(1, 1, 1, 1)) })
    }

    @Test func scanLinesDarkenBetweenLines() throws {
        let h = try solid(SIMD4(0.8, 0.8, 0.8, 1), 8, 16)
        let drawn = try draw([look(kind("scanLines"), ["lineSize": [4], "lineDarkness": [100]], choices: ["phosphorMask": "none"])], h)
        let rows = (0..<16).map { brightness(h.pixel(drawn, x: 2, y: $0)) }
        #expect((rows.max() ?? 0) - (rows.min() ?? 0) > 0.3)
        // Every fourth row alike.
        for y in 0..<12 { #expect(abs(rows[y] - rows[y + 4]) < 0.01) }
        // Still unless it rolls.
        #expect(ClipStack(effects: [look(kind("scanLines"))]).animatedRanges.isEmpty)
        #expect(!ClipStack(effects: [look(kind("scanLines"), ["rollSpeed": [1]])]).animatedRanges.isEmpty)
    }

    @Test func theAnimatedOnesDifferFrameToFrameAndAreMarkedSo() throws {
        let h = try gradient(64, 36)
        let effects = [
            look(kind("vhs")), look(kind("oldFilm")), look(kind("filmDamage"), ["scratches": [100], "dust": [100], "hairs": [100]]),
        ]
        for effect in effects {
            #expect(effect.kind.definition.package?.changesEveryFrame == true, "\(effect.kind.rawValue)")
            #expect(!ClipStack(effects: [effect]).animatedRanges.isEmpty, "\(effect.kind.rawValue)")
            let first = try draw([effect], h, at: 1), again = try draw([effect], h, at: 1)
            let next = try draw([effect], h, at: 1 + 1.0 / 24)
            #expect(first == again, "\(effect.kind.rawValue) draws a frame the same each time")
            #expect(first != next, "\(effect.kind.rawValue) is new each frame")
        }
        // The rest are still, but for Strobe, which runs on its own.
        for id in ["pixelate", "halftone", "crystallize", "oilPaint", "celShade", "findEdges", "emboss"] {
            #expect(ClipStack(effects: [look(kind(id))]).animatedRanges.isEmpty, "\(id)")
        }
    }

    @Test func strobeFlashesForItsLengthEachCycle() throws {
        let h = try solid(SIMD4(0.2, 0.2, 0.2, 1), 4, 4)
        let strobe = look(kind("strobe"), ["strobeRate": [2], "strobeLength": [50]])
        // Two a second, each for a quarter second.
        let on = try draw([strobe], h, at: 0.1), off = try draw([strobe], h, at: 0.35)
        #expect(close(on[0], SIMD4(1, 1, 1, 1)))
        #expect(close(off[0], SIMD4(0.2, 0.2, 0.2, 1)))
        let hidden = try draw([look(kind("strobe"), choices: ["strobeMode": "clear"])], h, at: 0.1)
        // The frame's black shows where the picture was.
        #expect(close(hidden[0], SIMD4(0, 0, 0, 1)))
        let still = try draw([look(kind("strobe"), ["strobeRate": [0]])], h, at: 0.1)
        #expect(close(still[0], SIMD4(0.2, 0.2, 0.2, 1)))
        #expect(!ClipStack(effects: [strobe]).animatedRanges.isEmpty)
    }

    @Test func fastStrobesAndHardFlickerCarryTheFlashingNote() {
        #expect(EditingProject.flashingNote(for: Effect(kind: kind("strobe"))) == nil)
        #expect(EditingProject.flashingNote(for: look(kind("strobe"), ["strobeRate": [8]])) != nil)
        #expect(EditingProject.flashingNote(for: Effect(kind: kind("oldFilm"))) == nil)
        #expect(EditingProject.flashingNote(for: look(kind("oldFilm"), ["flicker": [80]])) != nil)
    }
}
