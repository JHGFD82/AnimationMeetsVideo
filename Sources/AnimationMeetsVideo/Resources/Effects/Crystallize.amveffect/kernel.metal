// The picture broken into crystals, each the color under its seed point
// (a Voronoi diagram over one point per cell of a grid, moved at random),
// with borders between them; or into dots of those colors on a
// background, as pointillism.

// The picture's average a little around `p`, premultiplied.
inline float4 near(coreimage::sampler src, float2 p, float r) {
    float4 sum = src.sample(src.transform(p)) * 2.0;
    sum += src.sample(src.transform(p + float2(r, 0)));
    sum += src.sample(src.transform(p - float2(r, 0)));
    sum += src.sample(src.transform(p + float2(0, r)));
    sum += src.sample(src.transform(p - float2(0, r)));
    return sum / 6.0;
}

extern "C" [[stitchable]] float4 amvCrystallize(coreimage::sampler src, float space, float style, float size, float jitter,
                                                float dotSize, float border, float4 fill, float seed, float2 origin,
                                                float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    size = max(size, 1.0);
    float2 p = (d - origin) / size;
    float2 cell = floor(p);
    // The nearest seed point and the next nearest, in cells.
    float2 first = float2(0.0), second = float2(0.0);
    float firstDistance = 1e9, secondDistance = 1e9;
    int2 firstCell = int2(0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            int2 c = int2(cell) + int2(i, j);
            int3 id = int3(c, int(seed));
            float2 seedPoint = float2(c) + 0.5 + (float2(rand(id), rand(id, 1)) - 0.5) * jitter;
            float dist = length(seedPoint - p);
            if (dist < firstDistance) {
                second = first; secondDistance = firstDistance;
                first = seedPoint; firstDistance = dist; firstCell = c;
            } else if (dist < secondDistance) {
                second = seedPoint; secondDistance = dist;
            }
        }
    }
    float4 color = near(src, origin + first * size, size * 0.15);
    // The fill is in Rec. 709, as color controls are, taken to the
    // timeline's space.
    float4 background = float4(fromLinear(toLinear(fill.rgb, 0.0), space), 1.0) * fill.a;
    float4 result;
    if (style < 0.5) {
        // How far the pixel is from the line halfway between the two
        // nearest points, in output pixels.
        float2 between = second - first;
        float edge = (secondDistance * secondDistance - firstDistance * firstDistance) / (2.0 * max(length(between), 1e-4)) * size;
        float onBorder = border > 0.0 ? 1.0 - smoothstep(border * 0.5 - 0.5, border * 0.5 + 0.5, edge) : 0.0;
        result = mix(color, background, onBorder);
    } else {
        // Each dot a little bigger or smaller than the next.
        float radius = 0.5 * dotSize * (0.8 + 0.4 * rand(int3(firstCell, int(seed)), 2)) * size;
        float inside = 1.0 - smoothstep(radius - 0.75, radius + 0.75, firstDistance * size);
        result = mix(background, color, inside);
    }
    return mix(original, result, amount);
}
