# Color Correction effects

Status: **built**. Thirteen effects in the library's Color Correction
category, each an effect package with a color kernel, or for Curves a
general one that reads only its own pixel
(`Sources/AnimationMeetsVideo/Resources/Effects/`, see
[effect-packages.md](effect-packages.md)), listed in
`BuiltInEffects.libraryOrder` after the Mattes. They are the corrections
an editor expects beyond the Color effect of the Foundations (exposure,
contrast, saturation, temperature, tint, lift, gamma and gain), which
they don't repeat; the looks of the Color category (Hue Cycle, Gradient
Map, Posterize, Channel Mixer and the rest) are for changing a picture's
colors outright rather than correcting them.

## Where they work

Like the looks, each reads the picture as the timeline encodes it and
works on **tones**: ACEScct's log curve scaled so black is 0 and
reference white 1 (100% on Rec. 709, 203 nits on PQ, a 75% signal on
HLG), the prelude's `toTones` and `fromTones`. So a correction looks the
same in an SDR and an HDR timeline, and a percentage of the tones is the
same place on either. HDR highlights are tones above 1; the effects
carry them on rather than clip them, except where clipping is the point
(Threshold, Broadcast Safe). Gray Point and Broadcast Safe work in
linear light instead, since white balance and light limits are about
light. Every one has the standard Amount, and mixes by it in the
timeline's values; at 0% it isn't drawn.

All work on each pixel where it is: they don't read beside a pixel
(`EffectKind.readsBesidePixels` is false), so opacity and shapes above
them aren't settled first, and they cost little while the viewer plays.
Curves's kernel is a general one only to read its curves' tables;
`perPixel` says it reads the picture only at the pixel it draws.

## The effects

| Effect | ID | Controls | What it does |
| --- | --- | --- | --- |
| Levels | `levels` | Channel (RGB, Red, Green, Blue), Input Black, Input White, Gamma, Output Black, Output White | Tones from Input Black to Input White stretched to the whole range, bent by Gamma (above 1 brightens the midtones: a quarter goes to a half at 2), then fitted between Output Black and Output White, in all channels or one. Tones past the input white carry on along the same line. Defaults change nothing. |
| Curves | `curves` | RGB, Red, Green, Blue (curves) | Each channel's tone through the RGB curve, then through its own channel's curve. Each curve's points are joined smoothly without overshooting between two (see [effect-packages.md](effect-packages.md#curves)); tones past white carry on along the slope of a curve's last stretch, so HDR highlights aren't clipped. Straight curves, the default, change nothing. Edited on its [tone graph](#tone-graphs). |
| Highs & Lows | `shadowsHighlights` | Shadows, Highlights (−100 to 100%), Shadow Range, Highlight Range | Lifts or deepens the darkest Shadow Range of the tones, and brightens or recovers the brightest Highlight Range below white, by a smooth bump that is zero at black, at white and past its range, gentle enough that the tones keep their order. Each pixel moves by its brightness, all channels together, which on the log curve keeps its color. Per pixel, not a local tone mapper. |
| Hue/Saturation | `hueSaturation` | Hue (°), Saturation, Lightness (−100 to 100%) | Turns every hue around the gray axis, scales each color's distance from its gray (−100% is gray), then takes the tones toward black or white (toward white only below it, so HDR highlights stay). |
| Vibrance | `vibrance` | Vibrance (−100 to 100%), Protect Skin Tones | Saturation weighted by how muted a color is, so dull colors come up and vivid ones barely move; raising it spares hues near 25° (skin) by Protect Skin Tones. |
| Hue Range | `hueRange` | Hue, Width, Softness (°), Hue Shift, Saturation, Lightness, Show (Result, Range) | Hue/Saturation for the colors near one hue only: fully within Width of Hue, fading across Softness beyond, and less as a color nears gray, so grays are never touched. Show Range draws the selection, white where fully changed. |
| Gray Point | `grayPoint` | Make Gray (a color) | White balance from a color that should be gray: each channel's light is scaled so that color becomes the gray of its brightness, and everything else by the same. The color is in the timeline's values, as a shape's fill. Gray, the default, changes nothing. |
| Black & White | `blackAndWhite` | Reds, Yellows, Greens, Cyans, Blues, Magentas (−200 to 300%) | A gray from each color, weighting how much of each of six hues it holds: its lowest channel counts as is, the step to its middle channel as the secondary hue between its two highest, the step to the highest as that primary. A gray keeps its tone, pure red becomes Reds, pure yellow Yellows. The defaults are Photoshop's (40, 60, 40, 60, 20, 80). |
| Colorize | `colorize` | Hue (°), Saturation | One hue over the picture's brightness: each pixel the HSL color of that hue and saturation whose lightness is its tone. Black and white stay. |
| Sepia | `sepia` | Warmth | An old print's brown, from red-brown in the shadows to cream in the highlights, Warmth saying how strongly. |
| Invert | `invert` | Channels (RGB, Red, Green, Blue, Brightness) | A negative: each tone turned end for end, black for reference white, in all channels, one, or only the brightness (light and dark swap, hues stay). Inverting twice gives the picture back. |
| Threshold | `threshold` | Level, Softness, Channels (Brightness, Each Channel) | Black below Level, reference white above, by brightness or each channel; Softness ramps between them across that much of the tones. |
| Broadcast Safe | `broadcastSafe` | Brightest (% of reference white), Most Saturated, Bring In By (Desaturating, Clipping) | Keeps each pixel's light between black and Brightest and its saturation (highest less lowest channel, over highest, in linear light) at most Most Saturated. Desaturating moves an out-of-range color toward the gray of its brightness only as far as needed, keeping its hue; Clipping cuts each channel on its own. In range, nothing changes. Brightest is 100% for SDR; on an HDR timeline raise it to the master's peak (about 493% for 1000 nits on PQ), or it clips the highlights to reference white. |

## Tone graphs

Status: **built** (`ToneGraph`, in the effects panel above an effect's
controls). A graph of tones, black to white across, what they become
up, for an effect whose package has a `graph`
([effect-packages.md](effect-packages.md#graph)):

- **Curves** draws its four curves, the one picked in the RGB, Red,
  Green and Blue picker bold with its points, the others faint in their
  colors. Drag a point to move it, between its neighbors; click where
  there is none to add one there, or drag from there to add and move it;
  double-click a point, or pick it and press Delete, to delete it. Add
  Point (or +) puts one in the widest gap. Dragging a curve that is off
  turns it on. With keyframes, a point dragged between them makes a
  keyframe, and one added or deleted is added to or deleted from every
  keyframe.
- **Levels, Threshold, Highs & Lows and Solarize** draw what their
  kernels do to each tone, measured by drawing a row of grays through
  the effect (`ToneResponse`), so the line is the picture's, never a copy
  of the kernel's math that could drift from it; red, green and blue
  apart when they differ (Levels on one channel). Their handles sit on
  that line and move their controls:

  | Effect | Handles |
  | --- | --- |
  | Levels | Black (Input and Output Black, across and up), Gamma (across), White (Input and Output White) |
  | Threshold | Level (across), Softness (across, the top of the ramp) |
  | Highs & Lows | Shadows and Highlights, each at the top of its bump: across sets the range, up or down the amount |
  | Solarize | Threshold (across, where the tones fold) |

Picking a point or handle (a click, or Tab) shows its tones beside the
graph; the arrow keys move it a hundredth (a tenth with Shift). VoiceOver
reads each point and handle as an element, adjusting it moves it up or
down (a handle that only moves across, across), with actions to move it
across and to delete a point. A drag is one undo step, held to one side
of the project while it lasts, as an EQ band's is.

### What else could use it

Effects whose controls describe what happens to each tone gain the most
from a graph; these are the next candidates, roughly by how much a graph
would help:

- **The Color effect's Lift, Gamma and Gain**: three handles per channel
  and overall. It is written in Swift, so it needs a graph described in
  Swift rather than a package's `graph`, and its response measured
  through the Color step rather than a look's kernel.
- **Hue curves** (hue versus hue, saturation or brightness): Curves'
  editing on an axis that wraps around, which Hue Range's controls
  approximate. Needs a periodic curve and a hue axis on the graph.
- **A luma curve**, changing brightness while keeping each pixel's
  color, as a fifth curve for Curves.
- **Broadcast Safe's Brightest**: a ceiling handle, on a graph of light
  rather than tones.
- **Posterize, Invert and Dither** gain little: their response can be
  drawn with an empty `graph` today, but they have no control a handle
  could move usefully.

## Testing

`CorrectionLookTests` draws each effect on known tones in a Rec. 709 and a
PQ timeline and checks the numbers: Levels maps its black and white
points and gamma, one channel alone, and carries HDR tones past white;
inverting twice is the picture; Black & White has no color and weighs
each hue as listed; Hue/Saturation at −100% is gray and turns red to
green at 120°; Vibrance raises muted colors more than vivid ones and
spares skin; Highs & Lows keeps black, white and the tones' order;
Hue Range changes only its hues; Gray Point makes its color gray; Broadcast
Safe holds light and saturation to its limits in SDR and HDR. Each is a
no-op at 0% Amount, and Levels, Highs & Lows, Hue/Saturation, Vibrance,
Hue Range, Gray Point and Broadcast Safe at their defaults.

`CurvesLookTests` draws Curves on known tones in both timelines: straight
curves change nothing, the RGB curve maps every channel, each channel's
comes after it, HDR tones carry on past white, and it draws only over its
picture. It checks that Levels' and Highs & Lows' handles sit on the line
their kernels draw and set their controls as dragged (Levels' Gamma at a
quarter of the way is 2), and Threshold's and Solarize's levels.
`ToneCurveTests` checks the curve itself (through every point, no
overshoot, past its ends, editing across keyframes) and
`ToneGraphPackageTests` reading curves, curve pictures and graphs, and
each mistake in them.

## Not yet

- **Color Balance** by shadows, midtones and highlights: the Color
  effect's lift, gamma and gain already are one.
- **Picking a color from the viewer** for Gray Point and Hue Range, with
  an eyedropper.
- **A local Highs & Lows**, adapting to the picture around each
  pixel, which needs a blur and so a general kernel or filters after it.
- **A histogram behind the tone graph**, of the picture at the playhead,
  as the EQ's graph has a spectrum.
- **A larger tone graph** in a sheet, as the EQ has, for fine work.
