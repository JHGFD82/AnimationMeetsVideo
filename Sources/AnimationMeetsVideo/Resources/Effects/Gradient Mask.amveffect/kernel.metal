// Fades the picture out from Start to End: opaque at and before Start,
// clear at and past End, evenly between. Linear fades along the line
// from Start to End; Radial fades out from Start as a circle reaching
// End. Keep End turns it around, so the picture fades in instead.
// Animating End across the frame makes a soft wipe. Amount mixes the
// mask in.
extern "C" [[stitchable]] float4 amvGradientMask(coreimage::sample_t s, float space, float radial, float2 start, float2 end,
                                                 float keepEnd, float amount, coreimage::destination dest) {
    float2 p = dest.coord() - start;
    float2 line = end - start;
    float span = max(dot(line, line), 0.000001);
    float t = radial > 0.5 ? length(p) / sqrt(span) : dot(p, line) / span;
    float m = 1.0 - clamp(t, 0.0, 1.0);
    if (keepEnd > 0.5) m = 1.0 - m;
    return s * mix(1.0, m, amount);
}
