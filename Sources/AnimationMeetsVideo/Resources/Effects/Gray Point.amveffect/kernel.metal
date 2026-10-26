// White balance from a color that should be gray: each channel's light is
// scaled so that color becomes the gray of its own brightness, as a
// camera's white balance does, and every other color by the same. The
// color is in the timeline's values, as a shape's fill is, so pick the
// cast as it looks in the viewer. Gray, the default, changes nothing.
extern "C" [[stitchable]] float4 amvGrayPoint(coreimage::sample_t s, float space, float4 neutral, float amount) {
    float3 n = max(toLinear(neutral.rgb, space), float3(1e-5));
    float3 gain = dot(n, float3(0.2126, 0.7152, 0.0722)) / n;
    float3 l = toLinear(straight(s), space) * gain;
    return mixed(s, fromLinear(l, space), amount);
}
