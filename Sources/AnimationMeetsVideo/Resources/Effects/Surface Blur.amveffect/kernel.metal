// Smooths surfaces and keeps edges: a blur `radius` wide in which a
// neighbor counts less the more its color differs from the pixel's,
// by about `threshold` (a bilateral filter). Smooths skin, noise and
// banding without softening outlines. Drawn in two passes, across and
// then down, at most 32 reads either side.
extern "C" [[stitchable]] float4 amvSurfaceBlur(coreimage::sampler src, float space, float radius, float threshold, float pass,
                                                coreimage::destination dest) {
    float2 d = dest.coord();
    float4 here = src.sample(src.transform(d));
    if (radius < 0.5) return here;
    float2 axis = pass < 0.5 ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float3 color = straight(here);
    float sigma = radius / 2.0;
    float closeness = 0.5 / max(threshold * threshold, 1e-6);
    int taps = int(min(ceil(radius), 32.0));
    float stride = radius / float(taps);
    float4 sum = here;
    float total = 1.0;
    for (int i = 1; i <= taps; i++) {
        float x = float(i) * stride;
        float near = exp(-0.5 * x * x / (sigma * sigma));
        for (int side = -1; side <= 1; side += 2) {
            float4 n = src.sample(src.transform(d + axis * x * float(side)));
            float3 diff = straight(n) - color;
            float w = near * exp(-dot(diff, diff) * closeness);
            sum += w * n;
            total += w;
        }
    }
    return sum / total;
}
