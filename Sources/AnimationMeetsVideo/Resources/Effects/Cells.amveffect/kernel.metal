// Worley's cells: each cell's point drifts round a circle as it evolves.
extern "C" [[stitchable]] float4 amvCells(coreimage::sample_t s, float space, float scale, float size, float jitter,
                                          float output, float evolution, float seed, float amount, coreimage::destination dest) {
    float2 p = dest.coord() / (scale * size);
    float2 base = floor(p);
    float nearest = 8.0, second = 8.0;
    int3 owner = int3(0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int3 cell = int3(int2(base) + int2(i, j), int(seed));
            float2 home = float2(rand(cell), rand(cell, 1)) - 0.5;
            float turn = 6.283185307 * (evolution + rand(cell, 2));
            float2 point = base + float2(i, j) + 0.5 + jitter * (home * 0.7 + 0.15 * float2(cos(turn), sin(turn)));
            float d = distance(p, point);
            if (d < nearest) { second = nearest; nearest = d; owner = cell; }
            else if (d < second) { second = d; }
        }
    }
    float v = output < 0.5 ? 1.0 - smoothstep(0.0, 0.08, second - nearest)
            : output < 1.5 ? clamp(nearest, 0.0, 1.0)
            : rand(owner, 3);
    return generated(s, fromTones(float3(v), space), amount);
}
