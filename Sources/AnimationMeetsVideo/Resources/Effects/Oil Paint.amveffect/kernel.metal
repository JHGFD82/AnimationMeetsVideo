// A Kuwahara filter: each pixel takes the average of whichever of the
// four squares meeting at it is most even, so flat areas flatten into
// strokes while edges stay sharp. Sharpness blends the squares by how
// even each is, from a soft mix to the most even alone.

extern "C" [[stitchable]] float4 amvOilPaint(coreimage::sampler src, float space, float radius, float sharpness, float amount,
                                             coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    radius = max(radius, 0.5);
    // At most 6×6 samples a square, spread over a large brush.
    int n = int(clamp(floor(radius) + 1.0, 2.0, 6.0));
    float spacing = radius / float(n - 1);
    float q = mix(1.0, 12.0, sharpness);
    float4 means[4];
    float spreads[4];
    for (int k = 0; k < 4; k++) {
        float2 toward = float2(k == 1 || k == 2 ? -1.0 : 1.0, k >= 2 ? -1.0 : 1.0);
        float4 sum = float4(0.0);
        float3 squares = float3(0.0);
        for (int j = 0; j < n; j++) {
            for (int i = 0; i < n; i++) {
                float4 c = src.sample(src.transform(d + toward * float2(i, j) * spacing));
                sum += c;
                squares += c.rgb * c.rgb;
            }
        }
        float count = float(n * n);
        means[k] = sum / count;
        float3 variance = max(squares / count - means[k].rgb * means[k].rgb, 0.0);
        spreads[k] = variance.r + variance.g + variance.b + 1e-5;
    }
    // Weighed against the most even, which always counts fully.
    float least = min(min(spreads[0], spreads[1]), min(spreads[2], spreads[3]));
    float4 total = float4(0.0);
    float weights = 0.0;
    for (int k = 0; k < 4; k++) {
        float w = pow(least / spreads[k], q);
        total += means[k] * w;
        weights += w;
    }
    float4 painted = total / weights;
    return mix(original, painted, amount);
}
