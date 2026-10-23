// Colors each pixel by its brightness from a gradient of three colors, repeated and scrolled.
extern "C" [[stitchable]] float4 amvGradientMap(coreimage::sample_t s, float space, float4 low, float4 middle, float4 high,
                                 float repeats, float shift, float amount) {
    float y = luma(toTones(straight(s), space));
    float u = triangle(clamp(y, 0.0, 1.0) * repeats + shift);
    float4 color = u < 0.5 ? mix(low, middle, u * 2.0) : mix(middle, high, u * 2.0 - 1.0);
    float4 result = mixed(s, color.rgb, amount);
    return result * mix(1.0, color.a, amount);
}
