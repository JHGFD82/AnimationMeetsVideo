// The picture printed as a halftone screen: dots or lines of ink on
// paper, each cell's ink covering as much of it as the picture under it
// is dark. One ink, or the four of process printing, each on its own
// screen angle.

// The picture's average around a cell's middle, 0...1, on a 2.2 gamma
// curve: ink measured in linear light would leave the midtones nearly
// black, as a print does before its dot gain is corrected.
inline float3 cellLight(coreimage::sampler src, float2 middle, float size, float space) {
    float q = size * 0.25;
    float4 sum = src.sample(src.transform(middle));
    sum += src.sample(src.transform(middle + float2(q, q)));
    sum += src.sample(src.transform(middle + float2(-q, q)));
    sum += src.sample(src.transform(middle + float2(q, -q)));
    sum += src.sample(src.transform(middle + float2(-q, -q)));
    return pow(clamp(toLinear(straight(sum / 5.0), space), 0.0, 1.0), 1.0 / 2.2);
}

// Where `d` falls in a screen of cells `size` on a side turned by
// `angle` around `origin`: the middle of its cell, and where it is in
// the cell, -0.5...0.5 across and up.
struct Screen {
    float2 middle;
    float2 within;
};

inline Screen screenAt(float2 d, float2 origin, float size, float angle) {
    float2 q = turned(d - origin, -angle) / size;
    float2 cell = floor(q);
    Screen s;
    s.within = q - cell - 0.5;
    s.middle = origin + turned((cell + 0.5) * size, angle);
    return s;
}

// How much of the pixel is inked: a round dot (or a line) grows from the
// cell's middle as `ink` rises, and meets its neighbors at half. Smoothed
// over a pixel, and exactly none or all at the ends.
inline float inked(float2 within, float ink, float lines, float size) {
    float spot = lines > 0.5 ? 0.5 - 0.5 * cos(6.283185307 * within.y)
                             : 0.5 - 0.25 * (cos(6.283185307 * within.x) + cos(6.283185307 * within.y));
    float w = clamp(2.0 / size, 0.001, 0.5);
    spot = w * 0.5 + spot * (1.0 - w);
    return clamp((ink - spot) / w + 0.5, 0.0, 1.0);
}

extern "C" [[stitchable]] float4 amvHalftone(coreimage::sampler src, float space, float size, float lines, float cmyk, float angle,
                                             float4 inkColor, float4 paperColor, float2 origin, float amount,
                                             coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    size = max(size, 1.0);
    float3 paper = toLinear(paperColor.rgb, 0.0);
    float3 light;
    if (cmyk < 0.5) {
        Screen s = screenAt(d, origin, size, angle);
        float ink = 1.0 - luma(cellLight(src, s.middle, size, space));
        float covered = inked(s.within, ink, lines, size);
        light = mix(paper, toLinear(inkColor.rgb, 0.0), covered);
    } else {
        // Black at the angle, cyan 30° before it, magenta 30° after and
        // yellow 45° before, as presses set them to keep moiré small.
        float4 angles = angle + float4(-0.523598776, 0.523598776, -0.785398163, 0.0);
        float4 covered;
        for (int i = 0; i < 4; i++) {
            Screen s = screenAt(d, origin, size, angles[i]);
            float3 c = cellLight(src, s.middle, size, space);
            float k = 1.0 - max(c.r, max(c.g, c.b));
            float ink = i == 3 ? k : (k < 0.999 ? (1.0 - c[i] - k) / (1.0 - k) : 0.0);
            covered[i] = inked(s.within, ink, lines, size);
        }
        light = paper * (1.0 - covered.rgb) * (1.0 - covered.a);
    }
    return mixed(original, fromLinear(light, space), amount);
}
