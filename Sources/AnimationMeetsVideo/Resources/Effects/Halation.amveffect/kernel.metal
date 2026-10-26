// Film's halation: light from bright highlights reflected back through
// the film's red layer, a warm fringe around them that shows on the dark
// beside them. The first pass keeps how much light is above `threshold`,
// which the blur after it spreads; the second adds it, in `color`, over
// the picture as it reached the effect, less where the picture is
// already bright, so highlights stay their own color and the fringe
// shows around them.

// How much light a pixel has above `threshold`, as one number,
// premultiplied. Brightness is its luminance as a Rec. 709 signal (white
// 1, in any timeline), so a threshold looks the same in SDR and HDR.
inline float halationLight(float4 s, float space, float threshold) {
    float3 l = max(toLinear(straight(s), space), 0.0);
    float y = dot(l, float3(0.2126, 0.7152, 0.0722));
    return y * smoothstep(threshold, threshold + max(1.0 - threshold, 0.02), enc709(y)) * s.a;
}

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

extern "C" [[stitchable]] float4 amvHalation(coreimage::sampler src, float space, coreimage::sampler original, float pass,
                                             float threshold, float4 color, float intensity, float amount,
                                             coreimage::destination dest) {
    float2 d = dest.coord();
    float4 o = original.sample(original.transform(d));
    if (pass < 0.5) {
        float y = halationLight(o, space, threshold);
        return float4(float3(y), clamp(y, 0.0, 1.0));
    }
    if (amount <= 0.0) return o;
    float halo = src.sample(src.transform(d)).r;
    // Brightness here as a Rec. 709 signal, so the fringe fades out on
    // what is already near white.
    float here = enc709(dot(max(toLinear(straight(o), space), 0.0), float3(0.2126, 0.7152, 0.0722))) * o.a;
    float3 light = max(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), 0.0) * halo * intensity * amount * (1.0 - 0.85 * clamp(here, 0.0, 1.0));
    return lightOver(o, light, space);
}
