// Streaks around a center, as a camera turning while the shutter was
// open: each pixel the average of the picture along its circle, `angle`
// of arc centered on it. Drawn in two passes of `count` samples: the
// first spread over the whole arc, the second over one of its steps, so
// together they take count × count evenly spaced samples for 2 × count
// reads a pixel.
extern "C" [[stitchable]] float4 amvSpinBlur(coreimage::sampler src, float space, float2 center, float angle, float count,
                                             float pass, float repeatEdges, float width, float height, coreimage::destination dest) {
    float2 d = dest.coord();
    float2 v = d - center;
    int n = int(max(count, 1.0));
    float4 sum = float4(0.0);
    for (int k = 0; k < n; k++) {
        float turn = pass < 0.5 ? angle * (float(k) / float(n) - 0.5) : angle * (float(k) + 0.5) / float(n * n);
        float2 q = center + turned(v, turn);
        // The frame's edges go on, so its corners don't darken.
        if (repeatEdges > 0.5) q = clamp(q, float2(0.5), float2(width, height) - 0.5);
        sum += src.sample(src.transform(q));
    }
    return sum / float(n);
}
