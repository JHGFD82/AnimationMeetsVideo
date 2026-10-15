# Timeline view

Status: **implemented**: zooming and scrolling, the ruler, the playhead,
and moving and trimming clips on the frame grid. The placement rules, the
viewport math and the ruler and beat grouping are unit tested. The view
itself has been checked in offscreen renders, not yet driven on screen
with a trackpad. What is not built is listed under
[Not implemented yet](#not-implemented-yet).

The timeline sits under the library, viewer and inspector and spans the
full width of the window: a label column on the left (layer number and
name, and its volume row when shown), and the track area on the
right with the ruler across its top. The transitions panel and the effects
panel ([effects.md](effects.md#the-effects-panel)), each opened with its
button in the timeline's header (Shift-E for effects), take their place at
the right end, one at a time.

The timeline is as tall as the person makes it with the grip between it and
the viewer, whatever its layers need; it remembers that height. Under the
ruler it is split into three **areas**, top to bottom:

- **Video**: layers with pictures (`LayerKind.video`).
- **Sound**: dialogue and effects (`.sound`), including sound detached from
  video.
- **Music**: the score (`.music`). Audio files go here unless dropped
  elsewhere.

Each area has a title bar with its name and layer count, and scrolls its
layers on its own. Dragging the title bar of the sound or music area moves
its boundary with the area above, trading height between the two. The grip
above the timeline resizes every area in proportion. Neither changes how
tall a layer is: a bigger area shows more layers. Layer height is each
area's own vertical zoom (see [Zoom and scroll](#zoom-and-scroll)).
**View Options** has a checkbox per area that hides or shows it, and a
layer height slider for each. The layout (`TimelineAreaLayout`) is kept in
the app's defaults. Under each area's layers is a slim row for dropping
onto a new layer of that kind, then under the areas the scrollbar (shown
only while zoomed in).

Importing a file only adds it to the library. It reaches a timeline when
dragged there (a whole asset, or scenes of it), or from **Add to Timeline**
in its menu. Dropped on a layer it goes onto that layer at the drop time,
in the nearest gap it fits (`addScenes(_:ofAsset:intoLayer:in:at:)`);
dropped on the row under an area's layers it gets a new layer of that
area's kind; anywhere else, where it doesn't fit, or on a layer of the
wrong kind, it gets a new layer of its own default kind. New layers always
go at the top of the stack, which is the top of their area. **Add to
Timeline** always makes a new layer.

Dragged over the layer names, media from the library or a clip already on
the timeline lights up a translucent zone in the area's hue saying what a
drop there makes: **New Video Layer** for pictures, or for sound the column
split into **New Sound Layer** above **New Music Layer**, the half under
the pointer lit brighter. Media dropped there goes on the new layer at the
playhead. A clip dropped there keeps its time (`moveClipToNewLayer`). The
library notes which asset a drag carries as it begins
(`SceneDragPayload.draggedAssetID`), since the drop target can't read the
payload until the drop.

## Layers

Every layer has a kind (`TimelineLayer.kind`, saved as `kind`), which is
the area it sits in. Clips with pictures only go on video layers, and clips
of sound alone (audio files and detached sound) only on sound or music
layers; moves and drops onto the wrong kind are refused. Projects saved
before layers had kinds get one from their clips when opened
(`inferredKind(of:)`): video if any clip has pictures or the layer is
empty, sound if it holds sound detached from video, music otherwise.
Audio clips on music layers are drawn in a greener tone than sound.

A layer is named after its kind and numbered among layers of that kind
from the top ("Video 2", "Music 1"), so the names follow the stack as it is
reordered. Double-click the name to give it a custom one, which is saved as
the layer's `customName`; clearing it brings the default back.

Dragging a layer's header (its number and name) up or down reorders the
layers of its area; a line shows where it will land, and it goes there on
release (`moveLayer(_:in:toPositionInKind:)`). **Move Layer Up/Down** in
the header's menu step it one place among its kind. Layers of other kinds
keep their places in the stack, which still sets the order video layers
are composited in.

## Zoom and scroll

The track area scrolls itself sideways instead of sitting in a horizontal
scroll view, so a zoom can change the scale and the scroll offset in one
step. `TimelineViewport` holds both. The scale is either "fitted" or a
number of points per second. It is not stored relative to the fit, so a
drop that makes the timeline longer does not rescale the clips on screen.

- The track area spans the timeline plus a little room after its end (5%,
  at least one second) to drag clips into. The ruler shades that time.
- Fully zoomed out, that whole span fits the window. Fully zoomed in, one
  frame is 80 points wide.
- **Pinch** on a trackpad, or **Option-scroll**, zooms time about the
  pointer: the moment under the pointer stays under it.
- **Pinch has two axes.** The line between the two fingers as they land
  decides: side by side zooms time, as above; one above the other zooms
  **layer height** in the area under the pointer, and only there. The axis
  holds for the rest of that pinch. **Option-pinch** always zooms layer
  height. When the trackpad doesn't report finger positions, a pinch zooms
  time and **Shift-pinch** zooms layer height. Layer height is also a
  slider per area in the view options.
- The timeline's header has two **zoom sliders**: time (the arrows across)
  and layer height (the arrows up and down). The height slider zooms every
  shown area's layers by the same ratio, so areas keep their heights
  relative to each other; near the ends of the range the differences
  shrink, so the slider's ends make every area shortest or tallest
  (`setShownLayerHeightFraction`).
- The **zoom buttons** in the timeline's header, the **-** and **=** keys
  and the time zoom sliders zoom about the playhead. The
  playhead stays where it is on screen, or comes to the middle if it was out
  of view. The slider moves the zoom by the same ratio for each step.
  **\\** (or **Fit to Window**) fits the timeline again.
- Sideways trackpad scrolling, Shift-scroll on a mouse wheel and the
  scrollbar under the tracks scroll in time. Plain vertical scrolling moves
  through the layers of the area under the pointer. The ruler stays at the
  top.
- Zoom and scroll are view state: they reset when switching timelines and
  are not saved.

## Ruler

Ticks are grouped by whole frames. Every step splits a second into a whole
number of frames, or is a round number of seconds:

| Frame rate | Steps within a second, in frames |
| --- | --- |
| 24 (and 23.976) | 1, 2, 4, 6 (a quarter second), 8, 12 (a half second) |
| 25 | 1, 5 |
| 30 (and 29.97) | 1, 2, 5, 6, 10, 15 (a half second) |

Above a second the steps are 1, 2, 5, 10, 15 and 30 seconds, then minutes.
Labels go on the smallest step that is at least 80 points wide, with a
taller tick halfway and short ticks on the smallest step that divides the
label step and is at least 6 points wide. When labels are closer together
than a second, a minute or an hour, the labels on whole seconds, minutes
or hours stand out: brighter, heavier for each larger unit, and with a tick
the full height of the ruler. Labels are compact timecode
(`seconds:frames`, with minutes and hours added when needed), counted in
whole frames so NTSC rates line up with the timecode readout.

Beat markers (see [beat-detection.md](beat-detection.md)) are grouped in
the same spirit: once they would be closer than 10 points, only every 2nd,
4th, 8th… beat is drawn.

## Playhead

The playhead is a red line through the track area with a red tab at its
top, in the ruler. Only clicking or dragging in the ruler moves it, so
drags on the layers are free for the tools. It lands on frames and stays
within the timeline.

## Sections

A slim lane under the ruler holds the timeline's **sections**: named
stretches of time such as "Intro" or "Epilogue" (`TimelineSection`,
`TimelineSections.swift`). They're labels for parts of the edit, and they
also set the timeline's length: it runs to the end of its last clip or
last section, whichever is later. Past the last clip a section plays and
exports as black, so a timeline can be made longer than its footage (a
hidden track holds one frame of a source stretched over that time, since a
composition otherwise ends with its last media).

- Drag across empty space in the lane to make a section over that range;
  double-click empty space to make one five seconds long. A new section is
  named "Section N" and its name opens for typing at once.
- Double-click a section (or use its right-click menu) to rename it;
  leaving the name empty keeps the old one.
- Drag a section to move it and its edges to resize it.
- Click a section to select it, then Delete removes it (also in its menu).
  Selecting a section clears any clip or layer selection.

Sections land on frames, are at least a frame long and never overlap:
moving or resizing one stops at its neighbors, and a new one is cut short
by the next. With snapping on their edges snap like everything else, and
other edges snap to them. Section names don't affect the picture, so
renaming doesn't rebuild playback. They're saved in `project.json` under
each timeline as `sections` (`id`, `name`, `start`, `end`), left out while a
timeline has none.

## Tools

A segmented control in the timeline's header picks what dragging and
clicking clips does (`TimelineTool`); the keys switch tools while no text
is being edited.

- **Arrow (A)**: select, move and trim clips, as described below.
- **Blade (B)**: a red line follows the pointer over a clip, on the frame
  it would cut at; clicking splits the clip there (`split(…atTimelineTime:)`).
  Clips can't be moved or trimmed with it. The inspector no longer has a
  Split button.
- **Slip (Y)**: dragging a clip changes which part of its footage it
  plays while its start and end stay where they are, like moving film
  under a window: dragging right brings earlier frames in, left later ones
  (`slipClip` / `resolvedSlip`). Video slips by whole frames. When the
  footage runs out at the file's start or end, it stops there and the clip
  gets shorter from its end instead (never below a frame), and every later
  clip on its layer moves in by as much, so no gap opens. Those clips
  follow on screen during the drag, and the viewer shows the clip's first
  and last frames side by side with their source timecodes. Clips can't be
  moved or trimmed with it. In a transition's footage lane the cut line
  turns yellow and splits in two: its top half slips the outgoing clip,
  its bottom half the incoming one; the cut stays and the transition gets
  different footage to blend.

Slip is Y, as in Premiere. (P, S, R and T showed layer transforms, which
moved onto clips; see [effects.md](effects.md).)

## Snapping

Snapping is on by default; N or the button with two arrows meeting at a
line in the header turns it off and on, and the choice is remembered. With
it on, an edge that comes within 8 points (on screen, at any zoom) of a
target lands on it (`SnapTargets` in `Snapping.swift`). The targets are the
timeline's start, the start and end of every clip on every layer, the
playhead, and the beat markers of the layer chosen in the view options,
only those drawn at the current zoom (zoomed out, every second or fourth
beat is drawn, and only those snap).

- **Moving a clip** snaps by whichever of its ends is nearer a target.
- **Trimming** with the arrow snaps the edge being dragged.
- **The blade** cuts at a target near the pointer, so it can cut exactly at
  the playhead or another clip's edge.
- **Scrubbing** in the ruler snaps the playhead to clip edges and beats.

A clip never snaps to its own edges. While a drag has snapped, a yellow
line runs through the layers at the target. The usual placement rules still
apply after snapping: a snapped position that would overlap another clip
goes to the nearest free side, and video still lands on frames. Slipping,
transitions and keyframes don't snap.

## Moving and trimming clips

Dragging the middle of a clip moves it; dragging within a few points of
either edge trims that edge without destroying anything. The rules for where
a clip may go are in `ClipPlacement.swift`:

- **Video and nested timelines lock to frames.** Their start and end land
  on whole frames of the timeline's rate, never between two. This uses
  exact frame counts, so it holds at 23.976 and 29.97. A source rarely
  lasts a whole number of frames, so a clip put on a timeline (a whole
  asset, a scene or a nested timeline) is trimmed back to whole frames at
  the end (`coveringWholeFrames`), and so are clips in projects saved
  before this. Otherwise its end falls between frames and no neighbor
  can meet it to make a cut.
- **Audio moves freely**, to 1/48000 of a second.
- Clips never start before zero and never overlap on a layer. A moved
  clip lands where it is dropped. Dropped inside another clip, it goes to
  that clip's nearer edge, which is how a clip goes before the first clip
  or between two that meet. If it doesn't fit there, every clip on the
  layer from that point on moves right by just enough to make room,
  keeping the gaps between them (rounded up to a whole frame when any of
  them has pictures). Only that layer moves: other layers, keyframes and
  sections stay put.
- **A layer holds any number of clips.** Dragging a clip up or down onto
  another layer moves it there under the same rules. A layer left empty
  stays, so other clips can be moved into it.
- **Deleting.** Selecting a clip and pressing Delete removes it from the
  timeline (or, with one of its transitions selected, just that
  transition); its layer stays. Clicking a layer's name area selects the
  layer, and Delete then removes it with all its clips. Both can be
  undone.
- Trimming the start keeps the clip's end fixed. A trim can't reveal media
  before the source's start or after its end, can't cross a neighbor, and
  can't make a clip shorter than one frame (a twentieth of a second for
  audio).

While dragging, the clip is drawn where it will land under these rules,
not under the pointer, so it does not jump on release. A clip being moved
is drawn picked up: slightly larger, raised and shadowed, with a dashed
outline left in the slot it came from. Clips it pushes slide aside as the
drag makes room. The functions that work this out
(`resolvedMove(ofMoving:…)`, `resolvedTrimStart(of:…)`,
`resolvedTrimEnd(of:…)`) do not change the project, and the editing
functions commit what they return.

## Waveforms

Clips of sound alone (audio files and detached sound) draw their waveform,
faded, behind their label once their layer is at least 64 points tall,
fading in fully over the next 32: vertical zoom (a vertical pinch, or the
area's layer height slider) is what brings them up. Only the part of the
clip on screen is drawn, one mirrored bar every two points. The waveform is
a coarse envelope of each file (`Waveform`: the loudest sample in each
1/200 s window, scaled to the file's loudest), read the first time a clip
asks for it and kept for the session (`WaveformCache`). Replacing media
clears it.

The envelope is kept per channel: left and right for stereo, and files
with more channels are read mixed down to two. The split-square button on
a sound or music layer's header (or **Show Channels** in its menu) shows
each channel in a band of its own, left above right and labelled L and R,
at any layer height; the layer's row doubles in height (each band at least
32 points). On a video layer the button appears while its linked audio is
shown, and splits that lane the same way. Which layers show channels is
view state, not saved.

## Linked and detached audio

A video clip whose file has sound plays both, linked, and shows a speaker
badge. Its layer header gets a waveform button that expands a **linked
audio** lane under the clips, one block under each clip that carries sound.
**Detach Audio** (on a clip, on a linked audio block, on the layer header or
in the inspector) splits them: the clips keep only their picture
(`streams = .video`), and copies with the same timing and trims, playing
only the sound (`streams = .audio`), go onto a new sound layer. From
then on the two are ordinary clips: the sound is colored as audio, moves
freely off the frame grid, carries the beats, and takes no transitions.

## Transitions

Transitions are dragged from the panel onto a clip with pictures; the
nearer end of the clip gets it. Each end holds at most one, a second long
by default (shorter to fit beside the other end), and dropping another kind
on the same end keeps its length. With the arrow tool, dragging a
transition's side on the timeline changes its length: a transition joining
two clips grows or shrinks about its center (`JointEdit.widen`), the
other side moving as much the other way; one on a clip's free end keeps
its outer side at the clip's end and the inner side follows the drag.
The inspector sets the length in frames
and removes it; so does the clip's menu. A shaded wedge on the clip shows
where it plays. Splitting a clip keeps the way in on the first half and the
way out on the second. Detached sound is not affected.

A transition plays inside the clip's own range, bringing it in over (or
taking it out to) whatever is underneath: lower layers, or black.

### Transitions joining two clips

Where two media clips with pictures meet on a layer, a transition dropped
at the cut, on either clip, **joins** them: it becomes the incoming clip's
way in and is drawn as one box across the cut, over both clips. It blends
the outgoing clip into the incoming one, which needs footage beyond their
trims: before the cut the incoming clip plays the frames before its in
point, and after the cut the outgoing clip plays the frames after its out
point. A new one is centered on the cut, a second long, as far as that
spare footage allows (`fittedJoint`). Its `lead` is how much plays before
the cut. With no spare footage at all it plays inside the incoming clip as
above, over the layers below.

Double-clicking the box (or **Edit Footage…** in its menu) opens the
**transition footage** lane under the layer: the outgoing clip on top and
the incoming one below, each with its spare footage drawn faintly, the
transition across both and the cut as a white line.

- Drag the transition to move it across the cut, and either edge to change
  its length about its center (the other edge moves as much the other
  way). It can't need more footage than there is.
- Drag the cut to roll it: the outgoing clip's out point and the incoming
  clip's in point move together, so the clips still meet, nothing else
  moves, and the transition draws on different footage
  (`applyJointEdit(.roll…)`). Each clip keeps at least a frame.

Edits land on frames and are saved when a drag ends. **Done** in the
label column closes the lane. In the composition, the incoming clip's
frames before the cut go on a track above the layer's and the outgoing
clip's frames after it on a track below. Nested timelines don't join.

Kinds: cross dissolve, film dissolve, wipe left/right/up/down, slide
left/right and zoom. A wipe or slide acts in the frame of the timeline the
clip is on, after the clip's effect stack.

The **film dissolve** shows the following picture brightest parts first:
it appears wherever it is brighter than a threshold that falls from white
to black over the transition, with a soft edge (`LumaReveal`). On a way in
the following picture is the clip itself; on a way out it is what is under
the clip. Brightness is the encoded Rec. 709 luma, so it follows how the
picture looks.

### Rendering

Transitions sit below a clip's effect stack: the compositor draws the clip
through its stack, then applies the transition's opacity, transform and
crop in the frame of the timeline the clip is on (`EdgeTransitions` in
`ClipTransition.swift`, evaluated per frame). The film dissolve keys on
brightness, on the clip's picture or on what is drawn under it. All of it
is drawn by `LayeredCompositor` (Core Image), in preview and export alike,
without color management. A nested timeline is one picture, so a
transition on it applies to the whole; on a pass-through nested clip only
its dissolve, slide and zoom apply, to each layer inside.

### Curves

Each transition has a progress curve (`TransitionCurve`): bezier segments
from (0, 0) to (1, 1), time across, progress up. New slides and zooms get
Easy Ease, everything else Linear. Presets, named as in After Effects:

| Preset | Shape |
| --- | --- |
| Linear | Steady |
| Ease In | Slows into the end (flat handle at the end, 33% influence) |
| Ease Out | Starts slowly (flat handle at the start) |
| Easy Ease | Both |

They are in the transition's right-click menu on the timeline and the
inspector's **Curve** menu. Clicking a transition's wedge selects it; the
wedge's top edge is the curve (rising for a way in, falling for a way out).
Once the selected transition is drawn at least 80 points wide (zoom in) and
the layer is at least 30 points tall, its points and handles appear:

- Drag a point or a handle. Handles can't point back in time or past the
  neighboring point, so the curve never turns back; the end points stay at
  0 and 1 but their handles can be dragged.
- Click the line to add a point there; the curve keeps its shape.
- Option-click a point to make it a corner, or a corner smooth again.
  Option-click the line to make that segment straight.
- Right-click a point to delete it or toggle its corner.

A drag is saved when it ends, as one undo step.

## Clip badges and menus

A clip with effects shows a small badge with how many, and a nested clip
that passes through shows a mark. Dragging an effect from the effects panel
onto a clip adds it to the end of the clip's stack. The clip's menu has
**Pass Through** for nested clips.

## Not implemented yet

- Audio crossfades under transitions, and transitions on detached sound.
- A larger graph editor for curves on short transitions.
- Thumbnails of the frames in the transition footage lane.
- Joining nested timelines, and trimming at a joined cut from the clips
  themselves (the transition box covers the edges; roll the cut instead).
- Scrolling to follow the playhead during playback.
