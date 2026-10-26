// A picture on a tube television: dark gaps between the scan lines, the
// screen's red, green and blue phosphor stripes or slots, and a lighter
// band that can roll down the screen. In linear light, as the tube lit
// it; the mask keeps the picture's average brightness, the gaps darken
// it as they did.

extern "C" [[stitchable]] float4 amvScanLines(coreimage::sample_t s, float space, float size, float darkness, float mask,
                                              float strength, float roll, float2 origin, float height, float rolling, float amount,
                                              coreimage::destination dest) {
    float2 p = dest.coord() - origin;
    size = max(size, 1.0);
    // Darkest halfway between two lines.
    float v = fract(p.y / size);
    float lines = 1.0 - darkness * (0.5 + 0.5 * cos(6.283185307 * v));
    float3 phosphors = float3(1.0);
    if (mask > 0.5) {
        // One triad of stripes a line wide, smooth so it doesn't alias.
        float u = p.x / size;
        float3 stripes = 0.5 + 0.5 * cos(6.283185307 * (u - float3(0.0, 1.0, 2.0) / 3.0));
        phosphors = 1.0 - strength + strength * 2.0 * stripes;
        if (mask > 1.5) {
            // Slots two lines tall, every other column half a slot lower.
            float column = floor(u);
            float w = fract(p.y / (size * 2.0) + 0.5 * fmod(abs(column), 2.0));
            float gap = 1.0 - smoothstep(0.0, 0.12, w) * smoothstep(1.0, 0.88, w);
            phosphors *= 1.0 - strength * gap;
        }
    }
    // The rolling band, `roll` of the way down from the top.
    float down = 0.5 - p.y / max(height, 1.0);
    float offset = fract(down - roll + 0.5) - 0.5;
    float band = 1.0 + 0.15 * exp(-offset * offset / 0.004) * rolling;
    float3 light = toLinear(straight(s), space) * lines * phosphors * band;
    return mixed(s, fromLinear(light, space), amount);
}
