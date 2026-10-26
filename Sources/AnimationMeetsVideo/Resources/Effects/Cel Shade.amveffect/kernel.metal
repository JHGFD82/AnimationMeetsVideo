// Cartoon shading: brightness in a few flat bands, each keeping the
// picture's hue (unlike Posterize, which bands each channel), with ink
// outlines where brightness changes by more than `threshold`.

inline float3 tonesAt(coreimage::sampler src, float2 p, float space) {
    return toTones(straight(src.sample(src.transform(p))), space);
}

extern "C" [[stitchable]] float4 amvCelShade(coreimage::sampler src, float space, float bands, float width, float threshold,
                                             float4 outline, float saturation, float smoothing, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    // A little smoothing first, so grain doesn't break the bands up.
    float3 t = float3(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) t += tonesAt(src, d + float2(i, j) * smoothing, space) * (i == 0 && j == 0 ? 2.0 : 1.0);
    }
    t /= 10.0;
    float y = luma(t);
    // Banded, with the step between bands smoothed over a few percent so
    // its edge doesn't stair-step.
    float steps = max(bands - 1.0, 1.0);
    float f = clamp(y, 0.0, 1.0) * steps;
    float banded = (floor(f) + smoothstep(0.45, 0.55, fract(f))) / steps;
    float3 shaded = banded + (t - y) * saturation;
    if (width > 0.0) {
        float l[9];
        for (int j = 0; j < 3; j++) {
            for (int i = 0; i < 3; i++) l[j * 3 + i] = luma(tonesAt(src, d + float2(i - 1, j - 1) * width, space));
        }
        float gx = (l[2] + 2.0 * l[5] + l[8]) - (l[0] + 2.0 * l[3] + l[6]);
        float gy = (l[6] + 2.0 * l[7] + l[8]) - (l[0] + 2.0 * l[1] + l[2]);
        float edge = sqrt(gx * gx + gy * gy) * 0.25;
        float low = max(threshold - 0.05, 0.0);
        float line = smoothstep(low, low + 0.1, edge) * outline.a;
        shaded = mix(shaded, toTones(outline.rgb, 0.0), line);
    }
    return mixed(original, fromTones(shaded, space), amount);
}
