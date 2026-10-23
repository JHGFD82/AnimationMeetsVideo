// Folds tones above a threshold back down, as overexposed film does.
extern "C" [[stitchable]] float4 amvSolarize(coreimage::sample_t s, float space, float threshold, float folds, float eachChannel, float amount) {
    float3 t = toTones(straight(s), space);
    float3 folded;
    if (eachChannel > 0.5) {
        folded = select(threshold * float3(triangle(1.0 + (t.r - threshold) / threshold * folds),
                                           triangle(1.0 + (t.g - threshold) / threshold * folds),
                                           triangle(1.0 + (t.b - threshold) / threshold * folds)), t, t <= threshold);
    } else {
        float y = luma(t);
        float to = y <= threshold ? y : threshold * triangle(1.0 + (y - threshold) / threshold * folds);
        folded = t + (to - y);
    }
    return mixed(s, fromTones(folded, space), amount);
}
