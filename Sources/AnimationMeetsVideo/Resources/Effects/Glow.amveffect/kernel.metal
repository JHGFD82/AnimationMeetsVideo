// A glow around the picture's highlights, in two passes. The first keeps
// what is brighter than `threshold`, as linear light, which the blur
// after it spreads; the second adds that light, tinted by `color`, over
// the picture as it reached the effect. Light adds in linear light, so a
// highlight above white in an HDR timeline glows brighter still.

// The light in a pixel brighter than `threshold`, fading in over the
// brightness above it, premultiplied. Brightness is its luminance as a
// Rec. 709 signal (white 1, in any timeline), so a threshold looks the
// same in SDR and HDR and HDR highlights are past every one.
inline float3 glowLight(float4 s, float space, float threshold) {
    float3 l = max(toLinear(straight(s), space), 0.0);
    float y = enc709(dot(l, float3(0.2126, 0.7152, 0.0722)));
    float w = smoothstep(threshold, threshold + max(1.0 - threshold, 0.02), y);
    return l * w * s.a;
}

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover, so a glow reaches past a layer's edges.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

extern "C" [[stitchable]] float4 amvGlow(coreimage::sampler src, float space, coreimage::sampler original, float pass,
                                         float threshold, float4 color, float intensity, float amount,
                                         coreimage::destination dest) {
    float2 d = dest.coord();
    if (pass < 0.5) {
        float3 light = glowLight(original.sample(original.transform(d)), space, threshold);
        return float4(light, clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0));
    }
    float4 o = original.sample(original.transform(d));
    if (amount <= 0.0) return o;
    float3 light = src.sample(src.transform(d)).rgb * max(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), 0.0) * intensity * amount;
    return lightOver(o, light, space);
}
