// Colors by brightness: thermal, X-ray or a duotone.
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
