# Blur & Sharpen effects

Status: **built**. Nine effects in the library's Blur & Sharpen
category, each an effect package that ships with the app
(`Sources/AnimationMeetsVideo/Resources/Effects/`, see
[effect-packages.md](effect-packages.md)). Every number, point and
choice can be keyframed like any other control. Sizes are in the
timeline's pixels, scaled to the size a frame is drawn at, so the
viewer at Half draws what an export does; all nine say they depend on
pixel size, so a nested timeline holding one isn't pushed into its
layers.

## The effects

| Effect | Controls | How it is drawn |
| --- | --- | --- |
| Gaussian Blur | Radius, Edges | `CIGaussianBlur` after a kernel that passes the picture on. Radius is the Gaussian's spread. |
| Directional Blur | Length, Angle, Edges | `CIMotionBlur`: a blur along one line, both ways, as a fast pan. 0° is across, 90° up and down. |
| Zoom Blur | Center, Amount, Edges | Its own kernel: each pixel the average along its line to the center, Amount of the way there; below 0 it reads away from the center instead. |
| Spin Blur | Center, Angle, Edges | Its own kernel: each pixel the average along its circle around the center, Angle of arc, half either side. |
| Lens Blur | Radius, Highlight Rings, Ring Width, Ring Softness, Edges | `CIBokehBlur`: a disc-shaped blur, as an out-of-focus lens draws, with bright points opening into rings as Highlight Rings rises. |
| Tilt-Shift | Shape, Center, Angle, Focus Size, Transition, Radius | Its own kernel: sharp within Focus Size of a band through the center at Angle (or of a circle around it, for Radial), blurring to Radius over Transition beyond, as a miniature. |
| Surface Blur | Radius, Threshold | Its own kernel, a bilateral filter: neighbors count less the more their color differs from the pixel's, by about Threshold. Smooths skin, noise and banding, and keeps outlines. |
| Sharpen | Amount, Radius | `CISharpenLuminance`: sharpens brightness only, so edges gain no colored fringes. |
| Unsharp Mask | Amount, Radius | `CIUnsharpMask`: the difference from a blurred copy, Radius wide, added back Amount times. A wide radius and a low amount lift local contrast (clarity). |

At no blur (a Radius, Length, Amount or Angle of 0) each leaves the
picture as it is, without drawing its filter; Sharpen and Unsharp Mask
do so at an Amount of 0.

## Edges

The blurs that spread the picture (Gaussian, Directional, Zoom, Spin and
Lens) have **Edges**:

- **Repeat** (the default): the picture's edges go on past it, so a
  blurred full-frame clip keeps its corners and sides instead of fading
  into a dark border. The blur stays within the picture. For the filter
  blurs this is the picture's own rectangle (its `after` filter reads it
  with `"input": "clamped"`); Zoom and Spin Blur repeat the frame's edges,
  since a kernel isn't told where the picture ends. For a clip filling
  the frame they are the same.
- **Transparent**: past the picture is transparent, so the blur spreads
  beyond a title's or a shape's outline, and a full-frame clip's edges
  soften.

Tilt-Shift and Surface Blur always repeat the picture's edges (their
kernels read it `clamped`), as do Sharpen and Unsharp Mask, which would
otherwise draw a bright or dark rim at the frame's edge.

## Drawing in passes

A single kernel reading every pixel a wide blur covers is too slow, so
the four with kernels of their own draw twice (the package's `repeat`,
see [Repeating](effect-packages.md#repeating)), each pass over what the
first made:

- **Zoom** and **Spin Blur** read 24 points a pass. The first pass spreads
  them over the whole streak and the second over one of its steps, so the
  two together average 24 × 24 = 576 evenly spaced points for 48 reads a
  pixel, smooth even on long streaks. Zoom's points are evenly spaced in
  the log of their distance from the center, since a zoom scales
  distances rather than adding to them.
- **Tilt-Shift** and **Surface Blur** blur across, then down, at most 32
  reads either side, spaced further apart for a wide blur. A Gaussian
  splits this way exactly; a varying blur and a bilateral filter only
  nearly, which doesn't show.

With nothing to blur (a Radius, Amount or Angle of 0) there are no passes.

## Not built

- Channel Blur (each of red, green, blue and alpha its own radius) and a
  blur by a dropped picture or an earlier step's (a variable blur map,
  like `CIMaskedVariableBlur`): a package's filter takes only numbers,
  so the map would need a kernel of its own.
- A threshold for Unsharp Mask, which `CIUnsharpMask` doesn't have.
- An Amount mixing a filter blur with the picture: Amount mixes in the
  kernel, before the filter, so the filter blurs have none, and their
  size is their strength.

## Testing

`BlurLookTests` draws each effect through the compositor on a small
known picture: every one at no blur is a no-op; a Gaussian spreads a dot
evenly; Directional Blur along its angle only; Zoom Blur along the
line to its center and Spin Blur along its circle; Lens Blur into a
disc with an edge; Tilt-Shift keeps stripes in its band and blurs them
away from it, turned with its Angle; Surface Blur smooths noise and
keeps an edge; Sharpen and Unsharp Mask raise contrast at an edge and
leave flat areas and the frame's edges alone; and Repeat keeps the
frame's corners while Transparent fades them.
`PackageLookTests.aFilterCanReadThePictureWithItsEdgesRepeating` checks
the filters' `"input": "clamped"`.
