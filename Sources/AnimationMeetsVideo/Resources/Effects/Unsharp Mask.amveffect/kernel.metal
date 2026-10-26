// The picture as it is, for CIUnsharpMask after it: the difference from
// a blurred copy, `radius` wide, added back to each channel. A large
// radius and a small amount lift local contrast, as clarity does.
extern "C" [[stitchable]] float4 amvUnsharpMask(coreimage::sample_t s, float space) {
    return s;
}
