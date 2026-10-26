// Rays of light streaming out from `source` past the picture's bright
// parts, as light through haze. Each pixel gathers the light lying
// between it and the source, up to `rayLength` of the way there, fading
// with distance along the ray. Four passes: the first keeps the light
// above `threshold`; the second gathers it in 24 coarse steps, the
// third fills between those in 16 finer ones (384 samples in all, for
// the cost of 40); the last adds the rays, in `color`, over the picture
// as it reached the effect, in linear light.

constant int coarseSteps = 24;
constant int fineSteps = 16;

// The light in a pixel brighter than `threshold`, fading in over the
// brightness above it, premultiplied. Brightness is its luminance as a
// Rec. 709 signal (white 1, in any timeline).
inline float3 rayLight(float4 s, float space, float threshold) {
    float3 l = max(toLinear(straight(s), space), 0.0);
    float y = enc709(dot(l, float3(0.2126, 0.7152, 0.0722)));
    return l * smoothstep(threshold, threshold + max(1.0 - threshold, 0.02), y) * s.a;
}

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover, so rays reach past a layer's edges.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

inline float4 withCover(float3 light) { return float4(light, clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0)); }

extern "C" [[stitchable]] float4 amvLightRays(coreimage::sampler src, float space, coreimage::sampler original, float pass,
                                              float2 source, float rayLength, float threshold, float4 color, float intensity,
                                              float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    if (pass < 0.5) return withCover(rayLight(original.sample(original.transform(d)), space, threshold));
    // Steps toward the source, evenly in the logarithm of the distance
    // to it, so the finer pass fills between the coarse one's evenly.
    float2 away = d - source;
    float span = log(max(1.0 - clamp(rayLength, 0.0, 1.0) * 0.98, 0.02));
    if (pass < 1.5) {
        float3 sum = 0.0;
        float weights = 0.0;
        for (int i = 0; i < coarseSteps; i++) {
            float t = float(i) / float(coarseSteps);
            float w = exp(-2.5 * t);
            float2 p = source + away * exp(span * t);
            sum += src.sample(src.transform(p)).rgb * w;
            weights += w;
        }
        return withCover(sum / weights);
    }
    if (pass < 2.5) {
        float3 sum = 0.0;
        for (int j = 0; j < fineSteps; j++) {
            float2 p = source + away * exp(span * float(j) / float(coarseSteps * fineSteps));
            sum += src.sample(src.transform(p)).rgb;
        }
        return withCover(sum / float(fineSteps));
    }
    float4 o = original.sample(original.transform(d));
    if (amount <= 0.0) return o;
    float3 light = src.sample(src.transform(d)).rgb * max(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), 0.0) * intensity * amount;
    return lightOver(o, light, space);
}
