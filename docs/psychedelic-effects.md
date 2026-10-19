# Noise, Color and Distortion effects

Status: **steps 1 to 4 of 5 built**: every kind (see
[Building it](#building-it)); the recipes and the flashing notes remain. 25 effect kinds in three new
categories of the effects panel, chosen so that stacking them gives
psychedelic pictures from footage or from nothing at all. Everything here
fits the stack rules in [effects.md](effects.md) (gravity, the list is the
render order, Blending against an earlier step) and draws through the one
compositor in [rendering.md](rendering.md). Nothing needs a framework the
app doesn't already link: Core Image on the existing Metal context, a few
Metal kernels for Core Image, and Vision's optical flow, which the Morph
transition and Optical Flow frame blending already use.

## Counting kinds

As with [transitions](transitions.md#counting-kinds), a kind is a
different way of changing the picture. Kinds that differ only in a setting
(a shape, a palette, a count) are one kind: there is one Twirl with a
shape, not Twirl, Vortex, Pinch and Bulge.

## The combining rule: generate, then blend against the source

Psychedelic looks come from layering a few simple operations. The stack
already has the tool for that: a Blending step **against** an earlier
step (see [Against](effects.md#against)). So no effect here has its own
blend mode or mix slider beyond Amount:

- **Generators replace the picture.** Static, Fractal Noise, Cells and
  Interference draw a full, opaque picture in place of whatever reached
  them. On footage, follow one with Blending against "Before Fractal
  Noise" to put the footage back underneath in any of the 19 modes. On a
  clip with no media (a solid, or an adjustment clip) they *are* the
  footage.
- **Maps come from above.** Displace takes its map from an
  [input](effects.md#inputs), or works like Blending: set against an
  earlier step, the picture reaching it is the map and the earlier
  picture is what moves. A Fractal Noise step, then Displace against
  "Before Fractal Noise", distorts the footage by the noise in one stack
  with no extra layer.
- **Every setting can be keyframed**, and every kind that moves on its own
  has an **Evolution** or **Speed** setting so it animates without
  keyframes.

## Categories and kinds

"Built in" names a Core Image filter that already does the work. "Color
kernel", "warp kernel" and "kernel" are the three kinds of custom Core
Image kernels, written in Metal and compiled once at first use the way
`MorphFlow` compiles its warp (see [Efficiency](#efficiency) for why the
choice matters).

### Noise: grain, snow and procedural fields

| Kind | What it does | Settings | Made with |
| --- | --- | --- | --- |
| Grain | Film grain, strongest in the midtones, in color or mono. | Amount (25%), size (1 px), color (off) | Built in: `CIRandomGenerator` shifted by a per-frame seed, scaled with `samplingNearest`, shaped by `CIColorMatrix`, then one color kernel that weights it by luminance and adds it. |
| Static | Television snow with rolling sync bars; replaces the picture. | Size (1 px), bars (2), roll speed | Built in: `CIRandomGenerator` per frame, multiplied by a `CIStripesGenerator` bar pattern moved each frame. |
| Fractal Noise | Smooth, evolving clouds or marble (fractal simplex noise); replaces the picture with gray. | Scale, octaves (4), roughness (50%), type: smooth, turbulent or ridged, evolution, seed | Color kernel: 3D simplex noise (x, y, evolution) summed over octaves; no texture reads at all. |
| Cells | Voronoi cells that drift and pulse; replaces the picture with distance-to-edge gray. | Cell size, jitter (100%), output: edges, distance or flat cells, evolution, seed | Color kernel: Worley noise over the 3 × 3 neighboring cells, hashed per cell. |
| Dither | Few colors with an ordered or noise dither, as early computer graphics. | Levels (4), pattern: Bayer 4×4, Bayer 8×8 or noise | Built in: `CIDither` with `CIColorPosterize` for noise; color kernel with a Bayer table for ordered. |
| Interference | Two line patterns over each other, beating into moiré; replaces the picture. | Spacing (8 px), angle between (3°), drift speed | Built in: two `CIStripesGenerator`s, rotated, multiplied with `CIMultiplyCompositing`. |
| Block Glitch | Rectangles of the picture jump sideways and lose channels for a frame or two. | Intensity (30%), block size, rate (per second), seed | Kernel: hashes the block and frame to an offset and channel mask, then samples the picture once per channel. |

### Color: the picture's colors are remapped; nothing moves

All of these work per pixel, on the same log curve Contrast and
Saturation use (see [Color](effects.md#color)), so a look holds when
footage is replaced with a PQ or HLG version.

| Kind | What it does | Settings | Made with |
| --- | --- | --- | --- |
| Hue Cycle | Turns hue around the color wheel over time, offset by brightness so bands of color travel through the tones. | Speed (rotations per second, 0.25), spread by brightness (0°), saturation boost (0%) | Built in `CIHueAdjust` with no spread; color kernel otherwise. |
| Cosine Palette | Replaces each color with `a + b·cos(2π(c·luma + d))`, the classic rainbow and acid palettes, with a phase that cycles. | Preset: rainbow, acid, infrared, oil slick, or custom a, b, c, d; cycle speed | Color kernel: four vectors, no texture reads. |
| Gradient Map | Maps brightness to a gradient of up to 8 stops, which can scroll. | Stops, scroll speed, repeat (1) | Built in: the gradient drawn once to a 256 × 1 image, then `CIColorMap`. |
| Solarize | Inverts tones above a threshold, or folds them several times for a contour look. | Threshold (50%), folds (1), per channel (off) | Color kernel (a triangle wave on each channel). |
| Posterize | Few levels per channel, with hard edges between bands. | Levels (6) | Built in: `CIColorPosterize`. |
| Channel Mixer | Feeds each output channel from any mix of red, green and blue, including swaps and negatives. | 3 × 3 matrix and offsets; presets for swap and rotate | Built in: `CIColorMatrix`. |
| False Color | Heat-camera and x-ray looks, or a two-color tone map. | Look: thermal, x-ray or duotone; two colors for duotone | Built in: `CIThermal`, `CIXRay`, `CIFalseColor`. |
| Neon Edges | Bright, saturated outlines over black, colored by edge direction. | Width (2 px), glow (50%), color: by angle or one color | Built in `CIEdges` and `CIBloom`; a color kernel colors by gradient angle from `CIMorphologyGradient`. |

### Distortion: pixels are moved; their colors are kept

| Kind | What it does | Settings | Made with |
| --- | --- | --- | --- |
| Displace | Moves each pixel by a map's red and green. | Map: an input, or against an earlier step (see above); amount (2% of the width), gray is still (on) | Built in: `CIDisplacementDistortion`. |
| Liquid | Flowing, melting motion: the picture is pushed along a noise field that evolves, twice through itself (domain warping). | Amount (5%), scale, warps (2), evolution, seed | Warp kernel: the Fractal Noise function evaluated for the offset, so it needs no map image. |
| Twirl | Turns, sucks in or bulges out around a center. | Shape: twirl, vortex, pinch or bulge; center; radius; amount | Built in: `CITwirlDistortion`, `CIVortexDistortion`, `CIPinchDistortion`, `CIBumpDistortion`. |
| Wave | Sine waves bend the picture along x, y or out from a center. | Direction: horizontal, vertical or radial; wavelength; height; speed | Warp kernel. |
| Kaleidoscope | Mirrors a wedge of the picture around a center into N segments, turning. | Segments (6), center, angle, spin speed, style: wedges or triangles | Built in `CIKaleidoscope` and `CITriangleKaleidoscope`; a warp kernel for even, seamless mirroring (the built-in repeats rather than mirrors). |
| Mirror Tile | Repeats the picture as tiles, mirrored at their edges, or into itself as an endless spiral. | Pattern: tile, fourfold, eightfold or Droste; tile size; angle | Built in: `CIAffineTile`, `CIFourfoldReflectedTile`, `CIEightfoldReflectedTile`, `CIDroste`. |
| Chromatic Aberration | Pulls red and blue apart from green, outward from a center or along a direction, as a cheap lens. | Amount (1%), mode: radial or linear; center or angle | Kernel: three samples, one per channel, in one pass. |
| Flow Smear | Drags pixels along the motion in the footage, the "datamosh" smear without broken files. | Amount (100%), frames ahead (1) | Optical flow from Vision (`VNGenerateOpticalFlowRequest`) between this frame and the next, then the `MorphFlow` warp kernel the Morph transition uses. |
| Slit-Scan | Each band of the picture comes from a different moment, so moving things stretch and bend. | Direction: rows, columns or rings; bands (16); time spread (0.5 s) | The picture above this step drawn at N moments (the machinery behind Echo and Motion Blur), each cut to its band with a crop. |
| Feedback | Endless tunnels and spirals: copies of earlier moments, each zoomed, turned and recolored one more step than the last. | Copies (8), delay (1 frame), scale and rotation per copy, hue shift per copy, decay | The picture above drawn at N earlier moments; copy *k* gets the transform raised to the *k*-th power (one folded matrix) and a hue rotation of *k* steps, blended with `CIAdditionCompositing`. |

Feedback is why the psychedelic tunnel works without breaking random
access: real feedback reads the last output frame, which a background
render, a scrub or an export of one stretch doesn't have. Here copy *k* is
computed straight from the source at *t − k·delay* with the transform
applied *k* times, so any frame can be drawn on its own and cached. It
looks like true feedback as long as the copies fade out (decay) before
the count runs out.

## Recipes

Starting presets for the [Presets](browser.md) tab, each a stack of the
kinds above plus Foundations steps. Each works on footage or, over a black
solid, as generated footage.

| Preset | Stack, top to bottom |
| --- | --- |
| Liquid Acid | Liquid · Cosine Palette (acid) · Hue Cycle · Blending: Soft Light against "Before Liquid" |
| Infinite Tunnel | Kaleidoscope (8) · Feedback (12 copies, 103%, 4°, 15° hue) · Chromatic Aberration · Grain |
| Lava Lamp | Fractal Noise (smooth) · Liquid · Gradient Map (lava stops, scrolling) |
| Noise Melt | Fractal Noise (turbulent) · Displace against "Before Fractal Noise" · Hue Cycle · Grain |
| Electric Cells | Cells (edges) · Neon Edges · Hue Cycle (spread 120°) · Blending: Screen against "Before Cells" |
| Broken Signal | Block Glitch · Chromatic Aberration (linear) · Interference · Blending: Overlay against "Before Interference" · Static at 15% via Blending: Add |
| Melting Rainbow | Flow Smear · Solarize (3 folds) · Hue Cycle · Feedback (6 copies, 100%, 0°, 30° hue) |
| Oil Slick | Wave (radial) · Twirl (vortex) · Cosine Palette (oil slick) · Blending: Luminosity against "Before Wave" |
| Thermal Dream | False Color (thermal) · Slit-Scan (rows) · Posterize (5) · Grain |
| Eightfold Mandala | Mirror Tile (eightfold) · Kaleidoscope (12) · Channel Mixer (rotate) · Dither (Bayer 4×4) |
| Moiré Breathing | Interference · Twirl (pinch, keyframed) · Gradient Map · Feedback |

## Efficiency

The compositor already builds one lazy Core Image graph per frame on a
Metal context and caches finished frames. The kinds above are placed on
the cheapest rung of this ladder that can do them:

1. **Built-in Core Image filters.** Apple's own kernels, tuned per GPU
   and folded into the graph like any step. Used wherever one does the
   job exactly.
2. **Color kernels** (`CIColorKernel`): one output pixel from one input
   pixel. Core Image concatenates neighboring color kernels into a single
   GPU pass, so Hue Cycle, Cosine Palette, Solarize and the Foundations
   Color steps in a row cost about one pass together. Procedural noise is
   a color kernel too: it computes its value from the coordinate and
   reads no texture.
3. **Warp kernels** (`CIWarpKernel`): compute only where to sample. Core
   Image samples once at the end and can concatenate a warp with
   neighboring transforms, so Liquid, Wave and Kaleidoscope cost one
   texture read per pixel however they're stacked with Transform steps.
4. **General kernels** (`CIKernel`): several reads per pixel, for Block
   Glitch and Chromatic Aberration (three reads in one pass, rather than
   three filtered copies composited).
5. **Neighborhood filters** (Neon Edges, the Bloom inside it): draw an
   intermediate image, as Blur does today (see
   [Keeping it sharp and cheap](effects.md#keeping-it-sharp-and-cheap)).
6. **Several moments** (Slit-Scan, Feedback, Flow Smear): cost a draw of
   everything above per copy, or optical flow per frame. Like Motion Blur,
   they draw fewer copies while playing at reduced quality (Feedback
   every other copy, Slit-Scan 4 bands, Flow Smear none), the full count
   when paused, in background renders and in export.

Rules every kind follows:

- **Deterministic.** Noise is seeded from the effect's seed and the frame
  number in the clip's source time, never a clock or `random()`. The same
  frame always draws the same picture, so renders can be cached and an
  export matches the viewer. The seed is part of the render key.
- **A region of interest.** Every warp and general kernel declares how
  far it reads from each output pixel (Displace and Liquid their largest
  offset, Chromatic Aberration its spread), so Core Image only renders
  the pixels needed, at the viewer's size when previewing.
- **Generators have a finite extent.** `CIRandomGenerator`,
  `CIStripesGenerator` and the noise kernels are infinite; each is
  cropped to the timeline frame plus the
  [canvas margin](effects.md#keeping-it-sharp-and-cheap) as it is made.
- **Sizes are fractions of the frame.** Block sizes, wavelengths and
  offsets are stored as fractions of the frame's width (shown in pixels),
  so a look is the same at quarter-size preview and full-size export.
- **Compiled once.** Kernels are Metal source compiled by
  `CIKernel.kernels(withMetalString:)` at first use and kept, with the
  older kernel language as a fallback where Metal can't compile, as
  `MorphFlow` does. SwiftPM can't build Core Image metallibs, which would
  only save the first compile.
- **Not used:** GameplayKit's `GKNoise` (CPU, too slow per frame), Metal
  Performance Shaders through `CIImageProcessorKernel` (it breaks Core
  Image's pass fusion, and every kind here fits a cheaper rung), and
  Core ML style transfer (a model file, not built in, and slow at 4K).

## Safety: flashing

Static, Block Glitch, fast Hue Cycle and Feedback can flash several times
a second, which can trigger seizures in people with photosensitive
epilepsy. The effects panel notes it on those kinds, and their defaults
stay under three flashes a second. A check of a whole export for
dangerous flashing is listed under [Not yet](#not-yet).

## Testing

- Each kind at its defaults against a stored picture of a generated test
  frame, within a small tolerance (GPU differences).
- Each kind at Amount 0% (or its no-op value) leaves the picture
  unchanged, so it can be skipped like other no-op controls.
- The same frame drawn twice, and drawn after a seek, is identical
  (determinism).
- Feedback and Slit-Scan drawn at a frame on their own match the same
  frame drawn during playback.
- A UI snapshot of the effects panel showing each new category.

## Not yet

- Driving any setting from a beat map ([beat-matching.md](beat-matching.md)),
  so pulses land on the beat without keyframing each one.
- Driving a setting from the music's level or frequency bands, from the
  mix meter's analysis.
- A flash check of a timeline or export against the three-flashes rule.
- A pixel sort kind: sorting runs of pixels needs a GPU sort per row,
  which doesn't fit Core Image's per-pixel model.

## Building it

In order, each step usable on its own:

1. **Color** (done), with what every look shares. The eight Color kinds
   are in `EffectCategory.recolor` ("Color" in the library) and draw as a
   `.look` step (`LookStep`: each control's numbers and choices at the
   moment, Amount, and the clip's time for one that moves), which
   `LookRenderer` draws with the kernels in `LookKernels`: one Metal
   source of Core Image kernels, compiled once at first use. Where it
   differs from the tables above:
   - **Every look has Amount** (100%), mixing it with the picture it
     changes; at 0% it is a no-op, like other effects.
   - **All eight are kernels of our own**, color kernels except Neon
     Edges, rather than `CIHueAdjust`, `CIColorPosterize`, `CIColorMatrix`,
     `CIColorMap` or `CIThermal`: the compositor's pictures are the
     timeline's encoded values, which the built-ins would act on directly.
     Each decodes to the tone scale (ACEScct's log curve, black 0 and
     reference white 1, as Contrast uses) and back, so a look is the same
     in Rec. 709, PQ and HLG. Colors the person picks (Gradient Map's
     stops, the duotone, Neon Edges' one color) are the timeline's own
     values, as a shape's fill is; Thermal and X-Ray's palettes are Rec.
     709 colors converted to the timeline's.
   - **Gradient Map** has three stops (Shadows, Midtones, Highlights)
     rather than up to eight, and Repeat folds back and forth so repeats
     don't jump; Speed scrolls it.
   - **Solarize** folds above Threshold: Folds sets how many times the
     tones above it fold back down per threshold's height, on the
     brightness (keeping hues) or on each channel.
   - **Channel Mixer**'s rows are Red From, Green From and Blue From, with
     Offset, on the tone scale; the swap and rotate presets aren't there.
   - **Neon Edges** is a Sobel kernel over each channel's tones, `Width`
     timeline pixels apart, so a change of color alone lights an edge as a
     change of brightness does; colored by the strongest channel's
     direction or one color, with `CIBloom` for Glow. It reads its neighbors, so it is the one look that
     `dependsOnPixelSize`.
   - **Moving on its own**: a Hue Cycle with a Speed, or a Cosine Palette
     or Gradient Map with one, makes its clip's `animatedRanges` cover all
     of it, so it is drawn afresh each frame and never played as a plain
     file; only those carry the time into the render key.
   - **No fallback language.** Core Image's runtime Metal compiler needs
     each function marked `[[stitchable]]`; a kernel that doesn't compile
     leaves the picture as it is, and the error is logged.
   - **Each kernel is compiled from a source of its own**, the shared
     functions before it (`LookKernels.split`). Compiled together from one
     source, Core Image mistook them for each other within a `CIContext`
     and drew one look's cached picture for another's, which only shows
     when several are drawn in one context, as the app always does
     (`LookKernelIdentityTests`).
2. **Noise** (done), in `EffectCategory.noise`, drawn by the same
   `.look` step and `LookKernels`. Everything random is hashed (PCG) from
   the position in timeline pixels, the effect's Seed and the clip's time
   in thousandths of a second, never a clock, so a frame always draws the
   same at any size; Grain, Static and Block Glitch are new every frame
   and mark their clip as changing throughout, as do Fractal Noise and
   Cells with an Evolution and Interference with a Drift. Where it differs
   from the table:
   - **Generators** (Static, Fractal Noise, Cells, Interference) are
     opaque gray over the picture's area, or the whole canvas when
     nothing reached them, mixed in by Amount (100%) rather than always
     replacing.
   - **Grain** is Amount alone: 100% is the default strength, weighted to
     the midtones; Size and Channels (mono or color) as in the table.
   - **Fractal Noise** is three-dimensional gradient (Perlin) noise rather
     than simplex, its third dimension the Evolution (0.25 a second),
     summed over Octaves (4) with Roughness as each octave's weight.
   - **Cells** draws Edges, Distance or Flat Cells; each cell's point
     circles its place as it evolves.
   - **Dither** is Bayer 4×4, 8×8 or noise, on each channel's tones, in
     output pixels, so it `dependsOnPixelSize`.
   - **Block Glitch** moves blocks twice as wide as Block Size and half as
     high, up to 8% of the canvas, splitting red and blue three pixels
     apart and dropping one channel at random, a new set Rate times a
     second.
   - Kernels of our own throughout, as in step 1, rather than
     `CIRandomGenerator`, `CIStripesGenerator` and `CIDither`: the random
     generator is one fixed pattern that can't take a seed, so a new
     picture each frame would mean moving it by an offset, and the
     generators work on encoded values.
3. **Distortion** (done), in `EffectCategory.distortion`. Liquid, Twirl,
   Wave, Kaleidoscope and Mirror Tile are warp kernels (`CIWarpKernel`:
   only where to read from, so one read a pixel however they stack with
   moves); Displace and Chromatic Aberration are general kernels. Centers
   are offsets from the middle of the frame in timeline pixels, down
   positive, as Position is; sizes are timeline pixels or a percent of
   the frame's width. Each reads what reached it over transparency, so
   pulling from past the clip's picture shows nothing there. They settle
   the opacity and draw pending shapes first, and a Stroke after one has
   nothing to follow. Where it differs from the table:
   - **Amount** is each kind's strength (Displace and Liquid as a percent
     of the width, Twirl's turn, Chromatic Aberration's spread), not a mix
     with the original, which for a distortion would only double the
     picture.
   - **Displace** takes an input as its map (red across, green down, from
     middle gray or from black: Still At), or reads **Against** like
     Blending (`EffectKind.readsAgainst`): set against an earlier step, the
     picture before that step is moved by the picture reaching this one.
     The panel's Against row reads "Its Input" for the first. Without
     either it does nothing, with a note. It's our own kernel rather than
     `CIDisplacementDistortion`, so the map is read the same way as the
     other kinds' values.
   - **Twirl**'s shapes are one warp kernel rather than four built-ins:
     Twirl turns most at the middle, Vortex more the nearer the middle,
     Pinch reads from further out and Bulge from further in, all fading
     to nothing at Radius.
   - **Wave** moves along x or y by a sine of the other, or radially; Speed
     travels it.
   - **Kaleidoscope** folds every direction into one wedge of 360° /
     Segments, mirrored at its edges, so seams never show; the triangle
     style isn't there. Speed spins it.
   - **Mirror Tile** is our own warp: Tile repeats, Fourfold mirrors at
     each edge, Eightfold across the diagonals too, and Droste keeps the
     picture outside Tile Size and fills inside it with the picture
     shrunk (so the ring out to the frame's nearer edge fits), turned by
     Angle, again and again toward the middle.
   - **Chromatic Aberration** reads red and blue its Amount (a percent of
     the width) either side of green, radially from Center (the full
     amount half the frame's width out) or along Angle, in one pass.
4. **Several moments** (done): Flow Smear, Slit-Scan and Feedback, in the
   Distortion category. They draw the steps above them again at other
   moments, as Trails draws the finished clip: the composition gives the
   clip's footage again on tracks of its own, `delay` later for each
   earlier moment the effects ask for (`Effect.momentDelays`, on the
   timeline's frames by `MomentDelays`, shared between effects asking for
   the same, at the most any keyframe asks) and some frames ahead in the
   file for Flow Smear (`MediaDraw.moments`, `.ahead`). The compositor
   gives `runStack` a way to draw the steps above a look from one of those
   copies, resolved at that moment (`stepsAbove`); a shape clip's are its
   shapes then and a still's its picture, while a nested timeline has no
   earlier moments, and a several-moment look drawn inside another's
   copies draws only the present. A stretch holding one is always
   rendered, and its picture changes every frame. Where it differs from
   the table:
   - **Feedback** screens each copy over the picture (`CIScreenBlendMode`)
     rather than adding it, so the tunnel glows without burning out to
     white: copy *k* is the picture *k*·Delay frames back, scaled by Scale
     and turned by Rotation *k* times about Center (clockwise, as
     Rotation), its hues turned by Hue Shift *k* times, and faded to
     (1 − Decay)^*k*. Decay is 30% by default.
   - **Slit-Scan**'s bands run from now (the top, the left or the middle)
     to Time Spread ago, each on a frame; rings are masked by a small
     kernel, out to half the frame's diagonal, and the last band reaches
     the canvas's edges.
   - **Flow Smear** measures the motion with `BlockMatchFlow` rather than
     Vision, so it runs anywhere and is the same every time, and pulls the
     picture back along it by Amount with the `MorphFlow` warp, within the
     frame.
   - **While playing** the viewer draws Feedback's even copies only,
     Slit-Scan in four bands (each the moment of the band it stands for),
     and no Flow Smear; renders and export draw everything.
5. **Recipes and safety**: the presets above, and the flashing notes.

