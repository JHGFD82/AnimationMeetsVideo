# Keying & Masks

Status: **built**. Ten effects in the Keying & Masks category of the
effects library (`"category": "keying"`), each an effect package that
ships with the app in `Sources/AnimationMeetsVideo/Resources/Effects/`
(see [effect-packages.md](effect-packages.md)). They cut the picture by
its color, its brightness, a clean plate or a shape, and tidy the alpha
they leave. They take their places in the library from
`BuiltInEffects.libraryOrder`, after the Matte effect, which cuts a clip
by a dropped picture and stays in Swift (see [effects.md](effects.md)).

Each leaves the picture's color as it is and changes its alpha
(premultiplied, as the compositor keeps it), so the layers below show
through what it clears. Each has Amount, and at 0% does nothing; between,
it mixes its alpha in.

## The effects

| Effect | Kernel | What it does |
| --- | --- | --- |
| Chroma Key | color | Clears a key color. Controls: Key Color, Tolerance, Softness, Spill Suppression, View (Result or Matte). |
| Luma Key | color | Clears the darks or the brights. Controls: Key Out (Darks or Brights), Threshold, Softness, View. |
| Difference Key | general, input | Clears what matches a clean plate dropped onto it. Controls: Tolerance, Softness, View. |
| Despill | color | Takes a key color's cast out of what is kept. Controls: Spill Color, Range. |
| Matte Choker | general | Shrinks or grows the alpha's edge and feathers it. Controls: Shrink/Grow, Feather. |
| Box Mask | color | Keeps inside (or outside) a rectangle. Controls: Center, Size, Roundness, Feather, Angle, Keep. |
| Ellipse Mask | color | Keeps inside (or outside) an ellipse. Controls: Center, Size, Feather, Angle, Keep. |
| Corner Mask | color | Keeps inside (or outside) four corners, a garbage matte. Controls: Top Left, Top Right, Bottom Right, Bottom Left, Feather, Keep. |
| Gradient Mask | color | Fades the picture out from Start to End, linearly or as a circle. Controls: Shape, Start, End, Keep. |
| Alpha Tools | color | Invert Alpha, Alpha from Luma, Make Opaque, Premultiply, Unpremultiply, Show Alpha. |

A typical green screen stack, top to bottom: Corner Mask (Keep
Inside, around the subject, to cut away rigs and the screen's edges),
Chroma Key, Matte Choker (a pixel or two in, feathered), and Spill
Suppressor if Chroma Key's own spill suppression isn't enough.

## How they work

### Keys

Keys work on the tone scale the looks share (`toTones`, black 0 and
reference white 1, the same in Rec. 709, PQ and HLG), so their settings
mean the same in every timeline color space. Color controls are Rec. 709
values, turned into the timeline's space by the kernel.

- **Chroma Key** splits each pixel's tones into brightness and chroma
  (the `luma` weights, Cb and Cr). How far a pixel's chroma is from the
  key color's, as a share of how strong the key color's chroma is, is
  compared with Tolerance: within it the pixel is clear, past Tolerance +
  Softness opaque, smoothly between. Comparing chroma alone means the
  screen in shadow keys out as well as in light, and grays and white are
  never keyed. Spill Suppression removes the part of each kept pixel's
  chroma that points toward the key color, with its brightness
  unchanged. The defaults (a screen green, 35%, 15%, 50%) clear typical
  green screens and keep skin, blue and white.
- **Luma Key** compares each pixel's brightness with Threshold, softened
  over Softness on the side it keeps.
- **Difference Key** reads the picture dropped onto it as its input (a
  frame of the same shot without the subject) and compares the two
  pixel by pixel: the distance between their tones within Tolerance is
  cleared. Where the plate has nothing, the picture is kept. Without a
  plate it does nothing, and the effects panel says to drop one.
- **Despill** removes chroma toward its color as Chroma Key's
  Spill Suppression does, for footage keyed some other way (with Matte,
  or a key below). Range narrows which hues count: at 100% every color
  leaning toward the spill color, lower only those closer to its hue.
- **View: Matte** on each key shows its alpha as an opaque gray, the
  gray whose Rec. 709 value is the alpha (white opaque, reference white
  in HDR), for judging the key. Alpha Tools' Show Alpha does the same
  for any picture.

### Matte Choker

A general kernel reading a disk around each pixel, as far as the edge
can move: Shrink/Grow's size plus half the Feather. It averages the
alpha over 128 samples spread over the disk (a Vogel spiral). For a
straight edge the share of the disk that is opaque gives exactly how
far the pixel is from the edge, so the edge is moved by Shrink/Grow and
softened across Feather, centered on where it ends up. Corners round off
within the disk and details thinner than it thin out, as with any
choker. Where the edge grows, the color is the average of the opaque
pixels nearby. With both controls at 0 the picture is left as it is.
Its edges repeat past the picture's, so a subject touching the frame's
edge stays there.

### Masks

Each mask is a color kernel computing the signed distance from each
output pixel to its shape (rounded box, ellipse, four-sided polygon),
and softening across Feather, centered on the edge, at least one pixel
so the edge is smooth. Sizes and positions are in the timeline's pixels,
scaled to the output, so a mask looks the same at any viewer size.
Center and the corners are point controls: an offset from the middle of
the frame, down positive. Angle turns the shape clockwise. Keep Outside
inverts the mask.

The ellipse's distance is estimated from its gradient, so its feather is
even all the way round. The Corner Mask's corners can make any
four-sided shape; one that crosses itself keeps the two triangles it
makes.

Gradient Mask is opaque at Start and clear at End, linearly between:
along the line from Start to End (Linear), or out from Start in a
circle reaching End (Radial). Keep End reverses it. Animating End across
the frame makes a soft wipe.

### Alpha Tools

- **Invert Alpha**: clear where opaque and the other way round, color
  kept (what was clear becomes black).
- **Alpha from Luma**: as opaque as the pixel is bright on the tone
  scale, so white titles on black become titles on nothing.
- **Make Opaque**: alpha 1, what was clear black.
- **Premultiply**: color multiplied by alpha again, for footage stored
  with straight alpha but read as premultiplied (a bright fringe at its
  soft edges).
- **Unpremultiply**: color divided by alpha again, for footage
  premultiplied twice (a dark fringe).
- **Show Alpha**: as the keys' View Matte.

## Testing

`KeyingTests` (Tests/AnimationMeetsVideoTests/Rendering) draws each
effect on pictures whose answer is known, reading back the alpha the
compositor's final frame (flattened onto black) would hide: a green
field with a red square keyed to the square, in shadow too; the defaults
on typical screens and skin; softness and spill; luma darks and brights;
a difference key against a plate; the choker's edge moved 4 pixels each
way and feathered; masks opaque inside, clear outside, half at the edge
of their feather, moved, turned, rounded and inverted; the gradient's
ramp; each alpha tool; Amount 0 a no-op throughout. One test draws a
key through the compositor over a layer below. The shipped-package tests
check that every kernel compiles and the library keeps its order.

## Not yet

- **Picking the key color from the viewer** with an eyedropper; for now
  it is set with the color control.
- **On-screen handles** for the masks' centers, sizes and corners.
- **Free-form masks** of many points, drawn as Bezier paths.
- **Light wrap** and edge color correction for composites.
