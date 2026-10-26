# Stylize effects

Status: **built**. Twelve effect packages in the Stylize category of the
effects library, each a folder in
`Sources/AnimationMeetsVideo/Resources/Effects/` with one Metal kernel
(see [effect-packages.md](effect-packages.md)). They redraw the picture
as something else: a print, a mosaic, a painting, a drawing, a screen or
a worn film. Tests: `StylizeLookTests`.

Looks that already ship in other categories are not repeated here:
Posterize, Solarize, Neon Edges (Color), Dither, Grain, Static, Block
Glitch (Noise), Kaleidoscope and Mirror Tile (Distortion).

## The effects

In the library's order (`BuiltInEffects.libraryOrder`). Sizes are in the
timeline's pixels and scaled to the size a frame is drawn at, so a
preview at half size looks like the full frame. Colors set in a control
are Rec. 709 values, taken to the timeline's color space. Every one has
Amount, and at 0% leaves the picture as it is.

| Effect | Kernel | What it does | Controls |
| --- | --- | --- | --- |
| Pixelate | general | Square or hexagonal cells, each the average of the picture under it (not one sample, so it doesn't shimmer as the picture moves). The grid is laid out from Origin, the frame's middle by default. | Cell Size, Shape (Squares, Hexagons), Origin |
| Halftone | general | A printed screen: dots or lines of ink on paper, each cell's ink as large as the picture under it is dark (on a 2.2 gamma curve, as print screens are tuned). One ink, or CMYK with each ink on its own angle (cyan −30°, magenta +30°, yellow −45° from black) as presses set them. White stays paper, black solid ink. | Size, Pattern (Dots, Lines), Inks (One Ink, CMYK), Angle, Ink, Paper |
| Crystallize | general | A Voronoi mosaic: one seed point per cell of a grid, moved at random, each crystal the color under its point, with optional borders. Dots draws round dots of those colors over a background instead (pointillism). | Style (Crystals, Dots), Size, Randomness, Dot Size, Borders, Border & Background, Seed |
| Oil Paint | general | A Kuwahara filter: each pixel takes the average of whichever of the four squares meeting at it varies least, so flat areas smooth into strokes while edges stay sharp. Sharpness blends the squares by how even each is. At most 6 × 6 samples a square, so a large brush costs no more than a small one. | Brush Size, Sharpness |
| Cel Shade | general | Brightness in flat bands keeping each pixel's hue (Posterize bands each channel instead), after a little smoothing, with ink outlines where brightness changes by more than Threshold. | Bands, Outline, Threshold, Outline Color, Saturation |
| Find Edges | general | Edges drawn dark on white paper, where Neon Edges lights them over black: each channel's edges in its opposite color (Colored), gray pencil lines, or black ink where the edge passes Threshold. A flat picture is blank paper. | Style (Colored, Pencil, Ink), Width, Strength, Threshold |
| Emboss | general | The picture as a relief lit from Light: brightness is height, slopes facing the light lit and the rest shaded, over middle gray or the picture's colors. A flat picture stays flat. | Light, Height, Width, Coloring (Gray, Picture's Colors) |
| Scan Lines | color | A tube television: dark gaps between scan lines, an aperture grille's or slot mask's red, green and blue phosphors (which keep the average brightness), and a lighter band that rolls down the screen while Roll isn't 0. In linear light. | Line Size, Darkness, Mask (None, Aperture Grille, Slot Mask), Mask Strength, Roll |
| VHS | general | A worn tape: lines jittering sideways, color smeared to the right of detail, a band of bad tracking drifting down the frame, the bottom lines torn by the head switch, lifted blacks and noise streaks. New every frame. | Wear, Color Bleed, Tracking, Noise, Seed |
| Old Film | general | A projected print: toned black and white (sepia by default, or some of the picture's color kept), faded, flickering in brightness, weaving in the gate and darker toward the corners. New every frame. Pairs with Film Damage and Grain. | Tone, Color, Fade, Flicker, Gate Weave, Vignette, Seed |
| Film Damage | color | Scratches down the frame that last half a second to two, drifting and broken, and dust and hairs new every frame, dark (on the print), light (on the negative) or both. Sized to the frame's height. | Scratches, Dust, Hairs, Dirt (Dark, Light, Dark & Light), Size, Seed |
| Strobe | color | Flashes Rate times a second, each flash Length of its cycle: a color over the picture, the picture hidden, or its tones inverted. Never at Rate 0. | Rate, Length, Flash (Color, Hide Picture, Invert), Color |

## Why kernels and not Core Image's filters

Core Image has `CIPixellate`, `CIHexagonalPixellate`, `CIDotScreen`,
`CILineScreen`, `CICMYKHalftone`, `CICrystallize`, `CIPointillize`,
`CIEdges`, `CIEdgeWork` and `CIComicEffect`, and a package could list
them in `after`. None is used, because a filter in `after`:

- applies in full whatever Amount is, since Amount mixes only the
  kernel's result, so Amount can't fade it in or out;
- works on the encoded values, not the timeline's tones or linear light,
  so it looks different in PQ and HLG timelines;
- lays its grid out from the canvas's corner, so it shifts when the
  picture is drawn at another size or moved, where these lay theirs out
  from the frame's middle;
- samples one point per cell (`CIPixellate`, `CICrystallize`), which
  shimmers as the picture moves; these average the cell.

## Moving pictures and flashing

- **New every frame**: VHS, Old Film and Film Damage are
  `changesEveryFrame`, so the renderer never reuses a frame of them. The
  same frame drawn twice is the same picture, as each is seeded from the
  frame's time and Seed.
- **Moving on their own**: Scan Lines' Roll and Strobe's Rate are rates
  (`"rate": true`), so a clip with them is drawn afresh only while they
  aren't 0.
- **Flashing** (see [Safety](psychedelic-effects.md#safety-flashing)):
  Strobe warns above three flashes a second (`abs(strobeRate) > 3`), and
  Old Film above 50% Flicker, which changes the whole frame's brightness
  every frame. Both defaults stay below.

## Tests

`StylizeLookTests` checks that each ships in Stylize in its order and
compiles, and on known pictures:

- every one at Amount 0% is a no-op and draws the picture unchanged;
- Pixelate makes uniform cells of its size, each the average under it,
  and hexagons make few colors;
- Halftone keeps white paper and black solid ink, and a light gray
  becomes ink and paper, for one ink and CMYK, dots and lines;
- Emboss of a flat picture is flat (gray, or the picture in color), and
  lights the edge facing the light;
- Find Edges leaves flat areas as paper and draws an edge dark, in each
  style;
- Cel Shade bands a gradient and outlines an edge;
- Oil Paint and Crystallize keep a flat picture, and Oil Paint keeps an
  edge sharp;
- Scan Lines repeats every line and is still unless it rolls;
- VHS, Old Film and Film Damage draw the same frame the same each time
  and a new picture the next frame, and are marked so;
- Strobe is on for its Length of each cycle, and Strobe and Old Film
  carry the flashing note only past their limits.

## Not yet

- **Lens curvature for Scan Lines**: a tube's bulge needs a warp, and a
  package has one kernel. Stack Twirl's Bulge before it for now.
- **Pixel sorting** stays under [Not yet in
  psychedelic-effects.md](psychedelic-effects.md#not-yet).
