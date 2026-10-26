// Keys out by brightness, on the tone scale black 0 to white 1. With
// Darks, tones up to `threshold` are clear and those from `threshold +
// softness` opaque; with Brights, tones from `threshold` up are clear and
// those up to `threshold - softness` opaque. View Matte shows the alpha
// alone, as Alpha Tools' Show Alpha does.
extern "C" [[stitchable]] float4 amvLumaKey(coreimage::sample_t s, float space, float bright, float threshold, float softness,
                                            float view, float amount) {
    float y = luma(toTones(straight(s), space));
    float keep;
    if (bright > 0.5) keep = softness > 0.0 ? 1.0 - smoothstep(threshold - softness, threshold, y) : float(y < threshold);
    else keep = softness > 0.0 ? smoothstep(threshold, threshold + softness, y) : float(y > threshold);
    float alpha = mix(1.0, keep, amount);
    if (view > 0.5) return float4(fromLinear(toLinear(float3(s.a * alpha), 0.0), space), 1.0);
    return s * alpha;
}
