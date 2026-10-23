// Repeats the picture in mirrored tiles, or into itself.
extern "C" [[stitchable]] float2 amvMirrorTile(float2 center, float size, float angle, float pattern, float halfFrame,
                                               coreimage::destination dest) {
    float2 v = turned(dest.coord() - center, -angle);
    if (pattern > 2.5) {
        // Droste: outside the size the picture is as it was; inside it
        // is the picture again, shrunk so the ring from the size out to
        // the frame's nearer edge fits inside the size, turned by the
        // angle, and inside that again, toward the middle.
        float r = length(v);
        if (r >= size) return dest.coord();
        if (r <= 0.0) return center;
        float zoom = max(halfFrame / size, 1.25);
        float steps = ceil(log(size / r) / log(zoom));
        return center + turned(turned(v, -steps * angle) * pow(zoom, steps), angle);
    }
    float2 u = v / size + 0.5;
    if (pattern < 0.5) u = fract(u);
    else u = mirrored(u);
    if (pattern > 1.5 && u.y > u.x) u = u.yx;
    return center + turned((u - 0.5) * size, angle);
}
