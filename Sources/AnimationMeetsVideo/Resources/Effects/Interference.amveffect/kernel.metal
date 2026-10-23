// Two line patterns, one turned against the other, beating into moiré.
extern "C" [[stitchable]] float4 amvInterference(coreimage::sample_t s, float space, float scale, float spacing, float angle,
                                                 float drift, float amount, coreimage::destination dest) {
    float2 p = dest.coord() / scale;
    float2 turned = float2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle));
    float a = 0.5 + 0.5 * cos(6.283185307 * p.x / spacing);
    float b = 0.5 + 0.5 * cos(6.283185307 * (turned.x / spacing + drift));
    return generated(s, fromTones(float3(a * b), space), amount);
}
