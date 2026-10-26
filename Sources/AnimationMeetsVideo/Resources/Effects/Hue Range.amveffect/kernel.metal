// Changes only the colors near one hue: within Width of Hue fully, fading
// out across Softness beyond it, and less as a color nears gray, so grays
// are never touched. There it turns the hue, scales the saturation and
// takes the tone toward black or white. Show Range draws how much each
// pixel is changed instead, white for fully.
inline float hueOf(float3 c) {
    float high = max(c.r, max(c.g, c.b)), low = min(c.r, min(c.g, c.b)), d = high - low;
    if (d <= 0.0) return 0.0;
    float h = high == c.r ? (c.g - c.b) / d : (high == c.g ? 2.0 + (c.b - c.r) / d : 4.0 + (c.r - c.g) / d);
    return fract(h / 6.0);
}

extern "C" [[stitchable]] float4 amvHueRange(coreimage::sample_t s, float space, float center, float width, float softness,
                                             float hueShift, float saturation, float lightness, float view, float amount) {
    float3 t = toTones(straight(s), space);
    float d = abs(hueOf(t) - center);
    d = min(d, 1.0 - d);
    float within = softness > 0.0001 ? 1.0 - smoothstep(width, width + softness, d) : float(d <= width);
    float chroma = max(t.r, max(t.g, t.b)) - min(t.r, min(t.g, t.b));
    float w = within * smoothstep(0.0, 0.08, chroma);
    if (view > 0.5) return mixed(s, fromTones(float3(w), space), amount);

    float3 c = hueRotated(t, hueShift * w);
    float y = luma(c);
    c = y + (c - y) * max(1.0 + saturation * w, 0.0);
    float l = lightness * w;
    c = l >= 0.0 ? c + max(1.0 - c, 0.0) * l : c * (1.0 + l);
    return mixed(s, fromTones(c, space), amount);
}
