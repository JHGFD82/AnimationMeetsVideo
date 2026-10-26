// The picture as it is, for CISharpenLuminance after it, which sharpens
// brightness only, so edges gain no colored fringes.
extern "C" [[stitchable]] float4 amvSharpen(coreimage::sample_t s, float space) {
    return s;
}
