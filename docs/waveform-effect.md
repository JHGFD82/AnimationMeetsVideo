# Waveform effect

Status: **built**, not yet tried in the running app; what is left is
under [Not yet](#not-yet). It was talked through in ideas.md first.

An effect that draws a sound's waveform over the picture, moving with
the sound as it plays: along a **straight line** or around a **circle**
(radial), as many points as asked for, drawn as **connected lines**,
**dots** or **bars**, as the wave itself or its spectrum, from a set
of **preset styles** or set by hand.

### Where it sits

- **An effect in the Effects Library**, so it goes in any visual clip's
  stack and draws over the picture handed down to it, as the shapes do
  in a shape clip ([effects.md](effects.md#shapes)). Effects below it
  shape the picture under it; effects after it (a Glow, a Blur, a
  Transform) act on the waveform too. It is the one shape kind the
  library lists (`EffectsListPanel.kinds`) and any stack takes
  (`EditingProject.stack(of:takes:)`).
- **And a generator**: the browser's Generators tab has a Waveform item
  that makes a clip of its own with the effect and nothing under it,
  for a waveform on its own layer over the footage, fitted to the frame
  (`Effect.shapeValues`: a line across the middle two thirds, white,
  3 pixels wide, a sixth of the frame high).
- **In the inspector** its settings show as a shape's do, only those of
  its shape, mode and drawing (`Effect.waveformShows`), with a Listen
  To row and Fill & Stroke after them.
- **In Swift, not a package.** It needs the sound and vector drawing,
  neither of which a package's kernel has, so it joins
  [What stays in Swift](effect-packages.md#what-stays-in-swift) beside
  the shapes and Stroke, drawing with Core Graphics as they do.

### What it listens to

**Listen To**, as Audio Keys has it: the whole mix (the default), a
Sound or Music layer, or one clip with sound, each as heard, with its
volume and EQ ([Audio Keys](keyframing-effects.md#audio-keys-in-detail)).
What it draws at each frame is the sound around that frame's time on
the timeline, so it lines up with what is heard wherever the clip
drawing it is. It is saved as the effect's `listensToLayer` or
`listensToClip`, neither for the mix.

What it hears is worked out when the timeline is built
(`EditingProject.waveformSounds`, kept on the clip's `ClipStack`): each
clip with sound from a file, where it plays and its volume and its
layer's, and the EQs on the clip and its layer. A **nested timeline**
it hears is heard as its whole mix: each file inside it keeps the chain
of clips it plays through (`WaveformSound.Source.chain`), each mapping
its timeline's time into the next one in and adding its volume and EQ,
up to eight deep. The **EQ** is heard where the Waveform reads the
sound sample by sample (a spectrum, a level, the Spectrogram, and Wave
whenever the sound has an EQ), each source run through its EQs' filters
as they are set at the middle of the run, from 50 ms before it so they
have settled (`WaveformAudio.equalized`). A volume or EQ is a value,
not part of what the timeline is built from, so on its own an edit to
one doesn't build the player again; with a Waveform anywhere in the
project, `CompositionKey` keeps volumes and EQ settings, so such an
edit builds it again and the waveform follows at once. Dragging a
volume then rebuilds as it goes, which costs more than without a
Waveform.

### Settings

- **Mode**:
  - **Wave**: the sound's samples over a window of time, the wave
    itself.
  - **Spectrum**: how loud each frequency is at the frame's time, low to
    high along the shape, spaced by octave: a 4096-point FFT (a Hann
    window, about a tenth of a second) of the mix around the frame's
    time, read at each point's frequency, from −80 dB to full scale.
    It is worked out from the samples rather than from the spectrogram
    Audio Keys makes, so it has as many points as asked for and a
    spectrum for each channel.
  - **Level**: how loud the sound is, as a meter: its RMS over the last
    50 ms, a VU meter's span, with a full-scale sine reaching the full
    Height. One bar for the mix, or with Stereo set otherwise a bar a
    channel side by side, the right in its own color; always drawn as
    bars and colored by level (`WaveformAudio.level`).
  - **Spectrogram**: the spectrum over the Window before the frame's
    time as a scrolling heat map: a column a moment, oldest at the
    shape's start, newest at its end, and as many bands as Samples (at
    most 128) up from the baseline to the Height (or about it, Mirrored).
    Each cell is shaded by how loud it is: the Fill's gradient at that
    level, or the Fill's color that opaque. Cells of one shade (32 of
    them) are drawn as one area. Columns are on the look-back grid below,
    at most 200 of them, so as it plays only the newest is measured.
- **Scale** (Spectrum, Spectrogram): frequencies spaced by octave
  (**Log**, the default) or by hertz (**Linear**).
- **Floor** (Spectrum, Level, Spectrogram): the quietest level shown, in
  decibels: −80 by default, from −140 to −12.
- **Frequency range**, as Audio Keys has, so it draws only the kick or
  only the vocal: in Spectrum, the bands shown; in Wave, the sound
  filtered to that range first, with the same biquads as the
  [EQ](equalizer.md)'s cuts, twice each side (24 dB an octave), run
  from 50 ms before the window so they have settled by its start
  (`WaveformDrawing.bandFilters`). Filtering reads every sample of the
  window, so a long, narrowed window costs more than a whole one.
- **Shape**:
  - **Line**: from a start point to an end point, both points dragged
    in the viewer ([viewer-handles.md](viewer-handles.md)), the
    waveform rising off it on one side, the other or both (mirrored).
  - **Radial**: around a center with a radius, both dragged in the
    viewer, starting at an angle and going round a sweep (360° for a
    full ring, less for an arc), the waveform outward, inward or both.
- **Samples**: how many points across the line or round the circle (64
  to 2048, 256 by default).
- **Spacing** (Wave, Spectrum): pixels between points along the shape,
  which then decides how many there are, so bars keep their size as the
  line is dragged longer; 0 (the default) leaves it to Samples
  (`WaveformDrawing.pointCount`).
- **Window** (Wave): how much sound the points span, in milliseconds: a
  few for an oscilloscope's single wave, a second or more for a sound's
  shape scrolling past. **Align** puts the frame's time at the start,
  the middle or the end of the window.
- **Draw** as:
  - **Lines**: the points connected, with a width, straight or smoothed
    between points, and a fill to the baseline if wanted.
  - **Dots**: a dot at each point, with a size.
  - **Area**: the space between the points and the baseline filled,
    with no line: a mountain (smoothed as Lines are).
  - **Bars**: a bar from the baseline to each point, with a width (a
    share of the spacing between points, so the rest is the gap) and
    square or round ends; mirrored, a bar reaches both ways.
  - **Rays**: a thin line from the baseline to each point, in the
    Stroke at its width, round-ended: round a ring, rays out of it.
  - **Particles**: four dots on the way out to each point, growing and
    coming in toward it, at the Dot Size: round a ring, a spray.
- **Stereo**:
  - **Mixed**: one wave of both channels (the default).
  - **Split**: left on one side of the baseline and right on the other
    (above and below a line, outward and inward round a ring).
  - **Two**: a wave for each channel along the same baseline, each in
    its own color.
  - **X–Y** (Wave): left against right as a figure, as a vectorscope
    draws it, about the line's middle or the ring's center, its size the
    Height; the window's samples are its points.

  Spectrum's Split and Two need a spectrogram for each channel, which
  the effect makes beside the mixed one.
- **Height**: how far a full-scale sample reaches from the baseline,
  and **Gain** before it, linear or in decibels so quiet sounds still
  show.
- **Attack**, **Release** and **Peak Hold** (Spectrum, Level): each
  point rises over the attack (an average of the moments before, newer
  ones counting more), falls back no faster than the release lets it
  (the loudest of the moments before, each faded by how long ago it
  was), and with a hold, a mark across each bar (or meter) stays where
  its peak was over that long, then falls (`WaveformDrawing.envelope`).
  Every frame is drawn fresh, so this is worked out by looking back:
  the measures at moments on a grid 20 ms apart before the frame's
  time, which `WaveformAudio.measured` keeps between frames.
- **Time Smoothing** (Wave): each point averaged with the same point of
  the windows just before, newer ones counting more, so the line
  settles rather than jumps from frame to frame.
- **Color**: the shapes' **Fill** (dots, bars, a fill to the
  baseline) and **Stroke** (lines, with Stroke Width), in Fill &
  Stroke, each one color or a gradient laid over the waveform as it is
  drawn now ([gradients.md](gradients.md)): a linear one across a line,
  an angular one round a ring, which is **Along**. **Color: By Level**
  colors each point, dot or bar (each segment of a line) with the
  color the Fill's gradient has at how far it reaches, from quiet to
  loud. A bar by level with a Fill gradient is **shaded up its length**:
  the gradient from its base to the full Height, so its tip has its
  level's color (reflected about the baseline when Mirrored). With
  Stereo set to Split or Two, the right channel is in **Right Channel**.

**In the inspector**, the Waveform's group starts with **Graph**, a grid
of buttons that sets several of the settings below at once
(`WaveformGraph`, `WaveformGraphPicker`), each a small picture of that
graph over its name, drawn by `WaveformDrawing` from a made-up sound
(`WaveformPreview`): **Wave** (Wave, Lines, Line), **Filled** (the same,
Fill to Baseline on), **Area**, **Dots**, **Bars** (Spectrum, Bars),
**Ring** (Wave, Lines, Radial), **Rays** and **Particles** (Spectrum
round a ring), **Scope** (Stereo X–Y), **Meter** (Level) and
**Spectrogram** (which also lengthens a Window under half a second to
three seconds). Every graph but Scope takes Stereo off X–Y. The settings
stay where they were set, to change one by one after; none of the
buttons is lit while they match none of the graphs. Mode, Shape and
Draw are icon buttons rather than menus. The effects panel has the same
choice as a **Graph** pop-up at the top of the Waveform's rows, reading
Custom while the settings match none.

Every numeric setting can be keyframed and driven by a Keyframing
method, so a Beat Keys pulse can swell its height on the beat. Start,
End and Center are points, measured from the middle of the frame, so
the viewer shows a handle for each (`PointControlHandles`).

### Presets

Built-in **preset styles** to start from, installed into the Presets
folder with the look recipes (`LookRecipes.waveformStyles`, version 2),
so they are shown in the Effects Library with their previews and saved
and shared as any effect preset is
([Copying and presets](effects.md#copying-and-presets)):

- **Oscilloscope**: a thin bright line, a short window, mirrored off.
- **Mirrored**: lines filled to the baseline, mirrored, a long window.
- **Mirrored Bars**: round-ended bars, mirrored, colored by level.
- **Ring**: radial, a full sweep, outward lines with a fill.
- **Dot Ring**: radial dots, inward and outward.
- **Scroll**: a long window trailing the playhead, filled, as a clip's
  waveform on the timeline looks.
- **Spectrum Bars**: Spectrum, 64 bars along a line, colored by level.
- **Spectrum Ring**: Spectrum, bars outward round a full ring, a
  gradient along it.
- **Split Stereo**: left above and right below a line, in two colors.
- **Stereo Scope**: X–Y, a thin line, a short window.

### Drawing and caching

- **Sound data** (`WaveformAudio`): the app keeps a waveform per file
  at 200 peaks a second (`Waveform`), enough for a long window but not
  for an oscilloscope's single wave, so the effect reads the file's
  samples themselves. It keeps them per file for the session, 16-bit
  at 44.1 kHz in up to two channels, so a spectrum reaches 20 kHz:
  about 32 MB for a three-minute stereo song. A point that stands for
  many samples (a long window) is the one furthest from silence, so
  the peaks show.
- **Reading**: building a timeline starts reading what its Waveforms
  hear in the background (`prefetch`). A frame drawn before a file is
  read reads it there and then, one reader a file, so a waveform is
  never drawn without its sound and nothing drawn or rendered needs
  drawing again when it arrives; the first frame can take a fraction
  of a second a minute of sound.
- **Drawing** (`WaveformDrawing`): lines, dots and bars are areas
  (lines stroked with round ends, smoothed with Catmull–Rom curves),
  drawn by `ShapeRendering` as shapes are, so they stay sharp under the
  moves after them, and a Stroke below outlines them.
- **Every frame is new** while the sound moves: it changes on its own
  (`Effect.changesOnItsOwn`), and its step's render key holds the time
  and a fingerprint of what it listens to (`WaveformSound.fingerprint`),
  so renders follow a change to the sound or its placement.
- Under motion blur, it is drawn at each moment the stack is resolved
  at, from the sound at that moment.

## Testing

- `WaveformTests`, over a full-scale 1 kHz sine handed to
  `WaveformAudio`: it hears its timeline's mix and not a clip it
  doesn't listen to; a full-scale wave fills its height both ways;
  nothing is drawn without sound or past the song's end; bars by level
  are a paint each; the spectrum peaks at the tone, and a silent
  channel's is empty; Split draws the right channel in its own color;
  the inspector shows the settings of how it is set; it is fitted to
  the frame; and saving keeps what it listens to.
- `WaveformFilterTests`: the whole range isn't filtered, and a low
  range keeps a 60 Hz tone and drops a 4 kHz one.
- `GeneratorTests`: it is a generator and the one shape the library
  lists, and a footage clip takes it.
- `WaveformTests` also checks the graphs and timing added since: an
  Area is one fill; Rays and Particles draw; a meter reaches its Height
  for a full-scale tone and splits by channel; Peak Hold adds a mark;
  the Spectrogram shades cells and is empty in silence; attack,
  release and hold shape the level; Scale and Floor shape the spectrum;
  Spacing sets the count; bars by level are shaded; every graph has a
  preview; it hears the song's EQ and a nested timeline's sound; and a
  volume edit builds the timeline again. `WaveformGraphTests` checks the Graph presets.
- `UISnapshots.waveformInspector`.
- Not yet: a test drawing it through the compositor from a sound file.

## Not yet

- A volume or EQ drag shown without building the timeline again.
