// Keeps the picture inside the four-sided shape through four corners (or
// outside it, with Keep Outside), as a garbage matte cuts away rigs and
// the edges of a screen before a key. The corners can be dragged into
// any shape; one that crosses itself keeps the two triangles it makes. Its
// edge is softened across `feather` output pixels centered on it (one
// pixel at least). Amount mixes the mask in.
extern "C" [[stitchable]] float4 amvFourPointMask(coreimage::sample_t s, float space, float2 a, float2 b, float2 c, float2 e,
                                                  float feather, float outside, float amount, coreimage::destination dest) {
    float2 p = dest.coord();
    float2 corners[4] = {a, b, c, e};
    // The distance to the nearest edge, negative inside: p is inside when
    // a ray from it crosses the edges an odd number of times (as Inigo
    // Quilez's polygon distance finds it).
    float nearest = dot(p - a, p - a);
    float side = 1.0;
    for (int i = 0, j = 3; i < 4; j = i, i++) {
        float2 edge = corners[j] - corners[i];
        float2 w = p - corners[i];
        float2 onSide = w - edge * clamp(dot(w, edge) / max(dot(edge, edge), 0.000001), 0.0, 1.0);
        nearest = min(nearest, dot(onSide, onSide));
        bool3 crosses = bool3(p.y >= corners[i].y, p.y < corners[j].y, edge.x * w.y > edge.y * w.x);
        if (all(crosses) || all(!crosses)) side = -side;
    }
    float apart = side * sqrt(nearest);
    float m = smoothstep(0.0, 1.0, 0.5 - apart / max(feather, 1.0));
    if (outside > 0.5) m = 1.0 - m;
    return s * mix(1.0, m, amount);
}
