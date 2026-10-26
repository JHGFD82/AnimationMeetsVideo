// Takes a key color's spill out of the picture: the part of each pixel's
// chroma toward the spill color is removed with the brightness unchanged,
// so a green cast on hair and edges goes gray, as Chroma Key's Spill
// Suppression does. Range says which colors count: at 100% every one
// leaning toward the spill color, below that only those whose hue is
// closer to it.
inline float3 lumaChroma(float3 t) {
    float y = luma(t);
    return float3(y, (t.b - y) / 1.8556, (t.r - y) / 1.5748);
}
inline float3 fromLumaChroma(float3 c) {
    float r = c.x + 1.5748 * c.z, b = c.x + 1.8556 * c.y;
    return float3(r, (c.x - 0.2126 * r - 0.0722 * b) / 0.7152, b);
}

extern "C" [[stitchable]] float4 amvSpillSuppressor(coreimage::sample_t s, float space, float4 spillColor, float range, float amount) {
    float2 k = lumaChroma(toTones(spillColor.rgb, 0.0)).yz;
    float3 c = lumaChroma(toTones(straight(s), space));
    float2 along = k / max(length(k), 0.0001);
    float toward = max(dot(c.yz, along), 0.0);
    // How nearly the pixel's hue is the spill color's: 1 on it, 0 at
    // right angles to it.
    float lean = toward / max(length(c.yz), 0.0001);
    float weight = range >= 1.0 ? 1.0 : smoothstep(1.0 - range, 1.0 - range * 0.5, lean);
    float3 kept = fromLumaChroma(float3(c.x, c.yz - along * toward * weight));
    return mixed(s, fromTones(kept, space), amount);
}
