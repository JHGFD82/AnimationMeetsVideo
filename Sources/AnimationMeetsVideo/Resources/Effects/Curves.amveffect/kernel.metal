// Curves: each channel's tone through the RGB curve, then through its own
// channel's curve. Tones run from black (0) to reference white (1) in any
// color space; HDR highlights past white carry on along the slope of
// each curve's last stretch. It reads the picture only at the pixel it
// draws (`perPixel`), so it works like a color kernel; it is a general
// one only to read the curves' tables.
extern "C" [[stitchable]] float4 amvCurves(coreimage::sampler src, float space, coreimage::sampler master,
                                           coreimage::sampler red, coreimage::sampler green, coreimage::sampler blue,
                                           float amount, coreimage::destination dest) {
    float4 s = src.sample(src.transform(dest.coord()));
    float3 t = toTones(straight(s), space);
    float3 m = float3(curveTone(master, t.r), curveTone(master, t.g), curveTone(master, t.b));
    float3 c = float3(curveTone(red, m.r), curveTone(green, m.g), curveTone(blue, m.b));
    return mixed(s, fromTones(c, space), amount);
}
