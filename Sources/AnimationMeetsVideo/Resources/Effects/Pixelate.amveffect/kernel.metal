// Squares or hexagons of one color each, the average of the picture
// under the cell, laid out from `origin` so the grid stays put as the
// frame is drawn at other sizes.

// The average of the picture over a square `size` on a side from
// `corner`, from an even grid of samples, premultiplied.
inline float4 squareAverage(coreimage::sampler src, float2 corner, float size) {
    float4 sum = float4(0.0);
    for (int j = 0; j < 6; j++) {
        for (int i = 0; i < 6; i++) {
            sum += src.sample(src.transform(corner + (float2(i, j) + 0.5) / 6.0 * size));
        }
    }
    return sum / 36.0;
}

// The average over a hexagon around `middle`, `size` across its flats:
// its middle and two rings of six.
inline float4 hexagonAverage(coreimage::sampler src, float2 middle, float size) {
    float4 sum = src.sample(src.transform(middle));
    for (int k = 0; k < 6; k++) {
        float a = float(k) * 1.047197551;
        float2 v = float2(cos(a), sin(a));
        sum += src.sample(src.transform(middle + v * size * 0.22));
        sum += src.sample(src.transform(middle + turned(v, 0.523598776) * size * 0.4));
    }
    return sum / 13.0;
}

inline float2 floorMod(float2 p, float2 m) { return p - m * floor(p / m); }

extern "C" [[stitchable]] float4 amvPixelate(coreimage::sampler src, float space, float size, float shape, float2 origin,
                                             float amount, coreimage::destination dest) {
    float2 d = dest.coord();
    float4 original = src.sample(src.transform(d));
    size = max(size, 1.0);
    float2 p = d - origin;
    float4 cell;
    if (shape < 0.5) {
        cell = squareAverage(src, origin + floor(p / size) * size, size);
    } else {
        // The nearer of two offset grids' centers: pointy-topped
        // hexagons `size` apart side by side.
        float2 r = float2(1.0, 1.7320508) * size;
        float2 a = floorMod(p, r) - r * 0.5;
        float2 b = floorMod(p - r * 0.5, r) - r * 0.5;
        float2 offset = dot(a, a) < dot(b, b) ? a : b;
        // Rounded to a hundredth of a pixel, so every pixel of a cell
        // finds the same middle.
        float2 middle = origin + round((p - offset) * 100.0) / 100.0;
        cell = hexagonAverage(src, middle, size);
    }
    return mix(original, cell, amount);
}
