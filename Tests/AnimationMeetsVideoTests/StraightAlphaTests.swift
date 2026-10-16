import CoreImage
import CoreVideo
import Testing
@testable import AnimationMeetsVideo

@Suite struct StraightAlphaTests {
    /// A one-pixel white frame at half alpha, marked as the decoder marks it.
    private func frame(straight: Bool) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1, 1, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try #require(status == kCVReturnSuccess ? made : nil)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        // Straight white at half alpha, or the same color premultiplied.
        let value: UInt8 = straight ? 255 : 128
        base[0] = value; base[1] = value; base[2] = value; base[3] = 128
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if straight {
            CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        }
        return buffer
    }

    /// The premultiplied red and alpha of the picture's one pixel.
    private func drawn(_ image: CIImage) -> (red: Float, alpha: Float) {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (pixel[0], pixel[3])
    }

    @Test func straightAlphaIsPremultipliedOnce() throws {
        let pixel = drawn(LayeredCompositor.picture(of: try frame(straight: true)))
        #expect(abs(pixel.alpha - 0.5) < 0.01)
        // White at half alpha is half bright once premultiplied, not full
        // (drawn as it was) or a quarter (premultiplied twice).
        #expect(abs(pixel.red - 0.5) < 0.02)
    }

    @Test func premultipliedFramesAreLeftAsTheyAre() throws {
        let pixel = drawn(LayeredCompositor.picture(of: try frame(straight: false)))
        #expect(abs(pixel.red - 0.5) < 0.02)
        #expect(abs(pixel.alpha - 0.5) < 0.01)
    }
}
