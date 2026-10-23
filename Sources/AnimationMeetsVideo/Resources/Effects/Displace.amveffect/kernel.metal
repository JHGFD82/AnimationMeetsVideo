// Moves each point of a picture by a map's red (across) and green (down),
// from middle gray or from black: the picture reaching it by its input,
// or with Against set, the picture before that step by the one reaching
// it.
extern "C" [[stitchable]] float4 amvDisplace(coreimage::sampler src, float space, coreimage::sampler input, coreimage::sampler earlier,
                                             float hasAgainst, float reach, float fromGray, coreimage::destination dest) {
    float2 d = dest.coord();
    bool against = hasAgainst > 0.5;
    float4 m = against ? src.sample(src.transform(d)) : input.sample(input.transform(d));
    float2 v = m.a > 0.0 ? m.rg / m.a : float2(fromGray > 0.5 ? 0.5 : 0.0);
    float2 offset = fromGray > 0.5 ? (v - 0.5) * 2.0 : v;
    float2 at = d + float2(offset.x, -offset.y) * reach;
    return against ? earlier.sample(earlier.transform(at)) : src.sample(src.transform(at));
}
