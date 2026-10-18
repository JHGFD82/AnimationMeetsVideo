# Equalizer

Status: **implemented**: the EQ sound effect's eight bands, its filters in
playback and export, the graph with its live spectrum, keyboard and
VoiceOver access, and loading EQs saved before it had bands. The filters,
curves, migration and spectrum are unit tested (the filters against the
drawn curve, through real buffers); the graph has a UI snapshot but has
not yet been driven on screen. What remains is under [Not yet](#not-yet).

The EQ is one of the [sound effects](audio.md#sound-effects) of a clip,
or of a Sound or Music layer (see [On layers](audio.md#on-layers)): it
goes in the sound's stack from the library's Sound category, can be used
more than once, reordered, switched off, copied and saved in presets,
and plays before the clip's volume and pan, as a channel strip's EQ
comes before its fader.

## Why not Logic Pro's Channel EQ

Logic Pro's Channel EQ can't be borrowed: Logic's own plug-ins ship inside
the Logic app and aren't registered as system Audio Units, so no other app
can load them. What macOS offers any app:

| Option | What it gives | Why or why not |
| --- | --- | --- |
| `AUNBandEQ` | Up to 16 bands of parametric, shelf, pass and stop filters. | What the EQ first used. Its exact filter shapes aren't documented, so a graph drawn by the app could disagree with what is heard. |
| `AUGraphicEQ` | 10 or 31 fixed bands. | A graphic EQ, not a parametric one. |
| The app's own biquads | Second-order sections with the Audio EQ Cookbook's coefficients. | **Chosen.** The graph and the filters use the same coefficients, so the curve is exactly what is heard, and the coefficients can glide within a buffer. Eight bands in stereo at 48 kHz is a few hundred thousand multiply-adds a second, so writing the loop out costs nothing worth Accelerate's `vDSP_biquad` setups. |

The layout follows the channel-strip convention Logic, Final Cut Pro and
most DAWs share: a cut and a shelf at each end and bells between. That
convention is common to the field, not Logic's.

## Bands

Eight bands, each off until switched on, then a slope for each cut and
an output gain, in this order in the effects panel:

| Band | Shape | Default frequency | Default Q |
| --- | --- | --- | --- |
| Low Cut | high-pass | 30 Hz | 0.71 |
| Low Shelf | shelf | 100 Hz | 0.71 |
| Bell 1–4 | peak | 250 Hz, 800 Hz, 2.5 kHz, 6 kHz | 1 |
| High Shelf | shelf | 10 kHz | 0.71 |
| High Cut | low-pass | 18 kHz | 0.71 |

- Each band is one control (`EqualizerBand`): a cut's components are its
  **frequency** and **Q**, a shelf's or bell's its frequency, **gain** and Q.
  The control's on switch is the band's. Its components keyframe together,
  in the clip's source time, with the usual eases and graph editor.
- **Frequency** 20 Hz to 20 kHz, **gain** −24 to +24 dB, **Q** 0.1 to 18.
  On a cut, Q is resonance: above 0.71 it bumps up before it falls.
- **Low Slope** and **High Slope** set each cut to 6, 12 (the default), 24
  or 48 dB per octave. Steeper than 12 is a Butterworth cascade whose last
  section takes the band's Q; 6 is first-order and ignores Q.
- **Output**: −24 to +24 dB after the bands.
- Coefficients are the Audio EQ Cookbook's (Robert Bristow-Johnson's),
  computed for the track's sample rate, with frequencies kept under
  0.49 of it.
- A new EQ, or one whose bands are all off or at 0 dB, changes nothing and
  is dimmed. A cut always counts, wherever it sits. A cut's slope row is
  dimmed while its band is off.

Controls whose components measure different things now say so:
`ControlKind.unit(ofComponent:)`, `range(ofComponent:)` and
`dragStep(ofComponent:)` give each its own, used by the panel's fields
and the graph editor. A band's row reads "800 Hz, 4 dB, 1".

## The graph

Above an EQ's band rows, beside an empty lane (`EqualizerGraph`); its
expand button shows it larger in a sheet, with a field for every band's
frequency, gain and Q, each cut's slope and the output
(`EqualizerBandStrip`). On a layer it is in the inspector, with the same
fields under it.

- **Axes**: frequency on a log scale from 20 Hz to 20 kHz, labeled at 50,
  100, 200, 500, 1k, 2k, 5k and 10k; gain from −24 to +24 dB with a line
  at 0.
- **Curves**: each band that's on as a faint line and fill in its color,
  and the whole EQ in bold, from the same coefficients the filters use
  (`Equalizer.response`).
- **Dots**: one per band, at its frequency and gain (a cut's on 0 dB),
  filled when on and hollow when off. Drag one to move its frequency and
  gain; ⌥-drag up or down, or scroll over it, to narrow or widen its Q (an
  octave per 40 points dragged, or 120 scrolled; a scroll is one undo once
  it stops, and scrolling anywhere else scrolls the panel); ⇧-drag to move along one axis. Dragging a band that's off turns
  it on, and double-clicking one switches it on or off. A drag is one
  undo. While the band is keyframed, a drag sets a keyframe at the
  playhead, as editing its fields does.
- **Spectrum**: behind the curves, the sound at the playhead while it
  plays, after the EQ (the default) or before it, or off, from the
  waveform button; the choice is remembered per Mac. It reads from 0 dBFS
  at the top to −90 at the bottom, rising at once and falling at the
  meter's 24 dB a second.

### How the spectrum is read

The EQ's filter records each buffer, summed to mono, before and after
filtering (`EqualizerSpectrum`), stamped with the clip's source time it
plays at, about 1.4 s of it. Players decode ahead of what is heard, so the
graph doesn't take the newest samples: 30 times a second it takes the
4096 that end at the playhead's source time, windowed with a Hann window
and run through an FFT (`vDSP_fft_zrip`, as beat detection does). With
nothing recorded at that moment (paused, or scrubbed somewhere not yet
played), and the playhead and settings still for 200 ms, a media clip's
spectrum is read from its file instead: a quarter second ending at the
playhead (its source time plus the asset's alignment offset), mixed to
mono at 48 kHz and, after the EQ, run through a copy of it. That reading
leaves out the effects above the EQ and the clip's volume. A nested
timeline, a generated clip or an EQ on a layer has no one file, so its
spectrum falls away while paused. Only EQs whose graph is showing record,
so other tracks and exports don't pay for it. An EQ on a nested
timeline's clip runs on each track inside it, so its spectrum shows
whichever track played last.

### Keyboard and VoiceOver

Following [accessibility.md](accessibility.md): clicking a dot picks its
band and focuses the graph; Tab and ⇧Tab step through the bands. The
left and right arrows move the picked band's frequency by a twelfth of
an octave, up and down its gain by 0.5 dB, and ⌥ with up and down its Q
by a sixth of an octave. VoiceOver reaches each band as an element of its
own ("Bell 2, on, 800 hertz, 4 decibels, Q 1"), adjusting its gain (a
cut's frequency), with actions to switch it on or off, raise or lower its
frequency, and narrow or widen it. Every value is also a field in the
band's row.

## Playback and export

Each EQ is run by `EqualizerFilter`, which the track's tap makes in place
of an Audio Unit (`SoundEffects.processor`), on the same footing as the
compressor, limiter and voice isolation (see
[audio.md](audio.md#sound-effects)): settings are read from `MixCurves`
as each buffer plays, so edits and keyframes are heard without rebuilding
the player, and a jump in time clears the filters' memory.

The filter reads the settings at the buffer's start and end. When they
differ (a keyframed sweep, a drag) it rebuilds the coefficients every 32
frames along the way, frequencies and Qs moving on a log scale and gains
in decibels, instead of once per buffer, which would step audibly. The
sections run in doubles (transposed direct form II), and tiny values left
in their memory are cleared after each buffer so silence doesn't slow
them. Switching a band on or off changes which sections run, so they
start from silence. A flat EQ is skipped. The EQ doesn't look ahead, so
it adds no delay.

## Saving

Each band is a control in the effect's entry, as for any effect, written
with `"enabled": false` while off:

```json
{ "id" : "…", "kind" : "eqBell2", "value" : [800, 4, 1] }
```

EQs saved before bands, with `lowCut`, `bass`, `mid`, `midFrequency` and
`treble` controls, load as the bands they sounded like
(`Equalizer.controls(migrating:)`): the low cut as a 12 dB Low Cut (off if
it sat at 20 Hz, as it was then), bass as the Low Shelf at 100 Hz, the mid
as Bell 2 an octave wide (Q 1.41) at the mid frequency, and treble as the
High Shelf at 8 kHz, keeping their IDs, keyframes and eases. A mid whose
gain and frequency were keyframed apart gets keyframes at the times of
both. They're saved as bands from then on. The old filters were Apple's,
so the shelves' shapes differ slightly from before.

## Testing

- Each shape's response: a bell's gain at its center, shelves half their
  gain at their frequency, cuts 3 dB down at theirs and their slope an
  octave past it, a resonant cut's bump, the whole curve as the sum.
- What the filter does to a sine against the drawn curve, within 0.1 dB,
  for every shape at 44.1, 48 and 96 kHz; a flat EQ passes sound
  unchanged.
- Settings: bands that are on, slopes, ranges, per-component units, and
  sweeps on a log scale.
- Migration of old controls, static and keyframed, and loading an old
  project file and saving it again as bands.
- The spectrum shows a recorded tone in its bin near 0 dBFS, and nothing
  for a moment not played or an EQ not watched.
- Playback through a composition's audio mix: a high shelf cuts a high
  tone and leaves a low one.
- A UI snapshot of the graph.

## Not yet

- Linear-phase filtering, dynamic EQ and a match EQ.
- A spectrum while paused for a nested timeline or a layer's EQ.
- A layer EQ's spectrum mixes the layer's tracks: each records into the
  same place, so it shows whichever played last.
