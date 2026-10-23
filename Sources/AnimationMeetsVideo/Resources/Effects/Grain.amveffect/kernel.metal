// Film grain, strongest in the midtones, `size` timeline pixels a grain.
extern "C" [[stitchable]] float4 amvGrain(coreimage::sample_t s, float space, float scale, float size, float color,
                                          float seed, float frame, float amount, coreimage::destination dest) {
    int3 cell = int3(int2(floor(dest.coord() / (size * scale))), int(frame) * 31 + int(seed));
    float3 n = float3(rand(cell) + rand(cell, 3), rand(cell, 1) + rand(cell, 4), rand(cell, 2) + rand(cell, 5)) - 1.0;
    if (color < 0.5) n = float3(n.x);
    float3 t = toTones(straight(s), space);
    float y = clamp(luma(t), 0.0, 1.0);
    t += n * 0.25 * amount * (0.25 + 3.0 * y * (1.0 - y));
    return float4(fromTones(t, space) * s.a, s.a);
}
