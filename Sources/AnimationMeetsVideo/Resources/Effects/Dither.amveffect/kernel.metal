// Few colors with an ordered or noise dither, as early computer graphics.
extern "C" [[stitchable]] float4 amvDither(coreimage::sample_t s, float space, float levels, float pattern, float frame,
                                           float amount, coreimage::destination dest) {
    uint2 p = uint2(int2(floor(dest.coord())) & 0xFFFF);
    float threshold = pattern < 0.5 ? bayer(p, 2u) : pattern < 1.5 ? bayer(p, 3u) : rand(int3(int2(p), int(frame)));
    float steps = max(levels - 1.0, 1.0);
    float3 t = clamp(toTones(straight(s), space), 0.0, 1.0);
    return mixed(s, fromTones(floor(t * steps + threshold) / steps, space), amount);
}
