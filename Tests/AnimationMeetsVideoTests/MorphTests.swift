import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MorphTests {
    private let bounds = CGRect(x: 0, y: 0, width: 256, height: 128)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A textured square, 40 points across, centered at a point given as
    /// fractions of the frame from its top left, on black.
    private func square(atX x: Double, y: Double) -> CIImage {
        let center = CGPoint(x: bounds.width * x, y: bounds.height * (1 - y))
        let rect = CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)
        let checks = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 6,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0.6, green: 0.6, blue: 0.6),
        ])!.outputImage!
        return checks.cropped(to: rect).composited(over: CIImage(color: .black).cropped(to: bounds))
    }

    /// The average brightness, from 0 to 255, of a 12-point square around
    /// a point given as fractions of the frame from its top left.
    private func brightness(_ image: CIImage, x: Double, y: Double) throws -> Double {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let cgImage = try #require(context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space))
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmap = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let cx = Int(Double(width) * x), cy = Int(Double(height) * y)
        var total = 0, count = 0
        for py in max(0, cy - 6)..<min(height, cy + 6) {
            for px in max(0, cx - 6)..<min(width, cx + 6) {
                total += Int(pixels[(py * width + px) * 4 + 1])
                count += 1
            }
        }
        return Double(total) / Double(max(count, 1))
    }

    private func morph(_ a: CIImage, _ b: CIImage, at progress: Double) -> CIImage {
        let frame = TransitionFrame(kind: .morph, options: TransitionKind.morph.defaultOptions, progress: progress, entering: true)
        return TransitionRenderer.draw(frame, from: a, to: b, in: bounds)
    }

    @Test func aMorphMovesAShapeAcrossRatherThanFadingIt() throws {
        let middle = morph(square(atX: 0.35, y: 0.5), square(atX: 0.65, y: 0.5), at: 0.5)
        // A dissolve would leave the middle black and both ends half lit.
        #expect(try brightness(middle, x: 0.5, y: 0.5) > 120)
        #expect(try brightness(middle, x: 0.3, y: 0.5) < 100)
        #expect(try brightness(middle, x: 0.7, y: 0.5) < 100)
    }

    @Test func aMorphMovesAShapeDown() throws {
        let middle = morph(square(atX: 0.5, y: 0.3), square(atX: 0.5, y: 0.7), at: 0.5)
        #expect(try brightness(middle, x: 0.5, y: 0.5) > 120)
        #expect(try brightness(middle, x: 0.5, y: 0.22) < 100)
    }

    /// The red and green of a float image at a point given as fractions of
    /// the frame from its top left.
    private func vector(_ image: CIImage, x: Double, y: Double) -> (Float, Float) {
        var value = [Float](repeating: 0, count: 4)
        let point = CGRect(x: (bounds.width * x).rounded(), y: (bounds.height * (1 - y)).rounded(), width: 1, height: 1)
        context.render(image, toBitmap: &value, rowBytes: 16, bounds: point, format: .RGBAf, colorSpace: nil)
        return (value[0], value[1])
    }

    @Test func theWarpCompiles() {
        #expect(MorphFlow.canWarp, "\(MorphFlow.warpError ?? "")")
    }

    @Test func theMeasuredMotionPointsTheWayTheShapeMoves() throws {
        // Vision's measure where it runs, block matching where it doesn't.
        let field = try #require(MorphFlow.field(from: square(atX: 0.35, y: 0.5), to: square(atX: 0.65, y: 0.5), in: bounds))
        let across = vector(field, x: 0.35, y: 0.5)
        #expect(across.0 > 20, "measured \(across)")
        let downField = try #require(MorphFlow.field(from: square(atX: 0.5, y: 0.3), to: square(atX: 0.5, y: 0.7), in: bounds))
        let down = vector(downField, x: 0.5, y: 0.3)
        // Down the frame is down the output's y.
        #expect(down.1 < -15, "measured \(down)")
    }

    @Test func blockMatchingFindsAMoveAndLeavesPlainAreasStill() throws {
        let field = try #require(BlockMatchFlow.field(from: square(atX: 0.35, y: 0.5), to: square(atX: 0.65, y: 0.5), in: bounds))
        let across = vector(field, x: 0.35, y: 0.5)
        #expect(abs(across.0 - 77) < 20 && abs(across.1) < 10, "measured \(across)")
        let corner = vector(field, x: 0.05, y: 0.1)
        #expect(abs(corner.0) < 1 && abs(corner.1) < 1, "measured \(corner)")
        let downField = try #require(BlockMatchFlow.field(from: square(atX: 0.5, y: 0.3), to: square(atX: 0.5, y: 0.7), in: bounds))
        let down = vector(downField, x: 0.5, y: 0.3)
        #expect(down.1 < -30, "measured \(down)")
    }

    @Test func theWarpTakesEachPointFromAlongTheField() throws {
        // Every point moved 40 across: each takes what's 40 to its right.
        let pixel: [Float] = [40, 0, 0, 1]
        let field = CIImage(
            bitmapData: pixel.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
            size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil
        ).clampedToExtent().cropped(to: bounds)
        let warped = try #require(MorphFlow.warped(square(atX: 0.5, y: 0.5), along: field, by: 1, in: bounds))
        let moved = 0.5 - 40 / Double(bounds.width)
        #expect(try brightness(warped, x: moved, y: 0.5) > 120, "at \(moved)")
        #expect(try brightness(warped, x: 0.5 + 30 / Double(bounds.width), y: 0.5) < 60)
    }
}
