// Bands of the picture, each from its own moment, `timeSpread` across the
// last: rows from the top down, columns from the left, or rings out from
// the center. The first and last reach the canvas's edges. One band,
// `pass` of `passes`, each pass, over what the others drew.
extern "C" [[stitchable]] float4 amvSlitScan(coreimage::sampler src, float space, coreimage::sampler band, float pass, float passes,
                                             float direction, float2 middle, float width, float height, float2 center,
                                             coreimage::destination dest) {
    float2 p = dest.coord();
    float lo = pass / passes, hi = (pass + 1.0) / passes;
    bool first = pass < 0.5, last = pass > passes - 1.5;
    bool inside;
    if (direction < 0.5) {
        float t = (middle.y + height / 2.0 - p.y) / height;
        inside = (first || t > lo) && (last || t <= hi);
    } else if (direction < 1.5) {
        float s = (p.x - (middle.x - width / 2.0)) / width;
        inside = (first || s >= lo) && (last || s < hi);
    } else {
        float reach = sqrt(width * width + height * height) / 2.0;
        float r = distance(p, center);
        inside = r >= lo * reach && (last || r < hi * reach);
    }
    return inside ? band.sample(band.transform(p)) : src.sample(src.transform(p));
}
