import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Metal

/// One Color step ready to draw: a kind of grade and its numbers, already
/// in the units the kernel works in.
struct ColorOp: Equatable, Sendable {
    enum Kind: UInt32, Sendable {
        // Worked in linear light.
        case exposure = 0, temperature, tint, gain
        // Worked on the log curve.
        case contrast, saturation, lift, gamma

        var worksInLinearLight: Bool { rawValue <= Kind.gain.rawValue }
    }

    var kind: Kind
    /// Exposure: the stops. Temperature and tint: -1...1. Contrast and
    /// saturation: the factor (1 leaves it as it is). Lift, gamma and gain:
    /// all channels, then red, green and blue.
    var value: SIMD4<Float>

    init(kind: Kind, value: SIMD4<Float>) {
        self.kind = kind
        self.value = value
    }

    /// The step a Color control makes at `time`; nil for a control that
    /// isn't a Color one.
    init?(_ control: EffectControl, at time: CMTime) {
        let values = control.values(at: time).map(Float.init)
        func first() -> Float { values.first ?? 0 }
        func four() -> SIMD4<Float> {
            values.count == 4 ? SIMD4(values[0], values[1], values[2], values[3]) : SIMD4(repeating: values.first ?? 0)
        }
        switch control.kind {
        case .exposure: self.init(kind: .exposure, value: SIMD4(first(), 0, 0, 0))
        case .temperature: self.init(kind: .temperature, value: SIMD4(first() / 100, 0, 0, 0))
        case .tint: self.init(kind: .tint, value: SIMD4(first() / 100, 0, 0, 0))
        case .contrast: self.init(kind: .contrast, value: SIMD4(max(first(), 0) / 100, 0, 0, 0))
        case .saturation: self.init(kind: .saturation, value: SIMD4(max(first(), 0) / 100, 0, 0, 0))
        case .lift: self.init(kind: .lift, value: four())
        case .gamma: self.init(kind: .gamma, value: four())
        case .gain: self.init(kind: .gain, value: four())
        default: return nil
        }
    }
}

/// How a timeline's pictures are encoded, for the Color steps: each
/// converts to the working space its control needs and back, so a grade
/// looks the same whatever the timeline's color space. Linear light is
/// scaled so 1.0 is reference white (100% on Rec. 709, 203 nits on PQ,
/// 75% on HLG); the log curve is ACEScct's.
extension ProjectColorSpace {
    var gradingSpaceIndex: UInt32 {
        switch self {
        case .rec709: 0
        case .rec2020PQ: 1
        case .rec2020HLG: 2
        }
    }
}

/// The Color kernel, compiled from source when first used (see
/// `BlendKernels`), run inside the Core Image graph as an image processor.
enum ColorKernels {
    struct Parameters {
        var space: UInt32
        var count: UInt32
    }

    /// An op as the kernel reads it.
    struct GPUOp {
        var kind: UInt32
        var padding: (UInt32, UInt32, UInt32) = (0, 0, 0)
        var value: SIMD4<Float>
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        uint space;
        uint count;
    };

    struct Op {
        uint kind;
        float4 value;
    };

    // Rec. 709
    inline float dec709(float e) {
        float a = abs(e);
        return sign(e) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1.0 / 0.45));
    }
    inline float enc709(float l) {
        float a = abs(l);
        return sign(l) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099);
    }

    // PQ (SMPTE ST 2084), reference white at 203 nits
    constant float PQ_M1 = 0.1593017578125;
    constant float PQ_M2 = 78.84375;
    constant float PQ_C1 = 0.8359375;
    constant float PQ_C2 = 18.8515625;
    constant float PQ_C3 = 18.6875;
    inline float decPQ(float e) {
        float p = pow(clamp(abs(e), 0.0, 1.0), 1.0 / PQ_M2);
        float y = pow(max(p - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * p), 1.0 / PQ_M1);
        return sign(e) * y * 10000.0 / 203.0;
    }
    inline float encPQ(float l) {
        float p = pow(abs(l) * 203.0 / 10000.0, PQ_M1);
        return sign(l) * pow((PQ_C1 + PQ_C2 * p) / (1.0 + PQ_C3 * p), PQ_M2);
    }

    // HLG (ARIB STD-B67), reference white at a signal of 75%
    constant float HLG_A = 0.17883277;
    constant float HLG_B = 0.28466892;
    constant float HLG_C = 0.55991073;
    constant float HLG_WHITE = 0.26500502;
    inline float decHLG(float e) {
        float a = abs(e);
        float s = a <= 0.5 ? a * a / 3.0 : (exp((a - HLG_C) / HLG_A) + HLG_B) / 12.0;
        return sign(e) * s / HLG_WHITE;
    }
    inline float encHLG(float l) {
        float s = abs(l) * HLG_WHITE;
        return sign(l) * (s <= 1.0 / 12.0 ? sqrt(3.0 * s) : HLG_A * log(12.0 * s - HLG_B) + HLG_C);
    }

    inline float3 toLinear(float3 c, uint space) {
        if (space == 1) return float3(decPQ(c.r), decPQ(c.g), decPQ(c.b));
        if (space == 2) return float3(decHLG(c.r), decHLG(c.g), decHLG(c.b));
        return float3(dec709(c.r), dec709(c.g), dec709(c.b));
    }
    inline float3 fromLinear(float3 c, uint space) {
        if (space == 1) return float3(encPQ(c.r), encPQ(c.g), encPQ(c.b));
        if (space == 2) return float3(encHLG(c.r), encHLG(c.g), encHLG(c.b));
        return float3(enc709(c.r), enc709(c.g), enc709(c.b));
    }

    // The log curve of ACEScct.
    inline float lin2log1(float l) {
        return l <= 0.0078125 ? 10.5402377416545 * l + 0.0729055341958355 : (log2(l) + 9.72) / 17.52;
    }
    inline float log2lin1(float t) {
        return t <= 0.155251141552511 ? (t - 0.0729055341958355) / 10.5402377416545 : exp2(t * 17.52 - 9.72);
    }
    inline float3 lin2log(float3 c) { return float3(lin2log1(c.r), lin2log1(c.g), lin2log1(c.b)); }
    inline float3 log2lin(float3 c) { return float3(log2lin1(c.r), log2lin1(c.g), log2lin1(c.b)); }

    // Where black, mid gray and white sit on the curve.
    constant float LOG_BLACK = 0.0729055341958355;
    constant float LOG_MID = 0.4135884;
    constant float LOG_WHITE = 0.5547945;

    kernel void color_grade(texture2d<float, access::read> inTexture [[texture(0)]],
                            texture2d<float, access::write> outTexture [[texture(1)]],
                            constant Parameters &params [[buffer(0)]],
                            constant Op *ops [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        float4 pixel = inTexture.read(gid);
        float alpha = pixel.a;
        float3 c = alpha > 0.0 ? pixel.rgb / alpha : float3(0.0);
        // 0: as encoded, 1: linear light, 2: on the log curve.
        int state = 0;
        for (uint i = 0; i < params.count; i++) {
            Op op = ops[i];
            bool linear = op.kind <= 3;
            if (linear) {
                if (state == 0) c = toLinear(c, params.space);
                else if (state == 2) c = log2lin(c);
                state = 1;
            } else {
                if (state == 0) c = lin2log(toLinear(c, params.space));
                else if (state == 1) c = lin2log(c);
                state = 2;
            }
            float4 v = op.value;
            switch (op.kind) {
            case 0: // exposure
                c *= exp2(v.x);
                break;
            case 1: // temperature: warm raises red and lowers blue
                c *= float3(exp2(0.5 * v.x), 1.0, exp2(-0.5 * v.x));
                break;
            case 2: // tint: toward magenta lowers green
                c *= float3(exp2(0.25 * v.x), exp2(-0.5 * v.x), exp2(0.25 * v.x));
                break;
            case 3: // gain
                c *= v.x * v.yzw;
                break;
            case 4: // contrast about mid gray
                c = LOG_MID + (c - LOG_MID) * v.x;
                break;
            case 5: { // saturation about the picture's own luma
                float y = dot(c, float3(0.2126, 0.7152, 0.0722));
                c = y + (c - y) * v.x;
                break;
            }
            case 6: { // lift: raises the blacks, fading out toward white
                float3 weight = clamp(1.0 - (c - LOG_BLACK) / (LOG_WHITE - LOG_BLACK), 0.0, 1.0);
                c += (v.x + v.yzw) * weight;
                break;
            }
            case 7: { // gamma: bends the tones between black and white
                float3 g = max(v.x * v.yzw, 0.0001);
                float3 x = (c - LOG_BLACK) / (LOG_WHITE - LOG_BLACK);
                float3 bent = pow(max(x, 0.0), 1.0 / g);
                c = LOG_BLACK + select(x, bent, x > 0.0) * (LOG_WHITE - LOG_BLACK);
                break;
            }
            }
        }
        if (state == 2) c = log2lin(c);
        if (state != 0) c = fromLinear(c, params.space);
        outTexture.write(float4(c * alpha, alpha), gid);
    }
    """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pipelines: [Int: MTLComputePipelineState] = [:]

    static func pipeline(on device: MTLDevice) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device as AnyObject).hashValue
        if let cached = pipelines[key] { return cached }
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "color_grade"),
              let state = try? device.makeComputePipelineState(function: function)
        else {
            NSLog("The color kernel couldn't be compiled.")
            return nil
        }
        pipelines[key] = state
        return state
    }
}

/// Runs the Color kernel as a step of a Core Image graph.
final class ColorProcessor: CIImageProcessorKernel {
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
        guard let input = inputs?.first,
              let commandBuffer = output.metalCommandBuffer,
              let source = input.metalTexture, let target = output.metalTexture,
              let space = arguments?["space"] as? UInt32,
              let ops = arguments?["ops"] as? Data,
              let pipeline = ColorKernels.pipeline(on: commandBuffer.device),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw NSError(domain: "ColorProcessor", code: 1)
        }
        var parameters = ColorKernels.Parameters(space: space, count: UInt32(ops.count / MemoryLayout<ColorKernels.GPUOp>.stride))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<ColorKernels.Parameters>.size, index: 0)
        ops.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: ops.count, index: 1) }
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// `image` graded by `ops` over `region`, a rectangle in Core Image's
    /// space, in a timeline of `space`. Nil if it can't be set up, in which
    /// case the picture is left as it is.
    static func grade(_ image: CIImage, _ ops: [ColorOp], in space: ProjectColorSpace, over region: CGRect) -> CIImage? {
        let region = region.integral
        guard !ops.isEmpty, !region.isEmpty, !region.isInfinite else { return nil }
        let gpuOps = ops.map { ColorKernels.GPUOp(kind: $0.kind.rawValue, value: $0.value) }
        let data = gpuOps.withUnsafeBytes { Data($0) }
        let clear = CIImage(color: .clear).cropped(to: region)
        return try? apply(
            withExtent: region,
            inputs: [image.composited(over: clear).cropped(to: region)],
            arguments: ["space": space.gradingSpaceIndex, "ops": data]
        )
    }
}
