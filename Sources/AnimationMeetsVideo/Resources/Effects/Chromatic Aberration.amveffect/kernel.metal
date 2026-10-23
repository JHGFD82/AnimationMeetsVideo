// Red and blue pulled apart from green: out from the center, or along
// a direction.
// Radially, the full amount half the frame's width from the center.
extern "C" [[stitchable]] float4 amvChromaticAberration(coreimage::sampler src, float space, float2 center, float halfWidth, float reach,
                                                        float radial, float angle, coreimage::destination dest) {
    float2 d = dest.coord();
    float2 offset = radial > 0.5 ? (d - center) / max(halfWidth, 1.0) * reach : float2(cos(angle), sin(angle)) * reach;
    float4 r = src.sample(src.transform(d + offset));
    float4 g = src.sample(src.transform(d));
    float4 b = src.sample(src.transform(d - offset));
    return float4(r.r, g.g, b.b, max(g.a, max(r.a, b.a)));
}
