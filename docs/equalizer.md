# Equalizer

Status: **planned, not implemented**. A parametric EQ on every clip with
sound and every Sound and Music layer, edited on a graph with a live
spectrum behind it, applied in playback and export by the taps that
already apply volume ([audio.md](audio.md#playback-and-export)).

## Why not Logic Pro's Channel EQ

The app has no EQ today, so there is nothing to keep. Logic Pro's Channel
EQ can't be borrowed: Logic's own plug-ins ship inside the Logic app and
aren't registered as system Audio Units, so no other app can load them,
and copying their interface would copy Apple's design. What macOS does
offer to any app:

| Option | What it gives | Why or why not |
| --- | --- | --- |
| `AUNBandEQ` (`AVAudioUnitEQ`) | Up to 16 bands of parametric, shelf, pass and stop filters. | Only a generic slider view, and its exact filter shapes aren't documented, so a graph drawn by the app could disagree with what is heard. It also runs in `AVAudioEngine`, not in the composition's audio mix, so it would need an Audio Unit hosted inside each tap. |
| `AUGraphicEQ` | 10 or 31 fixed bands. | A graphic EQ, not the parametric kind the request describes. |
| Accelerate's `vDSP_biquadm` | Multichannel cascades of biquad filters, with coefficient ramps built in. | **Chosen.** The app computes each band's coefficients itself, so the graph is exactly the filter heard; it runs inside the existing `AudioLevelTap` with no extra Audio Unit; and `vDSP_biquadm_SetTargetsDouble` ramps to new coefficients over a buffer, so dragging a band or playing keyframes doesn't click. |

The layout follows the channel-strip convention that Logic, Final Cut
Pro and most DAWs share: a cut and a shelf at each end and parametric
bands between, over a spectrum. That convention is common to the field,
not Logic's.

## Bands

Eight bands, each off until touched, in this order:

| Band | Type | Default frequency | Choices |
| --- | --- | --- | --- |
| 1 | Low Cut | 30 Hz | Slope 6, 12, 24 or 48 dB per octave |
| 2 | Low Shelf | 100 Hz | |
| 3–6 | Bell | 250 Hz, 800 Hz, 2.5 kHz, 6 kHz | |
| 7 | High Shelf | 10 kHz | |
| 8 | High Cut | 18 kHz | Slope 6, 12, 24 or 48 dB per octave |

- **Frequency** 20 Hz to 20 kHz, **Gain** −24 to +24 dB (shelves and
  bells), **Q** 0.1 to 18 (bells; shelves and cuts take it as resonance).
- Coefficients are the Audio EQ Cookbook's (Robert Bristow-Johnson's)
  formulas, recomputed for each track's sample rate. A cut steeper than
  12 dB per octave is a cascade of second-order sections, so 48 dB is
  four.
- **Output** gain −24 to +24 dB after the bands, for matching loudness.
- Every band's on state, frequency, gain and Q, and Output, is keyframed
  like any control, in the clip's source time (a layer's in its
  timeline's). That is what the [Keyframing](keyframing-effects.md)
  effects can drive: an Audio Keys or Wiggler on a bell's frequency is a
  filter sweep.

**Order in the sound's path**: EQ, then the clip's volume, then the
layer's EQ and the layer's volume, then those of the nested clips and
layers it sits in, as a channel strip's EQ comes before its fader.

## The graph

The EQ opens in the effects panel from an **EQ** row above Volume (with
the Volume row, the panel's sound section), and in a larger sheet from
that row's expand button.

- **Axes**: frequency on a log scale, 20 Hz to 20 kHz, labeled at 50,
  100, 200, 500, 1k, 2k, 5k, 10k; gain −24 to +24 dB with a line at 0.
- **Curves**: each band's response faintly in its color, and the sum in
  bold. They are computed from the same coefficients the tap uses: the
  magnitude of each biquad at 256 log-spaced frequencies, in a few
  microseconds, so the curve follows the drag exactly.
- **Nodes**: one dot per band, at its frequency and gain (on the 0 line
  for cuts). Drag to move both; ⌥-drag or scroll to change Q, ⇧-drag to
  move along one axis; double-click to switch the band on or off.
  Dragging a band that's off turns it on.
- **Spectrum**: the sound under the playhead behind the curves, while
  playing, after the EQ (**Pre** in the graph's menu shows it before).
  The tap already measures each buffer for the meter; it also writes the
  samples into a ring buffer that a 4096-point FFT (`vDSP.FFT`, as
  `OnsetAnalyzer` uses) reads 30 times a second, smoothed with the
  meter's ballistics.
- **Band strip** under the graph: for each band, its on switch, type,
  and frequency, gain and Q fields (typing arithmetic works, as in every
  numeric field), with the keyframe stopwatch and diamonds as on other
  rows.

### Accessibility

Following [accessibility.md](accessibility.md): the graph is one
accessibility element per band, named "Band 3, Bell, 800 hertz, plus 4
decibels", with adjustable actions for gain and custom actions for
frequency up and down and Q wider and narrower. With a band focused, the
arrow keys move its frequency (left, right, by a twelfth of an octave)
and gain (up, down, by 0.5 dB), and ⌥ with them changes Q. Everything a
drag does is reachable from the band strip's fields.

## Playback and export

`AudioLevelTap` gains a filter stage before its gain: for each volume
stage of a track (`VolumeStage`) that has an EQ, one `vDSP_biquadm`
setup with as many sections as that EQ's active bands need, for the
track's channel count. Like volume curves, EQ settings live in a shared
store the editor replaces as they change, so an edit is heard at once and
EQ is left out of `CompositionKey`. On each buffer the tap reads the
settings at the buffer's time and, if they changed, sets new targets;
the ramp over the buffer keeps keyframed sweeps smooth. An EQ with every
band off costs nothing.

A clip with an EQ of its own gets a composition audio track of its own,
as a clip with a volume of its own does today.

## Saving

Written only when some band is on, as part of the clip's or layer's
entry:

```json
"eq" : { "bands" : [ { "band" : 4, "type" : "bell", "frequency" : { "value" : 800 }, "gain" : { "value" : 4 }, "q" : { "value" : 1.2 } } ] }
```

Values outside their ranges are clamped on load. Bands not listed are
off, at their defaults.

## Testing

- Each band type's computed response against the cookbook formulas, and
  against white noise filtered through `vDSP_biquadm` and measured by FFT,
  within 0.1 dB, at 44.1, 48 and 96 kHz.
- All bands off passes samples through unchanged.
- A keyframed sweep rendered through the tap has no step larger than the
  ramp allows (no clicks).
- Export of a clip with an EQ matches playback, through
  `AVAssetReaderAudioMixOutput` as the volume tests read the mix.
- A UI snapshot of the graph with a few bands on.

## Not yet

- Linear-phase filtering, dynamic EQ and a match EQ.
- Presets for EQ settings (until then, copy and paste the row).
- A spectrum while paused, of the sound around the playhead.
