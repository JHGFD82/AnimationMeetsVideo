// Fractal gradient noise, gray, evolving through its third dimension.
extern "C" [[stitchable]] float4 amvFractalNoise(coreimage::sample_t s, float space, float scale, float size, float octaves,
                                                 float roughness, float type, float evolution, float seed, float amount,
                                                 coreimage::destination dest) {
    float3 p = float3(dest.coord() / (scale * size), evolution);
    float sum = 0.0, weight = 1.0, weights = 0.0;
    for (int i = 0; i < int(octaves); i++) {
        float n = noise3(p, int(seed) + i * 13);
        if (type > 1.5) { n = 1.0 - abs(n); n *= n; }
        else if (type > 0.5) { n = abs(n); }
        else { n = 0.5 + 0.5 * n; }
        sum += n * weight;
        weights += weight;
        weight *= roughness;
        p = p * 2.0 + 17.13;
    }
    return generated(s, fromTones(float3(clamp(sum / weights, 0.0, 1.0)), space), amount);
}
