// Ripples the picture across, down or out from the middle.
extern "C" [[stitchable]] float2 amvWave(float2 center, float wavelength, float height, float phase, float direction,
                                         coreimage::destination dest) {
    float2 d = dest.coord();
    if (direction < 0.5) return d + float2(0.0, height * sin(6.283185307 * (d.x / wavelength - phase)));
    if (direction < 1.5) return d + float2(height * sin(6.283185307 * (d.y / wavelength - phase)), 0.0);
    float2 v = d - center;
    float r = length(v);
    return r > 0.0 ? d + v / r * height * sin(6.283185307 * (r / wavelength - phase)) : d;
}
