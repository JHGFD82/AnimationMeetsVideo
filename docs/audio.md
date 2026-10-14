# Audio levels

Status: **implemented**: keyframed layer volume, applied in playback and
export, and a meter of the whole mix. The level math, saving, nesting, the
mix's gain above unity and the meter's measurements and movement are unit
tested (the mix by reading a composition through its audio mix). The
controls and the meter have not yet been driven on screen. What is not built is listed
under [Not implemented yet](#not-implemented-yet).

Showing a layer's channels apart is described with the waveforms in
[timeline.md](timeline.md#waveforms).

## Volume

Every layer with sound has a **volume** (`TimelineLayer.volume`), in
decibels relative to its media (`AudioLevel`):

- **0 dB** plays the media as it is. That is the default.
- Up to **+6 dB**, twice as loud in amplitude. Louder sound can clip; the
  meter shows when it does.
- Down to **−60 dB**, which mutes. At or below it the field reads **−∞**.

The volume applies to everything the layer plays: audio files, the linked
sound of its video clips, and the sound of nested timelines, multiplied by
the volumes of the layers inside them. Detaching a video layer's sound
gives the new sound layer the same volume, so it plays as before.

It is keyframed like a transform property (see
[layer-transforms.md](layer-transforms.md#keyframes)): the stopwatch turns
animation on, editing the level at the playhead then sets a keyframe there,
and the diamonds step between keyframes or add and remove one. Keyframes
blend in **decibels**, so a fade sounds even instead of dropping away at
its end, and take the same eases and graph editor as transforms.

### In the timeline

**L** shows only the volume row under the selected clip's layer, or under
every layer with sound when nothing is selected; pressing it again hides
it. **Shift-L** adds or removes the row and keeps any transform rows, as P,
S, R and T do with Shift. The layer's disclosure arrow, now also on sound
and music layers, shows every property row the layer has.

The row's label column holds the stopwatch, the level (click it to type
decibels; arithmetic works), a fader, and the keyframe buttons. Its lane
draws the level as a line across the clips, mute at the bottom and +6 dB at
the top with a faint line at 0 dB, and the keyframes as diamonds to click,
drag in time or delete, as on transform lanes. The inspector shows the same
row as **Layer volume** for the selected clip's layer. Right-click the row
to reset it to 0 dB.

### Playback and export

AVFoundation's own mix volume can't go above unity, so each composition
audio track gets a processing tap (`AudioLevelTap`) that multiplies its
samples by its layers' gain, ramping across each buffer. Each track knows
the layers it plays through, innermost first, with the time shift of each
(`VolumeStage`); nested timelines add the stages of the layers they sit
in.

The curves themselves live in a shared store (`VolumeCurves`) that the
editor replaces whenever a volume changes. The taps read it as they play,
so an edit is heard at once: volume is left out of `CompositionKey` and
doesn't rebuild the player. Export builds its own store from the project.

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

A layer's `volume` is written only when it isn't a steady 0 dB, as a
property entry like a transform's: `{"value": -6}` or
`{"keyframes": [{"time": "0s", "value": 0}, …]}`. Values outside −60…+6
are clamped on load.

## Not implemented yet

- Volume per clip (it is per layer, like transforms), and pan.
- Dragging the level line up and down in the lane; levels are set in the
  field or with the fader.
- Audio fades under transitions.
- A meter per layer, and reading the mix while scrubbing or paused.
- Loudness (LUFS) rather than peak level.
