# Ideas

Status: **planned, not designed**. Features to add, each short enough to
talk through before it gets a design doc of its own. When an idea is
taken up, move it into the document it belongs to (or a new one) and
take it out of here.

## Strobe Keys

A new Keyframing method, picked for a control in the
[Keyframe Designer](keyframing-effects.md#the-keyframe-designer) like
the others, that writes a repeating pulse onto the control: a strobe on
Opacity, a Glow's Intensity, a Scale, a Volume (a gate). It writes real
keyframes, as every method does
([The idea](keyframing-effects.md#the-idea-they-write-real-keyframes)),
so it can be baked and edited by hand afterwards. Its name keeps it
apart from Stylize's Strobe effect
([effects-stylize.md](effects-stylize.md)), which flashes the picture
itself rather than driving a control.

It is a method of its own rather than more shapes for Beat Keys, which
already pulses on each beat with a peak and a decay: the envelope,
timings and variation below would crowd Beat Keys' settings, and a
separate chip is clearer in the designer.

### Timing

Where each pulse starts, one of:

- **Beats**: on the beat markers of a beat map, from a Sound or Music
  layer (Beats From, as Beat Keys has). **Every** N beats (1), or a
  fraction of a beat: 1/2, 1/4, 1/8, and triplets (1/3, 1/6), each
  placed between the beats on either side, so it follows a tempo ramp.
  **Downbeats only** and an **Accent** on the one (+50% of the pulse's
  height) as Beat Keys has them.
- **Every N frames** of the clip's timeline. The label says "frames" in
  full, since *between frames* already means moments inside one frame
  under motion blur
  ([python-scripting.md](python-scripting.md#between-frames)).
- **Per second**: a rate in pulses a second. A rate that isn't a whole
  number of frames puts pulses between frames, so how long each is seen
  for varies from pulse to pulse; the designer says so under the field.

**Offset** shifts every pulse later, or earlier when negative: in
frames, or in beats when timed to beats.

### Envelope

Each pulse is a full ADSR envelope from Min to Max and back:

- **Attack**: from Min up to Max.
- **Decay**: from Max down to the Sustain level.
- **Sustain**: a level, as a share of the way from Min to Max (100%).
- **Sustain For**: how long it stays at that level.
- **Release**: from there back down to Min.
- The rest of the interval stays at Min.

Decay at 0 and Sustain at 100% (the defaults) make it a plain attack,
hold and release. The times are in **frames**, exact but fixed, or as a
**share of the interval**, so pulses stretch with the tempo; the second
is the default when timed to beats. Attack 0, Release 0 and Sustain For
as a share is a duty cycle, which the designer offers as a one-click
**Duty** preset.

**Curves**: Attack, Decay and Release are each linear, eased or
exponential. Exponential is the default for Release, since that is how
a flash of light dies away. An Attack or Release of 0 is a hard step,
written as hold keyframes so it doesn't ramp between frames.

**Overlap**, for an envelope longer than the interval: **Cut**, where
each pulse is cut short at the next (the default), or **Retrigger**,
where the next starts from wherever the last had reached rather than
from Min.

### Min and Max

The values the pulse moves between, with a **Swap** button that
exchanges them, so the control dips on each pulse instead of rising (an
opacity that blinks off rather than on). What they mean follows
**Combine**: values with Replace, amounts added with Add, factors with
Multiply. Multiply is the default over an opacity, scale or gain, where
a strobe should scale what's there (Min 0, Max 1); Add elsewhere.

### Variation

So it doesn't feel mechanical:

- **Swing**: every other pulse late, by a share of the interval (0%).
- **Skip chance**: the share of pulses left out (0%).
- **Pattern**: a row of steps a bar long (`x.x.xx..`), each on, off or
  accented; empty means every pulse.
- **Seed** for the skip chance, so the same seed gives the same
  keyframes.

**Fade**, in seconds, at each end of the Range, as Oscillator has,
eases the whole strobe in and out.

### Keyframes and safety

- It writes keyframes at each pulse's corners, with the curves as eases,
  rather than sampling every frame and reducing, as Beat Keys and
  Oscillator do over a target that holds still. Over an animated target
  with Add or Multiply it samples and reduces like the rest.
- **Flashing**: over a target that changes brightness (Opacity, the
  Light and Color controls), it warns above three flashes a second, as
  Stylize's Strobe does, and its defaults stay below
  ([Safety](psychedelic-effects.md#safety-flashing)).

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

- **Every scrub is an exact seek.** Moving the playhead or skimming
  seeks the player to the exact frame (`PlaybackModel`, tolerances of
  zero), one seek at a time with the newest move next. H.264 and HEVC
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

1. **Rough, then exact.** While the playhead or the skimmer moves fast,
   seek to the nearest keyframe (or with a tolerance) and show that;
   once it rests (about 100 ms, as playback already waits 250 ms before
   prerolling) land on the exact frame. Final Cut and Premiere scrub
   this way. It is a change to the seek queue alone, and costs no disk.
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
