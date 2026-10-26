// The frame's edges fading to `color`, as a lens darkens its corners.
// Distance is measured from `center` in halves of the frame: at
// roundness 0 a rounded rectangle the frame's shape, at 50% an ellipse
// the frame's shape, at 100% a circle. Inside `size` the picture is as
// it was; over `feather` beyond it, it fades to `color`. The fade is in
// linear light, so a black vignette darkens as an exposure would.
extern "C" [[stitchable]] float4 amvVignette(coreimage::sample_t s, float space, float2 center, float halfWidth, float halfHeight,
                                             float size, float roundness, float feather, float4 color, float amount,
                                             coreimage::destination dest) {
    if (amount <= 0.0) return s;
    float2 halfFrame = max(float2(halfWidth, halfHeight), 1.0);
    float circle = sqrt((halfFrame.x * halfFrame.x + halfFrame.y * halfFrame.y) / 2.0);
    float n = mix(5.0, 2.0, clamp(roundness * 2.0, 0.0, 1.0));
    float2 axes = mix(halfFrame, float2(circle), clamp(roundness * 2.0 - 1.0, 0.0, 1.0));
    float2 u = abs(dest.coord() - center) / axes;
    float distance = pow(pow(u.x, n) + pow(u.y, n), 1.0 / n);
    float fade = smoothstep(size, size + max(feather, 0.001), distance) * amount;
    float3 l = toLinear(straight(s), space);
    float3 edge = toLinear(clamp(color.rgb, 0.0, 1.0), 0.0);
    return float4(fromLinear(mix(l, edge, fade), space) * s.a, s.a);
}
