// Makes each channel from a mix of all three.
extern "C" [[stitchable]] float4 amvChannelMixer(coreimage::sample_t s, float space, float3 red, float3 green, float3 blue, float3 offset, float amount) {
    float3 t = toTones(straight(s), space);
    float3 m = float3(dot(red, t), dot(green, t), dot(blue, t)) + offset;
    return mixed(s, fromTones(m, space), amount);
}
