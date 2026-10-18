# Audio levels

Status: **implemented**: keyframed volume and pan on clips and on Sound
and Music layers, sound effects (EQ, Compressor, Limiter) on clips, all
applied in playback and export, and a meter of the whole mix. The level
and pan math, saving, nesting, the mix's gain above unity, pan and each
sound effect in the mix, and the meter's measurements and movement are
unit tested (the mix by reading a composition through its audio mix). The
controls and the meter have not yet been driven on screen. What is not built is listed
under [Not implemented yet](#not-implemented-yet).

Showing a layer's channels apart is described with the waveforms in
[timeline.md](timeline.md#waveforms).

Volume lives on **clips** and on **Sound and Music layers** as a fader
over everything on them ([effects.md](effects.md#volume)). A clip's volume
is a row at the bottom of the effects panel (and in the inspector), and
while **L** is on each clip block draws it as a line across itself.

## Volume

Every clip with sound has a **volume** (`TimelineClip.volume`), and every
Sound and Music layer a layer volume (`TimelineLayer.volume`) applied after
the clips' own. Video layers have none, only their clips do. Both are in
decibels relative to the media (`AudioLevel`):

- **0 dB** plays the media as it is. That is the default.
- Up to **+6 dB**, twice as loud in amplitude. Louder sound can clip; the
  meter shows when it does.
- Down to **−60 dB**, which mutes. At or below it the field reads **−∞**.

A clip's volume applies to its audio file, the linked sound of a video
clip, or the sound of a nested timeline (multiplied by the volumes of the
clips and layers inside it); its keyframes count in the clip's source time,
so they move with the clip. A layer's volume applies to everything on it.
Detaching a video clip's sound gives the new sound clip the same clip
volume, so it plays as before.

It is keyframed like any other control (see
[layer-transforms.md](layer-transforms.md#keyframes)): the stopwatch turns
animation on, editing the level at the playhead then sets a keyframe there,
and the diamonds step between keyframes or add and remove one. Keyframes
blend in **decibels**, so a fade sounds even instead of dropping away at
its end, and take the same eases and graph editor as other controls.

### In the timeline

**L** shows volume: each clip's as a line across its block, mute at the
bottom and +6 dB at the top with a faint line at 0 dB, and a Sound or Music
layer's as a row under it. It acts on the selected clip's layer, or on every
layer with sound when nothing is selected; pressing it again hides it. A
layer's disclosure arrow shows or hides its row. Video layers have no volume
row, only the lines.

The row's label column holds the stopwatch, the level (click it to type
decibels; arithmetic works), a fader, and the keyframe buttons. Its lane
draws the level as a line across the clips, mute at the bottom and +6 dB at
the top with a faint line at 0 dB, and the keyframes as diamonds to click,
drag in time or delete. The inspector shows the same row under **Sound**
for the selected clip, and under **Layer sound** for a Sound or Music
layer. Right-click the row to reset it to 0 dB.

## Pan

Clips with sound and Sound and Music layers also have a **pan**
(`TimelineClip.pan`, `TimelineLayer.pan`), from **L 100** through **C** to
**R 100**, keyframed like volume and stored as −100…100 (`AudioPan`). It is
a balance: moving toward one side turns the other channel down and leaves
the near one as it is, so a centered pan plays the media unchanged rather
than 3 dB down. A layer's pan applies after its clips' own, so a clip
panned left on a layer panned right comes out quieter on both sides.

Pan is a row under volume in the effects panel and in the inspector's
**Sound** and **Layer sound** groups, with its own graph editor. The
timeline shows volume only.

Pan works on stereo sound. A mono file's sound stays centered at its
volume whatever its pan: its composition track reaches the audio tap as one
channel, which the mix then plays on both sides, and a tap can't add a
channel. Panning mono needs a stereo copy of the file to play from instead.

## Sound effects

A clip with sound has a second stack for its sound (`audioEffects`), shown
in the effects panel under its picture's stack and Shutter, above Volume
and Pan: the sound plays through its effects top to bottom, then its volume
and pan. The library's **Sound** category holds them; they are dragged onto
a clip or into the stack, or double-clicked, like picture effects, and
renamed, reordered, switched off, copied, pasted, saved in presets and
keyframed the same way. A sound effect dropped on a picture effect goes at
the end of the sound's stack, and an effect moves only within its own
stack. Audio-only clips have a sound stack and no picture stack. Detaching
a video clip's sound takes its sound effects with it.

- **EQ**: **Low Cut** (a high-pass, 20 Hz to 1 kHz; off at 20 Hz), **Bass**
  (a shelf at 100 Hz), **Mid** (a peak an octave wide at **Mid Freq**, 100
  Hz to 10 kHz) and **Treble** (a shelf at 8 kHz), each ±24 dB. At its
  defaults it changes nothing and is dimmed.
- **Compressor**: **Threshold** (−60 to 0 dB), **Headroom** (how far over
  the threshold sound may go before it is held down, 0.1 to 40 dB),
  **Attack** (1 to 300 ms), **Release** (10 ms to 3 s) and **Makeup** gain
  (−20 to +40 dB). It compresses at its defaults, so it is never dimmed.
- **Limiter**: **Drive** (0 to +24 dB into it) and **Release** (1 to
  40 ms); it holds the sound under full scale.

They are Apple's Audio Units (`AUNBandEQ`, `AUDynamicsProcessor`,
`AUPeakLimiter`), each made by the track's tap when it is prepared
(`AudioEffectUnit`) and run in place on its buffers before the volume and
pan. A clip with an enabled sound effect has its sound on a track of its
own, as one with a volume or pan does. Settings are read from `MixCurves`
as each buffer plays, at the buffer's start, so edits and keyframes are
heard without a rebuild; which effects a track runs is part of
`CompositionKey`, so adding, removing, reordering, switching on or off
rebuilds the player. A jump in time (a seek or a loop) resets the units,
so a compressor doesn't carry what it heard before. Effects on a nested
timeline's clip run on each track inside it separately, not on their sum.

The compressor delays its sound by about 5 ms and the limiter by 2 ms,
which isn't made up for. Apple's voice isolation unit (`AUSoundIsolation`)
isn't offered: it delays sound by about 76 ms, two frames, which would
have to be made up by starting the clip's sound that much earlier.

### Playback and export

AVFoundation's own mix volume can't go above unity, so each composition
audio track gets a processing tap (`AudioLevelTap`) that multiplies its
samples by its layers' gain, and each channel by its side of the pans,
ramping across each buffer. Each track knows
the volumes it plays through, innermost first, with the time shift of each
(`MixStage`, for a clip or a layer); nested timelines add the stages of
the clips and layers they sit in. A clip with a volume or pan of its own
has its sound on a composition track of its own.

The curves themselves live in a shared store (`MixCurves`) that the
editor replaces whenever a volume or pan changes. The taps read it as they
play, so an edit is heard at once: levels are left out of `CompositionKey`
and don't rebuild the player. Only whether a clip has a volume or pan of
its own is kept in the key, since that gives it a track of its own. Export
builds its own store from the project.

### Sound of a retimed clip

A clip that isn't at 100% speed has a **Sound** choice (in its menu and the
effects panel): **Keep Pitch** (the default) plays it at the new speed at its
own pitch, **Change Pitch** speeds it up and slows it down like tape, and
**Mute** silences it while the speed isn't 100%. They are AVFoundation's
time-pitch algorithms (`.spectral` and `.varispeed`) on the clip's audio mix
track, which is its own track, so they work in playback and export alike.
Its volume keyframes count in source time, so they follow the sound.

## Meter

The bar-chart button in the timeline's header shows a **meter** to the
right of the timeline (remembered in the app's defaults). It shows every
audio track together, left and right, in dBFS from −60 to 0: green up to
−18, yellow to −6, red above. The bar jumps up at once and falls back at
24 dB a second (`MeterBallistics`); a mark holds the recent peak for a
second and a half. The lamp over each channel lights once it reaches full
scale and stays lit until clicked. Mono sound reads the same on both
sides.

The taps that apply volume also measure what they let through
(`MixLevelMeter`): each track's mean square and peak per channel, in
1/50 s windows of timeline time. The meter reads the two windows at the
playhead, so it follows what is heard rather than what the player decoded
ahead. Tracks are combined by power, since taps may run at different
sample rates and their samples can't simply be added: the mix reads as the
square root of the sum of the tracks' squares. That is exact for unrelated
sounds and reads up to 3 dB low for the same sound on two tracks. A window
played again is averaged with itself, so replaying doesn't read louder.

## Saving

A clip's `volume`, and a Sound or Music layer's, is written only when it
isn't a steady 0 dB, as a property entry: `{"value": -6}` or
`{"keyframes": [{"time": "0s", "value": 0}, …]}`. Values outside −60…+6
are clamped on load. Its `pan` is written the same way while it isn't a
steady center, and values outside −100…100 are clamped on load. A clip's
sound effects are written as `audioEffects`, in the same shape as its
`effects` (see [effects.md](effects.md#saving)), only while it has any; a
picture effect in `audioEffects`, or a sound effect in `effects`, is
dropped on load.

## Not implemented yet

- Panning mono sound (see [Pan](#pan)).
- Pan in the timeline's volume row and lines.
- Dragging the level line up and down in the lane; levels are set in the
  field or with the fader.
- Audio fades under transitions.
- Sound effects on Sound and Music layers, and voice isolation (see
  [Sound effects](#sound-effects)).
- Making up for a sound effect's delay.
- A meter per layer, and reading the mix while scrubbing or paused.
- Loudness (LUFS) rather than peak level.
