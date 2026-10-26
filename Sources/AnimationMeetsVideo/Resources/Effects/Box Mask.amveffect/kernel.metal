// Keeps the picture inside a rectangle (or outside it, with Keep
// Outside): `size` timeline pixels across, turned by `turn` about
// `center`, its corners rounded by `roundness`, its edge softened across
// `feather` output pixels centered on it (one pixel at least, so it is
// smooth). Amount mixes the mask in.
extern "C" [[stitchable]] float4 amvRectangleMask(coreimage::sample_t s, float space, float2 center, float2 size, float scale,
                                                  float roundness, float feather, float turn, float outside, float amount,
                                                  coreimage::destination dest) {
    float2 p = turned(dest.coord() - center, -turn);
    float2 halfSize = max(size * scale * 0.5, float2(0.0));
    float r = clamp(roundness, 0.0, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    float apart = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float m = smoothstep(0.0, 1.0, 0.5 - apart / max(feather, 1.0));
    if (outside > 0.5) m = 1.0 - m;
    return s * mix(1.0, m, amount);
}
