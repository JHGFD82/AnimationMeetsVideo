// One hue over the picture's brightness: each pixel becomes the color of
// that hue and saturation whose lightness is the pixel's tone, as a
// monochrome print toned in one color. Black and white stay black and
// white; HDR highlights above white keep their extra brightness.
inline float3 hsl(float h, float s, float l) {
    float3 k = clamp(abs(fract(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return l + (1.0 - abs(2.0 * l - 1.0)) * s * (k - 0.5);
}

extern "C" [[stitchable]] float4 amvColorize(coreimage::sample_t s, float space, float hue, float saturation, float amount) {
    float y = luma(toTones(straight(s), space));
    float within = clamp(y, 0.0, 1.0);
    return mixed(s, fromTones(hsl(hue, saturation, within) + (y - within), space), amount);
}
