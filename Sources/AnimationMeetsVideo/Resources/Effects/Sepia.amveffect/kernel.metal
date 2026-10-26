// An old print's brown: the picture's brightness toned from a red-brown in
// the shadows to a cream in the highlights, Warmth saying how strongly.
// Black and white stay black and white.
inline float3 hsl(float h, float s, float l) {
    float3 k = clamp(abs(fract(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return l + (1.0 - abs(2.0 * l - 1.0)) * s * (k - 0.5);
}

extern "C" [[stitchable]] float4 amvSepia(coreimage::sample_t s, float space, float warmth, float amount) {
    float y = luma(toTones(straight(s), space));
    float within = clamp(y, 0.0, 1.0);
    float hue = mix(25.0, 45.0, within) / 360.0;
    return mixed(s, fromTones(hsl(hue, warmth * 0.6, within) + (y - within), space), amount);
}
