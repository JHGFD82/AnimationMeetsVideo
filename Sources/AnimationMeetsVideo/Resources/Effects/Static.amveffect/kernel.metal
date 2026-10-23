// Television snow, with dark bars rolling up through it.
extern "C" [[stitchable]] float4 amvStatic(coreimage::sample_t s, float space, float scale, float size, float bars, float roll,
                                           float seed, float frame, float height, float amount, coreimage::destination dest) {
    float2 p = dest.coord() / scale;
    float v = rand(int3(int2(floor(p / size)), int(frame) * 31 + int(seed)));
    float band = 0.5 + 0.5 * cos(6.283185307 * (p.y / height * bars + roll));
    v *= 1.0 - 0.6 * smoothstep(0.55, 1.0, band);
    return generated(s, fromTones(float3(v), space), amount);
}
