// Turns every hue by the same angle around the gray axis, scales how far
// each color is from its gray (-100% is gray, +100% twice as colorful),
// then takes the tones toward black or white by Lightness. Grays keep
// their tone through the first two.
extern "C" [[stitchable]] float4 amvHueSaturation(coreimage::sample_t s, float space, float hue,
                                                  float saturation, float lightness, float amount) {
    float3 t = toTones(straight(s), space);
    float3 c = hueRotated(t, hue);
    float y = luma(c);
    c = y + (c - y) * max(1.0 + saturation, 0.0);
    // Toward white only below it, so HDR highlights aren't pulled down.
    c = lightness >= 0.0 ? c + max(1.0 - c, 0.0) * lightness : c * (1.0 + lightness);
    return mixed(s, fromTones(c, space), amount);
}
