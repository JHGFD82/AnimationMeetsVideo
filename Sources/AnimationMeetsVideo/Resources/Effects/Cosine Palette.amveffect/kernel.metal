// Colors each pixel by its brightness from a cosine palette, a + b·cos(2π(c·t + d)) (Inigo Quilez's).
// Bias (a), amplitude (b), frequency (c) and phase (d) for red, green and
// blue: Rainbow, Acid, Infrared and Oil Slick, or the controls' for Custom.
constant float3 presets[4][4] = {
    { float3(0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(1, 1, 1), float3(0, 0.33, 0.67) },
    { float3(0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(2, 1, 0), float3(0.5, 0.2, 0.25) },
    { float3(0.8, 0.5, 0.4), float3(0.2, 0.4, 0.2), float3(2, 1, 1), float3(0, 0.25, 0.25) },
    { float3(0.5, 0.5, 0.5), float3(0.5, 0.5, 0.5), float3(1, 0.7, 0.4), float3(0, 0.15, 0.2) },
};

extern "C" [[stitchable]] float4 amvCosinePalette(coreimage::sample_t s, float space, float look, float3 a, float3 b, float3 c, float3 d,
                                                  float shift, float amount) {
    int preset = int(look);
    if (preset < 4) {
        a = presets[preset][0];
        b = presets[preset][1];
        c = presets[preset][2];
        d = presets[preset][3];
    }
    float y = luma(toTones(straight(s), space));
    float3 color = a + b * cos(6.283185307 * (c * y + d + shift));
    return mixed(s, fromTones(color, space), amount);
}
