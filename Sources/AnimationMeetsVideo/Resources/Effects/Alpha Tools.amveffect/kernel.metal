// Works on the picture's alpha, keeping its own color:
// 0 Invert Alpha: clear where it was opaque and the other way round.
// 1 Alpha from Luma: as opaque as it is bright (on the tone scale), so
//   white titles over black become titles over nothing.
// 2 Make Opaque: alpha 1 everywhere, what was clear black.
// 3 Premultiply: the color multiplied by alpha once more, for a picture
//   whose color was stored straight but read as premultiplied, which
//   shows a bright fringe at its soft edges.
// 4 Unpremultiply: the color divided by alpha once more, for a picture
//   premultiplied twice, which shows a dark fringe.
// 5 Show Alpha: the alpha as an opaque gray picture, the gray whose Rec.
//   709 value it is (white opaque, reference white in HDR).
// Amount mixes the result in.
extern "C" [[stitchable]] float4 amvAlphaTools(coreimage::sample_t s, float space, float operation, float amount) {
    float3 color = straight(s);
    float4 result;
    if (operation < 0.5) result = float4(color * (1.0 - s.a), 1.0 - s.a);
    else if (operation < 1.5) {
        float a = clamp(luma(toTones(color, space)), 0.0, 1.0) * s.a;
        result = float4(color * a, a);
    }
    else if (operation < 2.5) result = float4(color, 1.0);
    else if (operation < 3.5) result = float4(s.rgb * s.a, s.a);
    else if (operation < 4.5) result = float4(color, s.a);
    else result = float4(fromLinear(toLinear(float3(s.a), 0.0), space), 1.0);
    return mix(s, result, amount);
}
