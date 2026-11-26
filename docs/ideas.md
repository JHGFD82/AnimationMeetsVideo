# Ideas

Status: **planned, not designed**. Features to add, each short enough to
talk through before it gets a design doc of its own. When an idea is
taken up, move it into the document it belongs to (or a new one) and
take it out of here.

## Parameters in the timeline

Effect parameters edited in rows under their layer in the timeline, as
After Effects shows a layer's properties, but holding only the
parameters picked for it rather than all of them. The timeline had rows
like these for the four layer-transform properties until effects
replaced the transform
([layer-transforms.md](layer-transforms.md#in-the-timeline)); today
only the volume rows are left (Shift-L, [audio.md](audio.md)). This
brings rows back for any keyframed control of a clip's effects and sound
effects, the volume rows among them.

### Which rows a layer shows

A layer's rows are the parameters **of the clips selected on it**, or,
when none of its clips is selected, **of every clip on it**, as After
Effects always shows a layer's rows. So nothing comes and goes as the
playhead moves or a selection is let go, and selecting clips narrows a
layer to theirs; a layer with no clip selected shows all of its own,
whatever is selected on other layers. Either way there is one
**shared row** a parameter: each clip's Glow Intensity is one
row, whose lane draws each clip's keyframes under its block, and a clip
without that control leaves its stretch of the lane empty. Controls are
matched by effect kind and control, and a clip with two effects of one
kind by their order among them ("Glow", "Glow 2"). What each clip has
put in the timeline stays with the clip, and a row shows while any of
the clips it is for has put it in.

The clips a row **acts on** are the selected clips of its layer or,
with none selected, the clip under the playhead:

- **The value** is their value at the playhead, or "Mixed" when they
  differ, or empty with no clip under the playhead. Typing or dragging
  it sets it on each of them, at the playhead for each that is keyframed (so a
  keyframe is added there) and outright for the rest, as one undo step.
- **The stopwatch and keyframe buttons** act on each of them the
  playhead is over; previous and next go to the nearest keyframe of any
  clip on the row.

A parameter gets into the timeline in three ways:

- **Show All in Timeline**, a new item in an effect's ⋯ menu in the
  effects panel, with a key (**U** in the effects panel, where it is
  free), puts every control of that effect in the timeline. Pressed
  again over an effect whose controls are all shown, it takes them out.
- **Show in Timeline** in a single control's ⋯ menu puts in just that
  one.
- **Adding a keyframe** to a control puts it in, from anywhere: the
  panel's stopwatch or lane, the viewer's handles, a graph editor, a
  Keyframing method writing its first keyframes. This is the default
  behavior, which can be turned off (see [Settings](#settings)).

**Remove from Timeline**, in a row's menu and in the control's ⋯ menu
(which shows it in place of Show in Timeline), takes a row out. Taking
a row out leaves its keyframes as they are.

### The rows

- **Disclosure triangles**: the layer header's arrow shows or hides all
  its rows (today it does so for the volume row). Under it, each effect
  is a row of its own with an arrow, its controls indented under it, as
  in the effects panel, so a long stack folds to one row an effect.
  Option-click opens or closes every arrow beneath, as in the Finder.
- **Each control row** has, as the volume row does and the effects
  panel's rows do: the stopwatch, the name, the value at the playhead
  (drag it, or click to type, arithmetic and all), and the previous,
  add and next keyframe buttons. Its ⋯ menu adds Keyframe Designer…,
  Show in Graph Editor, Reveal in Effects Panel and Remove from
  Timeline.
- **The label column** widens to fit the rows while any are shown, as
  it did for the transform rows.
- **The lane** to its right, under the clips, shows the keyframes as
  diamonds with the same interactions as the panel's lanes: click to go
  to it, drag to retime (Option to copy), right-click for eases and
  Delete. Picks run across the timeline's lanes and the panel's as one
  (`LaneKeyframePicks`), so a lasso can take keyframes on several rows
  and clips at once.
- **Driven controls**: a control a Keyframing method drives shows its
  method's badge and its keyframes in the method's color, and refuses
  hand edits as everywhere else
  ([Editing by hand](keyframing-effects.md#editing-by-hand)).
- **Keyframes are in the clip's source time**, so a lane follows the
  clip's moves, trims and speed, as the panel's does.

### Settings

- **Add parameters to the timeline when keyframed**: on or off, in
  Project Settings for this project, and in Settings ▸ Timeline as the
  app-wide default that new projects start with. Turning it off leaves
  the rows already shown.
- **Hide parameter rows**: a View option (and in Settings ▸ Timeline)
  that hides every parameter row without forgetting them, for a compact
  timeline; turning it back on shows the same rows.
- Which rows each clip has, and which arrows are open, is kept in the
  project's `view-state.json`
  ([project-package.md](project-package.md#view-state)), not in the
  project file: it is how the timeline is looked at, not what plays, so
  showing or hiding a row is not an undo step and doesn't mark the
  project edited.

### Animated and changed

As After Effects' U and UU, **U** in the timeline shows only the
controls of the layers' clips (as above) that have **keyframes**, and **U pressed twice**
quickly only those **changed from their defaults**, keyframed or not,
picked into the timeline or not. Each is a filter over the rows, not a
change to what is picked: pressing U again, or Escape in the label
column, goes back to the picked rows. A note in the layer header says
which filter is on. The same is in the View menu, as Show Animated
Parameters and Show Changed Parameters.

### Graph mode

A **Graph** button at the top of the timeline's label column (and a
key: **G**, free in the timeline, or ⇧F3 as in After Effects) turns
the track area into a **graph**, as After Effects' Graph Editor does in
its timeline: the clips, sections and lanes give way to one value graph
across the timeline's width, and the label column stays with its layers
and rows. Pressing it again brings the clips back.

- **Which curves**: the rows picked in the label column (click a row,
  Shift-click a range, Command-click to add or take out), or, with none
  picked, every row shown. Each row's curve keeps its colors (X red, Y
  green, a single value yellow), and a picked row's are drawn bold.
- **The same graph** as the graph editors' (`KeyframeGraphView`): the
  same keyframe marks, handles, eases, lasso, F9 keys and Fit, with
  each curve fitted to its own value range or all to one, but in the
  timeline's time rather than a clip's source time, so curves of
  several clips line up with the ruler, the playhead, the loop region
  and the beat markers above them.
- **The ruler, playhead, zoom and scroll** are the timeline's own:
  graph mode zooms and scrolls in time with the clips' view, and
  leaving it keeps where it was.
- Driven controls draw their curves in their method's color and refuse
  hand edits, as in the lanes.
- Graph mode is kept with the timeline in `view-state.json`.

### Copying keyframes

With keyframes picked in the lanes or the graph, **⌘C** copies them
rather than the clips, and **⌘X** cuts them (the effects panel and the
timeline both offer it, as for clips and effects in
[Copy, paste and duplicate](timeline.md#copy-paste-and-duplicate)).

- **⌘V pastes them at the playhead**, keeping their times apart and
  their values and eases, onto the rows picked in the label column:
  onto the same controls they came from when no row is picked, or onto
  one picked row (a single control's keyframes onto any control of the
  same number of components, or a single component's onto one of a
  Position's). Pasted keyframes replace any at the same frames.
- They paste onto the clips the row acts on that the playhead is over,
  so a pulse made on one clip can be stamped onto several.
- **Option-drag** copies picked keyframes within their rows, as it does
  for one keyframe today.
- Copied keyframes go on the pasteboard as JSON too, so they paste into
  the effects panel's lanes and into a text editor alike.
- A paste onto a driven control is refused, as any hand edit is.

### Other kinds of lanes

Every kind of lane the effects panel has can be a row: a text run's
settings, a variable font's axes, a clip's speed, and volume and pan,
each with its own value editor in the row, as in the panel. Speed
shows under the clip with the same eases as in the
[Motion Designer](motion-designer.md). Volume rows become ordinary
rows of this kind, so Shift-L shows or hides the volume rows, as today,
alongside what has been picked.

### Accessibility

Following [accessibility.md](accessibility.md):

- Each layer, effect and control row is an accessibility element in an
  outline: its name, its value (or "Mixed"), whether it is open, and
  actions to open, close and Remove from Timeline. A control row is
  adjustable, and its value field takes typing as in the panel.
- Each diamond is an element with the actions the panel's lanes have
  (Add to selection, Move a frame earlier or later), and its value says
  which clip it is on.
- Keys for everything the arrows and drags do: in the label column, ↑
  and ↓ move between rows, → opens a row and ← closes it (Option for
  all beneath), Return types a value, and Delete takes the row out. ⌘A,
  ← → and Escape pick and move keyframes, as in the panel.
- In graph mode the curves have the graph editors' elements and
  actions, and the Graph button is labeled and says whether it is on.

## Smoother scrubbing on laptops

Scrubbing and skimming H.264 and HEVC footage on the timeline is too
heavy for a laptop. The first idea was to turn each clip into ProRes
when it is added to the timeline; this entry checks that against how
the app works and proposes doing without the copies first.

### Why scrubbing is heavy now

- **Every scrub was an exact seek.** Moving the playhead or skimming
  seeked the player to the exact frame (`PlaybackModel`, tolerances of
  zero), one seek at a time with the newest move next; step 1 below now
  seeks roughly while it moves fast. H.264 and HEVC
  are long-GOP: a frame can only be decoded from the keyframe before it,
  often a second or more back, so each step of a scrub decodes up to a
  whole GOP to show one frame. Playing forward is cheap, since the
  hardware decoder goes frame by frame; jumping around is what costs.
- **Sources are decoded at full size.** Half and Quarter make
  compositing cheaper, not decoding
  ([rendering.md](rendering.md#viewer-quality-implemented)), so a 4K
  clip costs a 4K decode per seek, and each layer of a stack adds its
  own.
- **Drawing ahead skips plain clips.** `PlayheadPrerenderer` keeps the
  pictures of the two seconds after the playhead, but only of stretches
  worth keeping (effects, stacks), not plain footage.

### ProRes copies, checked

It would work technically: clips point at assets, not files, so
decoding could read another file behind an asset, and the app already
writes ProRes for its render cache. But:

- **It reverses a stated rule.** The shared principles say the app
  never makes proxies, optimized copies or transcodes of footage
  ([README.md](README.md#shared-principles)), and
  [media-replacement.md](media-replacement.md) chose replacing files
  over proxies because of disk space.
- **Disk is acceptable.** ProRes 422 is about 147 Mb/s at 1080p30
  (66 GB an hour) and about 590 Mb/s at 4K30 (265 GB an hour), roughly
  ten times the H.264 or HEVC it comes from; 10-bit and HDR footage
  needs 422 HQ, larger again. But projects average about three minutes,
  and only the clips used on a timeline are copied, not the browser's,
  so a typical project's copies are 13 GB or so of 4K; an hour-long one
  at about 300 GB is reasonable too.
- **The laptop pays first.** Every clip added starts an encode. Macs
  with a ProRes engine (M1 Pro and Max, and later chips) do it faster
  than real time; others encode in software, slowly and on battery.
- **Timing has to match exactly.** Phone footage is often variable
  frame rate; a copy must keep every frame's own time or cuts, beats
  and keyframes drift against the original.
- **Export still reads the originals**, both for quality (ProRes 422 is
  not lossless) and because untouched stretches pass through as they
  are, so there would be two decode paths to keep alike. Replacing a
  file must throw its copy away.
- **It doesn't make effects faster.** An effect's cost is compositing,
  which is the same over ProRes. Heavy stretches are already rendered to
  ProRes in the background ([Render cache](rendering.md#render-cache-implemented)),
  and clips' pictures are kept between frames.

### Without copies

In order, each measured on a laptop before the next:

1. **Rough, then exact** (built, not yet measured on a laptop): see
   [rendering.md](rendering.md#rough-then-exact). Fast moves of the
   playhead or the skimmer seek with a tolerance, and the player lands
   on the exact frame 100 ms after they stop. A change to the seek queue
   alone, costing no disk.
2. **A scrub cache.** Paused, decode the footage around the playhead,
   forward from each keyframe as the hardware decoder likes, at the
   viewer's size, and keep the frames in memory, as
   `PlayheadPrerenderer` does for stretches with effects. Moving back
   and forth over that stretch then draws from memory. A quarter-size
   1080p frame is about half a megabyte, so ten seconds of 30 fps is
   150 MB.
3. **Decoding at the viewer's size**, where VideoToolbox can scale in
   the decoder, so a Quarter viewer stops paying for a full 4K decode.
4. **Thumbnails while catching up.** The asset's reference thumbnails
   and filmstrips are already on disk; while a seek is behind, a plain
   clip can show the nearest one until its frame arrives.

### If that isn't enough: ProRes copies of the clips used

The ProRes idea itself, as the fallback if the steps above still leave
laptops behind. Disk being acceptable, the copies are full size rather
than small proxies, so they serve playing as well as scrubbing:

- **Full size and all-intra**: ProRes 422, or 422 HQ for 10-bit and
  HDR footage, at the footage's own size and frame times, so any frame
  decodes on its own and a stack of layers decodes cheaply too.
- **Only what is used**: the clip's range on the timeline plus a few
  seconds of handles, made in the background after it is added (on the
  ProRes engine where the Mac has one), and never while playing, on
  battery or in Low Power Mode. Trimming a clip longer copies the new
  part; until a copy is done, the original plays.
- **Only for the viewer.** Scrubbing, skimming and playing read the
  copy; export always reads the original, so nothing about the output
  changes, and untouched stretches still pass through as they are.
- **Exact timing**: each frame keeps the original's own time, variable
  frame rate included, checked against the original's frame times
  before the copy is used.
- **Disposable**: in `Cache/`, kept while a timeline uses the clip and
  thrown away when no timeline does or the file is replaced. Project
  Settings shows how much they take, with a button to clear them.
- **A setting**, in Project Settings with an app-wide default for new
  projects, off unless turned on.

This needs the shared principle about proxies amended
([README.md](README.md#shared-principles)): footage is still never
re-encoded to be editable or exported, but disposable ProRes copies of
the clips used may be made to draw the viewer. The disk-space reason in
[media-replacement.md](media-replacement.md) was about proxies of
long-form footage, which this doesn't make.

## Waveform effect

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
  Transform) act on the waveform too.
- **And a generator**: the browser's Generators tab gets a Waveform
  item that makes a clip of its own with the effect and nothing under
  it, for a waveform on its own layer over the footage.
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
drawing it is.

### Settings

- **Mode**:
  - **Wave**: the sound's samples over a window of time, the wave
    itself.
  - **Spectrum**: how loud each frequency is at the frame's time, low to
    high along the shape, from the spectrogram Audio Keys already makes
    (48 bands from 20 Hz to 20 kHz, 50 times a second), spaced by
    octave and blended between bands when there are more points than
    bands.
- **Frequency range**, as Audio Keys has, so it draws only the kick or
  only the vocal: in Spectrum, the bands shown; in Wave, the sound
  filtered to that range first, with the same biquads as the
  [EQ](equalizer.md).
- **Shape**:
  - **Line**: from a start point to an end point, both points dragged
    in the viewer ([viewer-handles.md](viewer-handles.md)), the
    waveform rising off it on one side, the other or both (mirrored).
  - **Radial**: around a center with a radius, both dragged in the
    viewer, starting at an angle and going round a sweep (360° for a
    full ring, less for an arc), the waveform outward, inward or both.
- **Samples**: how many points across the line or round the circle (64
  to 2048, 256 by default).
- **Window** (Wave): how much sound the points span, in milliseconds: a
  few for an oscilloscope's single wave, a second or more for a sound's
  shape scrolling past. **Align** puts the frame's time at the start,
  the middle or the end of the window.
- **Draw** as:
  - **Lines**: the points connected, with a width, straight or smoothed
    between points, and a fill to the baseline if wanted.
  - **Dots**: a dot at each point, with a size.
  - **Bars**: a bar from the baseline to each point, with a width (a
    share of the spacing between points, so the rest is the gap) and
    square or round ends; mirrored, a bar reaches both ways.
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
- **Smoothing** over time: an attack and release per point, so a
  dot doesn't jitter from frame to frame.
- **Color**:
  - **Solid**: fill and stroke colors with opacity, picked with a color
    well as for shapes.
  - **Along**: a gradient along the line or round the ring.
  - **By level**: a gradient from quiet to loud, each point, dot or bar
    colored by how far it reaches, or a bar shaded up its length.

  Gradients have two or more stops; they share the gradient editor
  planned for shapes ([graphic-layers.md](graphic-layers.md)) once it
  is built. With Stereo set to Two, the right channel has its own.

Every numeric setting can be keyframed and driven by a Keyframing
method, so a Beat Keys pulse can swell its height on the beat.

### Presets

Built-in **preset styles** to start from, shown in the Effects Library
with their previews and saved and shared as any effect preset is
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

- **Sound data**: the app keeps a waveform per file at 200 peaks a
  second (`Waveform`), enough for a long window but not for an
  oscilloscope's single wave, so the effect reads the file's samples
  themselves near each frame's time, as the mix is read for scrubbing.
  It keeps them per file for the session, as `WaveformCache` and
  `SpectrogramStore` do, at the file's own rate so a frequency range
  can reach 20 kHz: 16-bit stereo at 48 kHz is about 35 MB for a
  three-minute song.
- **Every frame is new** while the sound moves: it is marked as
  changing every frame, and its render key holds a fingerprint of what
  it listens to, as Audio Keys' does, so renders follow a change to the
  sound, its volume or its EQ.
- Under motion blur, it is drawn at each moment between frames from the
  sound at that moment.

## Gradient builder

One gradient builder for everything that has a fill or a stroke, so any
of them can be painted with a gradient instead of a single color. It is
step (c), Gradients, of [graphic-layers.md](graphic-layers.md), which
plans linear and radial gradient fills for fills and strokes alike;
this entry is that plan widened to the whole app.

### Where it is offered

Everywhere a fill or stroke is a color today, the color is replaced by
a **paint**: a solid color, as now, or a gradient.

- **Shapes and free paths**: Fill and Stroke in Fill & Stroke
  (`PaintInspectorGroup`) and the effects panel.
- **Text**: the block's fill and stroke, and each styled run's own,
  which paint their letters.
- **The Stroke effect**, whose stroke goes around everything above it.
- **The Waveform effect**: its Along and By level colors (see
  [Waveform effect](#waveform-effect)) are this builder.
- **Effect packages**: a new `gradient` control type, handed to the
  kernel as a 256 × 1 picture of the gradient to sample, as Gradient
  Map draws its stops today
  ([psychedelic-effects.md](psychedelic-effects.md)). Gradient Map moves
  to it, so it has as many stops as it likes rather than three.

### Kinds

- **Linear**: from a start point to an end point.
- **Radial**: from a center out to a radius, with a **focal point**
  that can move off the center for a lit-sphere look, and an aspect
  and angle for an ellipse.
- **Angular**: round a center from a start angle, as a conic gradient,
  which suits a radial waveform's ring.
- **Repeat**: past its ends a gradient holds its end colors (the
  default), repeats, or reflects back and forth.

### Stops

- **A bar of stops** under the gradient's preview, as in Illustrator:
  each stop a color with opacity, at a location from 0 to 100%. Click
  the bar to add a stop with the color the gradient has there, drag a
  stop to move it, drag it off the bar or press Delete to take it out,
  Option-drag to copy it. Two stops at the same place make a hard edge.
- **A midpoint** between each pair of stops, a diamond dragged to where
  the two colors are half and half, for a gradient that leans one way.
- **The picked stop** has its color (the Mac's color picker, with its
  eyedropper), its opacity and its location as fields.
- **Reverse**, and **Distribute** to space the stops evenly.
- **Blend in**: the timeline's own values (as colors are drawn today)
  or a perceptual space (OKLab), whose middles don't go gray or muddy
  between saturated colors.

### Where it lies

- **Relative to the item** (the default): its points are in the item's
  bounds, so it moves, scales and turns with the shape or text, and a
  gradient copied to another shape fits it. **Relative to the frame**
  keeps it still while the item moves through it.
- **Handles in the viewer**
  ([viewer-handles.md](viewer-handles.md)): a selected item's gradient
  shows its line (start and end, or center, radius and focal point)
  over the picture, with its stops on it to drag, as Illustrator's
  gradient annotator does.
- **Text**: over the whole block (the default) or over **each letter**,
  each painted with the whole gradient.

### On strokes

A stroke's gradient can lie three ways, as Illustrator's can:

- **Within**: in space, as a fill's does, the stroke showing the part of
  the gradient under it.
- **Along**: following the path from its start to its end, so a line
  drawn on changes color as it goes.
- **Across**: from one edge of the stroke to the other, the same all
  along it.

Along and Across need how far along the path and how far across the
stroke each pixel is, which Core Graphics doesn't give; the stroke is
drawn with those as a second picture, from the path cut into short
pieces, and the gradient looked up from it.

### Animating

Every stop's color, opacity, location and midpoint, the points, angle,
radius and focal point are keyframed like any control. Stops are
matched by their order, so two keyframes always blend stop by stop:
adding or removing a stop does it in every keyframe at once (at the
color the gradient has there), and the count never differs between
keyframes.

### Presets

The paint popover keeps **saved gradients**, kept for the Mac rather
than the project, beside a set that ships: a few neutrals, a sunset, a rainbow, a metal sheen and
transparent-to-color fades. Saving the one being edited adds it. Each
is copied in when picked, so changing a saved gradient later doesn't
change what was painted with it.

### Drawing and saving

- **Drawing**: Core Graphics draws linear and radial gradients clipped
  to each fill or stroke's area, in 32-bit floats as fills are drawn
  now (`ShapeRendering`), and conic gradients on the macOS versions
  that have them, with a kernel otherwise. A **Dither** setting (on by
  default) adds a little noise so a slow gradient doesn't band once
  exported at 8 bits.
- **Sharpness**: a gradient follows its item through the moves that
  keep shapes sharp, as its outline does.
- **Render key**: the paint is part of the shape's step, so changing a
  stop re-renders it.
- **Saving**: a paint is saved as a color, as now, or as an object of
  its kind, stops, midpoints, points, repeat, blending space and
  where it lies; a project saved before gradients loads every color as
  a solid paint.

### Accessibility

Following [accessibility.md](accessibility.md): the stop bar is an
accessibility element with each stop a child, adjustable for its
location, with actions to add a stop after it, remove it, and pick the
next or previous. Tab moves between stops, ← → move the picked one a
percent (ten with Shift), Return opens its color, and Delete takes it
out. The paint well says whether it holds a color or a gradient and of
which kind, and the viewer's gradient handles have the actions the
other handles have.
