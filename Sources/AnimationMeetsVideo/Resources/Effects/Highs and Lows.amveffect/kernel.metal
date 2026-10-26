// Lifts or deepens the shadows and brightens or recovers the highlights,
// leaving the other tones be: a smooth bump over the darkest Shadow Range
// of the tones (and the brightest Highlight Range below reference white),
// zero at black, at white and past its range's end, and gentle enough
// that the tones keep their order. It moves each pixel by its brightness
// and all its channels together, which on the tones' log curve keeps its
// color as it is. Per pixel, so it doesn't adapt to the picture around
// each pixel as a local tone mapper would.
inline float bump(float u, float range) {
    if (u <= 0.0 || u >= range) return 0.0;
    float v = 1.0 - u / range;
    return u * v * v;
}

extern "C" [[stitchable]] float4 amvShadowsHighlights(coreimage::sample_t s, float space, float shadows, float highlights,
                                                      float shadowRange, float highlightRange, float amount) {
    float3 t = toTones(straight(s), space);
    float y = luma(t);
    // Lifting shadows and recovering highlights may go further than the
    // other way and still keep the tones in order.
    float d = shadows * (shadows > 0.0 ? 1.5 : 1.0) * bump(y, shadowRange)
            + highlights * (highlights > 0.0 ? 1.0 : 1.5) * bump(1.0 - y, highlightRange);
    return mixed(s, fromTones(t + d, space), amount);
}
