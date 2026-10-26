// Keeps every pixel's light between black and Brightest (a share of
// reference white: 100% for SDR, about 493% for a 1000-nit HDR master on
// PQ) and its saturation at most Most Saturated. Desaturating moves an
// out-of-range color toward the gray of its brightness only as far as it
// must, so its hue stays; Clipping cuts each channel on its own, and
// leaves saturation be. Colors already within the limits are unchanged.
extern "C" [[stitchable]] float4 amvBroadcastSafe(coreimage::sample_t s, float space, float ceiling, float saturationLimit,
                                                  float clipping, float amount) {
    float3 l = toLinear(straight(s), space);
    if (clipping > 0.5) return mixed(s, fromLinear(clamp(l, 0.0, ceiling), space), amount);

    float y = clamp(dot(l, float3(0.2126, 0.7152, 0.0722)), 0.0, ceiling);
    float3 d = l - y;
    // The largest share of the way from gray to the color that stays in.
    float k = 1.0;
    for (int i = 0; i < 3; i++) {
        if (d[i] > 0.0 && y + d[i] > ceiling) k = min(k, (ceiling - y) / d[i]);
        if (d[i] < 0.0 && y + d[i] < 0.0) k = min(k, y / -d[i]);
    }
    // Saturation as (highest - lowest) / highest, limited.
    float high = max(d.r, max(d.g, d.b)), low = min(d.r, min(d.g, d.b));
    float spread = high - low;
    if (saturationLimit < 1.0 && spread > 0.0) {
        float below = spread - saturationLimit * high;
        if (below > 0.0) k = min(k, saturationLimit * y / below);
    }
    return mixed(s, fromLinear(y + max(k, 0.0) * d, space), amount);
}
