// Copies of the picture from earlier moments screened over it: copy `k`,
// `k` delays back, scaled and turned about the center `k` times, its hue
// shifted `k` times and faded `k` times. One copy each pass, the furthest
// back first.
extern "C" [[stitchable]] float4 amvFeedback(coreimage::sampler src, float space, coreimage::sampler copy, float k, float2 center,
                                             float grow, float turn, float hue, float keep, coreimage::destination dest) {
    float2 p = dest.coord();
    // Where the copy's point comes from: the move undone, `k` times.
    float2 v = p - center;
    float a = turn * k;
    float2 from = center + float2(v.x * cos(a) - v.y * sin(a), v.x * sin(a) + v.y * cos(a)) / pow(grow, k);
    float4 c = copy.sample(copy.transform(from));
    if (hue != 0.0) {
        float3 turned = hueRotated(toTones(straight(c), space), 6.283185307 * fract(hue * k));
        c = float4(fromTones(turned, space) * c.a, c.a);
    }
    // Its color held to 0...1 as it fades, as Core Image's color matrix
    // did: a turned hue can carry a channel past white.
    c = float4(clamp(straight(c), 0.0, 1.0) * c.a, c.a) * pow(keep, k);
    float4 d = src.sample(src.transform(p));
    return c + d - c * d;
}
