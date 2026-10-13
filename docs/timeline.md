# Timeline view

Status: **implemented**: zooming and scrolling, the ruler, the playhead,
and moving and trimming clips on the frame grid. The placement rules, the
viewport math and the ruler and beat grouping are unit tested. The view
itself has been checked in offscreen renders, not yet driven on screen
with a trackpad. What is not built is listed under
[Not implemented yet](#not-implemented-yet).

The timeline sits under the library, viewer and inspector and spans the
full width of the window: a label column on the left (layer number and
name, and transform property rows when shown), and the track area on the
right with the ruler across its top. The transitions panel, opened with the
button in the timeline's header, takes its place at the right end.

The timeline is never taller than its layers need: under the last layer is
only a slim row for dropping onto a new layer, then the scrollbar (shown
only while zoomed in), and the viewer gets the rest of the window. The
resize handle above it sets the most it may take; with more layers than fit,
the layers scroll.

Importing a file only adds it to the library. It reaches a timeline when
dragged there (a whole asset, or scenes of it), or from **Add to Timeline**
in its menu. Dropped on a layer it goes onto that layer at the drop time,
in the nearest gap it fits (`addScenes(_:ofAsset:intoLayer:in:at:)`);
dropped on the row under the layers, anywhere else, or where it doesn't
fit, it gets a new layer at the top. **Add to Timeline** always makes a new
layer.

## Layers

Dragging a layer's header (its number and name) up or down reorders the
stack; a line shows where it will land, and it goes there on release
(`moveLayer(_:in:toIndex:)`). **Move Layer Up/Down** in the header's menu
step it one place.

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
- **Pinch** on a trackpad, or **Option-scroll**, zooms about the pointer:
  the moment under the pointer stays under it.
- The **zoom buttons** in the timeline's header, the **-** and **=** keys
  and the **zoom slider** in the view options zoom about the playhead. The
  playhead stays where it is on screen, or comes to the middle if it was out
  of view. The slider moves the zoom by the same ratio for each step.
  **\\** (or **Fit to Window**) fits the timeline again.
- Sideways trackpad scrolling, Shift-scroll on a mouse wheel and the
  scrollbar under the tracks scroll in time. Plain vertical scrolling moves
  through the layers. The ruler stays at the top.
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
top, in the ruler. Clicking or dragging anywhere in the ruler, or in empty
track space, moves it there. It lands on frames and stays within the
timeline.

## Moving and trimming clips

Dragging the middle of a clip moves it; dragging within a few points of
either edge trims that edge without destroying anything. The rules for where
a clip may go are in `ClipPlacement.swift`:

- **Video and nested timelines lock to frames.** Their start and end land
  on whole frames of the timeline's rate, never between two. This uses
  exact frame counts, so it holds at 23.976 and 29.97.
- **Audio moves freely**, to 1/48000 of a second.
- Clips never start before zero and never overlap on a layer. A move onto a
  neighbor goes to the nearest free side of it, rounded off the neighbor
  onto a frame for video. A move onto a layer with no gap big enough is
  refused.
- **A layer holds any number of clips.** Dragging a clip up or down onto
  another layer moves it there, under the same rules, when that layer has
  room; otherwise it stays on its own layer. A layer left empty is removed.
- Trimming the start keeps the clip's end fixed. A trim can't reveal media
  before the source's start or after its end, can't cross a neighbor, and
  can't make a clip shorter than one frame (a twentieth of a second for
  audio).

While dragging, the clip is drawn where it will land under these rules,
not under the pointer, so it does not jump on release. The functions that
work this out (`resolvedStart(ofMoving:…)`, `resolvedTrimStart(of:…)`,
`resolvedTrimEnd(of:…)`) do not change the project, and the editing
functions commit what they return.

## Linked and detached audio

A video clip whose file has sound plays both, linked, and shows a speaker
badge. Its layer header gets a waveform button that expands a **linked
audio** lane under the clips, one block under each clip that carries sound.
**Detach Audio** (on a clip, on a linked audio block, on the layer header or
in the inspector) splits them: the clips keep only their picture
(`streams = .video`), and copies with the same timing and trims, playing
only the sound (`streams = .audio`), go onto a new layer just below. From
then on the two are ordinary clips: the sound is colored as audio, moves
freely off the frame grid, carries the beats, and takes no transitions.

## Transitions

Transitions are dragged from the panel onto a clip with pictures; the
nearer end of the clip gets it. Each end holds at most one, a second long
by default (shorter to fit beside the other end), and dropping another kind
on the same end keeps its length. The inspector sets the length in frames
and removes it; so does the clip's menu. A shaded wedge on the clip shows
where it plays. Splitting a clip keeps the way in on the first half and the
way out on the second. Detached sound is not affected.

A transition plays inside the clip's own range, bringing it in over (or
taking it out to) whatever is underneath: lower layers, or black. Where two
clips on the same layer meet at a cut, the neighbor's frames beyond its
trim play underneath on a track of their own, so a dissolve blends the two
clips. Without spare frames the transition plays over the layers below.
Only media neighbors are extended, not nested timelines.

Kinds: cross dissolve, film dissolve, wipe left/right/up/down, slide
left/right and zoom. A wipe or slide acts in the frame of the timeline the
clip is on, after the layer's transform.

The **film dissolve** shows the following picture brightest parts first:
it appears wherever it is brighter than a threshold that falls from white
to black over the transition, with a soft edge (`LumaReveal`). On a way in
the following picture is the clip itself; on a way out it is what is under
the clip. Brightness is the encoded Rec. 709 luma, so it follows how the
picture looks.

### Rendering

Everything but the film dissolve is drawn with the built-in compositor's
opacity, transform and crop (`EdgeTransitions` in `ClipTransition.swift`,
applied per frame with the layer's keyframes). Keying on brightness needs
our own compositor, so a timeline with a film dissolve anywhere is drawn by
`LayeredCompositor` (Core Image) for its whole length, in preview and
export alike. It stacks the same layers with the same crops, transforms and
opacities, without color management just like the built-in one, and a test
checks the two draw the same picture. On a nested timeline the key applies
to each of its layers separately rather than to its composite, as opacity
already does.

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

## Not implemented yet

- Audio crossfades under transitions, and transitions on detached sound.
- A larger graph editor for curves on short transitions.
- **Snapping** to other clips' edges, the playhead or beat markers.
- Scrolling to follow the playhead during playback.
