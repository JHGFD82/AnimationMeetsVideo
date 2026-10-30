import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct OpticalFlowTests {
    private let size = CGSize(width: 320, height: 180)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A textured scene panned by (`dx`, `dy`) pixels, which is how a
    /// camera move looks between two frames.
    private func scene(panned dx: Double, _ dy: Double) -> CIImage {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let x = Double(column) - dx, y = Double(row) - dy
                let wave = sin(x * 0.21 + y * 0.07) + sin(y * 0.19 - x * 0.05) + sin((x + y) * 0.11) + sin(x * 0.043) * cos(y * 0.061)
                let value = UInt8(max(0, min(255, 128 + wave * 30)))
                let base = (row * width + column) * 4
                pixels[base] = value; pixels[base + 1] = value; pixels[base + 2] = value; pixels[base + 3] = 255
            }
        }
        return CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4, size: size, format: .RGBA8, colorSpace: nil)
    }

    private func bytes(of image: CIImage) -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: nil)
        return pixels
    }

    /// The mean difference in the red channel over the middle of the
    /// frame, away from the edges where a pan brings in new picture.
    private func difference(_ a: CIImage, _ b: CIImage) -> Double {
        let x = bytes(of: a), y = bytes(of: b)
        let width = Int(size.width), height = Int(size.height)
        var total = 0.0, count = 0.0
        for row in 40..<(height - 40) {
            for column in 40..<(width - 40) {
                total += abs(Double(x[(row * width + column) * 4]) - Double(y[(row * width + column) * 4]))
                count += 1
            }
        }
        return total / count
    }

    @Test func aPanIsInterpolatedByMovingTheFrames() throws {
        let first = scene(panned: 0, 0), second = scene(panned: 10, 6)
        let middle = try #require(OpticalFlow.between(first, second, fraction: 0.5))
        let truth = scene(panned: 5, 3)
        let faded = first.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: second, kCIInputTimeKey: 0.5])
        let moved = difference(middle, truth), blended = difference(faded, truth)
        #expect(moved < blended / 2)
        #expect(moved < 8)
    }

    @Test func aQuarterOfTheWayIsAQuarterOfThePan() throws {
        let first = scene(panned: 0, 0), second = scene(panned: 10, 6)
        let early = try #require(OpticalFlow.between(first, second, fraction: 0.25))
        let truth = scene(panned: 2.5, 1.5)
        let faded = first.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: second, kCIInputTimeKey: 0.25])
        #expect(difference(early, truth) < difference(faded, truth) / 2)
    }

    @Test func atTheEndsItIsTheFramesThemselves() throws {
        let first = scene(panned: 0, 0), second = scene(panned: 10, 6)
        let atStart = try #require(OpticalFlow.between(first, second, fraction: 0))
        let atEnd = try #require(OpticalFlow.between(first, second, fraction: 1))
        #expect(difference(atStart, first) < 2)
        #expect(difference(atEnd, second) < 2)
    }

    /// `image` within `rect`, row by row from the top.
    private func bytes(of image: CIImage, in rect: CGRect) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: Int(rect.width) * Int(rect.height) * 4)
        context.render(image, toBitmap: &pixels, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: nil)
        return pixels
    }

    /// Core Image asks for whatever part of the frame it needs: one strip
    /// of it is that strip, and around the frame, which a picture moved by
    /// part of a pixel reaches into, is transparent.
    @Test func anyPartOfTheFrameIsDrawnInPlace() throws {
        let first = scene(panned: 0, 0), second = scene(panned: 10, 6)
        let still = OpticalFlow.Field(width: 4, height: 4, vectors: [Float](repeating: 0, count: 32))
        let drawn = try #require(OpticalFlow.interpolated(from: first, to: second, fraction: 0, field: still))

        let strip = CGRect(x: 0, y: 120, width: size.width, height: 40)
        let (got, want) = (bytes(of: drawn, in: strip), bytes(of: first, in: strip))
        #expect(zip(got, want).allSatisfy { abs(Int($0) - Int($1)) <= 1 })

        let around = CGRect(x: 0, y: -8, width: size.width, height: size.height + 16)
        let moved = bytes(of: drawn.transformed(by: CGAffineTransform(translationX: 0, y: 0.5)), in: around)
        let width = Int(size.width)
        let outside = Array(0..<7) + Array((Int(around.height) - 8)..<Int(around.height))
        #expect(outside.allSatisfy { row in (0..<width).allSatisfy { moved[(row * width + $0) * 4 + 3] == 0 } })
    }

    @Test func framesOfDifferentSizesHaveNoFlow() {
        let small = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 36))
        #expect(OpticalFlow.field(from: scene(panned: 0, 0), to: small) == nil)
    }
}
