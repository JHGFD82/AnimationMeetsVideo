# Audio levels

Status: **implemented**: keyframed volume and pan on clips and on Sound
and Music layers, sound effects (EQ, Compressor, Limiter) on clips,
fades and crossfades under transitions, all applied in playback and
export, scrubbing by grains and like tape, a meter of the whole mix
with its short-term loudness,
exports mastered to a loudness target with peaks held under −1 dBFS, a
choice of output devices, and takes recorded from inputs and other apps.
Writing and placing a take are tested; capturing from a device or an
app needs the system's permission prompts, so it isn't, and has not yet
been tried in the running app. The
loudness measurement is tested against BS.1770's reference levels and
gates. The level and pan math, saving,
nesting, the mix's gain above unity, pan, fades and each sound effect in
the mix, the fades at joined cuts, and the meter's measurements and
movement are unit tested (the mix by reading a composition through its
audio mix). The
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

A mono file's composition track reaches the audio tap as one channel,
which the mix then plays on both sides, and a tap can't add a channel. So
mono sound played through any pan that is off center plays from a stereo
copy of its file instead (`StereoProxies`): the same sound on both
channels, 24-bit, with silence for a sound track that starts late so file
times mean the same. A copy is made the first time it is needed, on the
reading queue, and kept in the user's Caches folder, named for the file's
path, size and modification date, so a changed file gets a new one.
Whether each pan is centered is part of `CompositionKey`, so moving one
off center rebuilds the player onto the copy; moving it further doesn't.
A file whose copy can't be made plays centered.

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
- **Voice Isolation**: **Isolation** (0 to 100%, how much of the isolated
  voice is heard against the original), Apple's machine-learning voice
  isolation, for dialogue under music or noise. It is never dimmed.

They are Apple's Audio Units (`AUNBandEQ`, `AUDynamicsProcessor`,
`AUPeakLimiter`), each made by the track's tap when it is prepared
(`AudioEffectUnit`) and run in place on its buffers before the volume and
pan. A clip with an enabled sound effect has its sound on a track of its
own, as one with a volume or pan does. Settings are read from `MixCurves`
as each buffer plays, at the buffer's start, so edits and keyframes are
heard without a rebuild; which effects a track runs is part of
`CompositionKey`, so adding, removing, reordering, switching on or off
rebuilds the player. A jump in time (a seek or a loop) resets the units,
so a compressor doesn't carry what it heard before. A jump is a buffer
starting more than 20 ms from where the last one ended: the player stamps
its buffers loosely, a few milliseconds either way, though the sound runs
on unbroken, and resetting on that kept voice isolation, which needs
76 ms of sound before it says anything, at half its level. Effects on a nested
timeline's clip run on each track inside it separately, not on their sum.

Some of these hold sound back: the compressor by about 5 ms, the limiter
by 2 and voice isolation by about 76, two frames. That is made up for
where the composition is built: each audio track's sound is placed
earlier by the delay of the effects it plays through (each kind's delay
measured once from a unit made at 48 kHz, `AudioEffectUnit.latency(of:)`),
so the effects put it back where it was edited. Sound that would then
start before the timeline is cut off there. The track's tap goes by when
its sound is heard, its own time plus that delay, for its volume, pan,
fades, effects' keyframes and the meter.

## Under transitions

Sound fades under every transition of a clip that has sound, whatever the
transition does to the picture, following the transition's curve
(`AudioFade`). The fades are equal power (a sine rising, a cosine
falling), so two clips crossfading are as loud halfway through as either
alone, rather than 3 dB down.

- A way in fades the clip's sound in over the transition, and a way out
  fades it out. At an open end that is a fade from or to silence.
- At a joined cut each clip's sound carries on through the transition on
  its spare footage, as its picture does: the outgoing clip's past its
  out point and the incoming clip's before its in point, so they
  crossfade instead of one cutting off at the cut. A way in that joins
  the clip before fades that clip out over the same span; a way out at a
  cut fades the clip after in under it. Where there is no spare footage
  the sound stops at the cut, partway through its fade.

Each fade is a stage of the clip's track (`MixStage.fade`, in root time),
so a nested timeline's clip fades all the sound inside it, and a clip with
one has its sound on a track of its own. Fades come from the transitions,
which are part of `CompositionKey`, so changing one rebuilds the player.

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

### Loudness

Under the bars the meter shows the mix's **short-term loudness**: every
track over the last three seconds, in LUFS, as EBU R128 and ITU-R BS.1770
measure it (`Loudness`). Each tap K-weights what it lets through, after
volume and pan, with a filter per channel (`KWeighting`: a high shelf of
about +4 dB above 2 kHz and a high-pass below about 40 Hz), and the meter
keeps each window's weighted power beside its levels. Loudness is
−0.691 + 10·log10 of the weighted power summed over left and right, so a
full-scale 997 Hz sine on both channels reads 0 LUFS. A mono track plays
on both sides and counts twice. Tracks are added by power, with the same
caveat as the levels. It reads a dash while nothing plays, and windows
nothing was measured in (before playing started) are left out rather than
read as silence.

`LoudnessMeasurement` measures a whole program the same way: its
integrated loudness, gated as R128 has it (400 ms blocks every 100 ms,
leaving out those under −70 LUFS and then those more than 10 LU under the
rest), its loudest momentary (400 ms) and short-term loudness, and its
loudest sample.

## Loudness on export

The **Loudness** menu beside the export format (remembered in the app's
defaults) sets how loud the export's sound is (`LoudnessTarget`):

- **As Mixed** (the default): the mix as it is, mixed by the export
  session through the taps as in playback.
- **−14 LUFS** for streaming services, **−16 LUFS** for podcasts and
  Apple's spec, **−23 LUFS** for EBU R128 broadcast.

With a target, the sound is mastered before the pictures are exported
(`LoudnessMastering`), taking the first tenth of the progress bar.
AVFoundation's audio mix has taps on its tracks but none on their sum,
so there is nowhere to put a limiter on the whole mix while the export
session mixes it. Instead the mix is read out through its audio mix
twice, in stereo float at 48 kHz, off the cooperative pool
(`SampleReading`):

1. Once to measure its integrated loudness (`LoudnessMeasurement`).
2. Once to render it to a temporary CAF file: gained by the difference
   from the target, pushed 1 dB into Apple's peak limiter
   (`AUPeakLimiter`, as an `AudioEffectUnit`, with its longest release
   so held peaks don't pump) and brought 1 dB down again, so peaks are
   held under **−1 dBFS**. The limiter looks ahead by about 2 ms; that
   much is dropped from the start and flushed out at the end, so the
   sound stays in step with the picture.

The file's sound then replaces the composition's audio tracks and the
export runs without an audio mix. The render measures what it writes, and
when the export is done a note says what mastering did: what the mix
measured, how far it was raised or lowered and to what, how far the
limiter held peaks down (with a warning past 6 dB, where it can be
heard), and the loudest peak (`LoudnessMastering.Report`). WAV Mix
exports report the same. A mix with nothing in it, or nothing
above R128's −70 LUFS gate, is exported as mixed. The ceiling is on
samples, not true peak: sound between samples can go a little over it.
Heavy limiting, when a quiet mix with sharp peaks is raised a long way,
leaves the result a little under the target.

## Scrubbing

While paused, moving the playhead (dragging it, clicking the ruler,
stepping with the arrow keys, jumping to a keyframe) plays a moment of the
mix where it lands: an 80 ms grain whose ends fade over 10 ms with a
raised cosine, out of the playback device (`ScrubAudio`). The Settings
window's Sound tab turns it off.

A grain is never cut off, since a hard stop mid-waveform clicks, and a
drag makes dozens of them a second. Grains are paced (`GrainPacer`): the
first move plays at once; moves while a grain plays wait for the next
start, exactly 70 ms after the last, and only the newest of them plays,
from where the playhead is by then. Each grain goes to the other of two
players, so it fades in while the one before fades out, and the two
fades sum to a steady level across their 10 ms overlap. A drag is heard
as a smooth run of grains following the playhead, up to 70 ms behind it.

Each video frame is heard once. A grain plays from the start of the frame
the playhead is on, and a move to where the newest grain already plays,
or waits to, asks for nothing, so a drag across the many pixels of one
frame plays it once rather than over and over until the next.

The mix is read out through the composition's audio mix, as playback
hears it, a second before the playhead and three after, and kept, so
grains near each other cost nothing; moving outside it reads again. An
edit forgets what was read, since it may change the sound. All of it
(reading, the engine, scheduling) runs on one queue of its own, and
playing lets go of its engine.

## Tape scrubbing

**Window > Tape Scrubber** opens a small floating box with a slit, and
the ridged edge of a dial standing out of it (`TapeScrubberView`). It
plays the Main timeline's sound the way tape sounds rocked by hand
across a playback head: without a break, at the speed and direction the
dial is turned, its pitch going up and down with the speed
(`TapeScrub`). The playhead and picture follow. While another timeline
is open the dial is dimmed and doesn't turn.

The speed comes from how far the dial has been dragged since it was
grabbed (`TapeScrub.rate(forDrag:)`): slow at first and faster the
further it goes, up to 8 times normal; to the left it plays backwards.
Dragging back past where it was grabbed reverses it. Letting go brings
the tape to rest, and the playhead onto the start of the frame it
stopped in. Holding the Left or Right Arrow key runs it at normal
speed that way, four times with Shift; VoiceOver's adjust plays half a
second either way.

Nothing waits on the dial. The engine starts when the window opens and
runs until it closes, so grabbing it doesn't wait for a device. The
speed asked for goes to the render thread through an atomic, and the
render thread moves its head over the mix one output frame at a time
(`TapeTransport`), so a turn is heard within one output buffer, about
10 ms. The head's speed glides toward the dial's with a 15 ms time
constant, too short to feel but enough that a jump in speed doesn't
click; it reads between samples with a cubic, and below 0.03 times
normal the sound fades away, as tape's does, rather than holding one
sample. It stops at either end of the timeline.

The mix is read out through the composition's audio mix, as playback
hears it, in two-second pieces: the one the tape is in, two ahead the
way it is going and one behind, read on a queue of its own, one at a
time so a move elsewhere is seen at once, and let go of further than
four away. Each piece reads a quarter second before it and throws that
away, so effects that need sound before they say anything (Voice
Isolation) are running by its start. A piece not read yet plays as
silence. Moving the playhead any other way cues the tape there and
reads around it, ready for the next grab; an edit forgets what was
read.

## Output devices

The Settings window's **Sound** tab picks where sound plays: **Playback**,
the timeline's sound (System Default, or any output device), and **Beat
tick** (Same as Playback, or its own), so the timeline can play on the
room's speakers with the tick only in headphones. Beat Match uses the
same two. Devices are listed from Core Audio's hardware layer
(`AudioDevices`), leaving out hidden ones the system makes for itself,
and stored by UID, which stays the same across launches and replugging.

The player is pointed at its device with `audioOutputDeviceUniqueID`, and
the tick's engine by setting its output unit's current device. A device
can take seconds to wake (a display's speakers, say), so the tick moves
on a queue of its own and leaves the engine alone on the main thread
until it is there. A chosen device that is unplugged plays out of the
system's default, and the sound moves back when it is plugged in again;
Settings keeps the choice, shown as an unplugged device.

## Exporting sound

Beside the ProRes formats, the export format menu offers the sound alone
(`ExportFormat`, `AudioExport`), as 24-bit WAV at 48 kHz in stereo:

- **WAV Mix**: the whole mix in one file, as playback hears it, mastered
  to the Loudness menu's target like a movie's sound (see
  [Loudness on export](#loudness-on-export)).
- **WAV Stems**: a file for each layer of the timeline that has sound,
  in a new folder with the name given, each named for the export and the
  layer ("Cut - Music 1.wav"). Each holds only that layer: its clips with
  their effects, volume, pan and fades, its own volume and pan, and the
  sound of timelines nested on it. Stems aren't mastered, whatever the
  Loudness menu says, so together they add up to the mix as mixed.

A movie's sound can be split the same way. The toolbar's sound menu
(beside the format, holding the loudness target too) picks **Movie sound
tracks**: **Mix** (the default) or **Mix and Stems**, which gives the
movie a stereo track of the mix first and then one per layer with sound,
in layer order, for a mixer to rework (`CompositionExporter.addStems`).
The mix track is mastered when a target is set; the stems never are. The
export session keeps the tracks apart since none of them goes through an
audio mix any more.

Both read the mix out the way mastering does, through the composition's
audio mix (`LoudnessMastering.render`, without its limiter unless a
target is set). Samples past full scale clip in the file, as they would
on any fixed-point delivery.

## Recording

The record button in the timeline's header records a **take** onto the
timeline. Its popover picks what to record from: an **input** (the
default input, or any microphone or interface) or an **app**'s sound
(any running app Core Audio knows, playing ones first). With **Play the
timeline while recording** on (the default), the timeline plays from the
playhead while the take records, for voice-over or for catching what a
DAW or browser plays in time with the picture; off, the take lands at the
playhead. **Stop** (or Return) ends it. The button stays red while a take
records, and the popover shows its length and level. Both choices are
remembered in the app's defaults.

The take goes on a new Sound layer at the top of its area, as a clip of a
new asset named for when it was recorded ("Recording 2026-10-17 at
22.05.09"). The file is a 32-bit float CAF at the source's own rate,
copied into the project's `Media/` folder, or for a project not saved yet
kept in `Music/Animation Meets Video/Recordings`.

- **Inputs** record through an audio engine's input node, pointed at the
  chosen device (`InputCapture`). macOS asks once for the microphone.
- **Apps** record through a Core Audio process tap on every process of
  the app (a browser plays from its helpers), read by a private aggregate
  device on the default output's clock (`AppCapture`). The app is still
  heard. macOS asks once whether other apps' sound may be recorded.
- Buffers are written as they arrive, off the main thread
  (`TakeWriter`). Each carries the host time it reached the computer; the
  first one that arrives once the timeline is moving is converted through
  the player item's timebase to timeline time, and the take is placed
  back from there by the frames that came before it. An input's own
  latency (its device's latency, safety offset and stream latency) is
  taken off first, so a voice lands where it was spoken against what was
  heard. Sound clips aren't held to frames, so the take keeps that time
  exactly.

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

- Pan in the timeline's volume row and lines.
- Dragging the level line up and down in the lane; levels are set in the
  field or with the fader.
- A way to keep a clip's sound from fading under a transition.
- Sound effects on Sound and Music layers.
- A meter per layer, and a meter reading while scrubbing or paused.
- Integrated loudness of the timeline in the editor, and loudness range.
- A true-peak ceiling.
- Surround (5.1) sound: there is no surround panning to fill its channels.
- Names on a movie's stem tracks.
