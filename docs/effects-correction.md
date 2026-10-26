# Color Correction effects

Status: **built**. Twelve effects in the library's Color Correction
category, each an effect package with a color kernel
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

All are per-pixel color kernels: they don't read beside a pixel
(`EffectKind.readsBesidePixels` is false), so opacity and shapes above
them aren't settled first, and they cost little while the viewer plays.

## The effects

| Effect | ID | Controls | What it does |
| --- | --- | --- | --- |
| Levels | `levels` | Channel (RGB, Red, Green, Blue), Input Black, Input White, Gamma, Output Black, Output White | Tones from Input Black to Input White stretched to the whole range, bent by Gamma (above 1 brightens the midtones: a quarter goes to a half at 2), then fitted between Output Black and Output White, in all channels or one. Tones past the input white carry on along the same line. Defaults change nothing. |
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

## Not yet

- **Curves**: a tone curve needs a curve editor in the effects panel,
  which packages can't describe.
- **Color Balance** by shadows, midtones and highlights: the Color
  effect's lift, gamma and gain already are one.
- **Picking a color from the viewer** for Gray Point and Hue Range, with
  an eyedropper.
- **A local Highs & Lows**, adapting to the picture around each
  pixel, which needs a blur and so a general kernel or filters after it.
