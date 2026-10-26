// An old film print projected: toned black and white (sepia by
// default), faded, its brightness flickering from frame to frame, the
// frame weaving in the gate and darker toward the corners. Pairs with
// Film Damage and Grain.

extern "C" [[stitchable]] float4 amvOldFilm(coreimage::sampler src, float space, float4 toneColor, float keepColor, float fade,
                                            float flicker, float weave, float vignette, float seed, float frame, float seconds,
                                            float2 origin, float width, float height, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    int sd = int(seed);
    int tick = int(frame);
    // The gate weave: a slow, uneven wander, more up and down than across.
    float2 wander = float2(noise3(float3(seconds * 3.0, 0.5, 0.0), sd) * 0.4, noise3(float3(seconds * 3.0, 4.5, 0.0), sd));
    wander += (float2(rand(int3(tick, sd, 1)), rand(int3(tick, sd, 2))) - 0.5) * float2(0.2, 0.4);
    float4 moved = src.sample(src.transform(d - wander * weave));

    float3 t = toTones(straight(moved), space);
    float y = luma(t);
    // Toned: the gray multiplied by the tone, in linear light, with some
    // of the picture's own color kept.
    float3 light = toLinear(fromTones(float3(y), space), space) * toLinear(toneColor.rgb, 0.0);
    float3 toned = toTones(fromLinear(light, space), space);
    t = mix(toned, t, keepColor);
    // Faded: blacks lifted, whites lowered, as an old print's dyes.
    t = mix(t, 0.12 + t * 0.78, fade);
    // Flicker: each frame a little brighter or darker than the last.
    t += (rand(int3(tick, sd, 3)) - 0.5) * 0.3 * flicker;
    // Vignette, round on the frame's width and height.
    float2 v = (d - origin) / (0.5 * float2(max(width, 1.0), max(height, 1.0)));
    t *= 1.0 - vignette * 0.6 * smoothstep(0.35, 1.45, length(v));
    float4 projected = float4(fromTones(t, space) * moved.a, moved.a);
    return mix(original, projected, amount);
}
