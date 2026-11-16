# Viewer handles

Status: **planned, not implemented**. Nothing here is built. This
document is written for whoever builds it: it says what the person sees,
then the framework the handles are built on, then where each piece goes
in the code as it stands today, then the order to build it in. Choices
made while writing it that the request didn't settle are listed under
[Decisions made here](#decisions-made-here).

With **Show Handles** on, selecting a clip with pictures in the timeline
puts **handles** over it in the viewer: drag them to move, scale, turn
and fade the clip, and to move its anchor point. The handles edit the
same Transform controls the effects panel shows
([effects.md](effects.md#transform)), adding a Transform effect when the
clip has none. The viewer itself can be **zoomed and scrolled**, so
handles past the frame's edge can be reached. The handles are the first
user of a framework, the **viewer canvas**, that later tools (a pen for
masks and shapes, an effect's own controls) draw and edit through. The
synced external display gets the same canvas, in place of its freehand
markup.

[effects.md](effects.md#not-in-this-plan) left dragging in the viewer out
as "easy to trigger by mistake; left out until there's a design that
avoids that". What this design does about it is under
[Not by mistake](#not-by-mistake).

## What the person sees

### Show Handles

Handles are **off until asked for**. A toggle in the viewer's rail
(`viewfinder` glyph, beside the preview options) turns them on and off,
as do **Show Handles** in the View menu and the **H** key while the
viewer or the timeline has the keys. Remembered per Mac
(`Preferences.viewerHandles`, off by default).

### When handles show

With Show Handles on, handles show for the clip selected in the timeline
(`TimelineSelection`) when all of these hold:

- The clip has an effect stack (`EditingProject.hasEffectStack`) and
  isn't an adjustment clip: footage, a still, a nested timeline, shapes
  or text. Audio clips and adjustment clips get none.
- The playhead is inside the clip, the clip is on, and its layer is
  shown, so the clip is in the picture.
- The viewer shows the timeline at the playhead, paused. **Playing hides
  the handles** and the canvas takes no presses; so do a browser skim, a
  skim of the timeline (`PlaybackModel.skimTime`) and a trim preview,
  which show some other picture.
- One clip is selected, not a transition of it, and not several clips
  picked together.

Scrubbing or stepping the playhead keeps them: they follow the clip's
keyframes as its values change.

A clip the Motion Designer has locked (`ProjectState.lockedClipIDs`)
shows its box without handles, and a press on it gives the locked-clip
notice, as any other edit of it does.

### The handles

Everything is drawn in view points at a fixed size, whatever the
viewer's zoom.

- **The box**: the clip's **bounding box** as its Transform effects
  place it. It is always a rectangle before they act, whatever the
  clip's shape: an ellipse, a star or a line of text has the rectangle
  round what it draws. On screen it is that rectangle turned, or a
  parallelogram when a stretch is followed by a turn. A one point line
  in `Design.accent` over a three point line of black at 35%, so it
  reads on any footage.
- **Scale handles**: eight squares, 8 points, white with an accent
  edge, turned with the box: one at each corner and one at the middle
  of each edge.
- **Rotation**: there is no handle of its own. The zone just **outside**
  each of the eight scale handles, from the handle's edge to 24 points
  out, turns the clip.
- **Position** has no handle either: a drag **inside the box** moves the
  clip.
- **The anchor**: a 10 point crosshair where the clip's anchor point is,
  the point rotation turns about. It can be dragged.
- **The opacity chip**: a small chip under the middle of the box's bottom
  edge, kept inside the view, with the `circle.lefthalf.filled` glyph and
  the clip's opacity ("100%"). Drag it left or right to **fade**.

A press is given to the first of these it lands on: a scale handle
(within 6 points), the anchor, the chip, a rotation zone, the inside of
the box. Anywhere else it does nothing.

### The pointer

The pointer always shows what a press would do, and changes as it moves
between zones:

| Over | Pointer |
| --- | --- |
| A scale handle | A two-headed resize arrow along that handle's direction, turned with the box (`NSCursor.frameResize`) |
| A rotation zone | A curved two-headed arrow, turned to that corner or edge (drawn from `arrow.trianglehead.2.clockwise.rotate.90`) |
| Inside the box | A four-way move arrow (drawn from `arrow.up.and.down.and.arrow.left.and.right`) |
| The anchor | A crosshair (`NSCursor.crosshair`), with the anchor's position beside it (below) |
| The opacity chip | `.resizeLeftRight` |
| Anything else | The arrow |

A handle that can't be dragged (a driven control, below) shows
`.operationNotAllowed`.

### Dragging

A drag begins once the pointer has moved 3 points; a press without a
drag changes nothing. While it lasts the viewer follows it live, the
other handles are hidden, and a **readout** chip by the pointer (the
style of the timeline's drag timecode label) says the value it has
reached. Releasing saves it as one undo step. **Escape** puts everything
back, a Transform effect the drag added included. Modifiers are read as
they change, so pressing or releasing Shift or Option mid-drag takes
effect at once, with the pointer still.

| Drag | Does | Shift | Option | Readout |
| --- | --- | --- | --- | --- |
| Inside the box | Position follows the pointer, in whole pixels | Kept to one axis: the one the drag from its start is nearer (the 45° line decides), free to change as the pointer crosses it | | `120, −40` |
| A corner handle | Scale, **proportional**: both numbers grow by the same factor, keeping whatever ratio they had. The opposite corner stays where it is | **Free**: width and height apart, the corner under the pointer | Scales from the box's **center** instead | `150%`, or `150% × 120%` when apart |
| An edge-middle handle | Scale along **that axis only**: width for the left and right handles, height for the top and bottom. The opposite edge stays where it is | **Proportional**: both numbers by the same factor | Scales from the box's center | the same |
| A rotation zone | Rotation follows the pointer round the anchor; turns past 360° are kept | **Snapped to multiples of 15°** | | `37.5°`, always shown, to a tenth of a degree |
| The anchor | The anchor point follows the pointer, in whole pixels; the picture stays where it is | In steps of **ten pixels** | **A tenth** of the pointer's movement, in tenths of a pixel | `Anchor 120, −40` |
| The opacity chip | Opacity, one point of drag for 1%, 0 to 100 | Ten per point | A tenth per point | `80%` |

- **Shift means "the other way"** on a scale handle: a corner is
  proportional and Shift frees it; an edge is one axis and Shift makes
  it proportional.
- **Scale holds a point still.** The Scale control scales about the
  anchor, so to keep the opposite corner or edge (or, with Option, the
  box's center) where it is, a scale drag also changes **Position** by
  whatever that takes. When the point held is the anchor itself (Option
  on a clip whose anchor hasn't been moved), Position isn't touched.
- An edge handle changes one of Scale's two numbers, x or y, which the
  stack applies along the screen's axes at that step
  ([effects.md](effects.md#transform)). With Scale above Rotation in the
  effect, as a new Transform has them, that is the box's own width or
  height. With Rotation above Scale it shears the box, as the same
  numbers typed in the panel would.
- A scale handle dragged across the point held flips the clip (negative
  scale), as the control allows.
- **Rotation turns about the anchor**, from whichever zone it is dragged.
- **The anchor's readout shows before a press too**: hovering the
  crosshair puts its position by the pointer (`Anchor 0, 0`), so it is
  plain what a press there would move. The numbers are the ones the
  effects panel shows: the offset from the middle of the picture, in
  timeline pixels.
- **Moving the anchor leaves the picture where it is** at the playhead:
  on a clip that is scaled or turned, Position changes to make up for
  it. On a clip that is neither, only the anchor changes.
- Scale is kept to a tenth of a percent, rotation to a tenth of a
  degree, opacity to whole percents (tenths with Option).
- A Shift drag that leaves Scale's x and y apart, or an edge drag, turns
  the control's link off (`EffectControl.linked`), so the effects panel
  shows the two numbers as separate; a proportional drag leaves the link
  as it is.
- A control a Keyframing effect drives refuses hand edits
  ([keyframing-effects.md](keyframing-effects.md)). Its handle is drawn
  dimmed, and a press on it gives the same notice the panel's field does
  (`ProjectState.Refusal.drivenKeyframes`).
- Starting playback mid-drag (Space) ends the drag as letting go would,
  and the handles go.

### Keyframes

**A manipulation of something that already has keyframes adds a keyframe
at the playhead**, or changes the one already there, as typing in the
effects panel does (`EffectControl.setComponent(_:to:at:)`, in the
clip's source time). This holds for every value a drag writes: Position,
Scale, Rotation and Opacity, the anchor point
(`TimelineClip.anchorPoint`), and the Position a scale or anchor drag
changes to hold its point still. Something without keyframes simply
takes the new value; a drag never starts animating it.

The point a scale or anchor drag holds still is held at the playhead.
Where the other values are keyframed, the frames between keyframes move
as the keyframes say, as in any app.

### Which effect a drag edits

A stack can hold several Transform effects, or none.

- The **target** is the Transform effect selected in the effects panel
  (`EffectsPanelState.selectedEffectID`), when the selected effect is
  one and is on. Otherwise it is the **last** Transform effect in the
  stack that is on: the one nearest the finished picture, so the box on
  screen and the numbers changed agree, as a layer's transform does in
  other apps.
- With no Transform effect on, the drag **adds one**, named as one added
  from the library is (`Effect.make(_:among:)`). It goes at the end of
  the stack, above any Blending effects that end it, so a blend at the
  bottom still acts as the layer's blend mode
  ([effects.md](effects.md#blending)) and isn't moved along with the
  picture.
- A target that has lost the control being dragged (a Transform reduced
  to its Position, then scaled by a handle) gets it back
  (`Effect.addControl`); one switched off is switched on.
- Nothing is added by selecting the clip or by pressing: only by the
  first step of a drag (or a key) that changes a value. Moving the
  anchor of a clip that is neither scaled nor turned adds nothing: the
  anchor point isn't an effect.

The box always shows where **all** the Transform effects together put
the picture (`StackFolding.fold`). The drag is worked out so the handle
stays under the pointer whatever else is in the stack (see
[The arithmetic](#the-arithmetic)).

### Not by mistake

- **Handles are off by default.** Nothing in the viewer can be dragged
  until Show Handles is turned on.
- **The viewer never selects.** Handles belong to the clip chosen in the
  timeline; a click in the viewer on another clip's picture, or on
  nothing, does nothing.
- **A drag needs 3 points of movement** before anything changes.
- **The pointer and the anchor's hover text** say what a press would do
  before it is made.
- **Escape** cancels a drag, and a finished one is a single undo step.
- **Nothing is added to the stack** until a value really changes.

### Keys

A click in the canvas gives it the keyboard (it is focusable, and wears
the active panel's border as the viewer does). While it has it and
handles show, it claims these keys (`claimsKeys`), so the arrows don't
step the playhead and Delete doesn't delete the clip:

| Keys | Does |
| --- | --- |
| Tab / ⇧Tab | Pick what the arrows change, next or previous: Position, Scale, Rotation, Anchor, Opacity. Its part of the handles is ringed. |
| ← → ↑ ↓ | Nudge it: Position or Anchor one pixel that way; Scale 1% (→ and ↑ up, about the anchor); Rotation 1° (→ and ↓ clockwise); Opacity 1% |
| with Shift | Ten pixels, 10%, 15°, 10% |
| with Option | A tenth of a pixel, 0.1%, 0.1°, 0.1% |
| Escape | During a drag, cancel it; otherwise give the keys back to the timeline |

Position is picked to begin with, so a click in the viewer and an arrow
key nudges the clip. Each nudge is an edit of its own, as a nudge on the
tone graph is, and adds a keyframe as a drag does. Space still plays,
and the handles go.

## Zooming and scrolling the viewer

The viewer has shown the frame fitted to its well and nothing else. It
gains a zoom and a place, which work **whether or not handles show, and
while playing**: they change what is looked at, not the project.

- **Pinch** with two fingers to zoom in and out, about the pointer: the
  spot of the picture under it stays under it.
- **Scroll** with two fingers to move the picture in **any direction**,
  both axes at once. A mouse's wheel scrolls it up and down, and across
  with Shift, as the system has it.
- **⌘+** and **⌘−** zoom in and out by steps (10, 25, 50, 75, 100, 150,
  200, 400, 800%), about the middle of the view. ⌘= is taken as ⌘+.
- Zoom runs from 10% to 800%. 100% is one timeline pixel to one screen
  pixel. **Fit** is the frame fitted to the well with its 36 point
  margin, as today, and is where every viewer starts.
- The picture can't be scrolled away: at least 48 points of the frame
  stay in the well on each axis.
- Past 100% the picture's pixels are enlarged, not drawn again: the
  viewer draws the timeline's frame at the size its quality setting
  gives ([rendering.md](rendering.md)).

Two buttons **appear** over the well's bottom left corner, as chips
(`beveledChip`), only while they would do something:

| Button | Appears when | Does | Key |
| --- | --- | --- | --- |
| **Center** (`scope` glyph) | The frame isn't centered in the well | Centers it, keeping the zoom | ⇧⌘0 |
| **Fit** (`arrow.down.right.and.arrow.up.left` glyph, with the zoom now: "64%") | The zoom isn't Fit | Zooms to fit and centers | ⌘0 |

Zoom In, Zoom Out, Zoom to Fit and Center are also in the View menu
(`ViewerCommands`, new, beside `WindowCommands`), with Show Handles.
They act on the viewer in the window that has the keys.

- Each viewer has its own zoom and place (`ViewerFraming`): the main
  viewer, a timeline window's, and the external display's.
- They aren't saved. A viewer goes back to Fit when it is shown a
  timeline with a different frame size.
- The browser's skim picture and the trim preview keep their own layout;
  the zoom is the timeline picture's.
- Handles, their zones and the readout keep their size in points at any
  zoom, so zooming in makes a small clip's handles easier to tell apart.

## The framework

Three pieces, so that the next thing drawn over the viewer is a new
handle set or a new tool and nothing else.

### The canvas

`ViewerCanvas` (`UI/Viewer/ViewerCanvas.swift`) is the one view laid
over the picture, in the main viewer and on the external display. It
knows nothing about transforms. It is always there, handles or not,
since it also takes the pinch and the scroll. It:

- maps between the timeline frame's pixels and its own points
  (`ViewerMapping`: the frame size, the well's size, and the viewer's
  `ViewerFraming`). It covers the whole well, not just the picture, so
  handles on or past the frame's edge can be reached;
- takes the pinch (`MagnifyGesture`, as the graph editor does) and the
  scroll (`ScrollWheelMonitor`) and changes the framing;
- asks the active **handle set** what to draw at the playhead and draws
  it: handles, outlines, guides;
- finds the handle or zone under the pointer, sets the cursor, and shows
  a handle's hover text;
- runs every drag the same way: the 3 point slop, the modifiers as they
  change, the hold to one side of the project
  (`ProjectState.beginHold`, `hold`, `endHold`), Escape (`DragEscape`),
  the readout, and the single undo step (`ProjectHistory.endGesture`);
- runs the keys and VoiceOver the same way, from what the handle set
  says a nudge does;
- hides its handles and takes no presses while the viewer plays or
  shows something other than the timeline. Pinch and scroll go on
  working.

A press that hits no handle goes to the active **tool**.

### Handle sets

A handle set turns the selected clip into handles, and a drag of one
into an edit. It is plain logic with no views, so it lives in
`Model/ViewerHandles/` and is tested without a window.

```swift
/// What the canvas gives a handle set: the clip as it was when the drag
/// began (or as it is now, when drawing), and where and when.
struct HandleContext {
    var project: EditingProject
    var timelineID: UUID
    var clip: TimelineClip
    var sourceTime: CMTime
    var frameSize: CGSize
    /// The effect picked in the effects panel, if any.
    var selectedEffectID: UUID?
    /// Frame pixels per view point at the viewer's zoom, for sizes and
    /// slop given in points.
    var pixelsPerPoint: Double
}

struct ViewerHandle: Identifiable {
    var id: HandleID                 // stable through a drag and between frames
    var place: CGPoint               // frame pixels, origin top left
    var glyph: Glyph                 // square, round, crosshair, chip(text), vertex, tangent, none
    var cursor: HandleCursor         // resize(angle), rotate(angle), move, crosshair, slide
    /// A zone round `place` that is the handle too, in points: the ring
    /// outside a scale handle that rotates.
    var zone: HandleZone?
    var isEnabled = true             // false: drawn dimmed, refuses with `refusal`
    var name: String                 // "Scale", "Top Left Corner", "Center"
    var value: String                // "150%", read by VoiceOver and the readout
    /// Shown by the pointer while it rests on the handle: the anchor's.
    var hoverText: String?
}

struct HandleDrag {
    var handle: HandleID
    var start: CGPoint               // frame pixels
    var now: CGPoint
    var shift: Bool, option: Bool
}

protocol ViewerHandleSet {
    func handles(_ context: HandleContext) -> [ViewerHandle]
    /// Lines drawn with the handles: a box, a path, a guide.
    func outlines(_ context: HandleContext) -> [ViewerOutline]
    /// A handle with an area rather than a spot (the inside of the box).
    func area(at point: CGPoint, _ context: HandleContext) -> HandleID?
    /// The clip after the drag so far, worked out from the clip in
    /// `context`, which is the clip from before the drag.
    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit?
    /// The same for one press of an arrow key.
    func nudge(_ handle: HandleID, _ direction: Direction, step: NudgeStep, _ context: HandleContext) -> HandleEdit?
}

struct HandleEdit {
    var change: (inout TimelineClip) -> Void
    var readout: String
    /// The undo step's name: "Move", "Scale", "Rotate", "Move Anchor
    /// Point", "Change Opacity".
    var actionName: String
}
```

Every step of a drag is worked out from the clip as it was before the
drag, which is what `ProjectState.hold` expects ("a dragged field sets
the value the drag has reached, not a change to it"). A set that adds an
effect makes it once, when the drag begins, and inserts that same effect
(same ID) at each step.

More than one set can be shown at once; the canvas draws them in order
and asks them for a hit in reverse. Which sets show is decided in one
place (`ViewerHandleSets.active(for:)`):

- `TransformHandles` for a visual clip that isn't an adjustment clip,
  unless the effect selected in the panel has handles of its own;
- that effect's handles (later stages) when it has;
- a tool's own set (a pen's path being drawn) when the tool says so.

### Tools

`ViewerTool` says what a press that hits no handle does, and the
canvas's cursor, as `TimelineTool` does for the tracks.

```swift
enum ViewerTool: String, CaseIterable, Identifiable {
    /// Drags handles. A press on nothing does nothing.
    case arrow
    // Later: pen (a press adds a vertex), rectangle, ellipse, text,
    // hand (a drag scrolls the view), each with its own key.
}
```

With one tool there is no picker. The second tool brings one into the
viewer's rail, built as `TimelineToolPicker` is.

### State

- `ViewerCanvasState` (`@Observable`, `UI/Viewer/`) holds what the
  displays share: the tool, what the arrows change, and the drag in
  progress (which handle, its readout), so a drag made on one display is
  drawn on both. `EditorView` owns it beside `playback` and hands it to
  the surface's viewer and to the external display; an independent
  external editor makes its own, as it makes its own `PlaybackModel`.
- `ViewerFraming` (`@Observable`, `UI/Viewer/`) holds one viewer's zoom
  (nil for Fit) and the frame pixel at the middle of its well. Each
  viewer owns its own.

## Transform handles

`TransformHandles` (`Model/ViewerHandles/TransformHandles.swift`).

### The box

- The **bounding box** is the rectangle round the clip's picture before
  its stack, in the frame's pixels:
  - footage and stills: the oriented size fitted into the frame and
    centered (`CompositionFlattening.fitTransform`, moved out of
    `Export/` to where both can use it);
  - a nested timeline: its frame fitted the same way;
  - shapes and text: the rectangle round what its shapes draw at the
    source time, each with its own Position, Size and Rotation
    (`ShapeStep.path`'s `boundingBoxOfPath`, strokes left out), or the
    frame when it draws nothing.
- `StackFolding.fold(effects:anchorPoint:at:center:)` gives the
  placement: a matrix, the anchor and the opacity. The box is the
  rectangle's corners through the matrix; the scale handles are its
  corners and edge middles; the rotation zones are outside them; the
  crosshair is the anchor; the chip reads the opacity of the target's
  control, not the folded one.
- With **Show Up to Here** on, the fold is of the stack as the viewer
  draws it, cut short (`EditingProject.showing(upTo:ofClip:in:)`).
- The source time is the playhead's in the clip
  (`TimelineClip.sourceTime(atTimelineTime:)`).

Looks between Transform effects that bend the picture (Twirl, Wave)
aren't part of the fold, so the box is the picture's frame, not its
bent outline. The box of a graphic clip with a Transform between two
shapes is that of its shapes before any Transform, through the whole
fold: close, not exact.

### The arithmetic

The handle must stay under the pointer whatever follows the target in
the stack (a later Transform, an effect that doesn't move the anchor).
So nothing is assumed about the stack; the edit is **solved from the
fold itself**, by folding the stack with the target's controls set to
trial values.

- **Position.** Where a point of the picture lands is affine in
  Position's two numbers. Fold at the start value, at +1 in x and at +1
  in y; the three give a 2×2 matrix `J` from a change in Position to a
  change on screen. The new Position is `start + J⁻¹ · (now − press)`
  (after the Shift lock, which is applied to the pointer's movement on
  screen), rounded to whole pixels. `J` is the identity for a lone
  Transform, so this is the plain case too.
- **Scale**, in two steps. `F` is the point held still: the opposite
  corner or edge middle, or the box's center with Option.
  1. The vector from `F` to the dragged handle is linear in Scale's two
     numbers and doesn't depend on Position at all. Three folds give
     that 2×2. A corner, free (Shift): solve it so the handle is at the
     pointer. Proportional (a corner, or an edge with Shift): the one
     factor on both numbers that brings the handle nearest the pointer,
     a projection onto the line from `F` through the handle. An edge:
     the same projection for its one number.
  2. Fold again with the new Scale, see where `F` went, and move it back
     with Position, as a Position drag is solved. Nothing is written to
     Position when it comes out unchanged.

  A handle Scale can't move (its number is 0) is drawn dimmed.
- **Rotation.** The angle the pointer has swept round the anchor on
  screen since the press, added up from step to step so it runs past
  360°, times the direction the picture turns on screen for a positive
  Rotation (measured from two folds, so a flipped clip still follows the
  pointer). Shift snaps the resulting **value**, not the change, to a
  multiple of 15°.
- **The anchor.** Where the anchor is on screen, and where the picture
  is, are both affine in the anchor point's two numbers and Position's
  two together. Five folds give a 4×4 system with two conditions: the
  anchor has moved by the pointer's movement (cut to a tenth with
  Option), and a corner of the box is where it was. The anchor point's
  numbers are rounded to whole pixels (tens with Shift, tenths with
  Option) and Position solved again for the rounded anchor. With no
  scale or turn in the stack Position comes out unchanged and isn't
  written. A clip scaled to nothing has no answer; its crosshair is
  dimmed.
- **Opacity.** `start + points dragged × step`, through
  `ValueDrag.value(from:distance:step:flags:range:)`, the panel's own
  rule.

Each returns new numbers, written with `setComponent(_:to:at:)` at the
source time (the anchor point with `AnimatedValue.set(_:at:)`), which is
what sets or adds the keyframe on an animated value. Scale's link is
switched off first when the numbers are to differ, since `setComponent`
moves both while it is on.

### Following the drag without a rebuild

A held drag is drawn by patching the frame's clips with the drag's
values (`LiveValues`, `DrawClip.withValues`), which works while the
project's `StructureKey` is unchanged. The anchor point is already a
value there. **Adding an effect changes the key today**, so the first
drag on a clip with no Transform would let the hold go
(`ProjectState.letGo`) and wait for the player's item to be built again
before the picture moved.

`withValues` already replaces a clip's whole stack, so the compositor
can draw a Transform that wasn't there when the item was built. The
plan is to leave Transform effects out of `StructureKey`
(`Effect.bare`'s caller in `StructureKey.init(composition:)` drops
effects of kind `.transform`): they have no input, no track and no pass
of their own. To check when building it: transforms pushed into nested
timelines by `StackFolding`, and a stretch playing from a render
(`playWithoutRenders` already covers values). If it can't hold, the
fallback is to add the effect as a write of its own when the drag
begins, inside the same gesture, and accept one build before the
picture follows.

## An effect's own handles

Later stages; the framework above is shaped for them.

- **Point controls** (stage 8). A package's `point` control is "a
  position from the middle of the frame, in the timeline's pixels"
  ([effect-packages.md](effect-packages.md#controls)), which is exactly
  a handle. `PointControlHandles` gives every point control of the
  effect selected in the panel a round handle named for the control,
  with no change to any package: 18 shipped packages (Spotlight, the
  masks, Twirl, Zoom Blur, Lens Flare…) get one, Corner Mask four. A
  control opts out with `"handle": false`.
- **Where an effect's point is on screen.** An effect's coordinates are
  the frame's at its place in the stack; Transform effects below it
  move the picture afterwards. The canvas maps through them: the matrix
  of the steps after effect `i` is the whole fold times the inverse of
  the fold of the effects above `i`
  (`StackFolding.placement(after:)`, new). Every handle set says which
  effect it belongs to and works in that effect's coordinates.
- **Declared handles** (stage 9). A `viewer` key in effect.json, the
  sibling of `graph` ([effect-packages.md](effect-packages.md#graph)):
  handles whose `x` and `y` are expressions of the controls, a `set` of
  controls to expressions of where the handle was dragged, and guides
  (`line`, `ellipse`, `polygon`) drawn from expressions, so Spotlight's
  ellipse can be sized and turned on the picture and Corner Mask's four
  points are joined. It needs expressions to read and set one part of a
  vector (`spotSize.x`), which they can't today. Checked when the
  package loads, as `graph` is; it changes nothing drawn, so no
  `version` rise.
- **Built-in effects** conform in Swift: `EffectDefinition` gains
  `viewerHandles: (any ViewerHandleSet)?`. First the shapes (Size,
  Position, Rotation, Corner Radius) and a text box's width, which is
  step 4 of [graphic-layers.md](graphic-layers.md#building-it).
- **A pen tool** is a `ViewerTool` whose press on nothing adds a vertex,
  plus a `PathHandles` set for vertices and tangents. It waits on free
  paths in the model ([graphic-layers.md](graphic-layers.md#saving)).
  Masks drawn the same way wait on a mask effect that takes a path
  ([effects-keying.md](effects-keying.md)).

An adjustment clip gets no Transform handles, but the effects on it can
show their own: a Spotlight on an adjustment clip is placed in the
frame like any other.

## Where it appears

### The main viewer

`ViewerPanel` lays `ViewerCanvas` over the well, above the picture and
below the notices (banner, offline notice, build error), which keep
their hit testing; the Center and Fit chips sit above the canvas. It is
a view of its own that reads the playhead through `PlayheadReader`, so
`ViewerPanel.body` still reads nothing that changes as the playhead
moves (`ViewerPanelTrackingTests`). `TimelineEditorSurface` passes it
the project, the timeline, the selection, `effectsState` and the
playhead. `ViewerPicture`'s accessibility element stays; the canvas's
elements sit beside it.

`ViewerPanel.picture` stops being a fitted view with padding: it gives
the picture the rectangle `ViewerMapping` works out (the frame's size
times the zoom, placed by the framing) and clips the well. It is sized
and placed, not put through a scale effect, for the reason it has no
drop shadow: the video surface mustn't go through an offscreen pass.

The rail gains the Show Handles toggle.

### The external display

Synced, `ExternalViewerContent` shows `ViewerCanvas` over the picture in
place of `AnnotationOverlay`, with the primary's timeline and selection
(it already has both bindings), the shared `ViewerCanvasState` and
`PlaybackModel`, and a `ViewerFraming` of its own. Its top bar gains the
Show Handles toggle. Edits land in the one project through the
`ProjectState` the window already has in its environment; the window is
also given the history (`\.projectHistory`) for the undo step, and ⌘Z
already reaches the editor's undo manager (`editorUndoManager`).

Fit there fills the screen with no margin, so a full-frame clip's
handles sit on the screen's edges, half showing, and its rotation zones
are off the screen: pinch out, or ⌘−, to bring them in. ⌘0 goes back to
filling the screen.

**The markup goes**: `Annotations.swift` (`AnnotationModel`,
`AnnotationOverlay`, `InkLayers`), `AnnotationModelTests`, the Remove
last stroke and Clear markup buttons, `markupUndoManager` and
`onSyncChange` in `ExternalDisplay.swift`, and `EditorView`'s
`annotations`. Drawing on the picture comes back as the pen tool, as
shapes in the project rather than ink over it.

Independent, the window is a `TimelineEditorSurface`, whose viewer has
the canvas like any other.

## Accessibility

Following [accessibility.md](accessibility.md#rules-for-new-ui):

- The canvas is a container labelled "Handles of *clip name*". Each
  thing a drag can change is an **adjustable** element in it: Position X,
  Position Y, Scale, Rotation, Anchor X, Anchor Y, Opacity, with the
  number as its value ("120 pixels", "150 percent"). Increment and
  decrement are the arrow keys' nudges (`ViewerHandleSet.nudge`), so
  VoiceOver gets every later handle set for free.
- Named actions for the ten-fold steps (Move 10 pixels left…), and
  Reset on each.
- The readout and the hover text aren't announced; the element's value
  is read after.
- The Show Handles toggle is a toggle with a label and an on or off
  value. The Center and Fit chips are buttons with those labels; Fit's
  value is the zoom ("64 percent"). Handle glyphs and the box are
  `.decorative()`.
- Everything a drag does has the keys above. Everything the pinch and
  the scroll do has ⌘+, ⌘−, ⌘0 and ⇧⌘0, bar scrolling to a chosen spot,
  which Center undoes.
- No animation: handles and chips appear and go at once, and Fit and
  Center jump (or go through `editorAnimation`, which respects Reduce
  Motion).

## Tests

- `TransformHandlesTests` (`Tests/.../Model/ViewerHandles/`):
  - the box for footage, a still of another shape, a nested timeline, an
    ellipse and a line of text (a rectangle each time);
  - for each drag, that folding the edited clip puts the handle at the
    pointer, with a lone Transform, with a second Transform after the
    target, with an effect that doesn't move the anchor, and with a
    flip;
  - a corner proportional and, with Shift, free; an edge one axis and,
    with Shift, proportional; the opposite corner or edge unmoved after
    each, and the center unmoved with Option; Position untouched when
    the point held is the anchor;
  - rotation from a corner zone and from an edge zone, about the anchor;
    15° snapping of the value; turns past 360°;
  - the 45° lock and its change of axis;
  - the anchor: the box unmoved on a scaled and turned clip, Position
    untouched on a plain one, Shift's tens and Option's tenths;
  - keyframes: each of Position, Scale, Rotation, Opacity and the anchor
    gets a keyframe at the source time when animated and none when not,
    the held-still Position included;
  - the target rule (selected, last, added, above a trailing Blending, a
    missing control put back); nudges.
- `ViewerMappingTests`: frame to view and back at Fit, letterboxed both
  ways, and zoomed and scrolled; a pinch keeping the point under the
  pointer; the zoom's limits and steps; the 48 point scroll limit; Fit
  and Center.
- `ViewerCanvasInteractionTests` with `EventHarness` (`UI_EVENTS=1`):
  nothing happening with Show Handles off; the 3 point slop, a drag as
  one undo step, Escape putting back a Transform the drag added, Shift
  and Option pressed with the pointer still, no response while playing,
  Tab and the arrows, the keys going back to the playhead after Escape;
  the pointer over each zone; the anchor's hover text; scrolling both
  ways, and the chips appearing and going.
- `HeldDragFollowTests` and `StructureKeyTests`: a Transform added
  mid-drag keeps the key, and the held frame is drawn with it.
- `ViewerPanelTrackingTests`: the panel's body still isn't invalidated
  by the playhead, by a drag or by a scroll.
- `UISnapshots`: `viewerHandles` (a turned clip, a stretched one, a
  dimmed driven handle, the readout, the anchor's hover text),
  `viewerZoomed` (zoomed in and off center, with both chips) and the
  external display's synced view.
- Stage 8 on: `PointControlHandlesTests` over the shipped packages, and
  the loading checks for `viewer` beside those for `graph`.

## Decisions made here

- **A scale drag holds the opposite corner or edge still**, which the
  request implies by giving Option "from the center". The Scale control
  scales about the anchor, so this is done by changing Position with
  it, and a scale drag on a clip with Position keyframes adds one
  there. The other reading, scaling about the anchor unless Option is
  down, never touches Position but makes Option do nothing on a clip
  whose anchor is at its center.
- **Corners keep the first rule** (proportional, free with Shift) and
  only edges take the new one (one axis, proportional with Shift), so
  Shift flips whichever the handle does by itself.
- **Option on a scale handle means the box's center**, not the anchor,
  as the request says "object center"; they are the same until the
  anchor is moved.
- **Rotation turns about the anchor** though it is dragged from the
  box's edge.
- **Dragging the anchor keeps the picture still**, changing Position on
  a scaled or turned clip, as After Effects' Pan Behind does. Moving
  the anchor alone would make such a clip jump.
- **Shift and Option on the anchor follow the panel's value drag**: Shift
  ten at a time, Option a tenth. "More incremental" could also mean
  both slow it down.
- **Opacity is a chip dragged sideways**, the panel's value drag moved
  onto the picture: opacity has no place in space to grab. It is a build
  step of its own so it can be left out.
- **Shift on rotation snaps the value**, so a clip at 7° goes to 0° or
  15°, not 22°.
- **The last Transform effect is the target**, and a new one goes at the
  end above trailing Blending effects.
- **The viewer doesn't select clips.**
- **Handles hide during any skim**, not only playback; zoom and scroll
  work throughout.
- **Fit also centers**; Center keeps the zoom. **⌘0** and **⇧⌘0** are
  their keys, beside the ⌘+ and ⌘− asked for.
- **The Center and Fit buttons are chips over the well**, not in the
  rail, so they can come and go without the rail's controls moving.
- **Zoom is per viewer and isn't saved.**
- **Arrow keys nudge only while the canvas has the keyboard**, so the
  playhead keys stay what they are everywhere else.

## Not in this plan

- **Selecting a clip by clicking it in the viewer.**
- **Several clips at once.**
- **Snapping** to the frame's middle and edges, and guides.
- **Motion paths**: a keyframed Position drawn as a path with its
  keyframes as handles.
- **A hand tool** and Space-drag to scroll the viewer, and a menu of
  zoom sizes.
- **Crop and corner pin** handles.
- The pen, shape and text tools themselves, and free paths; this plan
  only makes room for them.

## Building it

1. `ViewerMapping` with zoom and place, `ViewerHandleSet` and its types,
   the bounding box (moving `fitTransform`), and `TransformHandles` for
   Position, Scale, Rotation and the anchor with the target rule and the
   keyframe rule, with `TransformHandlesTests` and `ViewerMappingTests`.
2. Transform effects out of `StructureKey`, with its tests.
3. `ViewerFraming`, the picture placed by the mapping, pinch, scroll,
   the Center and Fit chips, and `ViewerCommands` with their keys; the
   snapshot and event tests.
4. `ViewerCanvas` and `ViewerCanvasState`: drawing, hit testing and
   zones, cursors and hover text, the drag's life (slop, hold,
   modifiers, Escape, readout, undo), hiding while playing or skimming;
   in `ViewerPanel`, with Show Handles (off by default), its
   preference, menu item and key; snapshots and event tests.
5. The keys and the accessibility elements, checked with the
   `accessibility-reviewer` agent.
6. The opacity chip.
7. The external display: the canvas in place of the markup, and the
   markup's removal.
8. `StackFolding.placement(after:)` and `PointControlHandles`.
9. `viewer` in effect packages, expressions reading parts of a vector,
   and declarations for the shipped packages that gain from them.
10. Shape and text handles through `EffectDefinition.viewerHandles`
    (step 4 of [graphic-layers.md](graphic-layers.md#building-it)).
11. Docs, once built: this document's status; the README's row;
    [effects.md](effects.md) ("Not in this plan", and a section on the
    handles after "Changing values by dragging");
    [layer-transforms.md](layer-transforms.md)'s list of open work;
    [accessibility.md](accessibility.md) (the keys table, the VoiceOver
    list, and the Annotations entry under "Not implemented yet", which
    goes); `KeyboardShortcutsView`;
    [graphic-layers.md](graphic-layers.md), "Editing in the viewer";
    [effect-packages.md](effect-packages.md) (a "Viewer" section beside
    "Graph"); [effects-keying.md](effects-keying.md), "Not yet";
    [rendering.md](rendering.md), where it says what the structure key
    holds and how the viewer's picture is sized.

Steps 1 to 5 are the feature as asked; 6 and 7 complete it; 8 to 10 are
the framework's later users. This can't be built or run on Linux; it
needs full Xcode on a Mac. CI runs only when started by hand.
