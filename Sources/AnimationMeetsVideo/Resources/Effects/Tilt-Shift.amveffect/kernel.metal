// How blurred a pixel is, 0 to 1: sharp within `focus` of the center
// (either side of a line through it at `angle`, or around it), easing to
// full blur over `transition` beyond.
inline float defocus(float2 d, float2 center, float angle, float focus, float transition, float shape) {
    float2 v = d - center;
    float distance = shape < 0.5 ? abs(dot(v, float2(-sin(angle), cos(angle)))) : length(v);
    return smoothstep(0.0, 1.0, clamp((distance - focus) / max(transition, 0.001), 0.0, 1.0));
}

// A Gaussian blur that grows away from a band or circle in focus, as a
// tilted lens draws a miniature. Drawn in two passes, across and then
// down, each pixel's blur as wide as where it is says; at most 32 reads
// either side, spaced wider for a wide blur.
extern "C" [[stitchable]] float4 amvTiltShift(coreimage::sampler src, float space, float2 center, float angle, float focus,
                                              float transition, float radius, float shape, float pass, coreimage::destination dest) {
    float2 d = dest.coord();
    float sigma = radius * defocus(d, center, angle, focus, transition, shape);
    float4 here = src.sample(src.transform(d));
    if (sigma < 0.3) return here;
    float2 axis = pass < 0.5 ? float2(1.0, 0.0) : float2(0.0, 1.0);
    int taps = int(min(ceil(3.0 * sigma), 32.0));
    float stride = 3.0 * sigma / float(taps);
    float4 sum = here;
    float total = 1.0;
    for (int i = 1; i <= taps; i++) {
        float x = float(i) * stride;
        float w = exp(-0.5 * x * x / (sigma * sigma));
        sum += w * (src.sample(src.transform(d + axis * x)) + src.sample(src.transform(d - axis * x)));
        total += 2.0 * w;
    }
    return sum / total;
}
