import CoreImage
import Foundation
import Metal

/// Blend modes as Metal compute kernels, one per mode, run inside the Core
/// Image graph by `BlendProcessor`. Colors are un-premultiplied, combined
/// with the formulas of the W3C compositing model, and handed back
/// premultiplied; see docs/effects.md, "Blending".
///
/// The source is compiled when first needed, at run time: Swift packages
/// don't build shader files for an unbundled app, and compiling takes a
/// few milliseconds.
enum BlendKernels {
    /// The names of the kernels, one per mode.
    static func functionName(for mode: BlendMode) -> String { "blend_\(mode.rawValue)" }

    /// What the kernels take besides the two pictures.
    struct Parameters {
        /// How much of the blend is applied, 0...1.
        var amount: Float
        /// 1 to draw the blended clip over the picture it was blended
        /// with (Against), 0 to keep only the clip's own alpha.
        var keepsBackdrop: UInt32
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        float amount;
        uint keepsBackdrop;
    };

    // Separable modes: B(backdrop, source) per channel.
    inline float3 B_darken(float3 cb, float3 cs) { return min(cb, cs); }
    inline float3 B_multiply(float3 cb, float3 cs) { return cb * cs; }
    inline float colorBurn1(float cb, float cs) {
        if (cb >= 1.0) return 1.0;
        if (cs <= 0.0) return 0.0;
        return 1.0 - min(1.0, (1.0 - cb) / cs);
    }
    inline float3 B_colorBurn(float3 cb, float3 cs) {
        return float3(colorBurn1(cb.r, cs.r), colorBurn1(cb.g, cs.g), colorBurn1(cb.b, cs.b));
    }
    inline float3 B_linearBurn(float3 cb, float3 cs) { return max(cb + cs - 1.0, 0.0); }
    inline float3 B_lighten(float3 cb, float3 cs) { return max(cb, cs); }
    inline float3 B_screen(float3 cb, float3 cs) { return cb + cs - cb * cs; }
    inline float colorDodge1(float cb, float cs) {
        if (cb <= 0.0) return 0.0;
        if (cs >= 1.0) return 1.0;
        return min(1.0, cb / (1.0 - cs));
    }
    inline float3 B_colorDodge(float3 cb, float3 cs) {
        return float3(colorDodge1(cb.r, cs.r), colorDodge1(cb.g, cs.g), colorDodge1(cb.b, cs.b));
    }
    inline float3 B_add(float3 cb, float3 cs) { return cb + cs; }
    inline float hardLight1(float cb, float cs) {
        return cs <= 0.5 ? cb * (2.0 * cs) : (cb + (2.0 * cs - 1.0) - cb * (2.0 * cs - 1.0));
    }
    inline float3 B_hardLight(float3 cb, float3 cs) {
        return float3(hardLight1(cb.r, cs.r), hardLight1(cb.g, cs.g), hardLight1(cb.b, cs.b));
    }
    inline float3 B_overlay(float3 cb, float3 cs) { return B_hardLight(cs, cb); }
    inline float softLight1(float cb, float cs) {
        if (cs <= 0.5) return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
        float d = cb <= 0.25 ? ((16.0 * cb - 12.0) * cb + 4.0) * cb : sqrt(cb);
        return cb + (2.0 * cs - 1.0) * (d - cb);
    }
    inline float3 B_softLight(float3 cb, float3 cs) {
        return float3(softLight1(cb.r, cs.r), softLight1(cb.g, cs.g), softLight1(cb.b, cs.b));
    }
    inline float3 B_difference(float3 cb, float3 cs) { return abs(cb - cs); }
    inline float3 B_exclusion(float3 cb, float3 cs) { return cb + cs - 2.0 * cb * cs; }
    inline float3 B_subtract(float3 cb, float3 cs) { return max(cb - cs, 0.0); }
    inline float divide1(float cb, float cs) { return cs <= 0.0 ? 1.0 : min(cb / cs, 1.0); }
    inline float3 B_divide(float3 cb, float3 cs) {
        return float3(divide1(cb.r, cs.r), divide1(cb.g, cs.g), divide1(cb.b, cs.b));
    }

    // Non-separable modes.
    inline float lum(float3 c) { return dot(c, float3(0.3, 0.59, 0.11)); }
    inline float3 clipColor(float3 c) {
        float l = lum(c);
        float n = min(c.r, min(c.g, c.b));
        float x = max(c.r, max(c.g, c.b));
        if (n < 0.0) c = l + (c - l) * l / (l - n);
        if (x > 1.0) c = l + (c - l) * (1.0 - l) / (x - l);
        return c;
    }
    inline float3 setLum(float3 c, float l) { return clipColor(c + (l - lum(c))); }
    inline float sat(float3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
    inline float3 setSat(float3 c, float s) {
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        if (mx <= mn) return float3(0.0);
        return (c - mn) * s / (mx - mn);
    }
    inline float3 B_hue(float3 cb, float3 cs) { return setLum(setSat(cs, sat(cb)), lum(cb)); }
    inline float3 B_saturation(float3 cb, float3 cs) { return setLum(setSat(cb, sat(cs)), lum(cb)); }
    inline float3 B_color(float3 cb, float3 cs) { return setLum(cs, lum(cb)); }
    inline float3 B_luminosity(float3 cb, float3 cs) { return setLum(cb, lum(cs)); }

    // The clip is blended with the picture behind it: its color becomes
    //   (1 - ab) * cs + ab * B(cb, cs), mixed in by the amount,
    // and its alpha is kept. With keepsBackdrop the result is then drawn
    // over that picture instead (alpha as in normal compositing).
    #define BLEND_KERNEL(NAME) \\
    kernel void blend_##NAME(texture2d<float, access::read> clipTexture [[texture(0)]], \\
                             texture2d<float, access::read> backTexture [[texture(1)]], \\
                             texture2d<float, access::write> outTexture [[texture(2)]], \\
                             constant Parameters &params [[buffer(0)]], \\
                             uint2 gid [[thread_position_in_grid]]) { \\
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return; \\
        float4 clip = clipTexture.read(gid); \\
        float4 back = backTexture.read(gid); \\
        float ac = clip.a; \\
        float ab = back.a; \\
        float3 cs = ac > 0.0 ? clip.rgb / ac : float3(0.0); \\
        float3 cb = ab > 0.0 ? back.rgb / ab : float3(0.0); \\
        float3 blended = (1.0 - ab) * cs + ab * B_##NAME(cb, cs); \\
        float3 color = cs + params.amount * (blended - cs); \\
        float4 result; \\
        if (params.keepsBackdrop != 0) { \\
            result = float4(color * ac + back.rgb * (1.0 - ac), ac + ab * (1.0 - ac)); \\
        } else { \\
            result = float4(color * ac, ac); \\
        } \\
        outTexture.write(result, gid); \\
    }

    BLEND_KERNEL(darken)
    BLEND_KERNEL(multiply)
    BLEND_KERNEL(colorBurn)
    BLEND_KERNEL(linearBurn)
    BLEND_KERNEL(lighten)
    BLEND_KERNEL(screen)
    BLEND_KERNEL(colorDodge)
    BLEND_KERNEL(add)
    BLEND_KERNEL(overlay)
    BLEND_KERNEL(softLight)
    BLEND_KERNEL(hardLight)
    BLEND_KERNEL(difference)
    BLEND_KERNEL(exclusion)
    BLEND_KERNEL(subtract)
    BLEND_KERNEL(divide)
    BLEND_KERNEL(hue)
    BLEND_KERNEL(saturation)
    BLEND_KERNEL(color)
    BLEND_KERNEL(luminosity)
    """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [ObjectIdentifier: MTLLibrary] = [:]
    nonisolated(unsafe) private static var pipelines: [String: MTLComputePipelineState] = [:]

    /// The pipeline for a mode's kernel on `device`, nil if the source
    /// couldn't be compiled.
    static func pipeline(for mode: BlendMode, on device: MTLDevice) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        let name = functionName(for: mode)
        let key = "\(ObjectIdentifier(device as AnyObject).hashValue)/\(name)"
        if let cached = pipelines[key] { return cached }
        let library: MTLLibrary
        if let cached = libraries[ObjectIdentifier(device as AnyObject)] {
            library = cached
        } else {
            guard let compiled = try? device.makeLibrary(source: source, options: nil) else {
                NSLog("The blend kernels couldn't be compiled.")
                return nil
            }
            libraries[ObjectIdentifier(device as AnyObject)] = compiled
            library = compiled
        }
        guard let function = library.makeFunction(name: name),
              let state = try? device.makeComputePipelineState(function: function)
        else {
            return nil
        }
        pipelines[key] = state
        return state
    }
}

/// Runs a blend kernel as a step of a Core Image graph: the first input is
/// the clip, the second what it is blended with, both over the same
/// extent.
final class BlendProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    override class func process(
        with inputs: [any CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: any CIImageProcessorOutput
    ) throws {
        guard let inputs, inputs.count == 2,
              let commandBuffer = output.metalCommandBuffer,
              let clip = inputs[0].metalTexture, let backdrop = inputs[1].metalTexture,
              let target = output.metalTexture,
              let modeName = arguments?["mode"] as? String, let mode = BlendMode(rawValue: modeName),
              let amount = arguments?["amount"] as? Double,
              let pipeline = BlendKernels.pipeline(for: mode, on: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw NSError(domain: "BlendProcessor", code: 1)
        }
        var parameters = BlendKernels.Parameters(
            amount: Float(amount.clamped(between: 0, and: 1)),
            keepsBackdrop: (arguments?["keepsBackdrop"] as? Bool) == true ? 1 : 0
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(clip, index: 0)
        encoder.setTexture(backdrop, index: 1)
        encoder.setTexture(target, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<BlendKernels.Parameters>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// `clip` blended with `backdrop` over `region`, a rectangle in Core
    /// Image's space. Both are padded with transparency to the region, so
    /// the kernel reads two pictures of the same size. Nil if the blend
    /// can't be set up, in which case the clip is left as it is.
    static func blend(
        _ clip: CIImage,
        with backdrop: CIImage,
        mode: BlendMode,
        amount: Double,
        keepsBackdrop: Bool,
        over region: CGRect
    ) -> CIImage? {
        let region = region.integral
        guard !region.isEmpty, !region.isInfinite else { return nil }
        let clear = CIImage(color: .clear).cropped(to: region)
        let padded: (CIImage) -> CIImage = { $0.composited(over: clear).cropped(to: region) }
        return try? apply(
            withExtent: region,
            inputs: [padded(clip), padded(backdrop)],
            arguments: ["mode": mode.rawValue, "amount": amount, "keepsBackdrop": keepsBackdrop]
        )
    }
}
