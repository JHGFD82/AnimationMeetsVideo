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

A layer's rows are the parameters **of the clips selected on it**, one
**shared row** a parameter: every selected clip's Glow Intensity is one
row, whose lane draws each clip's keyframes under its block, and a clip
without that control leaves its stretch of the lane empty. Controls are
matched by effect kind and control, and a clip with two effects of one
kind by their order among them ("Glow", "Glow 2"). Selecting other
clips changes the rows; what each clip has put in the timeline stays
with the clip, and a row shows while any selected clip has put it in.

With several clips on a row:

- **The value** is the selected clips' value at the playhead, or
  "Mixed" when they differ. Typing or dragging it sets it on every
  selected clip, at the playhead for each that is keyframed (so a
  keyframe is added there) and outright for the rest, as one undo step.
- **The stopwatch and keyframe buttons** act on every selected clip the
  playhead is over; previous and next go to the nearest keyframe of any
  of them.

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
selected clips' controls that have **keyframes**, and **U pressed twice**
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
- They paste onto every selected clip the playhead is over, so a pulse
  made on one clip can be stamped onto several.
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

### Worth deciding

- **With no clip selected**, should a layer show nothing, the rows of
  the clip under the playhead, or every clip's rows?
