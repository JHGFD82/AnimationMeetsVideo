// The picture as a relief lit from `angle`: its brightness is the
// height, so slopes facing the light are lit and those facing away are
// shaded, over middle gray or the picture's own colors. A flat picture
// stays flat.

inline float height(coreimage::sampler src, float2 p, float space) {
    return luma(toTones(straight(src.sample(src.transform(p))), space));
}

extern "C" [[stitchable]] float4 amvEmboss(coreimage::sampler src, float space, float angle, float strength, float width,
                                           float keepColor, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    float2 toLight = float2(cos(angle), sin(angle)) * width;
    float2 across = float2(-toLight.y, toLight.x) * 0.5;
    // Higher away from the light than toward it faces the light. Three
    // taps either side, a little across, keep thin lines from aliasing.
    float away = height(src, d - toLight, space) * 2.0 + height(src, d - toLight + across, space) + height(src, d - toLight - across, space);
    float toward = height(src, d + toLight, space) * 2.0 + height(src, d + toLight + across, space) + height(src, d + toLight - across, space);
    float slope = (away - toward) / 4.0 * strength;
    float3 t;
    if (keepColor > 0.5) {
        t = toTones(straight(original), space) + slope;
    } else {
        t = float3(0.5 + slope);
    }
    return mixed(original, fromTones(t, space), amount);
}
