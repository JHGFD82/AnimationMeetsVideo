// A pool of light: an ellipse `size` timeline pixels across at
// `center`, turned by `angle` (clockwise on screen), lit `brightness`
// in `color`, and everything outside it lit only `ambient`. Its edge
// softens over `feather` of its radius. Light multiplies the picture in
// linear light, as a light on the scene would.
extern "C" [[stitchable]] float4 amvSpotlight(coreimage::sample_t s, float space, float2 center, float2 size, float scale,
                                              float angle, float feather, float brightness, float ambient, float4 color,
                                              float amount, coreimage::destination dest) {
    if (amount <= 0.0) return s;
    float2 radii = max(size * scale / 2.0, 0.5);
    float distance = length(turned(dest.coord() - center, angle) / radii);
    float inside = 1.0 - smoothstep(1.0 - clamp(feather, 0.0, 1.0), 1.0001, distance);
    float3 light = mix(float3(ambient), brightness * max(toLinear(clamp(color.rgb, 0.0, 1.0), 0.0), 0.0), inside);
    float3 l = toLinear(straight(s), space);
    return float4(fromLinear(l * mix(float3(1.0), light, amount), space) * s.a, s.a);
}
