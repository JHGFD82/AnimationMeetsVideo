import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// The Metal functions the looks of docs/psychedelic-effects.md share,
/// and the kernels of the looks still written in Swift (Displace, and
/// Slit-Scan's rings), compiled the first time a look is drawn, as
/// `MorphFlow` compiles its warp. The other looks' kernels are in their
/// effect packages, compiled with these functions in front (`prelude`).
/// They read the picture as the timeline encodes it and work on the log
/// curve the Color effect's Contrast does, so a look is the same in Rec.
/// 709, PQ and HLG.
enum LookKernels {
    /// Kernels by function name; one missing where it didn't compile, and
    /// its look then leaves the picture as it is.
    ///
    /// Each is compiled from a source of its own, the shared functions
    /// before it: within one `CIContext`, Core Image mistook kernels
    /// compiled from one source for each other, drawing one look's
    /// cached picture for another's.
    static let compiled: [String: CIKernel] = {
        let (prelude, functions) = split(source)
        var kernels: [String: CIKernel] = [:]
        for function in functions {
            do {
                for kernel in try CIKernel.kernels(withMetalString: prelude + function) { kernels[kernel.name] = kernel }
            } catch {
                NSLog("A look kernel couldn't be compiled: \(error)")
            }
        }
        return kernels
    }()

    /// The functions every look's kernel may use, put in front of an
    /// effect package's kernel too (see docs/effect-packages.md, "The
    /// kernel").
    static let prelude = split(source).prelude

    /// The source's shared functions, and each kernel's own text: from its
    /// `extern "C"` to the next one, or the end.
    static func split(_ source: String) -> (prelude: String, kernels: [String]) {
        let marker = "\nextern \"C\" [[stitchable]]"
        var parts = source.components(separatedBy: marker)
        let first = parts.removeFirst()
        // Helpers written between two kernels belong to the prelude too:
        // everything after a kernel's closing brace at the start of a line.
        var prelude = first
        var kernels: [String] = []
        for part in parts {
            if let end = part.range(of: "\n}\n") {
                kernels.append(marker + String(part[..<end.upperBound]))
                prelude += String(part[end.upperBound...])
            } else {
                kernels.append(marker + part)
            }
        }
        return (prelude, kernels)
    }

    static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // As the timeline encodes it, to linear light (1.0 is reference white)
    // and back: Rec. 709, PQ at 203 nits, HLG at a 75% signal.
    inline float dec709(float e) { float a = abs(e); return sign(e) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1.0 / 0.45)); }
    inline float enc709(float l) { float a = abs(l); return sign(l) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099); }
    inline float decPQ(float e) {
        float p = pow(clamp(abs(e), 0.0, 1.0), 1.0 / 78.84375);
        return sign(e) * pow(max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p), 1.0 / 0.1593017578125) * 10000.0 / 203.0;
    }
    inline float encPQ(float l) {
        float p = pow(abs(l) * 203.0 / 10000.0, 0.1593017578125);
        return sign(l) * pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), 78.84375);
    }
    inline float decHLG(float e) {
        float a = abs(e);
        float s = a <= 0.5 ? a * a / 3.0 : (exp((a - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
        return sign(e) * s / 0.26500502;
    }
    inline float encHLG(float l) {
        float s = abs(l) * 0.26500502;
        return sign(l) * (s <= 1.0 / 12.0 ? sqrt(3.0 * s) : 0.17883277 * log(12.0 * s - 0.28466892) + 0.55991073);
    }
    inline float3 toLinear(float3 c, float space) {
        if (space > 1.5) return float3(decHLG(c.r), decHLG(c.g), decHLG(c.b));
        if (space > 0.5) return float3(decPQ(c.r), decPQ(c.g), decPQ(c.b));
        return float3(dec709(c.r), dec709(c.g), dec709(c.b));
    }
    inline float3 fromLinear(float3 c, float space) {
        if (space > 1.5) return float3(encHLG(c.r), encHLG(c.g), encHLG(c.b));
        if (space > 0.5) return float3(encPQ(c.r), encPQ(c.g), encPQ(c.b));
        return float3(enc709(c.r), enc709(c.g), enc709(c.b));
    }

    // ACEScct's log curve, scaled so black is 0 and reference white 1.
    constant float LOG_BLACK = 0.0729055341958355;
    constant float LOG_WHITE = 0.5547945;
    inline float lin2log(float l) { return l <= 0.0078125 ? 10.5402377416545 * l + 0.0729055341958355 : (log2(l) + 9.72) / 17.52; }
    inline float log2lin(float t) { return t <= 0.155251141552511 ? (t - 0.0729055341958355) / 10.5402377416545 : exp2(t * 17.52 - 9.72); }
    inline float3 toTones(float3 c, float space) {
        float3 l = toLinear(c, space);
        return (float3(lin2log(l.r), lin2log(l.g), lin2log(l.b)) - LOG_BLACK) / (LOG_WHITE - LOG_BLACK);
    }
    inline float3 fromTones(float3 t, float space) {
        float3 c = LOG_BLACK + t * (LOG_WHITE - LOG_BLACK);
        return fromLinear(float3(log2lin(c.r), log2lin(c.g), log2lin(c.b)), space);
    }
    inline float luma(float3 t) { return dot(t, float3(0.2126, 0.7152, 0.0722)); }

    // The picture's own color, unpremultiplied; and a result mixed back in
    // by `amount`, premultiplied again.
    inline float3 straight(float4 s) { return s.a > 0.0 ? s.rgb / s.a : float3(0.0); }
    inline float4 mixed(float4 s, float3 result, float amount) {
        return float4(mix(straight(s), result, amount) * s.a, s.a);
    }

    inline float3 hueRotated(float3 t, float angle) {
        float c = cos(angle), s = sin(angle);
        float k = (1.0 - c) / 3.0, r = sqrt(1.0 / 3.0) * s;
        float3x3 m = float3x3(float3(c + k, k + r, k - r), float3(k - r, c + k, k + r), float3(k + r, k - r, c + k));
        return m * t;
    }
    inline float3 hsv(float h, float s, float v) {
        float3 k = clamp(abs(fract(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return v * mix(float3(1.0), k, s);
    }
    // Up 0...1, back down 1...2, and so on.
    inline float triangle(float x) { return 1.0 - abs(fmod(abs(x), 2.0) - 1.0); }

    // MARK: Noise

    // PCG's hash: well mixed and the same on every GPU, so the same seed
    // and frame always draw the same picture.
    inline uint pcg(uint v) {
        uint state = v * 747796405u + 2891336453u;
        uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
        return (word >> 22u) ^ word;
    }
    inline uint hash3(int3 v) { return pcg(as_type<uint>(v.x) ^ pcg(as_type<uint>(v.y) ^ pcg(as_type<uint>(v.z)))); }
    inline float rand(int3 v) { return float(hash3(v)) / 4294967295.0; }
    inline float rand(int3 v, int stream) { return rand(v + int3(stream * 7919, stream * 104729, stream * 1299709)); }

    // Perlin's gradient noise in three dimensions, about -1...1.
    inline float3 gradient(int3 c, int seed) {
        float u = rand(c + int3(0, 0, seed * 7)), v = rand(c + int3(0, 0, seed * 7), 1);
        float z = u * 2.0 - 1.0, a = v * 6.283185307, r = sqrt(max(1.0 - z * z, 0.0));
        return float3(r * cos(a), r * sin(a), z);
    }
    inline float noise3(float3 p, int seed) {
        float3 i = floor(p), f = p - i;
        float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        int3 c = int3(i);
        float n000 = dot(gradient(c, seed), f);
        float n100 = dot(gradient(c + int3(1, 0, 0), seed), f - float3(1, 0, 0));
        float n010 = dot(gradient(c + int3(0, 1, 0), seed), f - float3(0, 1, 0));
        float n110 = dot(gradient(c + int3(1, 1, 0), seed), f - float3(1, 1, 0));
        float n001 = dot(gradient(c + int3(0, 0, 1), seed), f - float3(0, 0, 1));
        float n101 = dot(gradient(c + int3(1, 0, 1), seed), f - float3(1, 0, 1));
        float n011 = dot(gradient(c + int3(0, 1, 1), seed), f - float3(0, 1, 1));
        float n111 = dot(gradient(c + int3(1, 1, 1), seed), f - float3(1, 1, 1));
        float x00 = mix(n000, n100, u.x), x10 = mix(n010, n110, u.x), x01 = mix(n001, n101, u.x), x11 = mix(n011, n111, u.x);
        return 1.6 * mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z);
    }

    // A generator's own picture, opaque, mixed over what reached it.
    inline float4 generated(float4 s, float3 c, float amount) { return mix(s, float4(c, 1.0), amount); }

    // The Bayer matrix's threshold for an output pixel, 2^bits on a side.
    inline float bayer(uint2 p, uint bits) {
        uint v = 0;
        for (uint i = 0; i < bits; i++) {
            uint x = (p.x >> i) & 1u, y = (p.y >> i) & 1u;
            v = v * 4u + 2u * (x ^ y) + y;
        }
        return (float(v) + 0.5) / float(1u << (2u * bits));
    }

    // MARK: Distortion

    inline float2 turned(float2 v, float angle) {
        float c = cos(angle), s = sin(angle);
        return float2(v.x * c - v.y * s, v.x * s + v.y * c);
    }
    // Back and forth between 0 and 1, so mirrored copies meet seamlessly.
    inline float2 mirrored(float2 w) { return 1.0 - abs(fract(w * 0.5) * 2.0 - 1.0); }

    // White from `inner` out to `outer` around the center: one of
    // Slit-Scan's rings.
    extern "C" [[stitchable]] float4 amvRingMask(float2 center, float inner, float outer, coreimage::destination dest) {
        float r = distance(dest.coord(), center);
        float v = r >= inner && r < outer ? 1.0 : 0.0;
        return float4(v, v, v, 1.0);
    }
    """
}

/// Draws a look step on a picture.
enum LookRenderer {
    /// `picture` with `step` drawn on it over `region`, in output pixels
    /// at `scale` of the timeline's, in a timeline of `space`. Every look
    /// drawn one step at a time comes from an effect package (see
    /// `PackageLookRenderer`); Displace and the looks drawn from other
    /// moments draw their own way (`displace`, `moments`). The picture as
    /// it is for any other.
    static func apply(
        _ step: LookStep, to picture: CIImage, over region: CGRect, canvas: CGRect, frame: CGRect, scale: CGFloat,
        space: ProjectColorSpace, pictures: [CIImage] = [], flags: [String: Double] = [:]
    ) -> CIImage {
        guard let package = step.kind.definition.package else { return picture }
        return PackageLookRenderer.apply(
            package, step, to: picture, over: region, canvas: canvas, frame: frame, scale: scale, space: space,
            pictures: pictures, flags: flags
        )
    }

    /// The looks drawn from the picture at other moments: `earlier` gives
    /// the picture just before the look from a moment `delay` back, and
    /// `ahead` from frames ahead in the footage; either is nil where there
    /// is none. While the viewer plays they draw less: Feedback every other
    /// copy, Slit-Scan four bands, Flow Smear nothing.
    static func moments(
        _ step: LookStep, current: CIImage, earlier: (CMTime) -> CIImage?, ahead: () -> CIImage?,
        canvas: CGRect, frame: CGRect, scale: CGFloat, space: ProjectColorSpace, frameDuration: CMTime, isPlaying: Bool
    ) -> CIImage {
        switch step.kind {
        case .feedback:
            let copies = Int(step.value(.copies)), delayFrames = Int(step.value(.feedbackDelay))
            let grow = step.value(.copyScale) / 100, turn = step.value(.copyRotation) * .pi / 180
            let hue = step.value(.hueStep) / 360, keep = 1 - step.value(.copyDecay) / 100
            let center = Self.center(step, frame: frame, scale: scale)
            var result = current
            for k in stride(from: copies, through: 1, by: -1) {
                if isPlaying, copies > 1, k % 2 == 1 { continue }
                guard let image = earlier(MomentDelays.feedback(copy: k, delayFrames: delayFrames, frame: frameDuration)) else { continue }
                // The move raised to the k-th power: scaled and turned k
                // times about the center (clockwise on screen, as Rotation).
                let move = CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(scaleX: pow(grow, Double(k)), y: pow(grow, Double(k))))
                    .concatenating(CGAffineTransform(rotationAngle: -turn * Double(k)))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
                var copy = image.transformed(by: move).cropped(to: canvas)
                if hue != 0 { copy = hueTurned(copy, by: hue * Double(k), space: space, over: canvas) }
                copy = copy.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(pow(keep, Double(k)))),
                ])
                result = copy.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: result])
            }
            return result.cropped(to: canvas)
        case .slitScan:
            let full = Int(step.value(.bands)), spread = step.value(.timeSpread)
            let bands = isPlaying ? min(4, full) : full
            let direction = step.choice(.slitDirection, as: SlitDirection.self) ?? .rows
            let center = Self.center(step, frame: frame, scale: scale)
            let reach = hypot(frame.width, frame.height) / 2
            var result = CIImage(color: .clear).cropped(to: canvas)
            for band in 0..<bands {
                // With fewer bands, each takes the moment of the band of the
                // full set it stands for, which the composition has.
                let index = bands > 1 ? Int((Double(band) * Double(full - 1) / Double(bands - 1)).rounded()) : 0
                let delay = MomentDelays.slit(band: index, of: full, spread: spread, frame: frameDuration)
                let image = delay > .zero ? earlier(delay) ?? current : current
                let lo = CGFloat(band) / CGFloat(bands), hi = CGFloat(band + 1) / CGFloat(bands)
                let piece: CIImage
                switch direction {
                case .rows:
                    // From the top down; the first and last reach the canvas.
                    let top = band == 0 ? canvas.maxY : frame.maxY - lo * frame.height
                    let bottom = band == bands - 1 ? canvas.minY : frame.maxY - hi * frame.height
                    piece = image.cropped(to: CGRect(x: canvas.minX, y: bottom, width: canvas.width, height: top - bottom))
                case .columns:
                    let left = band == 0 ? canvas.minX : frame.minX + lo * frame.width
                    let right = band == bands - 1 ? canvas.maxX : frame.minX + hi * frame.width
                    piece = image.cropped(to: CGRect(x: left, y: canvas.minY, width: right - left, height: canvas.height))
                case .rings:
                    guard let kernel = LookKernels.compiled["amvRingMask"] as? CIColorKernel,
                          let mask = kernel.apply(extent: canvas.integral, arguments: [
                              CIVector(x: center.x, y: center.y), Float(lo * reach), Float(band == bands - 1 ? 1e9 : hi * reach),
                          ])
                    else { return current }
                    piece = image.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
                    ])
                }
                result = piece.composited(over: result)
            }
            return result.cropped(to: canvas)
        case .flowSmear:
            guard !isPlaying, let later = ahead() else { return current }
            let bounds = frame.integral
            let amount = step.value(.smear) / 100
            guard let field = BlockMatchFlow.field(from: current, to: later, progress: 0, in: bounds, reach: 1.0 / 6),
                  let smeared = MorphFlow.warped(current, along: field, by: -amount, in: bounds)
            else { return current }
            return smeared.cropped(to: bounds).composited(over: current)
        default:
            return current
        }
    }

    /// `image` with its hues turned by `turn` of a full turn, by Hue Cycle's
    /// kernel from its package.
    private static func hueTurned(_ image: CIImage, by turn: Double, space: ProjectColorSpace, over region: CGRect) -> CIImage {
        guard let package = EffectKind.hueCycle.definition.package,
              let kernel = PackageKernels.kernel(for: package) as? CIColorKernel
        else { return image }
        return kernel.apply(extent: region.integral, arguments: [
            image.cropped(to: region), Float(space.gradingSpaceIndex), Float(turn - floor(turn)), Float(0), Float(0), Float(1),
        ]) ?? image
    }

    /// Where a look's Center is, in output pixels: an offset from the
    /// middle of the frame in the timeline's pixels, down being positive.
    private static func center(_ step: LookStep, frame: CGRect, scale: CGFloat) -> CGPoint {
        let offset = step.values(.distortCenter)
        return CGPoint(x: frame.midX + CGFloat(offset[0]) * scale, y: frame.midY - CGFloat(offset.count > 1 ? offset[1] : 0) * scale)
    }

    /// Which frame a look that changes every frame is on: its time in
    /// thousandths of a second, so each frame of any rate differs.
    private static func frameNumber(_ step: LookStep) -> Float {
        Float((step.seconds * 1000).rounded())
    }
}
