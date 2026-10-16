import CoreImage
import CoreVideo
import Foundation
import Vision

/// What a morph needs: how each point of the picture before moves to reach
/// the next one (optical flow, from Vision), and a warp that pulls a
/// picture along it.
enum MorphFlow {
    /// The flow is measured on pictures at most this wide; it is smooth
    /// enough that more detail only costs time.
    static let measuringWidth: CGFloat = 512

    /// How far each output point moves from `before` to `after`, in output
    /// points: red across, green up. Nil when Vision can't measure it.
    static func field(from before: CIImage, to after: CIImage, in bounds: CGRect) -> CIImage? {
        let scale = min(1, measuringWidth / max(bounds.width, 1))
        let toSmall = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let small = CGRect(x: 0, y: 0, width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let a = before.transformed(by: toSmall).cropped(to: small)
        let b = after.transformed(by: toSmall).cropped(to: small)

        let request = VNGenerateOpticalFlowRequest(targetedCIImage: b, options: [:])
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        do {
            try VNImageRequestHandler(ciImage: a, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        // Back to output points; Vision measures y downward, the output up.
        let grow = Float(1 / scale) * Float(small.width) / Float(max(width, 1))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
            for col in 0..<width {
                let index = (row * width + col) * 4
                pixels[index] = line[col * 2] * grow
                pixels[index + 1] = -line[col * 2 + 1] * grow
                pixels[index + 3] = 1
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let field = CIImage(
            bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
            format: .RGBAf, colorSpace: nil
        )
        return field
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: bounds.width / CGFloat(width), y: bounds.height / CGFloat(height))
                .concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY)))
            .cropped(to: bounds)
    }

    /// Each output point of `image` taken from `amount` times its flow away.
    static func warped(_ image: CIImage, along field: CIImage, by amount: Double, in bounds: CGRect) -> CIImage? {
        guard let kernel = warpKernel else { return nil }
        let reach = max(bounds.width, bounds.height)
        return kernel.apply(
            extent: bounds,
            roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -reach, dy: -reach) : rect },
            arguments: [image.cropped(to: bounds).clampedToExtent(), field.clampedToExtent(), Float(amount)]
        )
    }

    /// Whether the warp's kernel compiled here.
    static var canWarp: Bool { warpKernel != nil }

    /// Compiled once, the first time a morph is drawn. Nil if Core Image
    /// can't compile Metal here, and the morph is then a plain dissolve.
    nonisolated(unsafe) private static let warpKernel: CIKernel? = {
        let source = """
        #include <CoreImage/CoreImage.h>
        extern "C" float4 amvFlowWarp(coreimage::sampler image, coreimage::sampler flow, float amount, coreimage::destination dest) {
            float2 d = dest.coord();
            float4 f = flow.sample(flow.transform(d));
            return image.sample(image.transform(d + amount * f.xy));
        }
        """
        return try? CIKernel.kernels(withMetalString: source).first
    }()
}
