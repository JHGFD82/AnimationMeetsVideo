// Turns every hue around the color wheel, by brightness, as time goes on.
extern "C" [[stitchable]] float4 amvHueCycle(coreimage::sample_t s, float space, float turn, float spread, float boost, float amount) {
    float3 t = toTones(straight(s), space);
    float y = luma(t);
    float3 turned = hueRotated(t, 6.283185307 * turn + spread * y);
    turned = y + (turned - y) * (1.0 + boost);
    return mixed(s, fromTones(turned, space), amount);
}
