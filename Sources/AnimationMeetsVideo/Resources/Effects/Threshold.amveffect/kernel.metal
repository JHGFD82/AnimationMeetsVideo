// Black below Level and reference white above it, by brightness or each
// channel on its own; Softness ramps between them across that much of the
// tones, centered on Level.
inline float3 cut(float3 v, float level, float softness) {
    if (softness <= 0.0001) return select(float3(0.0), float3(1.0), v >= level);
    return smoothstep(level - softness * 0.5, level + softness * 0.5, v);
}

extern "C" [[stitchable]] float4 amvThreshold(coreimage::sample_t s, float space, float level, float softness,
                                              float eachChannel, float amount) {
    float3 t = toTones(straight(s), space);
    float3 v = eachChannel > 0.5 ? t : float3(luma(t));
    return mixed(s, fromTones(cut(v, level, softness), space), amount);
}
