// A negative: each tone turned end for end, black for reference white, in
// every channel or one of them; or only the brightness, which keeps each
// color's hue while light and dark swap. Inverting twice gives the picture
// back.
extern "C" [[stitchable]] float4 amvInvert(coreimage::sample_t s, float space, float channels, float amount) {
    float3 t = toTones(straight(s), space);
    float3 inverted;
    if (channels > 3.5) {
        inverted = t + (1.0 - 2.0 * luma(t));
    } else {
        float3 only = channels < 0.5 ? float3(1.0) : float3(channels < 1.5, channels > 1.5 && channels < 2.5, channels > 2.5);
        inverted = mix(t, 1.0 - t, only);
    }
    return mixed(s, fromTones(inverted, space), amount);
}
