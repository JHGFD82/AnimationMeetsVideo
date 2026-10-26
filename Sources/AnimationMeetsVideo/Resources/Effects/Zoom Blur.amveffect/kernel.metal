// Streaks toward a center, as a lens zoomed while the shutter was open:
// each pixel the average of the picture along the line to the center,
// `strength` of the way there (a negative strength reads away from it).
// Drawn in two passes of `count` samples: the first spread along the
// whole streak, the second along one of its steps, so together they take
// count × count evenly spaced samples for 2 × count reads a pixel.
// Distances scale rather than add, so the steps are even in their log.
extern "C" [[stitchable]] float4 amvZoomBlur(coreimage::sampler src, float space, float2 center, float strength, float count,
                                             float pass, float repeatEdges, float width, float height, coreimage::destination dest) {
    float2 d = dest.coord();
    float2 v = d - center;
    float lambda = log(1.0 - clamp(strength, -1.0, 0.99));
    int n = int(max(count, 1.0));
    float4 sum = float4(0.0);
    for (int k = 0; k < n; k++) {
        float e = pass < 0.5 ? float(k) / float(n) : (float(k) + 0.5) / float(n * n);
        float2 q = center + v * exp(lambda * e);
        // The frame's edges go on, so its sides don't darken.
        if (repeatEdges > 0.5) q = clamp(q, float2(0.5), float2(width, height) - 0.5);
        sum += src.sample(src.transform(q));
    }
    return sum / float(n);
}
