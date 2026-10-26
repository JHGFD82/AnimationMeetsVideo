// Edges drawn dark on white paper, where Neon Edges lights them over
// black: each channel's edges in its opposite color (Colored), gray
// pencil lines, or black ink lines where the edge is stronger than
// `threshold`. A flat picture is blank paper.

extern "C" [[stitchable]] float4 amvFindEdges(coreimage::sampler src, float space, float style, float width, float strength,
                                              float threshold, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    float3 l[9];
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            float4 n = src.sample(src.transform(d + float2(i - 1, j - 1) * width));
            l[j * 3 + i] = clamp(toTones(straight(n), space), 0.0, 1.0);
        }
    }
    // Sobel on each channel, a quarter of the way to 1 for a hard edge
    // from black to white.
    float3 gx = (l[2] + 2.0 * l[5] + l[8]) - (l[0] + 2.0 * l[3] + l[6]);
    float3 gy = (l[6] + 2.0 * l[7] + l[8]) - (l[0] + 2.0 * l[1] + l[2]);
    float3 edge = clamp(sqrt(gx * gx + gy * gy) * 0.25 * strength, 0.0, 1.0);
    float3 t;
    if (style < 0.5) {
        t = 1.0 - edge;
    } else {
        float e = max(edge.r, max(edge.g, edge.b));
        if (style < 1.5) {
            t = float3(1.0 - e);
        } else {
            float low = max(threshold - 0.05, 0.0);
            t = float3(1.0 - smoothstep(low, low + 0.1, e));
        }
    }
    return mixed(original, fromTones(t, space), amount);
}
