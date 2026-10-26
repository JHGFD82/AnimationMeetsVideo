import CoreImage
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A picture whose straight RGBA at each pixel (fractions across and down,
/// from the top left) is given, and the looks drawn on it read back with
/// their alpha, which the compositor's frame, flattened onto black, hides.
private struct Picture {
    typealias Color = SIMD4<Float>

    let size: CGSize
    let image: CIImage

    init(width: Int, height: Int, _ color: (Double, Double) -> Color) {
        size = CGSize(width: width, height: height)
        var floats: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                let c = color((Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
                floats += [c.x * c.w, c.y * c.w, c.z * c.w, c.w]
            }
        }
        let data = floats.withUnsafeBytes { Data($0) }
        image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: size, format: .RGBAf, colorSpace: nil)
    }

    /// `effects` drawn on the picture in turn, as straight RGBA per pixel
    /// from the top left; `pictures` are their input pictures by ID.
    func draw(_ effects: [Effect], pictures: [String: CIImage] = [:]) throws -> [Color] {
        let frame = CGRect(origin: .zero, size: size)
        var drawn = image
        for effect in effects {
            guard let step = LookStep(effect, at: CMTime(value: 1, timescale: 2)) else { continue }
            drawn = LookRenderer.apply(
                step, to: drawn, over: frame, canvas: frame, frame: frame, scale: 1, space: .rec709,
                pictures: pictures, flags: pictures.isEmpty ? [:] : ["hasInput": 1]
            )
        }
        let width = Int(size.width), height = Int(size.height)
        var bytes = [Float](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(
                drawn, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: frame, format: .RGBAf, colorSpace: nil
            )
        }
        var colors: [Color] = []
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a = bytes[i + 3]
                colors.append(a > 0 ? Color(bytes[i] / a, bytes[i + 1] / a, bytes[i + 2] / a, a) : .zero)
            }
        }
        return colors
    }

    func pixel(_ colors: [Color], x: Int, y: Int) -> Color {
        colors[y * Int(size.width) + x]
    }
}

/// The Keying & Masks packages (docs/effects-keying.md), drawn on pictures
/// whose answers are known.
@Suite struct KeyingTests {
    private typealias Color = SIMD4<Float>

    private static func kind(_ id: String) throws -> EffectKind {
        let kind = try #require(EffectKind(rawValue: id), "\(id) ships")
        #expect(kind.category == .keying)
        return kind
    }

    private func draw(_ effects: [Effect], _ picture: Picture) throws -> [Color] {
        try picture.draw(effects)
    }

    private static func inMiddle(_ x: Double, _ y: Double) -> Bool {
        (0.25..<0.75).contains(x) && (0.25..<0.75).contains(y)
    }

    /// A green field 32 pixels square with a red square in its middle,
    /// pixels 8 to 23 across and down.
    private func greenScreen(field: Color = Color(0, 1, 0, 1)) -> Picture {
        Picture(width: 32, height: 32) { Self.inMiddle($0, $1) ? Color(1, 0, 0, 1) : field }
    }

    /// A field 64 by 32 of one color, for the masks.
    private func field(_ color: Color = Color(0.2, 0.4, 0.6, 1)) -> Picture {
        Picture(width: 64, height: 32) { _, _ in color }
    }

    /// A red square on nothing, pixels 8 to 23 across and down.
    private func square() -> Picture {
        Picture(width: 32, height: 32) { Self.inMiddle($0, $1) ? Color(1, 0, 0, 1) : .zero }
    }

    @Test func everyKeyAndMaskShipsInItsCategoryInOrder() throws {
        let keying = EffectKind.all.filter { $0.category == .keying }.map(\.rawValue)
        #expect(keying == [
            "chromaKey", "lumaKey", "differenceKey", "spillSuppressor", "matteChoker",
            "rectangleMask", "ellipseMask", "fourPointMask", "gradientMask", "alphaTools",
        ])
        for id in keying {
            let package = try #require(try Self.kind(id).definition.package)
            #expect(PackageKernels.problem(for: package) == nil, "\(id)")
        }
        // Only the ones reading beside each pixel settle what is above them.
        #expect(try Self.kind("matteChoker").readsBesidePixels && Self.kind("differenceKey").readsBesidePixels)
        #expect(try !Self.kind("chromaKey").readsBesidePixels && !Self.kind("rectangleMask").readsBesidePixels)
        #expect(try Self.kind("differenceKey").takesInput)
    }

    // MARK: Keys

    @Test func aChromaKeyClearsTheScreenAndKeepsTheSubject() throws {
        let h = greenScreen()
        let key = look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1]])
        let drawn = try draw([key], h)
        #expect(h.pixel(drawn, x: 2, y: 2).w < 0.01)
        #expect(close(h.pixel(drawn, x: 16, y: 16), Color(1, 0, 0, 1), tolerance: 0.02))

        // At no Amount it draws nothing.
        let none = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1], "amount": [0]])], h)
        #expect(close(h.pixel(none, x: 2, y: 2), Color(0, 1, 0, 1)))

        // The matte on its own: white kept, black keyed out, all opaque.
        let matte = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1]], choices: ["keyView": "matte"])], h)
        #expect(close(h.pixel(matte, x: 2, y: 2), Color(0, 0, 0, 1)))
        #expect(close(h.pixel(matte, x: 16, y: 16), Color(1, 1, 1, 1), tolerance: 0.02))
    }

    @Test func atItsDefaultsAChromaKeyClearsAGreenScreenAndKeepsSkin() throws {
        let key = look(try Self.kind("chromaKey"))
        for screen in [Color(0.15, 0.75, 0.3, 1), Color(0.1, 0.6, 0.2, 1), Color(0.3, 0.85, 0.35, 1)] {
            #expect(try draw([key], greenScreen(field: screen))[0].w < 0.01, "\(screen)")
        }
        for kept in [Color(0.85, 0.65, 0.5, 1), Color(0.35, 0.22, 0.15, 1), Color(0.2, 0.3, 0.8, 1), Color(1, 1, 1, 1)] {
            #expect(try draw([key], greenScreen(field: kept))[0].w > 0.99, "\(kept)")
        }
    }

    @Test func aChromaKeyClearsTheScreenInShadowToo() throws {
        let shadow = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1]])], greenScreen(field: Color(0, 0.45, 0, 1)))
        #expect(shadow[0].w < 0.01)
        // Gray is no green, so it stays.
        let gray = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1]])], greenScreen(field: Color(0.5, 0.5, 0.5, 1)))
        #expect(close(gray[0], Color(0.5, 0.5, 0.5, 1), tolerance: 0.02))
    }

    @Test func softnessLeavesThePixelsBetweenPartlyClear() throws {
        // A green with some gray in it, between the key and gray.
        let h = greenScreen(field: Color(0.3, 0.6, 0.3, 1))
        let hard = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1], "keyTolerance": [100], "keySoftness": [0]])], h)
        #expect(hard[0].w < 0.01)
        let soft = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1], "keyTolerance": [20], "keySoftness": [100]])], h)
        #expect(soft[0].w > 0.05 && soft[0].w < 0.95)
    }

    @Test func spillSuppressionTakesTheKeyColorOutOfWhatIsKept() throws {
        // A gray with a green cast, too far from the key to be keyed out.
        let h = greenScreen(field: Color(0.4, 0.55, 0.4, 1))
        let kept = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1], "keyTolerance": [5], "keySoftness": [0], "spillSuppression": [100]])], h)
        #expect(kept[0].w > 0.99)
        #expect(abs(kept[0].y - kept[0].x) < 0.03 && abs(kept[0].y - kept[0].z) < 0.03)
        let untouched = try draw([look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1], "keyTolerance": [5], "keySoftness": [0], "spillSuppression": [0]])], h)
        #expect(close(untouched[0], Color(0.4, 0.55, 0.4, 1)))
    }

    @Test func theSpillSuppressorGraysTheSpillAndLeavesOtherColors() throws {
        let spill = try Self.kind("spillSuppressor")
        let cast = try draw([look(spill, ["spillColor": [0, 1, 0, 1]])], greenScreen(field: Color(0.4, 0.55, 0.4, 1)))
        #expect(abs(cast[0].y - cast[0].x) < 0.03 && abs(cast[0].y - cast[0].z) < 0.03 && cast[0].w == 1)
        // Magenta leans away from green, so it is as it was.
        let magenta = try draw([look(spill, ["spillColor": [0, 1, 0, 1]])], greenScreen(field: Color(0.8, 0.2, 0.8, 1)))
        #expect(close(magenta[0], Color(0.8, 0.2, 0.8, 1)))
        let none = try draw([look(spill, ["spillColor": [0, 1, 0, 1], "amount": [0]])], greenScreen(field: Color(0.4, 0.55, 0.4, 1)))
        #expect(close(none[0], Color(0.4, 0.55, 0.4, 1)))
    }

    @Test func aLumaKeyClearsTheDarksOrTheBrights() throws {
        let h = Picture(width: 2, height: 1) { x, _ in x < 0.5 ? Color(0, 0, 0, 1) : Color(1, 1, 1, 1) }
        let darks = try draw([look(try Self.kind("lumaKey"))], h)
        #expect(darks[0].w < 0.01 && close(darks[1], Color(1, 1, 1, 1)))
        let brights = try draw([look(try Self.kind("lumaKey"), ["lumaThreshold": [90]], choices: ["lumaKeyOut": "bright"])], h)
        #expect(close(brights[0], Color(0, 0, 0, 1)) && brights[1].w < 0.01)
        let none = try draw([look(try Self.kind("lumaKey"), ["amount": [0]])], h)
        #expect(close(none[0], Color(0, 0, 0, 1)))
    }

    @Test func aDifferenceKeyClearsWhatMatchesTheCleanPlate() throws {
        // The shot: gray with a red square; the plate: the gray alone.
        let shot = greenScreen(field: Color(0.5, 0.5, 0.5, 1))
        let plate = Picture(width: 32, height: 32) { _, _ in Color(0.5, 0.5, 0.5, 1) }
        let key = look(try Self.kind("differenceKey"))
        #expect(key.isNoOp)
        let drawn = try shot.draw([key], pictures: ["plate": plate.image])
        #expect(shot.pixel(drawn, x: 2, y: 2).w < 0.01)
        #expect(close(shot.pixel(drawn, x: 16, y: 16), Color(1, 0, 0, 1)))
        // Where the plate has nothing, the picture is kept.
        let empty = Picture(width: 32, height: 32) { _, _ in .zero }
        #expect(close(try shot.draw([key], pictures: ["plate": empty.image])[0], Color(0.5, 0.5, 0.5, 1)))
    }

    /// Through the compositor, what a key clears shows the layer below.
    @Test func whatAKeyClearsShowsTheLayerBelow() throws {
        var h = CompositorHarness(size: CGSize(width: 32, height: 32))
        try h.addPicture(track: 1) { x, y in Self.inMiddle(x, y) ? Color(1, 0, 0, 1) : Color(0, 1, 0, 1) }
        try h.addSolid(track: 2, Color(0, 0, 1, 1))
        let key = look(try Self.kind("chromaKey"), ["keyColor": [0, 1, 0, 1]])
        let drawn = try h.draw([
            CompositorHarness.clip(track: 1, effects: [key], frame: h.size), CompositorHarness.clip(track: 2, frame: h.size),
        ])
        #expect(close(h.pixel(drawn, x: 2, y: 2), Color(0, 0, 1, 1), tolerance: 0.02))
        #expect(close(h.pixel(drawn, x: 16, y: 16), Color(1, 0, 0, 1), tolerance: 0.02))
    }

    // MARK: Mattes

    @Test func theMatteChokerShrinksAndGrowsTheEdge() throws {
        let h = square()
        let choker = try Self.kind("matteChoker")
        let original = try draw([], h)
        #expect(try draw([look(choker, ["chokeGrow": [0], "chokeFeather": [0]])], h) == original)

        // Shrunk by 4 the square's edge is at 12, so 10 is clear and 14 kept.
        let shrunk = try draw([look(choker, ["chokeGrow": [-4], "chokeFeather": [0]])], h)
        #expect(h.pixel(shrunk, x: 10, y: 16).w < 0.05)
        #expect(close(h.pixel(shrunk, x: 14, y: 16), Color(1, 0, 0, 1), tolerance: 0.02))
        // Grown by 4 it is at 4, and what grows takes the square's color.
        let grown = try draw([look(choker, ["chokeGrow": [4], "chokeFeather": [0]])], h)
        #expect(close(h.pixel(grown, x: 5, y: 16), Color(1, 0, 0, 1), tolerance: 0.05))
        #expect(h.pixel(grown, x: 2, y: 16).w < 0.05)
        // Feathered, it is half clear at the edge, and as it was away from it.
        let feathered = try draw([look(choker, ["chokeGrow": [0], "chokeFeather": [8]])], h)
        let edge = (h.pixel(feathered, x: 7, y: 16).w + h.pixel(feathered, x: 8, y: 16).w) / 2
        #expect(abs(edge - 0.5) < 0.1)
        #expect(h.pixel(feathered, x: 1, y: 16).w < 0.01 && h.pixel(feathered, x: 15, y: 16).w > 0.99)
        #expect(h.pixel(feathered, x: 6, y: 16).w < h.pixel(feathered, x: 9, y: 16).w)
        let none = try draw([look(choker, ["chokeGrow": [-4], "amount": [0]])], h)
        #expect(none == original)
    }

    @Test func aRectangleMaskKeepsInsideAndSoftensItsEdge() throws {
        let h = field()
        let mask = try Self.kind("rectangleMask")
        let color = Color(0.2, 0.4, 0.6, 1)
        // 32 by 16 in the middle: 16 to 47 across, 8 to 23 down.
        let hard = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [0]])], h)
        #expect(close(h.pixel(hard, x: 32, y: 16), color))
        #expect(close(h.pixel(hard, x: 17, y: 9), color))
        #expect(h.pixel(hard, x: 14, y: 16).w == 0 && h.pixel(hard, x: 32, y: 6).w == 0 && h.pixel(hard, x: 2, y: 2).w == 0)
        // Keep Outside turns it around.
        let outside = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [0]], choices: ["maskKeep": "outside"])], h)
        #expect(h.pixel(outside, x: 32, y: 16).w == 0 && close(h.pixel(outside, x: 2, y: 2), color))
        // Feathered: half way at the edge, rising inward.
        let soft = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [8]])], h)
        let edge = (h.pixel(soft, x: 15, y: 16).w + h.pixel(soft, x: 16, y: 16).w) / 2
        #expect(abs(edge - 0.5) < 0.05)
        #expect(h.pixel(soft, x: 11, y: 16).w < 0.01 && h.pixel(soft, x: 20, y: 16).w > 0.99)
        #expect(h.pixel(soft, x: 14, y: 16).w < h.pixel(soft, x: 17, y: 16).w)
        // Moved down by 8, and turned upright.
        let moved = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [0], "maskCenter": [0, 8]])], h)
        #expect(h.pixel(moved, x: 32, y: 28).w == 1 && h.pixel(moved, x: 32, y: 12).w == 0)
        let turned = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [0], "maskAngle": [90]])], h)
        #expect(h.pixel(turned, x: 32, y: 2).w == 1 && h.pixel(turned, x: 20, y: 16).w == 0)
        // Rounded corners cut the corner pixel.
        let round = try draw([look(mask, ["maskSize": [32, 16], "maskFeather": [0], "maskRoundness": [8]])], h)
        #expect(h.pixel(round, x: 16, y: 8).w == 0 && h.pixel(round, x: 32, y: 8).w == 1)
        let none = try draw([look(mask, ["maskSize": [32, 16], "amount": [0]])], h)
        #expect(close(h.pixel(none, x: 2, y: 2), color))
    }

    @Test func anEllipseMaskKeepsACircle() throws {
        let h = field()
        let mask = try Self.kind("ellipseMask")
        let drawn = try draw([look(mask, ["maskSize": [20, 20], "maskFeather": [0]])], h)
        #expect(h.pixel(drawn, x: 32, y: 16).w == 1 && h.pixel(drawn, x: 39, y: 16).w == 1 && h.pixel(drawn, x: 32, y: 8).w == 1)
        #expect(h.pixel(drawn, x: 44, y: 16).w == 0 && h.pixel(drawn, x: 40, y: 9).w == 0)
        let outside = try draw([look(mask, ["maskSize": [20, 20], "maskFeather": [0]], choices: ["maskKeep": "outside"])], h)
        #expect(h.pixel(outside, x: 32, y: 16).w == 0 && h.pixel(outside, x: 2, y: 2).w == 1)
        // Its feather is even all the way round: as soft across as down.
        let soft = try draw([look(mask, ["maskSize": [40, 20], "maskFeather": [6]])], h)
        #expect(abs(h.pixel(soft, x: 51, y: 16).w - h.pixel(soft, x: 32, y: 25).w) < 0.1)
    }

    @Test func aFourPointMaskKeepsInsideItsCorners() throws {
        let h = field()
        let mask = try Self.kind("fourPointMask")
        // A triangle-like quad: its top corners together at the middle top.
        let corners: [String: [Double]] = [
            "cornerTopLeft": [0, -16], "cornerTopRight": [0, -16], "cornerBottomRight": [32, 16], "cornerBottomLeft": [-32, 16],
            "maskFeather": [0],
        ]
        let drawn = try draw([look(mask, corners)], h)
        #expect(h.pixel(drawn, x: 32, y: 28).w == 1 && h.pixel(drawn, x: 32, y: 4).w == 1)
        #expect(h.pixel(drawn, x: 8, y: 4).w == 0 && h.pixel(drawn, x: 56, y: 4).w == 0)
        let outside = try draw([look(mask, corners, choices: ["maskKeep": "outside"])], h)
        #expect(h.pixel(outside, x: 32, y: 28).w == 0 && h.pixel(outside, x: 8, y: 4).w == 1)
        // By default its corners are past this frame's, keeping it all.
        #expect(try draw([look(mask)], h) == draw([], h))
    }

    @Test func aGradientMaskFadesFromStartToEnd() throws {
        let h = field()
        let mask = try Self.kind("gradientMask")
        let across: [String: [Double]] = ["gradientStart": [-32, 0], "gradientEnd": [32, 0]]
        let drawn = try draw([look(mask, across)], h)
        for x in [0, 16, 40, 63] {
            #expect(abs(h.pixel(drawn, x: x, y: 16).w - (1 - (Float(x) + 0.5) / 64)) < 0.01, "\(x)")
        }
        let flipped = try draw([look(mask, across, choices: ["maskKeep": "end"])], h)
        #expect(abs(h.pixel(flipped, x: 16, y: 16).w - (16.5 / 64)) < 0.01)
        let radial = try draw([look(mask, ["gradientStart": [0, 0], "gradientEnd": [16, 0]], choices: ["gradientShape": "radial"])], h)
        #expect(h.pixel(radial, x: 32, y: 16).w > 0.95 && abs(h.pixel(radial, x: 40, y: 16).w - 0.47) < 0.05)
        #expect(h.pixel(radial, x: 49, y: 16).w == 0 && h.pixel(radial, x: 32, y: 0).w < 0.05)
        let none = try draw([look(mask, across.merging(["amount": [0]]) { $1 })], h)
        #expect(close(h.pixel(none, x: 63, y: 16), Color(0.2, 0.4, 0.6, 1)))
    }

    // MARK: Alpha

    @Test func alphaToolsWorkOnTheAlphaAndKeepTheColor() throws {
        let h = Picture(width: 2, height: 1) { x, _ in x < 0.5 ? Color(0.4, 0.2, 0.8, 0.25) : Color(1, 1, 1, 1) }
        let tools = try Self.kind("alphaTools")
        func run(_ operation: String, amount: Double = 100) throws -> [Color] {
            try draw([look(tools, ["amount": [amount]], choices: ["alphaOperation": operation])], h)
        }
        let inverted = try run("invert")
        #expect(close(inverted[0], Color(0.4, 0.2, 0.8, 0.75)) && inverted[1].w == 0)
        let opaque = try run("opaque")
        #expect(close(opaque[0], Color(0.4, 0.2, 0.8, 1)))
        let shown = try run("show")
        #expect(close(shown[0], Color(0.25, 0.25, 0.25, 1), tolerance: 0.02) && close(shown[1], Color(1, 1, 1, 1)))
        // Straight color read as premultiplied: multiplied by alpha again.
        #expect(close(try run("premultiply")[0], Color(0.1, 0.05, 0.2, 0.25)))
        // Premultiplied twice: divided once more.
        #expect(close(try run("unpremultiply")[0], Color(1.6, 0.8, 3.2, 0.25), tolerance: 0.02))
        // White is opaque by its brightness; the half-clear color less so.
        let luma = try run("fromLuma")
        #expect(luma[1].w == 1 && luma[0].w < 0.25 && luma[0].w > 0)
        #expect(try run("invert", amount: 0) == draw([], h))
    }
}
