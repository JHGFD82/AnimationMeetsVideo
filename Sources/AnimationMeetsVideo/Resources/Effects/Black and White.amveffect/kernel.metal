// A gray from each color, weighted by how much of each of the six hues it
// holds: its lowest channel is already gray, the step from there to its
// middle channel counts as the secondary hue between its two highest
// (yellow, cyan or magenta), and the step from the middle to the highest
// as that primary (red, green or blue). So a gray keeps its tone, a pure
// red becomes Reds, a pure yellow Yellows.
extern "C" [[stitchable]] float4 amvBlackAndWhite(coreimage::sample_t s, float space, float reds, float yellows,
                                                  float greens, float cyans, float blues, float magentas, float amount) {
    float3 t = toTones(straight(s), space);
    float v[3] = { t.r, t.g, t.b };
    float primaries[3] = { reds, greens, blues };
    int high = (t.r >= t.g && t.r >= t.b) ? 0 : (t.g >= t.b ? 1 : 2);
    int a = (high + 1) % 3, b = (high + 2) % 3;
    int low = v[a] <= v[b] ? a : b;
    int middle = 3 - high - low;
    // The secondary between the two highest: red and green make yellow,
    // red and blue magenta, green and blue cyan.
    int pair = high + middle;
    float secondary = pair == 1 ? yellows : (pair == 2 ? magentas : cyans);
    float gray = v[low] + (v[middle] - v[low]) * secondary + (v[high] - v[middle]) * primaries[high];
    return mixed(s, fromTones(float3(gray), space), amount);
}
