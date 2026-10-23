// Blocks of the picture jump sideways and lose a channel, a new set
// each tick.
extern "C" [[stitchable]] float4 amvBlockGlitch(coreimage::sampler src, float space, float scale, float size, float intensity, float seed,
                                                float tick, float reach, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    float2 block = float2(size * 2.0, size * 0.5) * scale;
    int3 id = int3(int2(floor(d / block)), int(tick) * 131 + int(seed));
    if (rand(id) >= intensity) return original;
    float2 offset = float2((rand(id, 1) - 0.5) * 2.0 * reach, 0.0);
    float split = 3.0 * scale;
    float4 r = src.sample(src.transform(d + offset + float2(split, 0.0)));
    float4 g = src.sample(src.transform(d + offset));
    float4 b = src.sample(src.transform(d + offset - float2(split, 0.0)));
    float4 glitched = float4(r.r, g.g, b.b, g.a);
    int drop = int(rand(id, 2) * 4.0);
    if (drop == 1) glitched.r = 0.0;
    else if (drop == 2) glitched.g = 0.0;
    else if (drop == 3) glitched.b = 0.0;
    return mix(original, glitched, amount);
}
