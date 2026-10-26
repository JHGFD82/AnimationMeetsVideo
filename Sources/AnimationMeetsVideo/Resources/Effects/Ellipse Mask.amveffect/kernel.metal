// Keeps the picture inside an ellipse (or outside it, with Keep
// Outside): `size` timeline pixels across, turned by `turn` about
// `center`, its edge softened across `feather` output pixels centered on
// it (one pixel at least). The distance to the edge is estimated from
// the ellipse's gradient, close enough that the feather is even all the
// way round. Amount mixes the mask in.
extern "C" [[stitchable]] float4 amvEllipseMask(coreimage::sample_t s, float space, float2 center, float2 size, float scale,
                                                float feather, float turn, float outside, float amount, coreimage::destination dest) {
    float2 p = turned(dest.coord() - center, -turn);
    float2 radii = max(size * scale * 0.5, float2(0.001));
    float k0 = length(p / radii);
    float k1 = length(p / (radii * radii));
    float apart = k1 > 0.0 ? k0 * (k0 - 1.0) / k1 : -min(radii.x, radii.y);
    float m = smoothstep(0.0, 1.0, 0.5 - apart / max(feather, 1.0));
    if (outside > 0.5) m = 1.0 - m;
    return s * mix(1.0, m, amount);
}
