// Passes the picture on over the whole canvas, for CIGaussianBlur after
// it to spread into.
extern "C" [[stitchable]] float4 amvGaussianBlur(coreimage::sampler src, float space, coreimage::destination dest) {
    return src.sample(src.transform(dest.coord()));
}
