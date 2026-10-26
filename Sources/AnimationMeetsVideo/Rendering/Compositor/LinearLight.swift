import CoreImage

/// A picture as the timeline encodes it to linear light and back, for a
/// package that works on light (`EffectPackage.linear`).
/// Premultiplied both ways, so a filter that averages pixels averages
/// light weighted by how much of each pixel there is. With the prelude's
/// `toLinear` and `fromLinear`, so 1.0 is reference white in every space,
/// as the kernels have it.
enum LinearLight {
    static func toLinear(_ picture: CIImage, space: Float) -> CIImage {
        apply(kernels?.toLinear, picture, space)
    }

    static func fromLinear(_ picture: CIImage, space: Float) -> CIImage {
        apply(kernels?.fromLinear, picture, space)
    }

    private static func apply(_ kernel: CIColorKernel?, _ picture: CIImage, _ space: Float) -> CIImage {
        guard let kernel, !picture.extent.isEmpty else { return picture }
        return kernel.apply(extent: picture.extent, arguments: [picture, space]) ?? picture
    }

    private static let kernels: (toLinear: CIColorKernel, fromLinear: CIColorKernel)? = {
        let source = LookKernels.prelude + """

        extern "C" [[stitchable]] float4 amvToLinearLight(coreimage::sample_t s, float space) {
            return float4(toLinear(straight(s), space) * s.a, s.a);
        }
        extern "C" [[stitchable]] float4 amvFromLinearLight(coreimage::sample_t s, float space) {
            return float4(fromLinear(straight(s), space) * s.a, s.a);
        }
        """
        guard let compiled = try? CIKernel.kernels(withMetalString: source),
              let to = compiled.first(where: { $0.name == "amvToLinearLight" }) as? CIColorKernel,
              let from = compiled.first(where: { $0.name == "amvFromLinearLight" }) as? CIColorKernel
        else { return nil }
        return (to, from)
    }()
}
