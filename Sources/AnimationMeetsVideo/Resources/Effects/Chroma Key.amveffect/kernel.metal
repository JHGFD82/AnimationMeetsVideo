// Keys out a color: each pixel's chroma (its color less its brightness)
// is compared with the key color's, so the screen in shadow keys out as
// well as in light. Within `tolerance` of the key color's chroma (as a
// share of how strong that chroma is) it is clear, past `tolerance +
// softness` opaque, and partly clear between. Spill, the key color
// reflected onto what is kept, is taken out of the chroma with the
// brightness unchanged. View Matte shows the alpha alone, as Alpha
// Tools' Show Alpha does.

// Brightness and chroma of tones, on the weights `luma` uses, and back.
inline float3 lumaChroma(float3 t) {
    float y = luma(t);
    return float3(y, (t.b - y) / 1.8556, (t.r - y) / 1.5748);
}
inline float3 fromLumaChroma(float3 c) {
    float r = c.x + 1.5748 * c.z, b = c.x + 1.8556 * c.y;
    return float3(r, (c.x - 0.2126 * r - 0.0722 * b) / 0.7152, b);
}

extern "C" [[stitchable]] float4 amvChromaKey(coreimage::sample_t s, float space, float4 keyColor, float tolerance, float softness,
                                              float spill, float view, float amount) {
    float2 k = lumaChroma(toTones(keyColor.rgb, 0.0)).yz;
    float3 c = lumaChroma(toTones(straight(s), space));
    float strength = max(length(k), 0.02);
    float apart = length(c.yz - k) / strength;
    float keep = softness > 0.0 ? smoothstep(tolerance, tolerance + softness, apart) : float(apart > tolerance);
    float alpha = mix(1.0, keep, amount);

    // The chroma toward the key color taken out, `spill` of it.
    float2 along = k / strength;
    float toward = max(dot(c.yz, along), 0.0);
    float3 kept = fromLumaChroma(float3(c.x, c.yz - along * toward * spill * amount));

    float a = s.a * alpha;
    if (view > 0.5) return float4(fromLinear(toLinear(float3(a), 0.0), space), 1.0);
    return float4(fromTones(kept, space) * a, a);
}
