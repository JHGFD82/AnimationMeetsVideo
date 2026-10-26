// A lens flare from a light at `source`: a bright core with a soft halo,
// a thin rainbow ring, a horizontal streak as an anamorphic lens draws,
// and reflections of the lens's elements strung along the line from the
// source through the frame's middle. `size` is the core's, in output
// pixels; the rest scale with it. Added over the picture in linear
// light, so in an HDR timeline the core is brighter than white.

constant int ghostCount = 7;
// Where each reflection sits along the line from the source (0) through
// the frame's middle (1) and past it, how big it is beside the core,
// how bright, and its hue.
constant float ghostAt[ghostCount] = {0.35, 0.62, 0.9, 1.3, 1.55, 1.8, 2.25};
constant float ghostSize[ghostCount] = {0.45, 0.2, 0.9, 0.35, 1.6, 0.25, 0.7};
constant float ghostLight[ghostCount] = {0.10, 0.18, 0.05, 0.12, 0.04, 0.16, 0.07};
constant float ghostHue[ghostCount] = {0.08, 0.55, 0.3, 0.75, 0.12, 0.45, 0.95};

// `light` (linear, premultiplied) added over `o`. Where `o` is clear the
// light makes its own cover.
inline float4 lightOver(float4 o, float3 light, float space) {
    light = max(light, 0.0);
    float a = o.a + (1.0 - o.a) * clamp(max(light.r, max(light.g, light.b)), 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float3 sum = toLinear(straight(o), space) * o.a + light;
    return float4(fromLinear(sum / a, space) * a, a);
}

extern "C" [[stitchable]] float4 amvLensFlare(coreimage::sample_t s, float space, float2 source, float2 middle, float size,
                                              float brightness, float4 color, float streak, float ghosts, float amount,
                                              coreimage::destination dest) {
    if (amount <= 0.0) return s;
    float2 d = dest.coord();
    float u = max(size, 1.0);
    float2 q = (d - source) / u;
    float r = length(q);
    float3 tint = max(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), 0.0);

    // The core, and a halo falling off as light scattered in the glass.
    float3 light = tint * (2.5 * exp(-r * r * 10.0) + 0.12 / (1.0 + r * r * 1.5));
    // Faint spokes from the aperture's blades, six of them.
    float spokes = pow(abs(cos(atan2(q.y, q.x) * 3.0)), 80.0) * exp(-r * 1.6) * 0.3;
    light += tint * spokes;
    // A thin ring, red outside and blue inside, as a rainbow.
    float ring = exp(-pow((r - 3.2) / 0.12, 2.0)) * 0.06;
    light += hsv(clamp((r - 3.0) * 1.6, 0.0, 0.75), 0.8, 1.0) * ring;
    // The streak, bluish, across the frame through the source.
    float across = exp(-abs(q.y) * 30.0) * exp(-abs(q.x) / max(streak * 8.0, 0.001));
    light += float3(0.55, 0.75, 1.0) * across * streak * 0.8;

    // Reflections: soft discs, brighter at their rims, along the line
    // through the frame's middle.
    float2 axis = middle - source;
    for (int i = 0; i < ghostCount; i++) {
        float2 at = source + axis * ghostAt[i];
        float g = length(d - at) / (u * ghostSize[i]);
        float disc = (1.0 - smoothstep(0.85, 1.0, g)) * (0.5 + 0.5 * smoothstep(0.3, 0.95, g));
        light += hsv(ghostHue[i], 0.55, 1.0) * mix(float3(1.0), tint, 0.5) * disc * ghostLight[i] * ghosts;
    }
    return lightOver(s, light * brightness * amount, space);
}
