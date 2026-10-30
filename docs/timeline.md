# Timeline view

Status: **implemented**: zooming and scrolling, the ruler, the playhead,
and moving and trimming clips on the frame grid. The placement rules, the
viewport math and the ruler and beat grouping are unit tested. The view
itself has been checked in offscreen renders, not yet driven on screen
with a trackpad. What is not built is listed under
[Not implemented yet](#not-implemented-yet).

The timeline sits under the browser, viewer and inspector and spans the
full width of the window: a label column on the left (layer number and
name, and its volume row when shown), and the track area on the
right with the ruler across its top. The Effects Library (effects and
transitions in tabs, [effects.md](effects.md#the-effects-panel)) takes the
right end when its button in the header is on. The inspector and the
effects list are tabs of the area beside the viewer.

The timeline is as tall as the person makes it with the grip between it and
the viewer, whatever its layers need; it remembers that height. Under the
ruler it is split into three **areas**, top to bottom:

- **Video**: layers with pictures (`LayerKind.video`).
- **Sound**: dialogue and effects (`.sound`), including sound detached from
  video.
- **Music**: the score (`.music`). Nothing goes here unless the person
  drops or drags it here: audio files go on Sound layers by default. Only
  clips on Music layers are analyzed for beats (see
  [beat-detection.md](beat-detection.md)).

Each area has a title bar with its name and layer count, and scrolls its
layers on its own. Dragging the title bar of the sound or music area moves
its boundary with the area above, trading height between the two. The grip
above the timeline resizes every area in proportion. Neither changes how
tall a layer is: a bigger area shows more layers. Layer height is each
area's own vertical zoom (see [Zoom and scroll](#zoom-and-scroll)).

A single layer is resized by dragging the line under it **in the layer
names column** (never in the track area, where a drag moves clips).
With **Option** every layer of that area goes to the new height, and with
**Option-Shift** every shown layer does. A layer sized on its own keeps a
scale of its area's height (`layerScales`), so zooming the area keeps it
in proportion; sizing all of an area's layers drops their scales. With
VoiceOver the line is adjustable in steps of 8 points.
**View Options** has a checkbox per area that hides or shows it, and a
layer height slider for each. The layout (`TimelineAreaLayout`) is kept in
the app's defaults. Under each area's layers, the rest of the area (at
least a slim row) takes drops onto a new layer of that kind, then under the
areas the scrollbar (shown only while zoomed in).

Importing a file only adds it to the browser. It reaches a timeline when
dragged there (whole assets, scenes, or a range; several go back to back
in the order dragged), or from **Add to Timeline** in its menu. Dropped on
a layer that takes all of it, it lands as a clip moved there would
(`addPieces(_:intoLayer:in:at:)`, by the same `insertion` rule as a move):
inside a clip it goes to that clip's nearer edge, and the clips from there
on move right just far enough to make room, shown moving while the drag is
over the layer;
dropped anywhere in an area below its layers, an empty area included, it
gets a new layer of that area's kind; anywhere else, where it doesn't fit,
or on a layer of the wrong kind, it gets new layers of its own default
kinds, one per kind, so sound and pictures dragged together land as one
run across two layers (`addPieces(_:intoTimeline:at:kind:)`). New layers
always go at the top of the stack, which is the top of their area. **Add
to Timeline** always makes a new layer.

Dragged over the layer names, media from the browser or a clip already on
the timeline lights up a translucent zone in the area's hue saying what a
drop there makes: **New Video Layer** for pictures, or for sound the column
split into **New Sound Layer** above **New Music Layer**, the half under
the pointer lit brighter. Media dropped there goes on the new layer at the
playhead. A clip dropped there keeps its time (`moveClipToNewLayer`). A
clip dragged over the empty part of another area that takes it, below
that area's layers, goes onto a new layer there at the time it was dragged
to: that is how detached sound goes from the Sound area to Music. The
browser notes the first asset a drag carries as it begins
(`MediaDragPayload.draggedAssetID`), since the drop target can't read the
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
layers of its area; a line (`InsertionLine`) shows where it will land, and
it goes there on release (`moveLayer(_:in:toPositionInKind:)`). With
**Option** held the pointer shows a plus and a copy of the layer, its
clips and sound effects with new IDs and its name followed by "copy",
goes there instead, the layer staying put (`duplicateLayer`). Held near
the top or bottom of its area, the drag scrolls the area, and what it
scrolls counts toward where the layer lands. **Move Layer Up/Down** in
the header's menu step it one place among its kind. Layers of other kinds
keep their places in the stack, which still sets the order video layers
are composited in.

## Zoom and scroll

The track area scrolls itself sideways instead of sitting in a horizontal
scroll view, so a zoom can change the scale and the scroll offset in one
step. `TimelineViewport` holds both. The scale is either "fitted" or a
number of points per second. It is not stored relative to the fit, so a
drop that makes the timeline longer does not rescale the clips on screen.
The one exception: when a drop or move leaves a music clip as the only
clip on the timeline, the view fits the timeline to it, so a song dragged
into an empty timeline is shown whole. Deleting everything else around a
song does not.

- The track area spans the timeline plus a little room after its end (5%,
  at least one second) to drag clips into. The ruler shades that time.
- Fully zoomed out, that whole span fits the window. Fully zoomed in, one
  frame is 80 points wide.
- **Pinch** on a trackpad, or **Option-scroll**, zooms time about the
  pointer: the moment under the pointer stays under it.
- **Zoom edges.** Every zoom in the editor (the timeline's time and
  layer height, the keyframe graph's time and values, the Beat Match
  waveform) has the same edge (`RubberBandZoom`): pushed past its
  farthest or closest, the view squeezes or stretches toward the pointer
  instead, against more resistance the further it goes, up to a fifth.
  A pinch holds the stretch until it lets go; a zoom slider stops at
  the limits, and a zoom button, key, menu command or Option-scroll
  springs back a moment after
  the last push, so a hard stop still answers. Zooming back takes up the
  stretch before the view zooms again. With reduced motion it simply
  stops. The zoom sliders stop at their ends, as sliders do.
- **Scroll edges.** Scrolling past the start or end does the same on
  every axis that zooms (`RubberBandScroll`): the timeline's tracks, the
  Beat Match waveform and the keyframe graph's time slide a little way on
  against growing resistance, never more than 8% of the view (60 points at
  most), so it reads as an edge as the zoom's does. They spring back
  as the fingers lift; a swipe's glide that reaches an edge bounces once,
  at once, and the rest of the glide is let go; a mouse wheel springs back
  a moment after its last click (`ScrollInputPhase`). Axes
  that don't zoom don't bounce: Beat Match has no vertical bounce, and the
  graph's values scroll without an end. The timeline's areas scroll up and
  down in system scroll views, which bounce on their own, as layer height
  zooms.
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
- Editing a clip's Time settings changes the timeline's length, and a
  fitted view would rescale with it (enormously, for a crawling clip). A
  time edit instead pins the zoom the view had; **Fit to Window** fits it
  again.
- Zoom and scroll are view state: they reset when switching timelines and
  are not saved.

### Zoom controls

**Built.** Every view with a timeline of its own zooms with the same
controls as this header, in the same order: a time zoom slider
(`ZoomSlider`: the arrows across, then a mini slider, even in ratio,
`ZoomScale`), then zoom out, zoom in and fit. The scene splitter, the
Beat Match panel and the motion designer use `ZoomControls`; the keyframe
graph editor has a value slider (the arrows up and down) and a time
slider along its bottom, with Fit. Panels that take typing (Beat Match,
the motion designer) zoom with ⌘- ⌘= ⌘0; the timeline and the scene
splitter with - = and \\.

The Tape Scrubber is the main timeline's alone: no other view has a dial
(the graph editor's zoom dials were replaced by these sliders).

### Tool tones

**Built.** The other timelines share this one's ruler, playhead and zoom
controls, and each is set apart only by a tone (`Design.ToolTone`): a
glyph at the start of its header (`ToolGlyph`) and a hairline along the
top of its time area (`toolEdge`). The tone is the clip tone of what the
tool shapes, keeping to "hue means category": the scene splitter is
video's violet, Beat Match music's green, the motion designer graphics'
amber and the graph editor adjustment's magenta. The main timeline has
none.

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

The playhead is a yellow line through the track area with a yellow tab at
its top, in the ruler, as in Final Cut Pro (`Design.playhead`). Clicking or
dragging in the ruler moves it, and so does a click in the tracks, on a
clip or in empty space, as in Final Cut: the click still selects the clip
or nothing, and the playhead goes to where it was. Only a click moves it
there: drags on the layers (moving, trimming, a lasso) stay free for the
tools, and so do clicks with ⌘, ⇧ or ⌃ and the blade's. The press and its
release are watched by the lasso's monitor (`TimelineView.lassoMonitor`),
which takes no events. It lands on frames, snaps as scrubbing in the ruler
does, and stays within the timeline.

While playing, only the playhead line and the timeline's timecode follow
the player. The line runs on the player's own clock: it sits in an
`AVSynchronizedLayer` bound to the player's item, with one linear Core
Animation across the timeline, so it moves on every display frame and
stays with play, pause and seeks without any view being redrawn
(`PlayheadRail.Following`). The animation is replaced only when the zoom,
scroll or player item changes. The rest of the editor reads the parked
playhead, which catches up when playback stops, so playback doesn't
redraw every layer on every tick. The
values shown in property rows and the inspector hold still while playing
for the same reason.

Scrolling and zooming redraw only the tracks: the zoom, the scroll and
their rubber bands are kept in `TimelineViewportModel`, which only
`TimelineTrackSurface` and the views it hands the viewport to read, so the
header and the rest of `TimelineView` aren't built again for each step.
Each layer's row builds only the clips in view or nearly, and those being
moved, so a long timeline zoomed in costs what is on screen. What the rows
compare and what edges snap to are worked out once per edit
(`TimelineDerivedCache`), not on every redraw.

Zoomed in, the view **follows the playhead** while playing: each time the
playhead runs off the edge of the view, the view turns a page so it is
just inside the left edge again (and starting playback with the playhead
out of view brings it into view). The player reports the playhead
reaching the right edge with a boundary time observer, and seeks with
its time-jumped notification, so following needs no per-frame check. The view options can turn this off.
Moving the playhead from the keyboard scrolls it to the middle when it
lands out of view.

### Skimming

While a dialog is open over the window (New Timeline, Timeline
Settings, an alert), the window behind it takes no pointer input at all:
no skimming, hovering, scrolling or clicks (`WindowInputBlock`), and a
skim under way when it opens ends.

With **Skimming** on (the default; it is switched in the timeline's
view options, the Timeline menu or the Settings window's Timeline tab),
moving the pointer over the track area or the ruler while paused shows
the frame under it in the viewer, on the nearest frame, and the playhead
stays where it is parked. A red hairline with no tab, Final Cut's
skimmer (`Design.skim`, which the blade's line also uses), marks the
frame skimmed (`TimelineSkimLine`). A grain of the mix plays at each
frame, as for moving the playhead (docs/audio.md, "Scrubbing"), unless Scrub Audio
is off. Leaving the tracks, moving over the names column, or turning
skimming off takes the viewer back to the playhead.

- The pointer is read by the timeline's input monitor
  (`TimelineInputMonitor`), which watches mouse-moved events without
  taking them; a drag sends none, so dragging clips or the playhead
  doesn't skim. Skimming waits while playing or tape scrubbing.
- `PlaybackModel.skim(to:)` seeks the player through the same queue as
  the playhead (one seek at a time, the newest move next) without
  touching the parked time; the player's time-jumped ticks are ignored
  until it is back at the playhead, so a skim never moves it.
- Moving the playhead (a click in the ruler, a drag, the keys) ends the
  skim. Space while skimming moves the playhead to the frame skimmed to
  and plays from there.
- Tested in the editor as the app hosts it, with mouse-moved events
  sent through the application (`TimelineSkimmingTests`), and the
  model's side on its own (`PlaybackSkimTests`).

### Moving the playhead from the keyboard

- **← / →** step one frame; with Shift, ten. Stepping pauses playback.
- **↑ / ↓** go to the previous or next edit: any clip's start or end, or
  the end of the timeline.
- **Home / End** go to the start and the end.
- **⌘B** splits the selected clip, or the clips picked together, at the
  playhead, as Final Cut's Blade; with nothing selected, every clip the
  playhead is in. **⇧⌘B** splits every clip the playhead is in, on every
  layer (Blade All). Both cut at the playhead, never at the skimmer, so
  clicking where to cut and pressing the key cuts there wherever the
  pointer has gone (`Timeline.clipsToSplit`).
- **, / .** nudge the selected clip a frame earlier or later; with Shift,
  ten. A nudge follows the same rules as dragging. Clips picked together
  are nudged together, each on its own layer.

These keys are left to a list or other control that has the keyboard (the
browser's Clips list uses the arrows), and to text being typed. All of them, and
the timeline's other keys (tools, snapping, zoom, Delete), are listed in
the **Timeline** menu (`TimelineCommands`) and in
[accessibility.md](accessibility.md). Keys without a modifier are
written after the item's name rather than set as menu shortcuts, since a
menu shortcut would take the key from a text field.

## VoiceOver

Clips, layers, the playhead, sections, keyframes and joined transitions
are all reachable with VoiceOver, with actions for what dragging does a
frame at a time. See [accessibility.md](accessibility.md).

## Sections

A slim lane under the ruler holds the timeline's **sections**: named
stretches of time such as "Intro" or "Epilogue" (`TimelineSection`,
`TimelineSections.swift`). They're labels for parts of the edit, and they
also set the timeline's length: it runs to the end of its last clip or
last section, whichever is later. Past the last clip a section plays and
exports as black, so a timeline can be made longer than its footage (a
hidden track holds one frame of a source stretched over that time, since a
composition otherwise ends with its last media).

- Double-click empty space in the lane to make a section five seconds
  long (dragging across empty space no longer draws one, which happened by
  accident). A new section is named "Section N" and its name opens for
  typing at once.
- Double-click a section (or use its right-click menu) to rename it, as
  with a file: the name is selected, Return or a click anywhere else saves
  it, Escape cancels, and leaving it empty keeps the old name.
- The sections button in the timeline toolbar (or the view options) shows
  or hides the whole row.
- Drag a section to move it and its edges to resize it. A line
  (`InsertionLine`) marks where a moved section will start. **Option-drag**
  a section to copy it: the pointer shows a plus, the section stays, and a
  dashed copy with its name and length shows where it will land
  (`resolvedSectionCopy`): in the stretch between sections under its start,
  or, dropped inside a section, in the stretch on the nearer side of it
  (else the other), cut short to fit. The copy is selected.
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
  and last frames side by side with their source timecodes (a nested
  timeline's from the timeline itself, timed in its own frames). The
  pictures along the clip slide with the footage as it is dragged, so
  which part plays is seen on the clip too. Clips can't be
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
either edge trims that edge without destroying anything. While an edge of
a video or nested timeline clip is dragged, the viewer shows the frame at
that edge (its first frame for the left edge, its last for the right)
with its source timecode, read straight from the file, or made from the
nested timeline (`TrimPreviewSource`), so footage a lengthened edge
reaches shows too (`TrimPreviewOverlay`). It follows the pointer as the
drag goes: one frame is read at a time, and when it is done the frame
where the edge is then is read next. Holding the
pointer near the left or right edge of the tracks during either drag
scrolls the timeline that way, faster the closer to the edge
(`TimelineAutoScroll`), so a clip can be taken past what is in view. Near
the top or bottom of an area, a clip moved across layers, or media dragged
in from the browser, scrolls that area up or down the same way
(`EdgeAutoScroll`, one per area, reached through `TimelineAutoScroll`).

**Motion.** A moved clip is drawn where it will land the whole way: on
the frame its start snaps to and on the row of the layer it will go onto,
stepping from frame to frame rather than floating with the pointer, so
what is seen is exactly what the drop will do. The line at its start and
the clips that slide aside show the rest. Only over the place a new layer
would go, which has no row yet, does it follow the pointer up or down;
let go there, the new layer's block takes up the motion from where it
was let go (`ClipFlights`). Clips
glide wherever an edit moves them, in whichever layer (`Motion.glide`),
but not when the view is zoomed. Reduced motion makes all of it instant.
The rules for where a clip may go are in `ClipPlacement.swift`:

- **Video and nested timelines lock to frames.** Their start and end land
  on whole frames of the timeline's rate, never between two. This uses
  exact frame counts, so it holds at 23.976 and 29.97. A source rarely
  lasts a whole number of frames, so a clip put on a timeline (a whole
  asset, a scene or a nested timeline) is trimmed back to whole frames at
  the end (`coveringWholeFrames`), and so are clips in projects saved
  before this. Otherwise its end falls between frames and no neighbor
  can meet it to make a cut.
- **Changing a timeline's frame rate** moves what is on it onto the new
  frames (`alignToFrames`): clip edges with pictures, transition lengths,
  keyframes and sections each go to the nearest frame, so edges that met
  still meet. Keyframes that land on one frame merge, keeping the later.
  Rates other than whole numbers and the NTSC family (such as 12.5) are
  kept exact rather than rounded to a whole number.
- **Conform Timeline to Clip**, in the right-click menu of a clip with
  pictures, gives the timeline that clip's frame size (read from its
  file, rotation applied), frame rate and colour space (SDR Rec. 709 or
  one of the HDR spaces), as one undoable edit that moves everything onto
  the new frames as above (`EditingProject.conformTimeline`). A still
  has no frame rate, so the timeline keeps its own.
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
- **A trim stops at a scene cut.** A clip's picture can't be trimmed past
  the start of the scene its first frame is in, or the end of the scene
  its last frame is in (`trimFootage(of:sceneTracks:)`), dragged, from
  the keyboard or typed into the inspector. A clip placed across several
  scenes keeps reaching all of them. Sound taken off on its own trims
  freely, having no picture edge to keep to.

A video clip shows its footage along it once its layer leaves room for a
band of pictures at least 22 points tall: one thumbnail per tile, each the
frame played where the tile starts (retimed and reversed clips included),
under an 18-point band of the clip's colour that holds its name, so the
name keeps its contrast. Only the drawn part of a clip is tiled, and the
pictures come from the same in-memory store as the browser's. A nested
timeline's clip shows the timeline's own frames the same way, made from
a composition of it that the editor keeps (`NestedTimelinePreviews`,
apart from the browser's) and builds again once edits to what it draws
settle; until then its tiles keep the pictures they have. Tiles are
laid out from where the footage's first frame would play, not from the
clip's start, so trimming either edge cuts into the pictures rather than
shifting them, and the two halves of a split line up; a retimed or
reversed clip tiles from its start.

A clip being moved is drawn picked up: raised and shadowed, at its own
size, and **where it will land** under these rules (snapped, on a frame,
at a clip's nearer edge), on whatever layer it is over, so the clip itself
shows where it will go, with an accent line (`InsertionLine`) down the
edge it will start at. Clips it pushes slide aside as the drag makes room.
**Option-dragging** copies the clip instead: the pointer shows a plus, a
dashed outline stays where the clip is, and on release a copy lands where
the clip would have gone (`paste(_:in:onto:at:)`, or `paste(_:in:newLayer:
at:)` over the layer names), the clip itself not moving. The place is the
one a move would take, worked out as if the clip had left its own; a copy
dropped over the clip pushes it right to make room. Over the layer names or an area's empty
space, where it would make a new layer, there is no place for it yet, so
it follows the pointer, and on release settles from there; with Reduce
Motion it goes there at once. A trim is still drawn where it will land. The functions that work this out
(`resolvedMove(ofMoving:…)`, `resolvedTrimStart(of:…)`,
`resolvedTrimEnd(of:…)`) do not change the project, and the editing
functions commit what they return.

- **The timecode over the pointer.** While anything on the timeline is
  dragged, a box just above the pointer shows the exact timecode it will
  land at, and beside it how far that is from where it was picked up
  ("+1:12", "−0:05", "±0:00" back where it began)
  (`DragTimecodeReadout`). For a moved clip that is its start; for a
  trim, the edge being dragged; for a keyframe (on a volume lane or in
  the effects panel), a section or either of its edges, or a clip's music
  point, that mark; in an expanded transition, its start when it is moved
  and the cut when it is rolled. It is always the timeline's time,
  snapped and placed as the drop will be, and goes away when the drag
  ends or Escape cancels it. Changing a transition's length (on a clip,
  joining two, or expanded) shows its whole length instead, with how much
  it grew or shrank. A slip, of a clip or in an expanded transition,
  shows only how far the footage moved, as its in point changes: dragging
  right brings earlier frames in, so it reads negative.
- **Shift** while moving keeps the clip on its own layer: it only moves
  in time, wherever the pointer goes up or down.
- **Escape** while moving, trimming or slipping cancels: the clip springs
  back to where it was and nothing is edited. The rest of that drag does
  nothing until the button comes up; Escape then doesn't also clear the
  selection.
- An edit let go of that the project **refuses** springs back at once,
  with the block's rim flashing in the warning colour and the alert
  sound, rather than sitting in the wrong place until it gives up.
- The pointer over a clip is an open hand with the Arrow, closed while
  the clip is carried, and the resize arrows with Slip.
- While a clip is carried or trimmed its pictures and sound aren't read:
  the tiles keep what they show, and what is new comes in once let go.

A clip too narrow on screen to read (under 24 points) is drawn as its
fill and outline alone. One under 6 points still takes a press a little
either side of it, to select or move it, and its trim handles narrow so
its middle still moves it. A clip turned off is drawn faded and grey,
pictures included.

## Waveforms

Clips of sound alone (audio files and detached sound) draw their waveform,
faded, behind their label once their layer is at least 64 points tall,
fading in fully over the next 32: vertical zoom (a vertical pinch, or the
area's layer height slider) is what brings them up. Only the part of the
clip on screen is drawn, one mirrored bar every two points. A clip whose
speed changes along it is drawn as far into the file as it plays at each
point (`WaveformFileTimes`), not at its first speed throughout. The waveform is
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
freely off the frame grid, carries the beats, and takes only the Audio
transitions (see [transitions.md](transitions.md#sound)).

A **nested timeline's** clip detaches the same way, from its menu, the
layer header or the inspector, when anything in it makes sound
(`EditingProject.canDetachAudio`): the clip keeps the nested timeline's
picture, drawn with its sound silenced, and a copy on the new sound layer
plays only its sound, drawing nothing (`CompositionFlattening` honors
`streams` for nested clips as for media). It has no linked audio lane,
which shows a file's waveform.

**Mute Sound** (in the clip's menu, for any clip that makes sound) keeps
the sound where it is and silences it (`soundMuted`): it is left out of
playback, the meter and exports, keeps its volume and effects, and its
badge and linked audio block show it muted. Unmute Sound, or Undo, plays
it again. Detaching a muted clip's sound unmutes it: the sound clip on
the new layer plays, and the picture has no sound left to mute. The
browser can mute video's sound as it is added
([browser.md](browser.md#dragging)).

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

Where two clips with pictures (media or nested timelines) meet on a layer (within
`Timeline.abutmentTolerance`, as clips meet everywhere else, so edges a
sliver apart from rounding still count), a transition dropped at the cut,
on either clip, **joins** them: it becomes the incoming clip's
way in and is drawn as one box across the cut, over both clips. It blends
the outgoing clip into the incoming one, which needs footage beyond their
trims: before the cut the incoming clip plays the frames before its in
point, and after the cut the outgoing clip plays the frames after its out
point. A new one is centered on the cut, a second long, as far as that
spare footage allows (`fittedJoint`). Its `lead` is how much plays before
the cut. With no spare footage at all it plays inside the incoming clip as
above, over the layers below.

Double-clicking the box (or **Expand Transition** in its menu) expands
it under the layer. The **Transition video** lane shows the outgoing clip
on top and the incoming one below, each with its spare footage drawn
faintly, the transition across both and the cut as a white line. While
either clip's sound is attached to its picture, a **Transition audio**
lane follows (`TransitionSoundLane`): the outgoing sound falling and the
incoming one rising across the same span, in the shape they crossfade
with (see [audio.md](audio.md#under-transitions)). The shape is chosen in
the lane's header or its menu: the project's, or S-Curve, Equal Power or
Linear for this transition alone (`JointEdit.soundCrossfade`). Its timing
can't be changed there: it is the transition's, so lengthening, moving or
rolling it in the video lane moves the sound's crossfade too. Detach the
sound to fade it on its own.

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
clip's frames after it on a track below. A nested timeline's spare
footage is the rest of it beyond its trims: it is flattened once over its
clip and the reach of its joints, and drawn there by groups that share
those clips, one above the layer for its frames before the cut and one
below for the frames under its neighbor's transition.

There are 25 kinds of picture in five groups (dissolves, wipes, moves,
3D, stylized), and three of sound (Audio) for clips with no picture;
what each does, its settings (set in the inspector under the
transition's length) and how it is drawn are in
[transitions.md](transitions.md). A wipe or slide acts in the frame of
the timeline the clip is on, after the clip's effect stack.

The **film dissolve** shows the following picture brightest parts first:
it appears wherever it is brighter than a threshold that falls from white
to black over the transition, with a soft edge (`LumaReveal`). On a way in
the following picture is the clip itself; on a way out it is what is under
the clip. Brightness is the encoded Rec. 709 luma, so it follows how the
picture looks.

### Rendering

Transitions sit below a clip's effect stack: the compositor draws the clip
through its stack, then applies the transition. Cross dissolve, wipe,
slide, zoom and spin set the clip's opacity, transform and crop in the
frame of the timeline the clip is on (`EdgeTransitions` in
`ClipTransition.swift`, evaluated per frame). The film dissolve keys on
brightness, on the clip's picture or on what is drawn under it. The rest
are drawn from two whole pictures, what's under the clip and the clip over
it ([transitions.md](transitions.md#two-pictures)). All of it is drawn by
`LayeredCompositor` (Core Image), in preview and export alike, without
color management. A nested timeline is one picture, so a transition on it
applies to the whole; on a pass-through nested clip everything but the
wipe and the film dissolve applies: moves and fades to each layer inside,
two-picture kinds to the layers as drawn over what's under them.

### Curves

Each transition has a progress curve (`TransitionCurve`): bezier segments
from (0, 0) to (1, 1), time across, progress up. New moves and 3D kinds
get Easy Ease, everything else Linear. Presets, named as in After Effects:

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

## Retimed clips

A clip's speed (percent of its source's own) decides how long it lasts: the
block is as long as its source range takes at that speed, and a clock mark
shows it is retimed. A clip block no longer shows its duration. Instead a
retimed one reads its speed along the second line of the bar: a `|`, a
space and the speed at the start and at each speed keyframe, where the
keyframe plays. Between two points whose speeds differ (a ramp) a stretched
arrow runs from one to the next; between equal speeds there is none. (A
hard change, with no ramp, would show no arrow either, but speed keyframes
always ramp for now.) Badges (effects, sound, time, shutter) sit at the end
of the name line. Dragging its end trims the source, never stretching the
clip; changing the speed moves the clips after it on the layer by as much as
its end moved, as trimming does. Speed, frame blending, echo and the sound
choice are in the clip's menu and the effects panel's Time rows; motion blur
and trails (a camera aperture mark) are under Shutter. See
[effects.md](effects.md#time-and-shutter).

### Rounding and gaps

A clip's end is exclusive: a clip that ends at frame 50 and one that starts
at frame 50 meet; one that starts at 51 leaves a one-frame gap. At a fixed
speed a clip's length is exact. Under a speed ramp, where the source time
for a moment is found by searching and stored to 1/240000 s, a clip's end
is only known to a few microseconds, so these rules apply:

- **1 ms is the tolerance** for "the same place": about 3% of a frame at
  30 fps, far above the 4 µs of error and far below anything a person
  could mean. It is `Timeline.abutmentTolerance`.
- A retimed clip's length within 1 ms of a whole number of frames is that
  number; otherwise trimming it back to whole frames rounds down.
- A clip that met a retimed clip's end before an edit still meets it after
  (it moves to the frame the end is at).
- Building a composition closes any gap between clips under 1 ms, so a
  microsecond of difference never draws a black frame.
- A gap of a frame or more is a real gap, and is never closed for you.

## Following the music

Clips on video and sound layers are attached to the song under their
first frame, and move with it when it moves; footage in their way is
pushed later. Where each is tied shows as its **music point**, a green
line with a point at its foot; the selected clip's can be dragged to
another frame, and is marked on its song too. A clip's menu turns this off
(**Follow Music**) or ties another frame (**Attach to Music at
Playhead**). See [motion-designer.md](motion-designer.md#clips-attached-to-the-music).

## Adjustment layers

The adjustment button in the timeline's header adds an **adjustment layer**
at the top of the stack. It lives in the Video area, holds adjustment clips
and nothing else, and is named "Adjustment 1" and so on. An adjustment clip
has no picture: its effect stack (edited in the effects panel, like any
clip's) is applied to the layers below it while it plays. Its layer's header
menu has **Reach**: all layers below, or down to a chosen one. A bracket
along the layer's left edge shows the layers it reaches, faded when it reaches
none. See [effects.md](effects.md#adjustment-layers).

## Clip badges and menus

A clip with effects shows a small badge with how many, and a nested clip
that passes through shows a mark. Dragging an effect from the effects panel
onto a clip adds it to the end of the clip's stack. The clip's menu has
**Cut**, **Copy**, **Paste** and **Duplicate** at its top, and **Pass
Through** for nested clips.

## Turning clips off

**V** turns the selected clip off, or every clip picked together; if all
of them are off already it turns them on again. The clip's menu has
**Turn Off** / **Turn On** for that clip, and the Timeline menu the same
as V. A clip that is off stays where it is and can still be moved,
trimmed and edited, but it is drawn faded and without colour and plays
as a gap: it is left out of the picture, the sound, renders and exports.
The timeline keeps its length when the clip that is off is the last one.
VoiceOver reads it as turned off and has Turn on / Turn off among its
actions.

## Copy, paste and duplicate

The Edit menu's **Cut** (⌘X), **Copy** (⌘C), **Paste** (⌘V),
**Duplicate** (⌘D) and **Delete** work on whatever is selected, as
everywhere on the Mac (`EditCommands`). Text being typed in has them
first; then Beat Match while it is open, then the effects panel, then the
timeline, each command going to the first that offers it. So with an
effect selected, ⌘C copies the effect; with only a clip selected, the
clip.

- **A clip comes along whole**: its trim, effects, keyframes,
  transitions, time and shutter (`ClipBundle`, `TimelineClip.duplicated`).
  The copy gets new IDs for itself, its effects and their controls, and
  what pointed between its effects (Against, a Keyframing effect's target
  and the keyframes it wrote) points at the copies.
- **Between projects**: what was copied is the app's, not one window's
  (`EditorClipboard`), so a clip or clips copied in one project's window
  paste into another's. A copy carries what it needs from its project
  (`PasteSources`): the media it plays, the timelines it embeds with
  everything they play, and its effects' inputs. Pasting adds what the
  other project lacks, by ID, so pasting in the same project adds
  nothing. At the next save, pasted media whose file is inside the other
  project's package is copied into this one's `Media/` (an instant clone
  on the same APFS volume), and its reference data is copied from that
  package, so this project doesn't depend on the other; media the other
  project referenced in place stays where it is.
- **Paste** puts the clip at the playhead, landing as a clip moved there
  would: inside a clip it goes to the nearer edge, and later clips on the
  layer move right to make room. It goes onto the selected clip's layer or
  the selected layer when that takes it, else back onto the layer it came
  from, else onto a new layer of its kind at the top. The pasted clip is
  selected and the playhead moves to its end, so pasting again lays the
  next copy after it. Clips paste into other timelines too, but a nested
  timeline never into itself or a timeline it contains, however deep; an
  effect input that would do that is taken off the pasted clip, which
  pastes without it.
- **Duplicate** puts a copy right after the clip on its layer.
- **One clipboard.** Paste pastes what was copied last: copying effects
  after a clip makes ⌘V paste the effects, and the other way round
  (`EditorClipboard`). A copied clip also fills **Paste Effects**, which
  adds its effects to another clip's, and gives it the copied clip's time
  and shutter if they differ.

## Selecting several clips

Picking several things works the same in every editor that has them: the
timeline, the graph editor, the motion designer and the effects panel
(`SelectClick`, `SelectionSet`).

Drag in empty space in the tracks (between a layer's clips, or under the
last layer) to draw a **lasso**: every clip it touches is picked, and they
draw as selected. Hold Shift or Command to add to what is picked. A lasso that touches
one clip selects it as a click does; one that touches none selects nothing.

- **Command-click** a clip to add it to what is picked, or take it out.
  One left is selected as a clip is.
- **Shift-click** a clip to pick the run from the clip last clicked (or
  Command-clicked) to it, in place of what was picked: on the layers from
  the one to the other, every clip that overlaps the time from the earlier
  start to the later end (`Timeline.clipRange`).
Only the Arrow tool lassos. A clip's trim handles reach a few points past
its edges, and a press there trims rather than starting a lasso.

The lasso's rectangle fades out when the button comes up.

- **Right-click a clip** to select it as its menu opens, unless it is
  already selected or picked with others, which stay as they are so the
  menu acts on them all.
- **Click empty space or press Escape** to select nothing: no clip, layer,
  section or lasso. (A click in empty space used to do nothing, so a
  selected clip stayed selected.) **⌘A** picks every clip of the timeline
  together, which is also how to do it without a pointer.
- Clips picked together have no one clip for the Inspector and the effects
  panel to show. What is done to one of them is done to them all: **Cut,
  Copy, Duplicate, Delete**, **Put Selection in New Timeline**, moving and
  nudging, **V**, ⌘B, and from the right-click menu of any of them **Turn
  Off**, **Mute Sound**, **Detach Audio**, **Pass Through**, **Follow
  Music**, **Paste Effects**, **Speed**, **Frame Blending**, **Echo**,
  **Sound at Other Speeds** and **Shutter** (each to those of them it
  applies to; a toggle sets them all to the opposite of the clip clicked).
  Items about one clip are greyed out: the reach of an adjustment, removing
  a transition, **Beat Match**, **Remove Beats**, **Open Timeline**,
  **Attach to Music at Playhead**, **Show in Clips Browser** and
  **Conform Timeline to Clip**. **Motion Designer for Selection** opens on
  them when they are all on one layer, and is greyed out when they aren't.
- **Copy** keeps where they sit relative to each other, in time and across
  layers (`ClipGroupBundle`); the clipboard holds that group until
  something else is copied. **Paste** puts the earliest at the playhead
  with the rest keeping their offsets, each as a single clip would land:
  clips from one layer go back onto it in the timeline they came from, else
  onto one new layer made for them, and the clips after move right to make
  room. The pasted clips are picked together and the playhead moves to
  their end. **Duplicate** pastes right after the group.
- **Put Selection in New Timeline** (also on one clip's menu, as **Put in
  New Timeline**) takes the clips out into a new timeline named Nested 1,
  Nested 2 and so on, with the same frame size, rate and colors, their
  layers and places kept and the start at zero, and puts that timeline
  where they were as one clip on a new layer at the top, starting where the
  earliest did. It is a nested timeline like any other (see
  [effects.md](effects.md)), so it can be opened from the browser, given
  effects, or retimed as one.
- **Dragging** one of them moves them all by as much, each staying on its
  own layer, in whole frames and no earlier than the earliest can go
  (`EditingProject.moveClips`). The dragged clip snaps as one moved alone
  does; clips not picked that are in the way are pushed later. A song
  among them carries every clip attached to it, picked or not, since the
  music ties them (see "Following the music"); copying, deleting and the
  rest still act only on what is picked. Option-dragging a group copies
  nothing; a group isn't moved to other layers.
- Trimming and slipping still act on the one clip dragged.

## Going into a nested timeline

**Double-click a nested timeline's clip** (Arrow tool) to go into the
timeline it plays (except on one of its transitions, where the click
selects the transition and shows its details, as on any clip); **Open Timeline** in its right-click menu and its
VoiceOver action do the same. The header bar then shows a **breadcrumb**
before the timeline's name: the timelines gone through to get here,
outermost first, each a button that goes back out to it (`trail` in
`TimelineEditorSurface`). Opening a timeline another way, from the
browser's Timelines tab, starts the trail over at the timelines it is
inside, as the tab lists it (`EditingProject.containingTimelines`), so a
nested timeline always has a way back out to the one that holds it.

The header only shows the open timeline's name: timelines are opened
(double-click) and renamed in the Timelines tab (see docs/browser.md). A
second display's own timeline, when it is independent, keeps its own
trail.

## Preview background

Timeline Settings has a **Background**: a checkbox and a color well. On,
the viewer shows that color wherever nothing is drawn, instead of black,
to see what is transparent: a title over nothing, the edges of a key, a
fade from nothing. It is the viewer's alone (`Timeline.previewBackground`,
saved as `previewBackground`, red, green and blue in the timeline's
encoded values, only while it is on). Exports, renders and the timeline
nested in another draw over black as before.

In the viewer the frame is drawn over transparency and then put over the
color (`LayeredInstruction.background`), as After Effects shows a
composition's background: it shows where export shows black, and no
blend mode or transition mixes with it. Renders are drawn over black for
export, so a timeline with a background plays in the viewer from its
clips, never its renders (`ViewerSource.playsRenders`); they are still
planned and made for export, and a stretch heavy enough to need one plays
as it would before it was rendered.

## Not implemented yet

- A larger graph editor for curves on short transitions.
- Thumbnails of the frames in the transition footage lane.
- Trimming at a joined cut from the clips themselves (the transition box
  covers the edges; roll the cut instead).
