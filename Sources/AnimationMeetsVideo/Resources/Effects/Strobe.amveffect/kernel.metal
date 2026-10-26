// Flashes `rate` times a second, each flash `duty` of its cycle: a
// color over the picture, the picture hidden, or its tones inverted. At
// rate 0 it never flashes.

extern "C" [[stitchable]] float4 amvStrobe(coreimage::sample_t s, float space, float phase, float on, float duty, float mode,
                                           float4 color, float amount) {
    if (on < 0.5 || phase >= duty) return s;
    if (mode < 0.5) {
        // The color, in Rec. 709 as color controls are, over the picture.
        float3 c = fromLinear(toLinear(color.rgb, 0.0), space);
        float a = color.a * amount;
        return float4(c * a, a) + s * (1.0 - a);
    }
    if (mode < 1.5) return s * (1.0 - amount);
    float3 t = toTones(straight(s), space);
    return mixed(s, fromTones(1.0 - t, space), amount);
}
