import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Draws test pictures through `TransitionRenderer` and reads back pixels.
struct RenderProbe {
    let bounds = CGRect(x: 0, y: 0, width: 64, height: 32)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    func solid(_ red: Double, _ green: Double, _ blue: Double) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: bounds)
    }

    /// White on the left half, black on the right.
    var halves: CIImage {
        let left = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        return solid(1, 1, 1).cropped(to: left).composited(over: solid(0, 0, 0))
    }

    /// White on the top half, black on the bottom.
    var topHalf: CIImage {
        let top = CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
        return solid(1, 1, 1).cropped(to: top).composited(over: solid(0, 0, 0))
    }

    func draw(
        _ kind: TransitionKind,
        _ progress: Double,
        from a: CIImage,
        to b: CIImage,
        options: TransitionOptions? = nil,
        entering: Bool = true
    ) -> CIImage {
        let frame = TransitionFrame(kind: kind, options: options ?? kind.defaultOptions, progress: progress, entering: entering)
        return TransitionRenderer.draw(frame, from: a, to: b, in: bounds)
    }

    /// The red, green and blue at a point given as fractions of the frame
    /// from its top left, from 0 to 255.
    func pixel(_ image: CIImage, x: Double, y: Double) throws -> [Int] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let cgImage = try #require(context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space))
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
        let index = (py * width + px) * 4
        return [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
    }

    func isNear(_ value: [Int], _ expected: [Int], within tolerance: Int = 8) -> Bool {
        zip(value, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

@Suite struct TransitionRendererTests {
    let probe = RenderProbe()

    @Test(arguments: TransitionKind.allCases.filter(\.drawsTwoPictures))
    func startsOnThePictureBeforeAndEndsOnThePictureAfter(kind: TransitionKind) throws {
        let red = probe.solid(1, 0, 0), blue = probe.solid(0, 0, 1)
        for (x, y) in [(0.5, 0.5), (0.1, 0.2), (0.9, 0.8)] {
            #expect(probe.isNear(try probe.pixel(probe.draw(kind, 0, from: red, to: blue), x: x, y: y), [255, 0, 0]))
            #expect(probe.isNear(try probe.pixel(probe.draw(kind, 1, from: red, to: blue), x: x, y: y), [0, 0, 255]))
        }
    }

    @Test func aDipGoesThroughItsColor() throws {
        let red = probe.solid(1, 0, 0), blue = probe.solid(0, 0, 1)
        #expect(probe.isNear(try probe.pixel(probe.draw(.dipToColor, 0.25, from: red, to: blue), x: 0.5, y: 0.5), [128, 0, 0]))
        #expect(probe.isNear(try probe.pixel(probe.draw(.dipToColor, 0.5, from: red, to: blue), x: 0.5, y: 0.5), [0, 0, 0]))
        #expect(probe.isNear(try probe.pixel(probe.draw(.dipToColor, 0.75, from: red, to: blue), x: 0.5, y: 0.5), [0, 0, 128]))
        var white = TransitionKind.dipToColor.defaultOptions
        white.color = .white
        let middle = probe.draw(.dipToColor, 0.5, from: red, to: blue, options: white)
        #expect(probe.isNear(try probe.pixel(middle, x: 0.5, y: 0.5), [255, 255, 255]))
    }

    @Test func anAdditiveDissolveAddsThePicturesHalfway() throws {
        let middle = probe.draw(.additiveDissolve, 0.5, from: probe.solid(1, 0, 0), to: probe.solid(0, 0, 1))
        #expect(probe.isNear(try probe.pixel(middle, x: 0.5, y: 0.5), [255, 0, 255]))
    }

    @Test func aChannelDissolveCrossesRedFirstAndBlueLast() throws {
        let middle = try probe.pixel(probe.draw(.channelDissolve, 0.5, from: probe.solid(0, 0, 0), to: probe.solid(1, 1, 1)), x: 0.5, y: 0.5)
        #expect(probe.isNear(middle, [212, 128, 42], within: 12))
    }

    @Test func aBlurDissolveSoftensEdgesHalfway() throws {
        var strong = TransitionKind.blurDissolve.defaultOptions
        strong.amount = 1
        let middle = probe.draw(.blurDissolve, 0.5, from: probe.halves, to: probe.halves, options: strong)
        let justRight = try probe.pixel(middle, x: 0.53, y: 0.5)
        #expect(justRight[0] > 15 && justRight[0] < 200)
        let colors = probe.draw(.blurDissolve, 0.5, from: probe.solid(1, 0, 0), to: probe.solid(0, 0, 1))
        #expect(probe.isNear(try probe.pixel(colors, x: 0.5, y: 0.5), [128, 0, 128]))
    }

    // MARK: Wipes

    /// Whether the point shows blue, the picture after, rather than red.
    private func showsAfter(_ image: CIImage, x: Double, y: Double) throws -> Bool {
        let value = try probe.pixel(image, x: x, y: y)
        return value[2] > 200 && value[0] < 55
    }

    private func wipe(_ kind: TransitionKind, _ progress: Double, _ change: (inout TransitionOptions) -> Void = { _ in }) -> CIImage {
        var options = kind.defaultOptions
        change(&options)
        return probe.draw(kind, progress, from: probe.solid(1, 0, 0), to: probe.solid(0, 0, 1), options: options)
    }

    @Test func anIrisOpensFromItsCenter() throws {
        for shape in IrisShape.allCases {
            let half = wipe(.iris, 0.5) { $0.shape = shape }
            #expect(try showsAfter(half, x: 0.5, y: 0.5))
            #expect(try !showsAfter(half, x: 0.02, y: 0.05))
        }
        let offCenter = wipe(.iris, 0.2) { $0.center = CGPoint(x: 0.2, y: 0.25) }
        #expect(try showsAfter(offCenter, x: 0.2, y: 0.25))
        #expect(try !showsAfter(offCenter, x: 0.8, y: 0.75))
    }

    @Test func aClockWipeSweepsClockwiseFromTwelve() throws {
        let quarter = wipe(.clockWipe, 0.3)
        #expect(try showsAfter(quarter, x: 0.6, y: 0.1))
        #expect(try !showsAfter(quarter, x: 0.4, y: 0.1))
        #expect(try !showsAfter(quarter, x: 0.4, y: 0.9))
    }

    @Test func blindsOpenEachStripFromItsSide() throws {
        let right = wipe(.blinds, 0.5) { $0.count = 2; $0.direction = .right }
        #expect(try showsAfter(right, x: 0.1, y: 0.5))
        #expect(try !showsAfter(right, x: 0.4, y: 0.5))
        #expect(try showsAfter(right, x: 0.6, y: 0.5))
        #expect(try !showsAfter(right, x: 0.9, y: 0.5))
        let up = wipe(.blinds, 0.5) { $0.count = 2; $0.direction = .up }
        // Each strip opens from its bottom.
        #expect(try showsAfter(up, x: 0.5, y: 0.9))
        #expect(try !showsAfter(up, x: 0.5, y: 0.6))
    }

    @Test func aDiagonalGridTurnsTheTopLeftFirst() throws {
        let early = wipe(.grid, 0.3) { $0.order = .diagonal }
        #expect(try showsAfter(early, x: 0.05, y: 0.1))
        #expect(try !showsAfter(early, x: 0.95, y: 0.9))
    }

    @Test func aMatteWipeOfNoiseRevealsScatteredParts() throws {
        let half = wipe(.matteWipe, 0.5)
        var shown = 0
        for row in 0..<4 {
            for col in 0..<8 where try showsAfter(half, x: (Double(col) + 0.5) / 8, y: (Double(row) + 0.5) / 4) {
                shown += 1
            }
        }
        #expect(shown > 4 && shown < 28)
    }

    @Test func aMatteWipeRevealsTheBrightPartsOfItsMapFirst() throws {
        let id = UUID()
        MatteMaps.shared.store(probe.halves, for: id)
        let early = wipe(.matteWipe, 0.3) { $0.matte = .clip(id) }
        #expect(try showsAfter(early, x: 0.2, y: 0.5))
        #expect(try !showsAfter(early, x: 0.8, y: 0.5))
    }

    // MARK: Moves

    @Test func aPushMovesBothPicturesTogether() throws {
        let right = wipe(.push, 0.5) { $0.direction = .right }
        #expect(try showsAfter(right, x: 0.25, y: 0.5))
        #expect(try !showsAfter(right, x: 0.75, y: 0.5))
        let up = wipe(.push, 0.5) { $0.direction = .up }
        #expect(try showsAfter(up, x: 0.5, y: 0.75))
        #expect(try !showsAfter(up, x: 0.5, y: 0.25))
    }

    @Test func aSplitOpensThePictureBeforeFromTheMiddle() throws {
        let sideways = wipe(.split, 0.5) { $0.direction = .left }
        #expect(try showsAfter(sideways, x: 0.5, y: 0.5))
        #expect(try !showsAfter(sideways, x: 0.1, y: 0.5))
        #expect(try !showsAfter(sideways, x: 0.9, y: 0.5))
        let upright = wipe(.split, 0.5) { $0.direction = .down }
        #expect(try showsAfter(upright, x: 0.5, y: 0.5))
        #expect(try !showsAfter(upright, x: 0.5, y: 0.05))
    }

    // MARK: 3D

    /// Whether the point shows red, the picture before.
    private func showsBefore(_ image: CIImage, x: Double, y: Double) throws -> Bool {
        let value = try probe.pixel(image, x: x, y: y)
        return value[0] > 200 && value[2] < 55
    }

    @Test func aFlipShowsTheFrontThenTheBack() throws {
        let early = wipe(.flip, 0.25)
        #expect(try showsBefore(early, x: 0.5, y: 0.5))
        // Turned, the card no longer reaches the edge it turns away from.
        let side = try probe.pixel(early, x: 0.02, y: 0.5)
        #expect(side.allSatisfy { $0 < 20 })
        #expect(try showsAfter(wipe(.flip, 0.75), x: 0.5, y: 0.5))
    }

    @Test func aCubeBringsTheNextFaceInFromTheSideItMovesAwayFrom() throws {
        let left = wipe(.cube, 0.5) { $0.direction = .left }
        #expect(try showsBefore(left, x: 0.25, y: 0.5))
        #expect(try showsAfter(left, x: 0.75, y: 0.5))
        let up = wipe(.cube, 0.5) { $0.direction = .up }
        #expect(try showsBefore(up, x: 0.5, y: 0.25))
        #expect(try showsAfter(up, x: 0.5, y: 0.75))
    }

    @Test func aPageCurlIsNeitherPictureAloneHalfway() throws {
        // The curled page and its shaded back cover parts of both.
        let half = wipe(.pageCurl, 0.5)
        var before = 0, after = 0
        for x in [0.1, 0.5, 0.9] {
            for y in [0.2, 0.8] {
                if try showsBefore(half, x: x, y: y) { before += 1 }
                if try showsAfter(half, x: x, y: y) { after += 1 }
            }
        }
        #expect(before < 6 && after < 6)
    }

    // MARK: Stylized

    @Test func pixelatingTurnsAnEdgeIntoBlocksHalfway() throws {
        var strong = TransitionKind.pixelate.defaultOptions
        strong.amount = 1
        let middle = probe.draw(.pixelate, 0.5, from: probe.halves, to: probe.halves, options: strong)
        // Blocks about 7 points wide straddle the edge at the middle, so a
        // point just left of it may turn black and one just right white;
        // either way each block is one flat value.
        let values = try (0..<8).map { try probe.pixel(middle, x: 0.40 + Double($0) * 0.025, y: 0.5)[0] }
        #expect(values.allSatisfy { $0 < 20 || $0 > 235 })
    }

    @Test func aGlitchIsTheSameEachTimeItPlays() throws {
        let first = wipe(.glitch, 0.4)
        let second = wipe(.glitch, 0.4)
        for (x, y) in [(0.1, 0.1), (0.5, 0.5), (0.9, 0.7)] {
            #expect(try probe.pixel(first, x: x, y: y) == probe.pixel(second, x: x, y: y))
        }
    }
}
