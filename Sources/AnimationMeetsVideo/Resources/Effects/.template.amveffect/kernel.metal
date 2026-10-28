// Each pixel's tones multiplied by a color, `strength` of the way: a
// starting point. See docs/effect-packages.md for what a package can
// say, and the looks that ship for kernels of every kind.
extern "C" [[stitchable]] float4 __FUNCTION__(coreimage::sample_t s, float space, float4 tint, float strength, float amount) {
    float3 t = toTones(straight(s), space);
    float3 tinted = t * mix(float3(1.0), tint.rgb, strength);
    return mixed(s, fromTones(tinted, space), amount);
}
