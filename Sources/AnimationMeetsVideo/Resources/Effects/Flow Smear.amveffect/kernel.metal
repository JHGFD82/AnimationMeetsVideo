// The picture smeared back along its motion to a frame ahead: each point
// of the frame taken from `amount` times its motion away, the frame's
// edges going on past it, laid over the picture. Past the frame the
// picture is as it was.
extern "C" [[stitchable]] float4 amvFlowSmear(coreimage::sampler src, float space, coreimage::sampler motion, float amount,
                                              float2 middle, float width, float height, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 picture = src.sample(src.transform(d));
    // The frame, out to whole pixels.
    float2 lo = floor(middle - float2(width, height) / 2.0), hi = ceil(middle + float2(width, height) / 2.0);
    if (any(d < lo) || any(d >= hi)) return picture;
    float2 from = clamp(d + amount * motion.sample(motion.transform(d)).xy, lo + 0.5, hi - 0.5);
    float4 smeared = src.sample(src.transform(from));
    return smeared + picture * (1.0 - smeared.a);
}
