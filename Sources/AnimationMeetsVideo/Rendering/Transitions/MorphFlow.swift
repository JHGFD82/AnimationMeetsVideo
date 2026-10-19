import CoreImage
import Foundation

/// The warp a morph pulls each picture along its motion with
/// (`BlockMatchFlow`).
enum MorphFlow {
    /// Each output point of `image` taken from `amount` times its flow away.
    static func warped(_ image: CIImage, along field: CIImage, by amount: Double, in bounds: CGRect) -> CIImage? {
        guard let kernel = compiled.kernel else { return nil }
        let reach = max(bounds.width, bounds.height)
        return kernel.apply(
            extent: bounds,
            roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -reach, dy: -reach) : rect },
            arguments: [image.cropped(to: bounds).clampedToExtent(), field.clampedToExtent(), Float(amount)]
        )
    }

    /// Whether the warp's kernel compiled here.
    static var canWarp: Bool { compiled.kernel != nil }

    /// Why it didn't, if it didn't.
    static var warpError: String? { compiled.error }

    /// Compiled once, the first time a morph is drawn: from Metal source,
    /// or where Core Image can't compile Metal at runtime (as without a
    /// GPU), from its older kernel language, which it can always run. Nil
    /// if neither compiles, and the morph is then a plain dissolve.
    private static let compiled: (kernel: CIKernel?, error: String?) = {
        let metal = """
        #include <CoreImage/CoreImage.h>
        extern "C" [[stitchable]] float4 amvFlowWarp(coreimage::sampler image, coreimage::sampler flow, float amount, coreimage::destination dest) {
            float2 d = dest.coord();
            float4 f = flow.sample(flow.transform(d));
            return image.sample(image.transform(d + amount * f.xy));
        }
        """
        let metalError: String
        do {
            if let kernel = try CIKernel.kernels(withMetalString: metal).first { return (kernel, nil) }
            metalError = "no kernel in the Metal source"
        } catch {
            metalError = "\(error)"
        }
        let legacy = """
        kernel vec4 amvFlowWarp(sampler image, sampler flow, float amount) {
            vec2 d = destCoord();
            vec4 f = sample(flow, samplerTransform(flow, d));
            return sample(image, samplerTransform(image, d + amount * f.xy));
        }
        """
        if let kernel = (LegacyKernel.self as LegacyKernelCompiling.Type).compile(legacy) { return (kernel, nil) }
        return (nil, "Metal: \(metalError); the kernel language one didn't compile either")
    }()
}

/// Compiles Core Image's older kernel language, deprecated but still the
/// only fallback where Metal can't compile at runtime. Called through the
/// protocol so the deliberate use doesn't warn on every build.
private protocol LegacyKernelCompiling {
    static func compile(_ source: String) -> CIKernel?
}

private enum LegacyKernel: LegacyKernelCompiling {
    @available(macOS, deprecated: 10.14)
    static func compile(_ source: String) -> CIKernel? { CIKernel(source: source) }
}
