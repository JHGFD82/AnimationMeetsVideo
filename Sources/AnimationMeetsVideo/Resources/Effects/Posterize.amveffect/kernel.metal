// Few tones per channel, as in a poster: each channel's tone rounded to
// one of `levels` steps from black to white.
extern "C" [[stitchable]] float4 amvPosterize(coreimage::sample_t s, float space, float levels, float amount) {
    float3 t = toTones(straight(s), space);
    float steps = max(levels - 1.0, 1.0);
    return mixed(s, fromTones(round(clamp(t, 0.0, 1.0) * steps) / steps, space), amount);
}
