// Saturation that favors the muted colors: each color moves from its gray
// by a factor that shrinks as the color is already saturated, so vivid
// colors don't clip while dull ones come up. Raising it spares the
// orange hues of skin by Protect Skin Tones.
inline float hueOf(float3 c) {
    float high = max(c.r, max(c.g, c.b)), low = min(c.r, min(c.g, c.b)), d = high - low;
    if (d <= 0.0) return 0.0;
    float h = high == c.r ? (c.g - c.b) / d : (high == c.g ? 2.0 + (c.b - c.r) / d : 4.0 + (c.r - c.g) / d);
    return fract(h / 6.0);
}

extern "C" [[stitchable]] float4 amvVibrance(coreimage::sample_t s, float space, float vibrance, float protect, float amount) {
    float3 t = toTones(straight(s), space);
    float y = luma(t);
    float chroma = clamp(max(t.r, max(t.g, t.b)) - min(t.r, min(t.g, t.b)), 0.0, 1.0);
    float weight = 1.0 - chroma;
    if (vibrance > 0.0) {
        // Skin sits near 25° of hue.
        float d = abs(hueOf(t) - 25.0 / 360.0);
        d = min(d, 1.0 - d) * 360.0;
        float skin = exp(-(d * d) / (2.0 * 15.0 * 15.0)) * smoothstep(0.02, 0.1, chroma);
        weight *= 1.0 - protect * skin;
    }
    float3 c = y + (t - y) * max(1.0 + vibrance * weight, 0.0);
    return mixed(s, fromTones(c, space), amount);
}
