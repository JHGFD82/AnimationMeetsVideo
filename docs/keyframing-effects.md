# Keyframing effects

Status: **planned, not implemented**. A new **Keyframing** category in the
Effects Library: effects that draw nothing and instead write keyframes
onto other controls, from a sound (Audio Keys, as Trapcode Sound Keys
does in After Effects), from a song's beats, from noise (Wiggler, as
After Effects' Wiggler) or from the control's own keyframes (Smoother,
Looper).

## The idea: they write real keyframes

The app has no expressions, and should not need them for this. A
Keyframing effect **generates ordinary keyframes** on a target control.
Everything else already works with those: the graph editor, eases,
copying, saving, the render key and the render cache, and the audio taps
for a volume or EQ target. Drawing, playback and export need no new path,
and a project opened elsewhere plays the same.

What makes them effects rather than one-off commands is that each keeps
its settings and what it was made from, so its keyframes can be made
again:

- **Live while editing.** Changing a setting regenerates at once (in a
  background task, replacing the target's keyframes when done), so the
  sliders feel like a live link.
- **Out of date** when what it read changes (the sound's media is
  replaced, the source clip is moved or its volume changed, the beat map
  edited): the effect's row says so, and regenerates by itself unless the
  generated keyframes were edited by hand, in which case it asks first
  (**Regenerate** or **Keep Edits**).
- **Bake** in its ⋯ menu removes the effect and leaves the keyframes as
  plain keyframes.

Generated keyframes are marked with the effect's ID in the target's
keyframes, so regenerating replaces only its own, between the effect's
**start and end** (the clip by default; set from the panel's ruler like a
range). Keyframes outside that range are kept.

## Where they sit: gravity again

Following [effects.md](effects.md#guiding-principle-gravity), a Keyframing
effect acts on what is below it: its **Target** lists every numeric
control of the effects below it in the same stack, plus the clip's Volume
and [EQ](equalizer.md) bands, as Blending's Against lists the effects
above. Dragging the effect below its target, or deleting the target,
dims it with a note until it's pointed somewhere else, and leaves the
keyframes it made.

- **One component or all**: a Position or Scale target can take x, y or
  both (with Wiggler, both move apart).
- **To animate several clips together**, put the effects on an
  adjustment clip or a nested clip, as for any effect.
- **Compositing**: Keyframing effects are skipped by the compositor and
  the taps (they have no picture or sound); in the panel they show a small
  curve icon instead of a thumbnail.

### How the result meets the target

- **Replace**: the target's value is the generated one.
- **Add** (the default): the generated value is added to the target's
  value as it was before generating, so a wiggle rides on a hand-made
  move. The effect remembers that base curve, so regenerating adds to
  the original rather than to the last result.
- **Multiply**: for scales, opacities and gains, where a pulse should
  scale what's there.

### How many keyframes

Generators that follow a signal (Audio Keys, Wiggler at high rates)
evaluate it once per frame of the clip's timeline, then **reduce**: the
Ramer–Douglas–Peucker algorithm drops every keyframe the line through its
neighbors passes within **Tolerance** (0.5% of the output range by
default) of, and the kept keyframes get linear or Auto Bézier eases. A
three-minute song typically keeps a tenth of its frames. Generators with
a natural rate (Beat Keys, Oscillator, Wiggler at low rates) write one
keyframe per event with eases, as an animator would.

Keyframes are in the clip's source time; a retimed clip's frames are
mapped through its speed curve (`ClipTime`) so a pulse lands on the beat
as heard, not as stored.

## The kinds

| Kind | What it makes | Settings |
| --- | --- | --- |
| **Audio Keys** | Follows how loud a range of frequencies is in a sound: kicks, hi-hats, a vocal. | Source, frequency range, amplitude range, attack and release, output range, see below |
| **Beat Keys** | A pulse on each beat of a beat map: up at the beat, back over a decay. | Beat map (from a Sound or Music layer), every N beats (1), offset, downbeats only, accent on the one (+50%), shape: pulse, step, ramp or alternate; peak; decay |
| **Wiggler** | Random, organic movement around the current value. | Frequency (wiggles per second, 2), magnitude, type: smooth (Perlin) or jagged, octaves (1), dimensions: independent or together, seed |
| **Oscillator** | A regular wave. | Wave: sine, triangle, square or sawtooth; frequency in Hz or beats; amplitude; phase; ease in and out over the range |
| **Smoother** | Smooths the target's existing keyframes, and thins them. | Strength (frames of averaging), tolerance |
| **Looper** | Repeats the target's keyframes past their end (or before their start). | Mode: cycle, ping-pong, offset (each cycle continues from the last), continue (at the last speed) |
| **Time Step** | Holds each value for N frames, for a stop-motion or "on twos" look. | Hold (2 frames) |
| **Overshoot** | Adds spring bounce after each keyframe of the target, as if the move had weight. | Stiffness, damping, mass |

Smoother, Looper, Time Step and Overshoot read the target's own keyframes
(the base curve above), so they are not out of date until those change.

## Audio Keys in detail

The panel shows the sound's **spectrum** at the playhead, frequency on a
log scale across and level up, and a **box** on it: its left and right
edges are the frequency range, its bottom and top the amplitude range.
Drag the box or its edges, as in Sound Keys; three boxes can be on at
once, each its own output, so one effect can drive kick, snare and hats
onto three targets.

For each output, at every frame:

1. **Level**: the energy in the frequency range, in decibels.
2. **Range**: below the box's bottom reads 0, above its top 1, linear in
   decibels between (a gate and a ceiling in one).
3. **Envelope**: rises at most at the **attack** speed and falls at the
   **release** speed (defaults 0 ms and 200 ms), so it hits fast and
   lingers.
4. **Output range**: 0 to 1 is mapped to two values in the target's units
   (Scale 100% to 130%, say), along a curve (linear, ease, or a
   threshold that makes a trigger).

**Source**: a Sound or Music layer, one audio clip, or the whole mix, of
this timeline. Each source's sound is taken as heard, with its volume
and EQ.

### Analysis

Recomputing an FFT every time a slider moves would be slow on a long
song, so the expensive part is done once per audio file and kept:

- A **spectrogram** per asset: 48 bands, log-spaced from 20 Hz to
  20 kHz, every 1/50 s (a 4096-point `vDSP.FFT` with a Hann window, hop
  20 ms, more than a frame's resolution at 30 fps). Each band's level is
  one byte, in half-decibel steps from −128 dB to 0 dB, so a file costs
  2.4 KB per second of sound: about 430 KB for a three-minute song,
  8.6 MB per hour. It is computed by `AssetAnalysis` in
  the background with the waveform and beats, and stored with them as
  disposable data, in the asset's time, so moving or trimming a clip
  doesn't recompute it.
- For a source of several clips, each clip's spectrogram is placed on
  the timeline in its time, scaled by its volume curve, and by its EQ's
  magnitude at each band's center frequency; layers are summed as
  power. A frequency range sums the bands it covers (part of a band at
  each edge).
- From there, the rest of the steps above are a few arithmetic
  operations per frame: a three-minute song at 30 fps is 5,400 values,
  done in well under a millisecond with vDSP. So the box and every
  slider regenerate the keyframes as fast as they're dragged.

## The library and the panel

The Effects Library lists a **Keyframing** category after Mattes
(`EffectCategory.keyframing`), with a chip per kind, dragged onto a clip
or into the stack like any effect. Dropped on a clip, a new Keyframing
effect goes to the top of the stack and targets the first numeric control
below it; dropped into the stack, it targets the first below where it
lands.

In the panel its row has the Target picker, Combine, and the kind's
settings, and the target's keyframe lane highlights the keyframes it made
in its own color. VoiceOver reads the row as "Wiggler, driving Transform
Position, 48 keyframes", and every setting, the Audio Keys box included,
has fields as well as drags (the box as four frequency and level fields).

## Saving

The effect is saved with its kind, settings, target (by control ID),
combine mode, range, the base curve for Add and Multiply, and a
fingerprint of what it read (the asset's signature, the source clips'
placements and volume and EQ, or the beat map's revision). The generated
keyframes are saved on the target as usual, with `"generatedBy"` holding
the effect's ID. A project opened by an app that ignores Keyframing
effects still plays the same.

## Testing

- Each kind against hand-worked curves: Oscillator's values at known
  times, Beat Keys' keyframe times against a beat map, Looper's modes,
  Time Step's holds.
- Wiggler with the same seed gives the same keyframes; a new seed
  doesn't.
- Reduction keeps every frame's value within tolerance of the unreduced
  curve.
- Audio Keys on generated tones (a 60 Hz burst and a 5 kHz burst on one
  track) moves only the box over its tone, at the bursts' times, with the
  attack and release asked for.
- Regenerating after an Add keeps the original base; after hand edits it
  asks first; a removed target leaves its keyframes.
- A clip at 50% speed gets its beat pulses on the beats as heard.

## Not yet

- Expressions, or linking a control to another live.
- Driving a control on another clip directly, without an adjustment or
  nested clip.
- Audio Keys from a sound that isn't on the timeline (an input from the
  browser).
- Motion Sketch: recording a mouse path as Position keyframes.
