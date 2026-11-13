# Keyframing effects

Status: **built** (see [Building it](#building-it) for what each step
does and leaves out). A **Keyframing** category of effects that draw
nothing and instead write keyframes onto other controls, from a sound
(Audio Keys, as Trapcode Sound Keys does in After Effects), from a song's
beats, from noise (Wiggler, as After Effects' Wiggler) or from the
control's own keyframes (Smoother, Looper). They are picked for a control
in the [Keyframe Designer](#the-keyframe-designer), opened from an
effect's ⋯ menu, rather than from the Effects Library.

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

- **Live while editing.** Changing a setting makes the keyframes again
  at once, on the main thread (a clip is a few thousand samples), so the
  sliders feel like a live link.
- **Out of date** when what it read changes (the sound's media is
  replaced, the source clip is moved or its volume changed, the beat map
  edited): it regenerates by itself unless the keyframes on the control
  are no longer the ones it wrote. Then the control's
  [badge](#the-badge) turns to a warning and the Keyframe Designer asks
  first (**Regenerate** or **Keep Edits**).
- **Not edited by hand** while the effect drives the control: the editor
  refuses the change and says to bake first (see
  [Editing by hand](#editing-by-hand)).
- **Bake Keyframes**, in the Keyframe Designer, removes the effect and
  leaves the keyframes as plain keyframes. What the control was before
  the effect goes with it: a method picked afterwards starts from the
  baked keyframes.

Generated keyframes are marked with the effect's ID in the target's
keyframes, so regenerating replaces only its own, between the effect's
**start and end** (the clip by default; set in the Keyframe Designer's
Range menu, Start at Playhead and End at Playhead). Keyframes outside
that range are kept.

## Where they sit: hidden in the stack

A Keyframing effect is kept in its clip's picture stack, but the effects
panel doesn't list it (`TimelineClip.stackEffects`): it shows as a
**badge** on the row of the control it drives, and is made, changed and
taken away in the [Keyframe Designer](#the-keyframe-designer). So where it
sits in the stack means nothing, unlike the
[gravity](effects.md#guiding-principle-gravity) of the effects shown: its
**Target** can be any numeric control of the clip's other picture
effects, above or below it, plus its Volume and its sound effects'
controls ([EQ](equalizer.md) bands and the rest). Deleting the control,
or its effect, takes the Keyframing effect away with it
(`removeOrphanedKeyframing`), since nothing would be left to point it
elsewhere.

- **One component or all**: a Position or Scale target can take x, y or
  both (with Wiggler, both move apart).
- **To animate several clips together**, put the effects on an
  adjustment clip or a nested clip, as for any effect.
- **Compositing**: Keyframing effects are skipped by the compositor and
  the taps (they have no picture or sound).
- **Copying** an effect (Copy, Save as Preset, Duplicate) brings along
  the Keyframing effects driving its controls, driving the copy's.

### How the result meets the target

- **Replace**: the target's value is the generated one.
- **Add** (the default): the generated value is added to the target's
  value as it was before generating, so a wiggle rides on a hand-made
  move. The effect remembers that base curve, so regenerating adds to
  the original rather than to the last result.
- **Multiply**: for scales, opacities and gains, where a pulse should
  scale what's there.

### Editing by hand

The effect starts from the control as it was before it first wrote (the
base), every time it makes its keyframes. A keyframe added, moved, eased
or deleted by hand on the control would therefore be gone the next time
a setting changed, and deleting them all would leave the method, and the
base, in place: opening the Keyframe Designer again brought the old
curve back. So while a method drives a control, its keyframes can't be
changed by hand, in the Keyframe Designer's graph or anywhere else (the
effects panel's fields, lanes and stopwatch, a graph editor, the
viewer's handles, the easing keys, the volume line on the timeline).

- The edit is **refused** where every edit lands, in the project's state
  (`ProjectState.Refusal.drivenKeyframes`), so no control needs to know
  about it. Nothing changes, and an alert says which method makes the
  control's keyframes and how to get out: **Bake Keyframes**, which the
  alert offers, or None in the Keyframe Designer, which puts the control
  back as it was (`DrivenKeyframesWarning`). A drag is refused at each
  step and shows the alert once, after the mouse is up. The designer
  says the same under the method's blurb.
- **By hand** means the control's numbers changed while the effect
  driving it didn't (`EditingProject.drivenKeyframesEdit(since:)`). The
  effect's own writes change its fingerprints, so they pass, as do
  picking, changing and removing a method and Bake. Undo and redo pass
  (`ProjectState.writeRestored`), and so does what follows from an edit
  (`writeDerived`).
- **Not by hand**: an edit that also moves, trims, retimes or re-sources
  the clip. Joining two clips at a scene cut or nesting one rewrites
  every keyframe on the clip; the effect then finds what it reads
  changed and, since the control no longer holds what it wrote, asks
  (Regenerate or Keep Edits). A project saved with hand edits by an
  earlier version asks the same way.
- Every component is covered, and keyframes outside the effect's Range
  too: they are kept from the base, so an edit there would be lost just
  the same.
- The other controls of the effect, the method's own settings and
  everything else about the clip are edited as ever.

After Bake the keyframes are plain and the base is forgotten, so they
are edited freely, and deleting them leaves nothing behind.

### How many keyframes

Every kind evaluates its signal once per frame of the clip's timeline,
then **reduces** it: the Ramer–Douglas–Peucker algorithm drops every
keyframe the line through its neighbors passes within **Tolerance**
(0.5% of the output range by default) of, and the kept keyframes are
linear. A three-minute song typically keeps a tenth of its frames.
Time Step has no Tolerance: it keeps both sides of each jump, so its
holds stay flat. Over a target that holds still, the kinds with a
natural rate (Beat Keys, Oscillator) instead write one keyframe per
event with eases, as an animator would.

Keyframes are in the clip's source time; a retimed clip's frames are
mapped through its speed curve (`ClipTime`) so a pulse lands on the beat
as heard, not as stored.

## The kinds

| Kind | What it makes | Settings |
| --- | --- | --- |
| **Audio Keys** | Follows how loud a range of frequencies is in a sound: kicks, hi-hats, a vocal. | Source, frequency range, amplitude range, attack and release, output range, see below |
| **Beat Keys** | A pulse on each beat of a beat map: up at the beat, back over a decay. | Beat map (from a Sound or Music layer), every N beats (1), offset, downbeats only, accent on the one (+50%), shape: pulse, step, ramp or alternate; peak; decay |
| **Wiggler** | Random, organic movement around the current value. | Frequency (wiggles per second, 2), magnitude, type: smooth (Perlin) or jagged, octaves (1), dimensions: independent or together, seed |
| **Oscillator** | A regular wave. | Wave: sine, triangle, square or sawtooth; frequency (Hz, 1); amplitude; phase; fade, in seconds, at each end of the range |
| **Smoother** | Smooths the target's existing keyframes, and thins them. | Strength (frames of averaging), tolerance |
| **Looper** | Repeats the target's keyframes past their end (or before their start). | Mode: cycle, ping-pong, offset (each cycle continues from the last), continue (at the last speed) |
| **Time Step** | Holds each value for N frames, for a stop-motion or "on twos" look. | Hold (2 frames) |
| **Overshoot** | Adds spring bounce after each keyframe of the target, as if the move had weight. | Stiffness, damping, mass |

Smoother, Looper, Time Step and Overshoot read the target's own keyframes
(the base curve above), so they are not out of date until those change.

## Audio Keys in detail

The Keyframe Designer shows the sound's **spectrum** at the playhead,
frequency on a log scale across and level up, and a **box** on it: its
left and right edges are the frequency range, its bottom and top the
amplitude range.
Drag the box or its edges, as in Sound Keys. An effect has one box and
one target; to drive kick, snare and hats onto three targets, use three
Audio Keys effects.

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

**Listen To**: the whole mix (the default), a Sound or Music layer, or
one clip with sound, of this timeline. Each clip's sound is taken as
heard, with its volume and its layer's, and their EQs; other sound
effects, pan, nested timelines' sound and missing files aren't heard.

### Analysis

Recomputing an FFT every time a slider moves would be slow on a long
song, so the expensive part is done once per audio file and kept:

- A **spectrogram** per asset: 48 bands, log-spaced from 20 Hz to
  20 kHz, every 1/50 s (a 4096-point `vDSP.FFT` with a Hann window, hop
  20 ms, more than a frame's resolution at 30 fps). Each band's level is
  one byte, in half-decibel steps from −128 dB to 0 dB, so a file costs
  2.4 KB per second of sound: about 430 KB for a three-minute song,
  8.6 MB per hour. The level is the band's power (mean square), so a
  full-scale sine reads −3 dB; the file is read mixed to mono at
  44.1 kHz. `Spectrogram.read` makes it on the sample-reading queue the
  first time an effect listens to the file, and `SpectrogramStore` keeps
  it for the session by file, as `WaveformCache` keeps waveforms: it is
  in the file's time, so moving or trimming a clip doesn't recompute it,
  and making it again takes a fraction of a second a minute, so it isn't
  saved in the package.
- For a source of several clips, each clip's spectrogram is placed on
  the timeline in its time, scaled by its volume curve, and by its EQ's
  magnitude at each band's center frequency; layers are summed as
  power. A frequency range sums the bands it covers (part of a band at
  each edge).
- From there, the rest of the steps above are a few arithmetic
  operations per frame: a three-minute song at 30 fps is 5,400 values,
  done in well under a millisecond with vDSP. So the box and every
  slider regenerate the keyframes as fast as they're dragged.

## The Keyframe Designer

A Keyframing effect is about one control, so it is made from that
control rather than dragged from the Effects Library, which doesn't list
the category (`EffectsListPanel.kinds`). Every effect's ⋯ menu with a
numeric control has **Keyframe Designer…**, as does a numeric control's
own ⋯ menu, and the badge on a driven control (see [The badge](#the-badge))
opens it too. The menus never list the methods
themselves: they open the designer, a floating panel beside the graph
editors, one per clip (`KeyframeDesigner`,
`KeyframeGraphHUDs.showDesigner`), turned to the control it was opened
from: the one asked for, else the effect's first a method drives, else
its first.

- **Along the top**: Play/Pause, the playhead's timecode and skimming,
  as in the other designers. Space plays unless a focused field or
  control uses it. A note says **Changes apply immediately**: closing
  keeps the edits, and Undo reverts them; there is no draft to accept or
  cancel. Below, Control is a picker of every control of the clip a
  method can drive (each effect's numeric controls, its sound effects'
  and its volume, those driven named with their method: "Transform ·
  Position (Wiggler)"), beside **Bake Keyframes**.
- **Down the left**: the **Method**, a chip for None and each kind, the
  one driving the control lit, with a line on what it does; under it, for
  a method, a line saying its keyframes are baked before they are edited
  by hand, its note when it can't write, Regenerate and Keep Edits when
  it is out of date with hand edits, **Applies To** (Component, Combine,
  Listen To or Beats From, and the Range, from the playhead), and its
  **Settings** as fields and pop-ups, set at the playhead.
- **Filling the right**: the control's graph (`KeyframeGraphView`, with
  its time row to drag the playhead along), which every change redraws as
  the keyframes are made again. Audio Keys puts the sound's spectrum and
  its box over it (`AudioKeysGraph`), at the playhead or, while it plays,
  the player's time.
  The ruler and **Add keyframe at playhead** remain available with zero
  or one keyframe. A separate selection row shows the keyframe's time,
  a compact **Ease** menu and **Handles…**. Handles opens reach sliders
  and speed fields for each side of a single keyframe, usable with the
  keyboard and VoiceOver; sides can be added or removed independently.

Dragging a setting, handle-reach slider or Audio Keys box shares the
editor's held edits and gesture history: intermediate values preview
without autosaving, and the whole drag is one undo step even after a pause.

Picking a method (`EditingProject.setKeyframing`) is one undo step: with
none driving the control, a Keyframing effect of that kind goes just
above the control's effect, so it reaches it (at the top for the volume
or a sound effect's control), Audio Keys listening to the whole mix and
Beat Keys to the first Sound or Music layer with beats. Over another
method, the old one is taken away, putting the control back as it was,
and the new one takes its place in the stack, keeping its Component,
Combine, Range, beats and sound. **None** takes it away, putting the
control back. Picking the one already driving it changes nothing. A clip
with no picture stack can't hold one, so there the chips are off with a
note.

## The badge

In the effects panel, a control a method drives has a small badge after
its values (`KeyframeMethodBadge`): the method's glyph in the generated
keyframes' color, and its lane draws the keyframes it made in that
color. A click opens the Keyframe Designer on the control. When the
method can't write (no beats yet, the sound gone) or waits on the person
(out of date after hand edits, for Regenerate or Keep Edits), the badge
turns to a warning triangle in the warning tone, and its help and
VoiceOver say why. VoiceOver reads it as "Keyframes made by Wiggler"; the
Volume row has one too.

## Saving

The effect is saved with its kind, settings, target (by control ID),
component, combine mode, range, the base curve for Add and Multiply, the
layer or sound it reads, and two fingerprints: of what it read (the
clip's placement, speed and range, plus, for Audio Keys, the heard files'
spectrograms and their clips' volume and EQ, or, for Beat Keys, the
layer's beats) and of the target as it left it (see step 3 of
[Building it](#building-it)). The generated keyframes are saved on the
target as usual, with `"generatedBy"` holding the effect's ID. A
project opened by an app that ignores Keyframing effects still plays
the same.

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
- A hand edit of a driven control is told from the method's own writes,
  from Bake and None, and from keyframes rewritten with the clip; the
  project's state refuses it, also in a held drag, and takes it from
  undo. Baked, the control is edited by hand, and a method picked then
  starts from the baked keyframes.
- A clip at 50% speed gets its beat pulses on the beats as heard.

## Not yet

- Expressions, or linking a control to another live.
- Driving a control on another clip directly, without an adjustment or
  nested clip.
- Audio Keys from a sound that isn't on the timeline (an input from the
  browser).
- Motion Sketch: recording a mouse path as Position keyframes.

## Building it

In order, each step usable on its own:

1. **Model, generators and saving** (done). `EffectKind` has Beat Keys,
   Wiggler, Oscillator, Smoother, Looper, Time Step and Overshoot in
   `EffectCategory.keyframing`; Audio Keys comes with step 4. A kind's
   settings are ordinary controls (`ControlKind.wiggleFrequency`, `.seed`,
   `.loopMode` and so on), so they save, load strictly and edit like any
   other, and the numeric ones can be keyframed: a Wiggler's Magnitude can
   fade in, and a keyframed Frequency is integrated so the phase never
   jumps. What the effect writes to is its `KeyframingSetup`: the target (a
   control, or `volume`), one component or all, Combine, the range (source
   time, nil for the clip) and the base curve, saved as the effect's
   `keyframing`. Generated keyframes carry `generatedBy`.
   - **Targets** were at first the numeric controls of the effects below
     it, except other Keyframing effects', then those of the clip's sound
     effects (all of them, not only the EQ's) and its volume; step 6 let
     it reach every effect of the clip. A new one went at the top of the
     stack and took the first target no other Keyframing effect wrote to;
     now the designer places it (see
     [The Keyframe Designer](#the-keyframe-designer)). A duplicate has
     none until it's pointed somewhere. A pasted one follows its target
     when that was pasted with it, and otherwise waits for one (a Volume
     target is kept). Pointing one elsewhere leaves what it wrote on the
     old target as plain keyframes.
   - **Making keyframes** happens at once whenever the effect is edited
     (`EditingProject.editEffect`), on the main thread. Every kind samples
     each timeline frame of the range as heard (`KeyframeSampling`) and is
     reduced by Tolerance; Time Step keeps a keyframe at each side of every
     jump (`KeyframeGenerators.steps`), so its holds survive, or, on one
     component of several, is reduced only where it is exactly straight.
     Kept keyframes are linear. Each setting is read once for the whole
     range, at every sample when it is keyframed, and the curves are held
     flat, every sample's components one after another. Over a
     target that holds still, Oscillator and Beat Keys instead write a
     keyframe per event (`KeyframeSignal.events`), as an animator would:
     a sine's peaks and troughs with Easy Ease, a triangle's linear, a
     square's or sawtooth's jumps held to the frame before; each beat, the
     frame before it and where its decay ends, eased out of the beat and
     into the rest. A target with keyframes of its own is still followed
     frame by frame, since its curve shows between the events.
   - **Combine** applies to Beat Keys, Wiggler and Oscillator. Multiply
     scales by the signal as a percent more (30 makes 130%). Smoother,
     Looper, Time Step and Overshoot reshape the base and ignore it.
   - **The base** is taken the first time the effect writes, and every
     regeneration starts from it, so hand edits to the target would be
     lost when the effect's own settings are edited (only a change to
     what it reads asks first; see step 3). The editor therefore refuses
     them until the keyframes are baked (step 7). Deleting the effect
     puts the base back; Bake (`bakeKeyframing`) removes the effect, and
     the base with it, and keeps its keyframes, unmarked.
   - **Beat Keys** reads a layer's beats as the timeline's beat markers
     do: a song's confirmed beat map where it has one, otherwise the beats
     analysis detected, which the editor mirrors into `DetectedBeats` for
     the model and which make it out of date when they arrive (in the undo
     baseline, as a spectrogram does). It counts Every and Offset from the
     first beat at or after the range's start. Accent applies to downbeats
     when every beat is chosen; detected beats have no measures, so they
     have no downbeats. A layer with no beats yet gets a note.
   - **Overshoot** adds, after each of the base's keyframes in the range, a
     damped spring set going at the speed the curve arrived (ω = √(k/m),
     decay c/2m), summed over keyframes so a new one never jumps. A bounce
     is left out once its decay has brought it under a millionth of its
     push (`bounceLength`).
   - Keyframing effects are no-ops to the compositor and the sound taps,
     and have no animated ranges. They go only in the picture's stack, so
     a clip with no pictures can't have one yet.
2. **Library and panel** (done, then replaced: the library no longer
   lists the category, see step 5, and the panel no longer shows the
   rows, see step 6). This is how it was. In the panel a Keyframing
   effect had Target (None, each target by effect and control name, and
   Unavailable for one that's gone or above), Component (All or each of
   the target's, when it has more than one), Combine (not for the kinds
   that reshape) and, for Beat Keys, Beats From (the timeline's Sound and
   Music layers) above its settings, under a **Bake Keyframes** button,
   which was too important to live only in the ⋯ menu. Its ⋯ menu had
   Bake Keyframes too, and a Range menu (Start at Playhead, End at
   Playhead, Whole Clip), with a note under the effect while a range was
   set. While a Keyframing effect was selected, its range was a band over
   the panel's ruler (`KeyframingRangeBar`, since removed; the whole
   clip, fainter, with none set) with a handle at each end, dragged on
   the timeline's frames as one undo step (Escape during the drag put the
   end back), or adjusted a frame at a time by VoiceOver. It was dimmed
   only when off or with a note: no target, one it can't reach, Beat Keys
   with no layer, or a reshaper whose target has fewer than two
   keyframes. A curve stood in for its thumbnail (none is drawn), and its
   name read as the summary above. Keyframes it wrote are still drawn in
   the accent color in every lane and read as "Generated keyframe" by
   VoiceOver. Today the Keyframe Designer holds Applies To (whose Range
   menu names a range that is set), the note when it can't write, and
   Bake Keyframes, and the badge stands in for the row.
3. **Out of date** (done). When it writes, the effect saves two
   fingerprints (`KeyframingPrint`, FNV-1a, so they are the same in every
   run, written as hexadecimal): `readPrint`, of what it read (the clip's
   start, trim and speed curve, the frame rate, its range and, for Beat
   Keys, the layer's beats), and `writtenPrint`, of the target as it left
   it. After every edit the editor runs `refreshKeyframing(after:)` before
   the edit is recorded for undo, so the new keyframes are part of the same
   step and undoing never sets it off again. It looks only in the timelines
   the edit changed, or everywhere when it changed something outside them
   (the media); opening a project and analysis arriving check every
   timeline (`refreshKeyframing()`). Making the same keyframes again
   writes nothing, so it doesn't count as an edit. An effect whose read print no
   longer matches makes its keyframes again by itself, unless the target no
   longer matches its written print. Then it was edited by hand: the
   control's badge turns to a warning, and the Keyframe Designer shows
   Regenerate (losing the edits) and Keep Edits (taking what it
   reads now as its source, so it asks again at the next change). Off
   effects and ones that can't reach their target are never out of date.
   Making keyframes stays on the main thread: a clip is a few thousand
   samples, and only Audio Keys' analysis needs the background (see step
   4).
4. **Audio Keys** (done), as described above. Its settings are
   Frequencies and Levels (each low and high, the box as fields),
   Attack and Release (0 and 200 ms, time constants of the envelope),
   Output (from and to), Curve and Tolerance, and its setup's
   `audioSource` (saved as `listensToMix`, `listensToLayer` or
   `listensToClip`). At first the effects panel had a Listen To row and
   drew the box small under the effect's header (`EffectGraphPreview`);
   those went with steps 5 and 6. Listen To is now under Applies To in
   the Keyframe Designer (see
   [The Keyframe Designer](#the-keyframe-designer)), with `AudioKeysGraph`
   over the control's graph and every setting as fields beside them, set
   at the playhead. The spectrum shows the
   bands heard (−96 to 0 dB) at the playhead, or at the player's time while
   it plays, so the spectrum moves with the sound (only it redraws), with
   the box shaded up to how loud its range is now. The box's edges or
   inside are dragged as one undo step, and VoiceOver adjusts it by a third
   of an octave, with actions that raise or lower its levels by 3 dB. Its read print includes each heard file's
   spectrogram fingerprint and the clips', layers' and EQs' settings, so
   while a file is still being read the effect keeps its keyframes (with
   a "Reading the sound…" note), and when it arrives the editor makes them
   in the undo baseline as well as the project, since the analysis
   arriving isn't an edit.
5. **Keyframe Designer** (done), as described in
   [The Keyframe Designer](#the-keyframe-designer): the methods move out
   of the Effects Library into a panel opened from an effect's ⋯ menu,
   which drives one control at a time against its graph, and replaces
   Audio Keys' own editor. Effects already in a project are untouched.
6. **Hidden from the stack** (done), as described in
   [Where they sit](#where-they-sit-hidden-in-the-stack) and
   [The badge](#the-badge): the stack no longer lists Keyframing effects,
   so their rows, ⋯ menu and range bar over the ruler are gone (the range
   is set in the designer); they reach any control of the clip, go with
   the control they drive, and come along when its effect is copied.
   Step 2 describes the rows as they were.
7. **No hand edits while driven** (done), as described in
   [Editing by hand](#editing-by-hand). Before, a driven control's
   keyframes could be edited or deleted by hand: the edits lasted until
   the next setting change, and keyframes deleted in the effects panel
   came back, with the curve from before the method, when the designer
   was opened again, because the hidden effect and its base were still
   there. Regenerate and Keep Edits (step 3) stay for keyframes changed
   along with the clip, and for projects saved with hand edits.
