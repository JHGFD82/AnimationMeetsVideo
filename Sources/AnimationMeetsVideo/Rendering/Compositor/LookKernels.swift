import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// The Metal functions the looks of docs/psychedelic-effects.md share.
/// Every look's kernel is in its effect package, compiled with these in
/// front (`prelude`) by `PackageKernels`.
/// They read the picture as the timeline encodes it and work on the log
/// curve the Color effect's Contrast does, so a look is the same in Rec.
/// 709, PQ and HLG.
enum LookKernels {
    /// The functions every look's kernel may use, put in front of an
    /// effect package's kernel (see docs/effect-packages.md, "The kernel").
    static let prelude = source

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

    // MARK: Curves

    // What tone `t` becomes on a curve, read from its table (a curve
    // picture, `ToneCurveTable`): tones from black to white across its
    // pixels, each one's new tone in red, and in green the slope it leaves
    // white at, which tones past white carry on along. Below black it holds.
    inline float curveTone(coreimage::sampler table, float t) {
        float4 e = table.extent();
        float at = e.x + 0.5 + clamp(t, 0.0, 1.0) * (e.z - 1.0);
        float4 c = table.sample(table.transform(float2(at, e.y + 0.5)));
        return t > 1.0 ? c.r + (t - 1.0) * c.g : c.r;
    }

    // MARK: Distortion

    inline float2 turned(float2 v, float angle) {
        float c = cos(angle), s = sin(angle);
        return float2(v.x * c - v.y * s, v.x * s + v.y * c);
    }
    // Back and forth between 0 and 1, so mirrored copies meet seamlessly.
    inline float2 mirrored(float2 w) { return 1.0 - abs(fract(w * 0.5) * 2.0 - 1.0); }

    """
}

/// Draws a look step on a picture.
enum LookRenderer {
    /// `picture` with `step` drawn on it over `region`, in output pixels
    /// at `scale` of the timeline's, in a timeline of `space`. Every look
    /// comes from an effect package (see `PackageLookRenderer`); the
    /// picture as it is for any other kind.
    static func apply(
        _ step: LookStep, to picture: CIImage, over region: CGRect, canvas: CGRect, frame: CGRect, scale: CGFloat,
        space: ProjectColorSpace, pictures: [String: CIImage] = [:], flags: [String: Double] = [:],
        moments: PackageLookRenderer.Moments? = nil
    ) -> CIImage {
        guard let package = step.kind.definition.package else { return picture }
        return PackageLookRenderer.apply(
            package, step, to: picture, over: region, canvas: canvas, frame: frame, scale: scale, space: space,
            pictures: pictures, flags: flags, moments: moments
        )
    }
}
