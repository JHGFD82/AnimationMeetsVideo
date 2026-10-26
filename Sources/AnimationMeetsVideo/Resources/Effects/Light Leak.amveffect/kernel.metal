// Light leaking into the camera from one side, as through a gap in an
// old camera's body: large soft washes of warm color from the edge the
// angle points to (0 the left, turning clockwise), whose shape and
// colors drift as `time` (speed times the clip's seconds) goes on.
// Added over the picture in linear light, burning toward white where
// it is strongest.

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

extern "C" [[stitchable]] float4 amvLightLeak(coreimage::sample_t s, float space, float2 middle, float width, float height, float angle,
                                              float size, float brightness, float4 color, float4 color2, float time,
                                              float seed, float amount, coreimage::destination dest) {
    if (amount <= 0.0) return s;
    // Toward the edge the light comes from, 0.5 there and -0.5 at the
    // other; and across the frame's longer side, -0.5 to 0.5.
    float2 from = -float2(cos(angle), sin(angle));
    float2 v = dest.coord() - middle;
    float toward = dot(v, from) / max(abs(from.x) * width + abs(from.y) * height, 1.0);
    float2 w = v / max(max(width, height), 1.0) / max(size, 0.1);
    int n = int(seed);
    // Two slow layers of noise: one bends the edge of the light, the
    // other mixes its two colors.
    float bend = noise3(float3(w * 1.6, time * 0.35), n);
    float blend = noise3(float3(w * 0.9 + 7.3, time * 0.22 + 4.1), n + 1);
    float pulse = 0.8 + 0.2 * noise3(float3(0.5, 0.5, time * 0.3 + 11.0), n + 2);
    float strength = clamp(1.8 * toward - 0.05 + 0.5 * bend, 0.0, 1.0);
    strength = strength * strength * pulse;
    float3 hue = mix(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), toLinear(clamp(color2.rgb, 0.0, 1.0), 0.0),
                     smoothstep(-0.45, 0.45, blend));
    // Where it is strongest it burns toward white.
    float3 light = (hue * strength + float3(1.0, 0.9, 0.75) * pow(strength, 4.0) * 0.6) * 1.5;
    return lightOver(s, light * brightness * amount, space);
}
