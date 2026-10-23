// Folds every direction round the center into one wedge, mirrored at
// its edges.
extern "C" [[stitchable]] float2 amvKaleidoscope(float2 center, float segments, float angle, coreimage::destination dest) {
    float2 v = dest.coord() - center;
    float wedge = 6.283185307 / segments;
    float a = atan2(v.y, v.x) - angle;
    a -= floor(a / wedge) * wedge;
    if (a > wedge * 0.5) a = wedge - a;
    return center + length(v) * float2(cos(a + angle), sin(a + angle));
}
