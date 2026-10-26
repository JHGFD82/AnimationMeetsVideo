// Moves the edge of the picture's alpha in (Shrink/Grow below 0) or out
// (above 0) by `grow` output pixels, and softens it across `feather`
// pixels centered on where it ends up. With both 0 the picture is left
// as it is.
//
// The alpha is averaged over a disk around each pixel, reaching as far
// as the edge can move. For a straight edge, the share of the disk that
// is opaque says exactly how far the pixel is from the edge (`covered`
// inverted), so the edge can be moved and feathered by that distance.
// Corners round off within the disk, and details thinner than it thin
// out, as with any choker. Color where the edge grows is the average of
// the opaque pixels nearby.

// The share of a unit disk on one side of a straight edge whose center
// is `u` radii inside it.
inline float covered(float u) {
    u = clamp(u, -1.0, 1.0);
    return 1.0 - (acos(u) - u * sqrt(1.0 - u * u)) / 3.14159265;
}

// How many radii inside an edge a disk is whose share `c` is opaque.
inline float insideBy(float c) {
    float low = -1.0, high = 1.0;
    for (int i = 0; i < 16; i++) {
        float middle = 0.5 * (low + high);
        if (covered(middle) < c) low = middle; else high = middle;
    }
    return 0.5 * (low + high);
}

extern "C" [[stitchable]] float4 amvMatteChoker(coreimage::sampler src, float space, float grow, float feather, float amount,
                                                coreimage::destination dest) {
    float2 d = dest.coord();
    float4 s = src.sample(src.transform(d));
    if (abs(grow) < 0.001 && feather < 0.001) return s;
    float radius = abs(grow) + feather * 0.5 + 1.0;

    // A Vogel spiral of samples, spread evenly over the disk.
    const int count = 128;
    float alpha = 0.0;
    float3 color = float3(0.0);
    for (int i = 0; i < count; i++) {
        float r = radius * sqrt((float(i) + 0.5) / float(count));
        float angle = float(i) * 2.39996323;
        float4 n = src.sample(src.transform(d + r * float2(cos(angle), sin(angle))));
        alpha += n.a;
        color += n.rgb;
    }
    float inside = insideBy(alpha / float(count)) * radius;
    float width = max(feather, 1.0);
    float a = smoothstep(0.0, 1.0, 0.5 + (inside + grow) / width);

    // The pixel's own color where it has one, else its neighbors'.
    float3 near = alpha > 0.0 ? color / alpha : float3(0.0);
    float3 straightColor = mix(near, straight(s), clamp(s.a * 4.0, 0.0, 1.0));
    return mix(s, float4(straightColor * a, a), amount);
}
