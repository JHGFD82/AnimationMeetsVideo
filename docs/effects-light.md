# Light effects

Status: **built**. Eight effects in the Light category of the effects
library, each a built-in [effect package](effect-packages.md) in
`Sources/AnimationMeetsVideo/Resources/Effects/`: Glow, Bloom,
Halation, Light Rays, Lens Flare, Light Leak, Spotlight and Vignette.
`LightLookTests` draws each through the compositor on a known picture.

## How they add light

Every one works in linear light, not on the timeline's encoded values:
a pixel is turned to light with the prelude's `toLinear`, light is
added or multiplied, and `fromLinear` encodes it again. So a glow in an
HDR timeline (PQ or HLG) adds as many nits as it would on set, and a
highlight above reference white glows brighter than white does.
Colors picked in a Color control are read as Rec. 709 values and
turned to light the same way.

Thresholds measure brightness as a Rec. 709 signal of the pixel's
luminance (white 1 in any timeline), so 60% picks the same highlights
in SDR and HDR, and every HDR highlight is past every threshold.

Added light covers what was clear: where the picture is transparent (a
title's surroundings) light makes its own alpha, so a glow reaches past
a layer's edges. The glows, Bloom, Halation and Light Rays draw over
the whole canvas for this reason; Lens Flare, Light Leak, Spotlight
and Vignette draw over the picture only.

## Passes

A package has one kernel and filters after it, and the glows need the
picture twice: the highlights to spread, and the picture to add them
to. They use what packages already have (no Swift of their own):

- `"repeat"` runs the kernel several times, each pass over what the one
  before drew, with `pass` telling the kernel which it is.
- A `moment` picture with a delay of 0 is the picture reaching the step,
  in every pass.
- An `after` filter's `when` can read `pass`, so a `CIGaussianBlur`
  runs after one pass only.

Glow's first pass keeps the light above its threshold, the blur after
it spreads it, and its second pass adds it over the picture. Bloom adds
the same light again before each of three blurs (its radius, a quarter
and a sixteenth), for a core and a long tail. Light Rays gathers along
the line to its source in two passes, 24 coarse steps and 16 finer ones
between them, for 384 samples at the cost of 40.

## The effects

| Effect | Controls | What it does |
| --- | --- | --- |
| Glow | Threshold, Radius, Intensity, Color, Amount | Highlights above the threshold, blurred and added back, tinted by Color. |
| Bloom | Threshold, Radius, Intensity, Saturation, Amount | A softer glow at three sizes at once, as light scattered in a lens; Saturation sets how much of the highlights' color it keeps. |
| Halation | Threshold, Radius, Intensity, Color, Amount | Film's red-orange fringe around highlights, added less where the picture is already bright, so it shows on the dark beside them. |
| Light Rays | Source, Length, Threshold, Intensity, Color, Amount | Rays streaming away from the Source point past the picture's bright parts, each reaching Length of the way from the source, fading along the ray. |
| Lens Flare | Source, Brightness, Size, Color, Streak, Reflections, Amount | A procedural flare at the Source point: core and halo, faint aperture spokes, a rainbow ring, an anamorphic streak, and seven reflections along the line through the frame's middle. |
| Light Leak | From, Size, Brightness, Color, Second Color, Speed, Seed, Amount | Soft washes of two colors coming in from one edge (From: 0° the left, turning clockwise), drifting while Speed isn't 0, burning toward white where strongest. Warns of flashing above 3/s. |
| Spotlight | Center, Size (width, height), Angle, Feather, Brightness, Surroundings, Color, Amount | An ellipse of light, turned by Angle, its edge soft over Feather; everything outside it lit only Surroundings. |
| Vignette | Size, Roundness, Feather, Center, Color, Amount | The frame's edges fading to Color (black darkens, white lightens) from Size outward over Feather; Roundness goes from the frame's rounded rectangle (0%) through its ellipse (50%) to a circle (100%). |

Sizes are in the timeline's pixels and scale with the picture drawn;
points are offsets from the frame's middle, as for the other effects.
At Amount 0 each draws the picture as it was.

## Not built

- **Light Wrap**, which blends the backdrop's light into a layer's
  edges, needs the picture of the layers below. Against only gives the
  clip's own picture before an earlier step, so it can't be a package
  yet.
