// A soft bloom of the picture's highlights, spread at three sizes at
// once, so it has a bright core and a long, faint tail, as light
// scattered in a lens does. The first pass keeps the light above
// `threshold` and the blur after it spreads it widest; the next two each
// add the same light again before a smaller blur; the last adds the sum
// over the picture as it reached the effect, in linear light.

// The light in a pixel brighter than `threshold`, fading in over the
// brightness above it, premultiplied, its colors `saturation` of theirs.
// Brightness is its luminance as a Rec. 709 signal (white 1, in any
// timeline), so a threshold looks the same in SDR and HDR.
inline float3 bloomLight(float4 s, float space, float threshold, float saturation) {
    float3 l = max(toLinear(straight(s), space), 0.0);
    float y = dot(l, float3(0.2126, 0.7152, 0.0722));
    float w = smoothstep(threshold, threshold + max(1.0 - threshold, 0.02), enc709(y));
    return max(mix(float3(y), l, saturation), 0.0) * w * s.a;
}

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover, so a bloom reaches past a layer's edges.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

extern "C" [[stitchable]] float4 amvBloom(coreimage::sampler src, float space, coreimage::sampler original, float pass,
                                          float threshold, float saturation, float intensity, float amount,
                                          coreimage::destination dest) {
    float2 d = dest.coord();
    float4 o = original.sample(original.transform(d));
    if (pass < 2.5) {
        float3 light = bloomLight(o, space, threshold, saturation);
        if (pass > 0.5) light += src.sample(src.transform(d)).rgb;
        return float4(light, clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0));
    }
    if (amount <= 0.0) return o;
    float3 light = src.sample(src.transform(d)).rgb * intensity * amount;
    return lightOver(o, light, space);
}
