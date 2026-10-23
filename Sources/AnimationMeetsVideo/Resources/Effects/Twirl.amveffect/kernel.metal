// Twists, pinches or bulges the picture around a center.
extern "C" [[stitchable]] float2 amvTwirl(float2 center, float radius, float amount, float shape, coreimage::destination dest) {
    float2 d = dest.coord();
    float2 v = d - center;
    float r = length(v);
    if (r >= radius || r <= 0.0) return d;
    float t = 1.0 - r / radius;
    if (shape < 0.5) return center + turned(v, amount * 3.14159265 * t * t);
    if (shape < 1.5) return center + turned(v, amount * 0.5 * (radius / max(r, 1.0) - 1.0) * t * t);
    // Pinch takes each point from further out, bulge from further in.
    float f = shape < 2.5 ? pow(r / radius, -0.5 * amount * t) : pow(r / radius, amount * t);
    return center + v * clamp(f, 0.05, 20.0);
}
