// Passes the picture on over the whole canvas, for CIMotionBlur after it
// to spread into.
extern "C" [[stitchable]] float4 amvDirectionalBlur(coreimage::sampler src, float space, coreimage::destination dest) {
    return src.sample(src.transform(dest.coord()));
}
