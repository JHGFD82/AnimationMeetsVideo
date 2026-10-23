import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// The Core Image kernels the looks of docs/psychedelic-effects.md draw
/// with, compiled from one Metal source the first time a look is drawn,
/// as `MorphFlow` compiles its warp. Each Color look is a color kernel,
/// one pixel in and one out, so Core Image joins a run of them into one
/// pass. They read the picture as the timeline encodes it and work on the
/// log curve the Color effect's Contrast does, so a look is the same in
/// Rec. 709, PQ and HLG.
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

    // Each point taken from along a noise field evolving through time,
    // warped `warps` times through itself.
    extern "C" [[stitchable]] float2 amvLiquid(float scale, float size, float reach, float warps, float evolution, float seed,
                                               coreimage::destination dest) {
        float2 d = dest.coord();
        float2 p = d / (scale * size);
        float2 q = float2(0.0);
        for (int i = 0; i < int(warps); i++) {
            float2 at = p + 4.0 * q;
            q = float2(noise3(float3(at, evolution), int(seed) + i * 2), noise3(float3(at + 5.2, evolution), int(seed) + i * 2 + 1));
        }
        return d + q * reach;
    }

    extern "C" [[stitchable]] float2 amvTwirl(float2 center, float radius, float amount, float shape, coreimage::destination dest) {
        float2 d = dest.coord();
        float2 v = d - center;
        float r = length(v);
        if (r >= radius || r <= 0.0) return d;
        float t = 1.0 - r / radius;
        if (shape < 0.5) return center + turned(v, amount * 3.14159265 * t * t);
        if (shape < 1.5) return center + turned(v, amount * 0.5 * (radius / max(r, 1.0) - 1.0) * t * t);
        // Pinch takes each point from further out, bulge from further in.
        float f = shape < 2.5 ? pow(r / radius, -0.5 * amount * t) : pow(r / radius, amount * t);
        return center + v * clamp(f, 0.05, 20.0);
    }

    extern "C" [[stitchable]] float2 amvWave(float2 center, float wavelength, float height, float phase, float direction,
                                             coreimage::destination dest) {
        float2 d = dest.coord();
        if (direction < 0.5) return d + float2(0.0, height * sin(6.283185307 * (d.x / wavelength - phase)));
        if (direction < 1.5) return d + float2(height * sin(6.283185307 * (d.y / wavelength - phase)), 0.0);
        float2 v = d - center;
        float r = length(v);
        return r > 0.0 ? d + v / r * height * sin(6.283185307 * (r / wavelength - phase)) : d;
    }

    // Folds every direction round the center into one wedge, mirrored at
    // its edges.
    extern "C" [[stitchable]] float2 amvKaleidoscope(float2 center, float segments, float angle, coreimage::destination dest) {
        float2 v = dest.coord() - center;
        float wedge = 6.283185307 / segments;
        float a = atan2(v.y, v.x) - angle;
        a -= floor(a / wedge) * wedge;
        if (a > wedge * 0.5) a = wedge - a;
        return center + length(v) * float2(cos(a + angle), sin(a + angle));
    }

    extern "C" [[stitchable]] float2 amvMirrorTile(float2 center, float size, float angle, float pattern, float halfFrame,
                                                   coreimage::destination dest) {
        float2 v = turned(dest.coord() - center, -angle);
        if (pattern > 2.5) {
            // Droste: outside the size the picture is as it was; inside it
            // is the picture again, shrunk so the ring from the size out to
            // the frame's nearer edge fits inside the size, turned by the
            // angle, and inside that again, toward the middle.
            float r = length(v);
            if (r >= size) return dest.coord();
            if (r <= 0.0) return center;
            float zoom = max(halfFrame / size, 1.25);
            float steps = ceil(log(size / r) / log(zoom));
            return center + turned(turned(v, -steps * angle) * pow(zoom, steps), angle);
        }
        float2 u = v / size + 0.5;
        if (pattern < 0.5) u = fract(u);
        else u = mirrored(u);
        if (pattern > 1.5 && u.y > u.x) u = u.yx;
        return center + turned((u - 0.5) * size, angle);
    }

    // Moves each point of `image` by `map`'s red (across) and green (down),
    // from middle gray or from black.
    extern "C" [[stitchable]] float4 amvDisplace(coreimage::sampler image, coreimage::sampler map, float reach, float fromGray,
                                                 coreimage::destination dest) {
        float2 d = dest.coord();
        float4 m = map.sample(map.transform(d));
        float2 v = m.a > 0.0 ? m.rg / m.a : float2(fromGray > 0.5 ? 0.5 : 0.0);
        float2 offset = fromGray > 0.5 ? (v - 0.5) * 2.0 : v;
        return image.sample(image.transform(d + float2(offset.x, -offset.y) * reach));
    }

    // Red and blue pulled apart from green: out from the center, or along
    // a direction.
    // Radially, the full amount half the frame's width from the center.
    extern "C" [[stitchable]] float4 amvChromaticAberration(coreimage::sampler src, float2 center, float halfWidth, float reach,
                                                            float radial, float angle, coreimage::destination dest) {
        float2 d = dest.coord();
        float2 offset = radial > 0.5 ? (d - center) / max(halfWidth, 1.0) * reach : float2(cos(angle), sin(angle)) * reach;
        float4 r = src.sample(src.transform(d + offset));
        float4 g = src.sample(src.transform(d));
        float4 b = src.sample(src.transform(d - offset));
        return float4(r.r, g.g, b.b, max(g.a, max(r.a, b.a)));
    }

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
    /// at `scale` of the timeline's (for sizes given in its pixels), in a
    /// timeline of `space`. The picture as it is if the kernels didn't
    /// compile.
    /// A generator, which replaces the picture, fills `region`, or with
    /// nothing there `canvas`.
    static func apply(
        _ step: LookStep, to picture: CIImage, over region: CGRect, canvas: CGRect, frame: CGRect, scale: CGFloat,
        space: ProjectColorSpace
    ) -> CIImage {
        if let package = step.kind.definition.package {
            return PackageLookRenderer.apply(
                package, step, to: picture, over: region, canvas: canvas, frame: frame, scale: scale, space: space
            )
        }
        var region = region.integral
        if region.isEmpty, step.kind.generates { region = canvas.integral }
        guard !region.isEmpty, !region.isInfinite else { return picture }
        let spaceIndex = Float(space.gradingSpaceIndex)
        let amount = Float(step.amount)
        func color(_ name: String, _ arguments: [Any]) -> CIImage {
            guard let kernel = LookKernels.compiled[name] else { return picture }
            // A generator draws where nothing was too.
            let input = step.kind.generates
                ? picture.composited(over: CIImage(color: .clear)).cropped(to: region) : picture.cropped(to: region)
            if let color = kernel as? CIColorKernel {
                return color.apply(extent: region, arguments: [input, spaceIndex] + arguments + [amount]) ?? picture
            }
            return kernel.apply(extent: region, roiCallback: { _, rect in rect }, arguments: [input, spaceIndex] + arguments + [amount]) ?? picture
        }
        func vector(_ values: [Double]) -> CIVector {
            let v = values.map { CGFloat($0) }
            return v.count >= 4 ? CIVector(x: v[0], y: v[1], z: v[2], w: v[3]) : CIVector(x: v[0], y: v.count > 1 ? v[1] : 0, z: v.count > 2 ? v[2] : 0)
        }
        switch step.kind {
        case .liquid, .twirl, .wave, .kaleidoscope, .mirrorTile:
            return warped(step, picture, canvas: canvas, frame: frame, scale: scale)
        case .chromaticAberration:
            guard let kernel = LookKernels.compiled["amvChromaticAberration"] else { return picture }
            let reach = CGFloat(step.value(.aberration) / 100) * frame.width
            let radial = step.choice(.aberrationMode, as: AberrationMode.self) != .linear
            let center = Self.center(step, frame: frame, scale: scale)
            let input = picture.composited(over: CIImage(color: .clear)).cropped(to: canvas)
            return kernel.apply(
                extent: canvas.integral,
                roiCallback: { _, rect in rect.insetBy(dx: -2 * abs(reach) - 1, dy: -2 * abs(reach) - 1) },
                arguments: [
                    input, CIVector(x: center.x, y: center.y), Float(frame.width / 2), Float(reach),
                    Float(radial ? 1 : 0), Float(-step.value(.distortAngle) * .pi / 180),
                ]
            ) ?? picture
        default:
            return picture
        }
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

    /// `image` with its hues turned by `turn` of a full turn.
    private static func hueTurned(_ image: CIImage, by turn: Double, space: ProjectColorSpace, over region: CGRect) -> CIImage {
        guard let kernel = LookKernels.compiled["amvHueCycle"] as? CIColorKernel else { return image }
        return kernel.apply(extent: region.integral, arguments: [
            image.cropped(to: region), Float(space.gradingSpaceIndex), Float(turn - floor(turn)), Float(0), Float(0), Float(1),
        ]) ?? image
    }

    /// Displace: `moved` taken from along `map`'s red and green.
    static func displace(_ step: LookStep, moved: CIImage, map: CIImage, canvas: CGRect, frame: CGRect) -> CIImage? {
        guard let kernel = LookKernels.compiled["amvDisplace"] else { return nil }
        let reach = CGFloat(step.value(.displacement) / 100) * frame.width
        let fromGray = step.choice(.mapCenter, as: MapCenter.self) != .black
        let clear = CIImage(color: .clear)
        return kernel.apply(
            extent: canvas.integral,
            roiCallback: { index, rect in index == 0 ? rect.insetBy(dx: -abs(reach) - 1, dy: -abs(reach) - 1) : rect },
            arguments: [
                moved.composited(over: clear).cropped(to: canvas), map.composited(over: clear).cropped(to: canvas),
                Float(reach), Float(fromGray ? 1 : 0),
            ]
        )
    }

    /// Where a look's Center is, in output pixels: an offset from the
    /// middle of the frame in the timeline's pixels, down being positive.
    private static func center(_ step: LookStep, frame: CGRect, scale: CGFloat) -> CGPoint {
        let offset = step.values(.distortCenter)
        return CGPoint(x: frame.midX + CGFloat(offset[0]) * scale, y: frame.midY - CGFloat(offset.count > 1 ? offset[1] : 0) * scale)
    }

    /// The looks that only move where each pixel is read from.
    private static func warped(_ step: LookStep, _ picture: CIImage, canvas: CGRect, frame: CGRect, scale: CGFloat) -> CIImage {
        let name: String
        let arguments: [Any]
        let center = Self.center(step, frame: frame, scale: scale)
        let centerVector = CIVector(x: center.x, y: center.y)
        let degrees = { (kind: ControlKind) in step.value(kind) * .pi / 180 }
        switch step.kind {
        case .liquid:
            name = "amvLiquid"
            arguments = [
                Float(scale), Float(step.value(.noiseScale)), Float(step.value(.displacement) / 100 * frame.width),
                Float(step.value(.warps)), Float(step.value(.evolution) * step.seconds), Float(step.value(.seed)),
            ]
        case .twirl:
            name = "amvTwirl"
            let shape: Float = switch step.choice(.twirlShape, as: TwirlShape.self) ?? .twirl {
            case .twirl: 0
            case .vortex: 1
            case .pinch: 2
            case .bulge: 3
            }
            arguments = [centerVector, Float(step.value(.distortRadius) * scale), Float(step.value(.twirlAmount) / 100), shape]
        case .wave:
            name = "amvWave"
            let direction: Float = switch step.choice(.waveDirection, as: WaveDirection.self) ?? .horizontal {
            case .horizontal: 0
            case .vertical: 1
            case .radial: 2
            }
            arguments = [
                centerVector, Float(step.value(.wavelength) * scale), Float(step.value(.waveHeight) * scale),
                Float(step.value(.waveSpeed) * step.seconds), direction,
            ]
        case .kaleidoscope:
            name = "amvKaleidoscope"
            let spin = step.value(.spinSpeed) * step.seconds * 2 * .pi
            arguments = [centerVector, Float(step.value(.segments)), Float(-(degrees(.distortAngle) + spin))]
        case .mirrorTile:
            name = "amvMirrorTile"
            let pattern: Float = switch step.choice(.tilePattern, as: TilePattern.self) ?? .fourfold {
            case .tile: 0
            case .fourfold: 1
            case .eightfold: 2
            case .droste: 3
            }
            arguments = [
                centerVector, Float(step.value(.tileSize) * scale), Float(-degrees(.distortAngle)), pattern,
                Float(min(frame.width, frame.height) / 2),
            ]
        default:
            return picture
        }
        guard let kernel = LookKernels.compiled[name] as? CIWarpKernel else { return picture }
        let input = picture.composited(over: CIImage(color: .clear)).cropped(to: canvas)
        return kernel.apply(
            extent: canvas.integral, roiCallback: { _, _ in canvas }, image: input, arguments: arguments
        ) ?? picture
    }

    /// Which frame a look that changes every frame is on: its time in
    /// thousandths of a second, so each frame of any rate differs.
    private static func frameNumber(_ step: LookStep) -> Float {
        Float((step.seconds * 1000).rounded())
    }
}
