// Outlines where the picture changes, in brightness or in color, read
// `width` output pixels either side, over black.
extern "C" [[stitchable]] float4 amvNeonEdges(coreimage::sampler src, float space, float width, float byDirection, float4 color,
                               float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 s = src.sample(src.transform(d));
    float3 l[9];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            float4 n = src.sample(src.transform(d + float2(i - 1, j - 1) * width));
            l[j * 3 + i] = toTones(straight(n), space);
        }
    }
    // Sobel on each channel; the direction is the strongest channel's.
    float3 gx = (l[2] + 2.0 * l[5] + l[8]) - (l[0] + 2.0 * l[3] + l[6]);
    float3 gy = (l[6] + 2.0 * l[7] + l[8]) - (l[0] + 2.0 * l[1] + l[2]);
    float3 size = sqrt(gx * gx + gy * gy);
    int strongest = size.r >= size.g && size.r >= size.b ? 0 : (size.g >= size.b ? 1 : 2);
    float strength = clamp(max(size.r, max(size.g, size.b)) * 1.5, 0.0, 1.0);
    float3 tint = byDirection > 0.5 ? hsv(atan2(gy[strongest], gx[strongest]) / 6.283185307 + 0.5, 0.85, 1.0) : color.rgb;
    float3 lit = fromTones(toTones(tint, 0.0) * strength, space);
    return mixed(s, lit, amount);
}
