# Parameters in the timeline

Status: **partly built** (steps 1 to 3 of [Building it](#building-it),
not yet tried in the running app). The rest is planned.


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
  effects panel, puts every control of that effect in the timeline; over
  an effect whose controls are all shown it reads **Remove All from
  Timeline** and takes them out. A graphic clip's own shape (its
  drawing, whose ⋯ menu is shorter than an effect's) has it too. In the
  inspector, the same item is in the context menu of each shape group's
  title (a shape's settings, Fill & Stroke, and a Text effect's
  Character, Paragraph and Path), for that group's controls. Its key
  (**U** in the effects panel) is not built yet.
- **Show in Timeline** in a single control's ⋯ menu puts in just that
  one, as does a control's context menu in the inspector's shape
  groups. Both menus build their items from `ParameterRowMenuItems`.
  A Text effect's run and variation lanes (`.textRun`,
  `.textVariation`) aren't controls, so they can't be rows yet.
- **Adding a keyframe** to a control puts it in, from anywhere: the
  panel's stopwatch or lane, the viewer's handles, a graph editor, a
  Keyframing method writing its first keyframes. This is the default
  behavior, which can be turned off (see [Settings](#settings)). It is
  worked out rather than recorded: a clip's rows are those picked by
  hand and those it has keyframes on, less those taken out by hand
  (`TimelineParameterRows.keys(of:addsKeyframed:)`), so nothing needs to
  watch for keyframes being added.

Picking one from the effects panel opens its layer's rows, so it shows.

**Remove from Timeline**, in a row's menu and in the control's ⋯ menu
(which shows it in place of Show in Timeline), takes a row out. Taking
a row out leaves its keyframes as they are. Only controls that can be
rows are offered: numbers and colors, not choices, curves, paths or
gradients (`EffectControl.isDrivable`), of a clip's picture effects
other than Keyframing ones, and of its sound effects.

### The rows

- **Disclosure triangles**: the layer header's arrow shows or hides all
  its rows, its volume row with them; a video layer has the arrow once
  its clips have rows. Under it, each effect is a row of its own with an
  arrow, its controls indented under it, as in the effects panel, so a
  long stack folds to one row an effect. Option-click opens or closes
  every effect's arrow of the layer, as in the Finder.
- **Each control row** has, as the volume row does and the effects
  panel's rows do: the stopwatch, the name, the value at the playhead
  (drag it, or click to type, arithmetic and all; "Mixed" where the
  clips it acts on differ, a dash with none), and the previous, add and
  next keyframe buttons, which go to the keyframes of every clip on the
  row. Its ⋯ menu has Remove from Timeline; Keyframe Designer…, Show in
  Graph Editor and Reveal in Effects Panel are not built yet.
- **The label column** widens to fit the rows while any are shown, as
  it does for the volume rows.
- **The lane** to its right, under the clips, shows the keyframes of
  every clip on the row (`ParameterLaneMarks`), each where it plays, as
  diamonds with the volume row's interactions: click to go to it, drag
  to retime (Option to copy), right-click for eases and Delete, each
  routed to its clip in its source time. Picks across the timeline's
  lanes and the panel's as one (`LaneKeyframePicks`), so a lasso can
  take keyframes on several rows and clips at once, are not built yet.
- **Driven controls**: a control a Keyframing method drives shows its
  keyframes in the generated keyframes' color, as every lane does, and
  refuses hand edits as everywhere else, since the project's state
  refuses them ([Editing by hand](keyframing-effects.md#editing-by-hand));
  its method's badge in the row is not built yet.
- **Keyframes are in the clip's source time**, so a lane follows the
  clip's moves, trims and speed, as the panel's does.

### Settings

- **Add parameters to the timeline when keyframed**: on or off in
  Settings ▸ Timeline (`Preferences.addsKeyframedParameters`), for every
  project; a project's own setting in Project Settings is not built
  yet. Turning it off leaves the rows already shown: the timeline keeps
  them as picked by hand (`keepKeyframedRows`).
- **Hide parameter rows**: in Settings ▸ Timeline, hides every parameter
  row without forgetting them, for a compact timeline; turning it back
  on shows the same rows. Also Parameter rows in the timeline's view
options, under Areas.
- Which rows each clip has, and which effects' arrows are closed, is
  kept in the project's `view-state.json`
  ([project-package.md](project-package.md#view-state)) as each
  timeline's `rows`, not in the project file: it is how the timeline is
  looked at, not what plays, so showing or hiding a row is not an undo
  step and doesn't mark the project edited. It is held for the window
  by `ParameterRowsStore`, which the timeline and the effects panel both
  change, and rows of clips and layers that are gone are let go when it
  is saved. Whether a layer's arrow is open is not kept, as for the
  volume rows.

### Animated and changed

As After Effects' U and UU, **U** in the timeline shows only the
controls of the layers' clips (as above) that have **keyframes**, and **U pressed twice**
quickly only those **changed from their defaults**, keyframed or not,
picked into the timeline or not. Each is a filter over the rows, not a
change to what is picked: pressing U again, or Escape in the label
column, goes back to the picked rows. A note in the layer header says
which filter is on. The same is in the View menu, as Show Animated
Parameters and Show Changed Parameters.

Built as a note in the timeline's title bar, rather than in each layer
header, which also turns the filter off when clicked; while one is on,
every layer with such parameters shows its rows, whether or not its
arrow is open (`ParameterRowFilter`). Escape anywhere in the timeline, not only
the label column, turns it off. Changed is measured against what
a new effect of the kind has, its shapes sized to the frame. The View
menu's items are not built yet.

### Graph mode (not yet)

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

Built in the effects panel (`CopiedKeyframes`, `EditorClipboard.keyframes`):
⌘C and ⌘X (and the Edit menu) copy or cut the keyframes picked in its
lanes, with their times apart in the timeline's time, their values,
eases and holds, and ⌘V pastes them at the playhead onto the selected
clip: onto the same controls, matched as the rows match them, or with
one control's keyframes copied and a control selected, onto that one
when it has as many numbers. Pasted keyframes replace any at the same
times; a paste that finds no control says so. They go on the pasteboard
as JSON too. Not built yet: copying and pasting in the timeline's own
lanes (which have no picks yet), pasting onto several clips, Option-drag
of several picked keyframes, and pasting JSON from elsewhere back in.

### Other kinds of lanes (not yet)

Every kind of lane the effects panel has can be a row: a text run's
settings, a variable font's axes, a clip's speed, and volume and pan,
each with its own value editor in the row, as in the panel. Speed
shows under the clip with the same eases as in the
[Motion Designer](motion-designer.md). Volume rows become ordinary
rows of this kind, so Shift-L shows or hides the volume rows, as today,
alongside what has been picked.

### Accessibility

Following [accessibility.md](accessibility.md). Built: each effect row
is an element with its name, whether it is open and an action to open
or close it; each control row has its name, its value fields (or
"Mixed"), and an action to Remove from Timeline; the diamonds are the
volume row's. The rest below is not built yet:

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

## Testing

- `TimelineParameterRowsTests`: a keyframed control is in the rows
  until taken out, and not with adding off; clips share a row and a
  second effect of a kind has its own; selecting narrows a layer to its
  clips' rows; a row acts on the selected clips or the one under the
  playhead, reads "Mixed" where they differ, and sets them all as one
  edit; turning adding off keeps the rows shown; rows of clips and
  layers that are gone are let go; `view-state.json` keeps them; and U
  shows the animated parameters and UU the changed ones, whatever is
  picked.
- `KeyframeCopyingTests`: keyframes paste at the playhead onto the same
  control keeping their spacing and eases, and replace those at the same
  times; one control's paste onto another with as many numbers, not one
  with more; and they go through their text.
- `UISnapshots.parameterRows`: the rows in the names column and their
  lanes.

## Building it

1. **Rows** (done): the rows above under each layer, picked from the
   effects panel's menus or by keyframing, their values, stopwatch,
   keyframe buttons and lanes, the settings in Settings ▸ Timeline, and
   the view state.
2. **U and UU** (done), but for the View menu's items and the effects
   panel's U.
3. **Copying keyframes** (done in the effects panel); in the timeline's
   lanes, with picks across them, not yet.
4. **Graph mode** (not yet).
5. **Other kinds of lanes** (not yet): text runs, axes, speed, and the
   volume rows as ordinary rows; the row menu's other items, the
   method's badge, the keys of the names column, and the per-project
   setting.
