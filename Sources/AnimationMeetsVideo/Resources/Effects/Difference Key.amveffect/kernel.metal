// Keys out what matches a clean plate: a picture of the same shot
// without the subject, dropped onto the effect as its input. Where the
// picture's tones are within `tolerance` of the plate's (their distance
// apart, black to white being 1) it is clear, from `tolerance +
// softness` opaque. Where the plate has nothing the picture is kept.
// View Matte shows the alpha alone, as Alpha Tools' Show Alpha does.
extern "C" [[stitchable]] float4 amvDifferenceKey(coreimage::sampler src, float space, coreimage::sampler plate, float tolerance,
                                                  float softness, float view, float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 s = src.sample(src.transform(d));
    float4 p = plate.sample(plate.transform(d));
    float apart = length(toTones(straight(s), space) - toTones(straight(p), space));
    float keep = softness > 0.0 ? smoothstep(tolerance, tolerance + softness, apart) : float(apart > tolerance);
    float alpha = mix(1.0, mix(1.0, keep, p.a), amount);
    if (view > 0.5) return float4(fromLinear(toLinear(float3(s.a * alpha), 0.0), space), 1.0);
    return s * alpha;
}
