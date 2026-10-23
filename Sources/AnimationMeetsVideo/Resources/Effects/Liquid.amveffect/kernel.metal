// Each point taken from along a noise field evolving through time,
// warped `warps` times through itself.
extern "C" [[stitchable]] float2 amvLiquid(float scale, float size, float reach, float warps, float evolution, float seed,
                                           coreimage::destination dest) {
    float2 d = dest.coord();
    float2 p = d / (scale * size);
    float2 q = float2(0.0);
    for (int i = 0; i < int(warps); i++) {
        float2 at = p + 4.0 * q;
        q = float2(noise3(float3(at, evolution), int(seed) + i * 2), noise3(float3(at + 5.2, evolution), int(seed) + i * 2 + 1));
    }
    return d + q * reach;
}
