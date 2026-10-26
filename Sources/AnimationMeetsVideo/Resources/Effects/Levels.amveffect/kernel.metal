// Levels: the tones from Input Black to Input White stretched to the
// whole range, bent by Gamma (above 1 brightens the midtones), then
// fitted between Output Black and Output White. Tones run from black (0)
// to reference white (1) in any color space, so HDR highlights above
// white carry on along the same line instead of being clipped.
extern "C" [[stitchable]] float4 amvLevels(coreimage::sample_t s, float space, float channel,
                                           float inBlack, float inWhite, float gamma,
                                           float outBlack, float outWhite, float amount) {
    float3 t = toTones(straight(s), space);
    float3 x = (t - inBlack) / max(inWhite - inBlack, 0.001);
    float3 bent = select(x, pow(max(x, 0.0), 1.0 / max(gamma, 0.01)), x > 0.0);
    float3 leveled = outBlack + bent * (outWhite - outBlack);
    float3 only = channel < 0.5 ? float3(1.0) : float3(channel < 1.5, channel > 1.5 && channel < 2.5, channel > 2.5);
    return mixed(s, fromTones(mix(t, leveled, only), space), amount);
}
