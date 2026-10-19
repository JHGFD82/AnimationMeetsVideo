import CoreGraphics
import CoreImage
import Foundation

/// The Core Image kernels the looks of docs/psychedelic-effects.md draw
/// with, compiled from one Metal source the first time a look is drawn,
/// as `MorphFlow` compiles its warp. Each Color look is a color kernel,
/// one pixel in and one out, so Core Image joins a run of them into one
/// pass. They read the picture as the timeline encodes it and work on the
/// log curve the Color effect's Contrast does, so a look is the same in
/// Rec. 709, PQ and HLG.
enum LookKernels {
    /// Kernels by function name; empty where the source didn't compile, and
    /// the looks then leave the picture as it is.
    static let compiled: [String: CIKernel] = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            return Dictionary(kernels.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            NSLog("The look kernels couldn't be compiled: \(error)")
            return [:]
        }
    }()

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

    extern "C" [[stitchable]] float4 amvHueCycle(coreimage::sample_t s, float space, float turn, float spread, float boost, float amount) {
        float3 t = toTones(straight(s), space);
        float y = luma(t);
        float3 turned = hueRotated(t, 6.283185307 * turn + spread * y);
        turned = y + (turned - y) * (1.0 + boost);
        return mixed(s, fromTones(turned, space), amount);
    }

    extern "C" [[stitchable]] float4 amvCosinePalette(coreimage::sample_t s, float space, float3 a, float3 b, float3 c, float3 d, float shift, float amount) {
        float y = luma(toTones(straight(s), space));
        float3 color = a + b * cos(6.283185307 * (c * y + d + shift));
        return mixed(s, fromTones(color, space), amount);
    }

    extern "C" [[stitchable]] float4 amvGradientMap(coreimage::sample_t s, float space, float4 low, float4 middle, float4 high,
                                     float repeats, float shift, float amount) {
        float y = luma(toTones(straight(s), space));
        float u = triangle(clamp(y, 0.0, 1.0) * repeats + shift);
        float4 color = u < 0.5 ? mix(low, middle, u * 2.0) : mix(middle, high, u * 2.0 - 1.0);
        float4 result = mixed(s, color.rgb, amount);
        return result * mix(1.0, color.a, amount);
    }

    extern "C" [[stitchable]] float4 amvSolarize(coreimage::sample_t s, float space, float threshold, float folds, float eachChannel, float amount) {
        float3 t = toTones(straight(s), space);
        float3 folded;
        if (eachChannel > 0.5) {
            folded = select(threshold * float3(triangle(1.0 + (t.r - threshold) / threshold * folds),
                                               triangle(1.0 + (t.g - threshold) / threshold * folds),
                                               triangle(1.0 + (t.b - threshold) / threshold * folds)), t, t <= threshold);
        } else {
            float y = luma(t);
            float to = y <= threshold ? y : threshold * triangle(1.0 + (y - threshold) / threshold * folds);
            folded = t + (to - y);
        }
        return mixed(s, fromTones(folded, space), amount);
    }

    extern "C" [[stitchable]] float4 amvPosterize(coreimage::sample_t s, float space, float levels, float amount) {
        float3 t = toTones(straight(s), space);
        float steps = max(levels - 1.0, 1.0);
        return mixed(s, fromTones(round(clamp(t, 0.0, 1.0) * steps) / steps, space), amount);
    }

    extern "C" [[stitchable]] float4 amvChannelMixer(coreimage::sample_t s, float space, float3 red, float3 green, float3 blue, float3 offset, float amount) {
        float3 t = toTones(straight(s), space);
        float3 m = float3(dot(red, t), dot(green, t), dot(blue, t)) + offset;
        return mixed(s, fromTones(m, space), amount);
    }

    extern "C" [[stitchable]] float4 amvFalseColor(coreimage::sample_t s, float space, float look, float4 low, float4 high, float amount) {
        float y = clamp(luma(toTones(straight(s), space)), 0.0, 1.0);
        float3 color;
        if (look < 0.5) {
            // Thermal: black, blue, magenta, red, yellow, white.
            float3 stops[6] = { float3(0.0), float3(0.1, 0.1, 0.8), float3(0.8, 0.1, 0.7), float3(1.0, 0.15, 0.05),
                                float3(1.0, 0.85, 0.1), float3(1.0) };
            float x = y * 5.0;
            int i = min(int(x), 4);
            color = mix(stops[i], stops[i + 1], x - float(i));
        } else if (look < 1.5) {
            // X-ray: the tones inverted, toward a cold blue in the shadows.
            float v = 1.0 - y;
            color = mix(float3(0.02, 0.05, 0.15), float3(0.85, 0.95, 1.0), v * v);
        } else {
            // The person's colors are the timeline's own values, as a
            // shape's fill is.
            return mixed(s, mix(low.rgb, high.rgb, y), amount);
        }
        // The built-in palettes are Rec. 709 colors, the same in any space.
        return mixed(s, fromTones(toTones(color, 0.0), space), amount);
    }

    // Outlines where the brightness changes, read `width` output pixels
    // either side, over black.
    extern "C" [[stitchable]] float4 amvNeonEdges(coreimage::sampler src, float space, float width, float byDirection, float4 color,
                                   float amount, coreimage::destination dest) {
        float2 d = dest.coord();
        float4 s = src.sample(src.transform(d));
        float l[9];
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) {
                float4 n = src.sample(src.transform(d + float2(i - 1, j - 1) * width));
                l[j * 3 + i] = luma(toTones(straight(n), space));
            }
        }
        float gx = (l[2] + 2.0 * l[5] + l[8]) - (l[0] + 2.0 * l[3] + l[6]);
        float gy = (l[6] + 2.0 * l[7] + l[8]) - (l[0] + 2.0 * l[1] + l[2]);
        float strength = clamp(length(float2(gx, gy)) * 2.0, 0.0, 1.0);
        float3 tint = byDirection > 0.5 ? hsv(atan2(gy, gx) / 6.283185307 + 0.5, 0.85, 1.0) : color.rgb;
        float3 lit = fromTones(toTones(tint, 0.0) * strength, space);
        return mixed(s, lit, amount);
    }
    """
}

/// Draws a look step on a picture.
enum LookRenderer {
    /// `picture` with `step` drawn on it over `region`, in output pixels
    /// at `scale` of the timeline's (for sizes given in its pixels), in a
    /// timeline of `space`. The picture as it is if the kernels didn't
    /// compile.
    static func apply(_ step: LookStep, to picture: CIImage, over region: CGRect, scale: CGFloat, space: ProjectColorSpace) -> CIImage {
        let region = region.integral
        guard !region.isEmpty, !region.isInfinite else { return picture }
        let spaceIndex = Float(space.gradingSpaceIndex)
        let amount = Float(step.amount)
        func color(_ name: String, _ arguments: [Any]) -> CIImage {
            guard let kernel = LookKernels.compiled[name] else { return picture }
            let input = picture.cropped(to: region)
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
        case .hueCycle:
            let turn = step.value(.hueSpeed) * step.seconds
            return color("amvHueCycle", [
                Float(turn - floor(turn)), Float(step.value(.hueSpread) * .pi / 180), Float(step.value(.saturationBoost) / 100),
            ])
        case .cosinePalette:
            let look = step.choice(.palette, as: PaletteLook.self) ?? .rainbow
            let vectors = look == .custom
                ? (step.values(.paletteBias), step.values(.paletteAmplitude), step.values(.paletteFrequency), step.values(.palettePhase))
                : look.vectors
            let shift = step.value(.cycleSpeed) * step.seconds
            return color("amvCosinePalette", [
                vector(vectors.0), vector(vectors.1), vector(vectors.2), vector(vectors.3), Float(shift - floor(shift)),
            ])
        case .gradientMap:
            let shift = step.value(.scrollSpeed) * step.seconds
            return color("amvGradientMap", [
                vector(step.values(.shadowColor)), vector(step.values(.midtoneColor)), vector(step.values(.highlightColor)),
                Float(step.value(.repeats)), Float((shift - floor(shift / 2) * 2)),
            ])
        case .solarize:
            let each = step.choice(.solarizeChannels, as: SolarizeChannels.self) == .each
            return color("amvSolarize", [Float(step.value(.solarizeLevel) / 100), Float(step.value(.folds)), Float(each ? 1 : 0)])
        case .posterize:
            return color("amvPosterize", [Float(step.value(.levels))])
        case .channelMixer:
            return color("amvChannelMixer", [
                vector(step.values(.mixRed)), vector(step.values(.mixGreen)), vector(step.values(.mixBlue)), vector(step.values(.mixOffset)),
            ])
        case .falseColor:
            let look: Float = switch step.choice(.falseColorLook, as: FalseColorLook.self) ?? .thermal {
            case .thermal: 0
            case .xray: 1
            case .duotone: 2
            }
            return color("amvFalseColor", [look, vector(step.values(.shadowColor)), vector(step.values(.highlightColor))])
        case .neonEdges:
            guard let kernel = LookKernels.compiled["amvNeonEdges"] else { return picture }
            let width = CGFloat(step.value(.edgeWidth)) * scale
            let byDirection = step.choice(.edgeColoring, as: EdgeColoring.self) != .oneColor
            let input = picture.cropped(to: region).clampedToExtent()
            guard var edges = kernel.apply(
                extent: region,
                roiCallback: { _, rect in rect.insetBy(dx: -ceil(width) - 1, dy: -ceil(width) - 1) },
                arguments: [input, spaceIndex, Float(width), Float(byDirection ? 1 : 0), vector(step.values(.edgeColor)), amount]
            ) else { return picture }
            let glow = step.value(.glow) / 100
            if glow > 0 {
                edges = edges.applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: width * 4, kCIInputIntensityKey: glow,
                ]).cropped(to: region)
            }
            return edges
        default:
            return picture
        }
    }
}
