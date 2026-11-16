# Viewer handles

Status: **implemented**, steps 1 to 11 of [Building it](#building-it):
the handles, the zoom and scroll, the keys and VoiceOver, and the
opacity chip, in every editor surface's viewer and on the synced
external display, whose markup is gone; the point controls' handles;
the loupe a held press opens; the handles and guides packages declare
in `viewer`; and a selected shape's or text block's handles. A pen tool
and free paths' vertices wait on free paths in the model. None of it
has been built or run yet (see [As built](#as-built)). Where the code differs from what follows is listed
under [As built](#as-built). The document says what the person sees,
then the framework the handles are built on, then where each piece goes
in the code, then the order to build it in. Choices made while writing
it that the request didn't settle are listed under
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
viewer or the timeline has the keys (left alone while text is typed, as
the timeline's plain keys are). Remembered per Mac
(`Preferences.viewerHandles`, off by default), one setting for every
viewer. The toggle's help says what it waits for: "Show handles on the
clip selected in the timeline (H)".

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
  reads on any footage. It is drawn past the frame's edge too, in the
  well, for a clip moved or scaled out of the frame, and it isn't
  changed by a transition playing over the clip.
- **Scale handles**: eight squares, 8 points, white with an accent
  edge, turned with the box: one at each corner and one at the middle
  of each edge. An edge shorter than 32 points on screen has no middle
  handle, so a small box's handles don't run together; zooming in
  brings it back.
- **Rotation**: there is no handle of its own. The zone just **outside**
  each scale handle turns the clip: the part of a circle 24 points
  round the handle that lies outside the box and past the handle's own
  6 points.
- **Position** has no handle either: a drag **inside the box** moves the
  clip.
- **The anchor**: a 10 point crosshair where the clip's anchor point is,
  the point the scale handles and the rotation zones work about (see
  [Scaling and turning about the anchor](#scaling-and-turning-about-the-anchor)).
  It can be dragged, and a double-click puts it back at the middle of
  the picture.
- **The opacity chip**: a small chip in the well's top left corner, with
  the `circle.lefthalf.filled` glyph and the clip's opacity ("100%").
  Drag it left or right to **fade**. It has a fixed place, not one by
  the box: the ground round the box is the rotation zones', and a fixed
  chip is in reach wherever the box is.

A press is given to the first of these it lands on: the chip, a scale
handle (within 6 points), the anchor, a rotation zone, the inside of the
box. Anywhere else it does nothing.

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
box follows the picture, the handles are hidden (all but the crosshair,
during a scale or a turn), and a **readout** chip
by the pointer (the style of the timeline's drag timecode label) says
the value it has reached: the control's own numbers, as the effects
panel shows them. Releasing saves it as one undo step. **Escape** puts
everything back, a Transform effect the drag added included. Modifiers
are read as they change, so pressing or releasing Shift or Option
mid-drag takes effect at once, with the pointer still. A pinch or a
scroll during a drag is ignored.

| Drag | Does | Shift | Option | Readout |
| --- | --- | --- | --- | --- |
| Inside the box | Position follows the pointer, in whole pixels | Kept to one axis: the one the drag from its start is nearer (the 45° line decides), free to change as the pointer crosses it | | `120, −40` |
| A corner handle | Scale about the **anchor**, **proportional**: both numbers grow by the same factor, keeping whatever ratio they had | **Free**: width and height apart, the corner under the pointer | | `150%`, or `150% × 120%` when apart |
| An edge-middle handle | Scale about the anchor along **that axis only**: width for the left and right handles, height for the top and bottom | **Proportional**: both numbers by the same factor | | the same |
| A rotation zone | Rotation follows the pointer round the **anchor**, from any of the eight zones; turns past 360° are kept. The pointer hides and the drag goes on past the screen's edge, turning finer the farther it is from the anchor (see [Turning](#turning)) | **Snapped to multiples of 15°** | | `37.5°`, always shown, to a tenth of a degree |
| The anchor | The anchor point follows the pointer, in whole pixels, catching on the box's corners, edge middles and center; the picture stays where it is | In steps of **ten pixels** | **A tenth** of the pointer's movement, in tenths of a pixel, and no catching | `Anchor 120, −40` |
| The opacity chip | Opacity, one point of drag for 1%, 0 to 100 | Ten per point | A tenth per point | `80%` |

- **Shift means "the other way"** on a scale handle: a corner is
  proportional and Shift frees it; an edge is one axis and Shift makes
  it proportional.
- **Scale and rotation write only their own control.** They turn about
  the anchor, which is what the controls do, so a scale or a turn never
  touches Position and never adds a keyframe to it.
- An edge handle changes one of Scale's two numbers, x or y, which the
  stack applies along the screen's axes at that step
  ([effects.md](effects.md#transform)). With Scale above Rotation in the
  effect, as a new Transform has them, that is the box's own width or
  height. With Rotation above Scale it shears the box, as the same
  numbers typed in the panel would.
- A scale handle dragged across the anchor flips the clip (negative
  scale), as the control allows.
- **The anchor's readout shows before a press too**: hovering the
  crosshair puts its position by the pointer (`Anchor 0, 0`), so it is
  plain what a press there would move. The numbers are the ones the
  effects panel shows: the offset from the middle of the picture, in
  timeline pixels.
- **Moving the anchor leaves the picture where it is**: on a clip that
  is scaled or turned, Position is shifted to make up for it (see
  [Keyframes](#keyframes) for how). On a clip that is neither, only the
  anchor changes.
- **The anchor catches** on the box's nine points (corners, edge middles,
  center) when it comes within 8 points of one, and the readout names
  it (`Anchor 480, −270 · Top Right`). Option, for fine movement, turns
  the catching off.
- Scale is kept to a tenth of a percent, rotation to a tenth of a
  degree, opacity to whole percents (tenths with Option).
- A Shift drag that leaves Scale's x and y apart, or an edge drag, turns
  the control's link off (`EffectControl.linked`), so the effects panel
  shows the two numbers as separate; a proportional drag leaves the link
  as it is.
- A control a Keyframing effect drives refuses hand edits
  ([keyframing-effects.md](keyframing-effects.md)). A handle is drawn
  dimmed when the control its drag writes is driven, and a press on it
  gives the same notice the panel's field does
  (`ProjectState.Refusal.drivenKeyframes`).
- Starting playback mid-drag (Space) ends the drag as letting go would,
  and the handles go.

### The loupe

**A handle pressed and held still** for 450 ms opens a **loupe** beside
the pointer: a box 168 points square showing the picture, the box and
the handles round the handle enlarged four times, a reticle at the spot
the drag has reached, and under it the hint "Hold ⌥ for finer control".
The drag has begun: in the loupe it goes at **a quarter** of the
pointer's pace, so the enlarged handle keeps up with the pointer, and
at **a sixteenth** while Option is held (the hint then says "Finer,
with ⌥"). Releasing saves it as any drag does, and Escape puts it back.

- It opens **only as a handle is first grabbed**: a press that moves
  past the 3 point slop first is an ordinary drag, and a drag that
  pauses, however long, never opens it.
- Option and the rate change where the pointer is when it goes down or
  up, so the handle never jumps (`FineDrag`).
- In the loupe the handle set sees the drag as **fine** rather than as
  Option: each value goes in its finest steps (tenths of a pixel for the
  anchor and a point, tenths of a percent for opacity) and the anchor
  doesn't catch on the box's points. Shift keeps its meaning.
- It sits above and to the right of the pointer, or wherever there is
  room in the well, clear of the readout under the pointer, and is
  drawn only on the display the drag is on.
- The opacity chip has no place on the picture to enlarge, so a press
  held on it opens none.
- **A rotation zone opens none either**: a turn gets fine by going far
  from the anchor instead ([Turning](#turning)), which a slowed pointer
  held to the screen would only cut short.
- It is decoration: VoiceOver and the keys have their own steps.

### Turning

**A drag on a rotation zone hides the pointer** once it passes the
3 point slop, and holds it still: the drag follows the mouse's own
movement from there (`FreePointer`), added up without bounds, so it
goes on past the well's and the screen's edges. A turn is the angle
round the anchor, so the farther the drag goes from the anchor the less
each point of movement turns the picture: a tenth of a degree is a
small move a few thousand points out. The lever runs from the anchor
toward the drag's point, a dot at its end standing in for the pointer
while that is in the well, and the readout stays in the well.

- Shift's 15° snap works the same at any distance.
- As the drag ends, let go or Escape, the pointer shows again on the
  line from the anchor toward where the drag got to, as far from the
  anchor as it was grabbed: about where the zone it grabbed has turned
  to.

### Scaling and turning about the anchor

**The scale handles and the rotation zones work about the anchor
point**, wherever it is: at the picture's middle, where it starts, on a
corner, or outside the box altogether. That is what the Scale and
Rotation controls do with the same numbers
([effects.md](effects.md#transform)), so a handle changes one control
and nothing else. Holding some other point still (the opposite corner,
the box's center) would mean changing Position along with it, and on a
clip whose Position has keyframes that would add one and animate
something nobody asked to animate.

**Any handle works, wherever the anchor is.** A drag is read as a lever
from the anchor to the pointer:

- a **turn** is the angle that lever sweeps. The spot that was grabbed
  stays on the line from the anchor to the pointer, so the clip follows
  the hand from any of the eight zones, the ones nearest the anchor
  included;
- a **scale** is how much longer or shorter the lever gets. The handle
  stays under the pointer.

A zone or handle near the anchor is a short lever: a small movement
turns or scales a lot. One far from it is a long lever, and finer. With
the anchor outside the box, every handle is on the same side of it and
the clip swings or grows away from the anchor like a door on its hinge.
None of this is special to this app; it is how a moved reference point
behaves in Photoshop, Illustrator and After Effects.

What keeps it readable:

- **The lever is drawn.** During a scale or a turn, a thin line joins
  the crosshair to the pointer, so what the clip is working about is in
  plain sight, and the crosshair stays while the other handles hide.
  When the anchor is out of view the line runs off the edge toward it.
- **The crosshair lights up** (an accent ring) while the pointer rests
  on a scale handle or a rotation zone, before any press.
- **No lever, no drag.** A scale handle within 10 points of the anchor
  on screen is dimmed, since the least movement would scale the clip
  out of sight. So is an edge handle on the same line as the anchor:
  with the anchor on the top edge, the top handle has nothing to pull
  against, while the bottom, left and right ones work as ever. A turn
  holds its angle while the pointer is within 10 points of the anchor
  and picks it up again as it leaves.
- **Putting the anchor somewhere useful is quick**: it catches on the
  box's corners, edge middles and center as it is dragged, and a
  double-click sends it home. To scale from a corner, drop the anchor
  on that corner and drag the one opposite.

There is no Option on a scale handle. "From the center" is what a clip
does until its anchor is moved, and once it is moved, the anchor is the
point asked for.

### Keyframes

**A manipulation of something that already has keyframes adds a keyframe
at the playhead**, or changes the one already there, as typing in the
effects panel does (`EffectControl.setComponent(_:to:at:)`, in the
clip's source time). The rule is one for every value a drag or a key
changes:

- Position, from a drag inside the box;
- Scale, Rotation and Opacity, from their handles, zones and chip;
- **the anchor point** (`TimelineClip.anchorPoint`), from dragging the
  crosshair.

Something without keyframes simply takes the new value; nothing in the
viewer ever starts animating it. Each drag changes the one thing it is
named for, with one exception.

**The exception is the Position an anchor drag shifts** to keep a scaled
or turned picture where it is. That shift isn't a manipulation of
Position, so it adds no keyframe: Position is moved **as a whole**, its
one value or every one of its keyframes by the same amount. While Scale
and Rotation hold still over the clip, that keeps the picture exactly
where it was at every frame. Where they are keyframed no single shift
can; the picture is exact at the playhead and the anchor's move shows
at the other frames, which is what moving the pivot of an animated
scale or turn means.

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
- With **Show Up to Here** on, the target is picked among the effects
  the viewer is drawing, so a drag is always seen.
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
handles show, it claims Tab, the arrows and Escape (`claimsKeys`), so
the arrows don't step the playhead. Delete isn't claimed: it deletes the
selected clip, as it does with the viewer active today.

| Keys | Does |
| --- | --- |
| Tab / ⇧Tab | Pick what the arrows change, next or previous: Position, Scale, Rotation, Anchor, Opacity. A chip beside the opacity chip names it and its value ("Position 120, −40") while the canvas has the keys. |
| ← → ↑ ↓ | Nudge it: Position or Anchor one pixel that way; Scale 1% (→ and ↑ up, proportional); Rotation 1° (→ and ↓ clockwise); Opacity 1% |
| with Shift | Ten pixels, 10%, 15°, 10% |
| with Option | A tenth of a pixel, 0.1%, 0.1°, 0.1% |
| Escape | During a drag, cancel it; otherwise give the keys back to the timeline |

Position is picked to begin with, so a click in the viewer and an arrow
key nudges the clip. Each nudge is an edit of its own, as a nudge on the
tone graph is, and does what the drag does: it adds a keyframe where
the value is animated, and a nudge of the anchor keeps the picture
still. Space still plays, and the handles go. The canvas gives the
keys back when its handles stop showing (another selection, playback)
and at a press outside it, as other drawn views do.

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
  200, 400, 800%), about the middle of the view. ⌘= is taken as ⌘+. The
  timeline keeps its plain **=**, **−** and **\\**: with Command the keys
  are the viewer's, without it the timeline's.
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
    var isEnabled = true             // false: drawn dimmed; a press gives the project's refusal
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
- **Scale.** Where the dragged handle lands is affine in Scale's two
  numbers as well. With the same three folds: a corner, free (Shift),
  solve the 2×2 so the handle is at the pointer. Proportional (a
  corner, or an edge with Shift): the one factor on both numbers that
  brings the handle nearest the pointer, a projection onto the line
  from the anchor through the handle. An edge: the same projection for
  its one number. A handle Scale can't move (it is level with the
  anchor on that axis, or its number is 0) is drawn dimmed.
- **Rotation.** The angle the pointer has swept round the anchor on
  screen since the press, added up from step to step so it runs past
  360° and held while the pointer is within 10 points of the anchor,
  times the direction the picture turns on screen for a positive
  Rotation (measured from two folds, so a flipped clip still follows the
  pointer). Shift snaps the resulting **value**, not the change, to a
  multiple of 15°.
- **The anchor.** Where the anchor is on screen, and where the picture
  is, are both affine in the anchor point's two numbers and Position's
  two together. Five folds give a 4×4 system with two conditions: the
  anchor has moved by the pointer's movement (cut to a tenth with
  Option, or brought onto one of the box's nine points when within 8
  view points of it), and a corner of the box is where it was. The
  anchor point's numbers are rounded to whole pixels (tens with Shift,
  tenths with Option) and Position solved again for the rounded
  anchor. The change in Position is added to its one value or to every
  keyframe of it alike (`AnimatedValue.offset(by:)`, new), never set as
  a keyframe. With no scale or turn in the stack Position comes out
  unchanged and isn't written. A clip scaled to nothing has no answer;
  its crosshair is dimmed.
- **Opacity.** `start + points dragged × step`, through
  `ValueDrag.value(from:distance:step:flags:range:)`, the panel's own
  rule.

Each returns new numbers, written with `setComponent(_:to:at:)` at the
source time (the anchor point with `AnimatedValue.set(_:at:)`), which is
what sets or adds the keyframe on an animated value. Scale's link is
switched off first when the numbers are to differ, since `setComponent`
moves both while it is on.

### The effects panel during a drag

The rows of what a drag changes show its values as it goes: the
overlay names the effects it changes, and the clip when its anchor point
moves (`TimelineClip.partsChanged(to:)`), to `ProjectState.showHeld`,
and those rows read `held` while their IDs are in
`ProjectState.heldParts`. The set changes as the drag begins and ends,
not on every step, so the panel's other rows aren't redrawn. A
Transform the drag adds has no row until the drag ends.

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

Point controls, declared handles and the shapes' handles are built
(steps 8, 10 and 11); a pen tool waits on free paths.

- **Point controls** (step 8, built). A package's `point` control is "a
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
- **Declared handles** (step 10, built). A `viewer` key in effect.json, the
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
their hit testing; the Center and Fit chips sit above the canvas, bottom
left, and the opacity chip is the canvas's own, top left. It is
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
filling the screen. The opacity chip sits under the top bar.

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
  Reset on each. The anchor's elements also have Move to Center and
  Move to *each of the box's eight other points*, the keyboard's way to
  what catching does for a drag.
- The readout and the hover text aren't announced; the element's value
  is read after.
- The Show Handles toggle is a toggle with a label and an on or off
  value. The Center and Fit chips are buttons with those labels; Fit's
  value is the zoom ("64 percent"). Handle glyphs and the box are
  `.decorative()`.
- Everything a drag does has the keys above. The pinch has ⌘+, ⌘− and
  ⌘0; the scroll has ⇧⌘0 and the canvas's VoiceOver scroll actions
  (`accessibilityScrollAction`), which move the picture half a well
  that way.
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
    with Shift, proportional; each with the anchor at the center, on a
    corner and outside the box, the anchor unmoved on screen and
    Position untouched every time;
  - rotation from a corner zone and from an edge zone, near the anchor
    and far from it, the grabbed point staying on the line from the
    anchor to the pointer; the angle held within 10 points of the
    anchor; 15° snapping of the value; turns past 360°;
  - handles dimmed within 10 points of the anchor and level with it;
  - the 45° lock and its change of axis;
  - the anchor: the box unmoved on a scaled and turned clip, Position
    untouched on a plain one, Shift's tens and Option's tenths, catching
    on each of the nine points and not with Option, the double-click;
  - keyframes: each of Position, Scale, Rotation, Opacity and the anchor
    point gets a keyframe at the source time when animated and none when
    not, and no other value is written;
  - an anchor drag on a clip with Position keyframes: every keyframe
    shifted alike, none added, and the box unmoved at each of them while
    Scale and Rotation hold still;
  - no edge-middle handle on an edge under 32 points;
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
  dimmed driven handle, the readout, the anchor's hover text, a turn
  with its lever line and the anchor outside the box),
  `viewerZoomed` (zoomed in and off center, with both chips) and the
  external display's synced view.
- Stage 8 on: `PointControlHandlesTests` over the shipped packages, and
  the loading checks for `viewer` beside those for `graph`.

## Decisions made here

- **Scale and rotation work about the anchor**, from every handle, so
  they change one control each. Holding another point still was planned
  and dropped: it wrote Position, and a keyframe there when Position was
  animated.
- **Option does nothing on a scale handle.** The request gave it "from
  the object's center"; with the anchor as the pivot that is either
  what already happens or a second pivot that writes Position.
- **A drag near the anchor is a short lever, not an error**, shown by a
  line from the anchor to the pointer, with handles dimmed and turns
  held only inside 10 points of it.
- **The anchor catches on the box's nine points** and a double-click
  centers it, so "scale from this corner" is a drop and a drag.
- **An anchor drag shifts Position as a whole** rather than setting a
  keyframe, so it animates nothing. It is the one place a drag writes a
  value it isn't named for.
- **Corners keep the first rule** (proportional, free with Shift) and
  only edges take the new one (one axis, proportional with Shift), so
  Shift flips whichever the handle does by itself.
- **Dragging the anchor keeps the picture still**, changing Position on
  a scaled or turned clip, as After Effects' Pan Behind does. Moving
  the anchor alone would make such a clip jump.
- **Shift and Option on the anchor follow the panel's value drag**: Shift
  ten at a time, Option a tenth. "More incremental" could also mean
  both slow it down.
- **Opacity is a chip dragged sideways**, the panel's value drag moved
  into the viewer: opacity has no place in space to grab. It sits in a
  corner of the well, not by the box, where the rotation zones are. It
  is a build step of its own so it can be left out.
- **Only the anchor has hover text.** The pointer's shape says enough
  for the rest; the anchor sits where a move would start.
- **Delete with the canvas focused deletes the clip**, as it does
  whenever the viewer is the active panel.
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
- **A hand tool** and Space-drag to scroll the viewer, zooming with a
  mouse's wheel, and a menu of zoom sizes.
- **Crop and corner pin** handles.
- The pen, shape and text tools themselves, and free paths; this plan
  only makes room for them.

## As built

Where the code (steps 1 to 11) differs from the plan above:

- **`HandleContext`** carries the clip's picture before its stack
  (`pictureRect`, worked out by `TransformHandles.pictureRect`), Show Up
  to Here's effect (`shownUpTo`) and whether the clip is locked, rather
  than the project and the timeline: a handle set needs no more. A drag
  that adds a Transform is given the effect itself (`newTransform`, made
  once by `TransformHandles.newTransform` when the drag begins), so each
  step inserts the same effect with the same controls.
- **`ViewerHandleSet`** also has `pivot(of:_:)`, the point a rotation
  zone's drag turns about; `HandleDrag` adds up the angle swept round it
  (`move(to:about:holdingWithin:)`), holding within 10 points.
- **The undo step's name** comes from `ProjectChange`, as for every
  other edit; `HandleEdit.actionName` is kept for a later set to use.
- **"Not several clips picked together"** isn't checked: the editor's
  surface sees only `TimelineSelection`, the one clip last picked, so
  with clips picked together the handles are that clip's.
- **The layer being shown** isn't a rule: layers can't be hidden, so the
  clip being on and under the playhead is enough.
- **Drawn and run** by `ViewerHandlesOverlay` (`UI/Viewer/`), which
  `ViewerCanvas` puts over the well inside a `PlayheadReader`; the
  pointer shapes are drawn from SF Symbols by `HandleCursors`, the
  resize arrow included, turned to the nearest 15°.
- **`ViewerCanvasState`** is owned by `EditorView` and handed to its
  surface and the external display, as planned; a surface not given one
  (a timeline window's, the external display's independent editor) keeps
  its own. It also carries the editor surface's parked playhead and
  effects panel (`follow(playhead:effects:)`, set while the surface is
  shown), which the external display's canvas reads: neither lived
  outside the surface before.
- **The readout and the lever** are drawn only on the display the drag
  is on, since the pointer is in its points; the other display shows
  the clip moving, and a fade's value in its opacity chip.
- **The zoom keys** (⌘+, ⌘=, ⌘−, ⌘0, ⇧⌘0) are taken by the canvas's key
  monitor in its own window, before the View menu, which can't reach
  the external display's window (not one of the app's scenes). The menu
  still lists them, and has them when text is being typed.
- **The external display's picture** is `FramedPicture` (moved out of
  `ViewerPanel`), with no hairline round it, filling the screen at Fit.
- **The anchor drag** solves the anchor and Position together (the 4×4
  system), rounds the anchor, then solves Position again from one corner
  of the box, as planned; with no Transform on, the anchor moves alone.
- **Point handles take the place of the Transform handles** while the
  effect selected in the panel has a point with a handle
  (`ViewerHandleSets.active`), on any clip, an adjustment clip's too.
  Only points that are on get one. The point being dragged stays drawn
  (the Transform rule hides every handle mid-drag), and a point's hover
  text says where it is ("Center 120, −40"). Shift keeps a point's drag
  to one axis and Option takes a tenth, as for the anchor.
- **The keys and VoiceOver come from the handle sets**: `keyTargets`
  says what Tab picks, with the axes VoiceOver adjusts and any extra
  actions (the anchor's moves), and `reset` and `refusal` are the set's
  too, so the canvas has no code of its own for a set. What the arrows
  change is kept by handle (`ViewerCanvasState.picked`).
- **Declared handles** are their own set (`DeclaredHandles`), shown
  with the point handles for the effect selected: drawn as diamonds,
  over the round points, and asked first for a press. Guides are drawn
  dashed, apart from the clip's box. A handle with Shift moves on one
  axis and with Option a tenth, as a point does. Places are offsets
  from the frame's middle, as point controls are, and expressions gain
  `sin`, `cos`, `atan2`, `deg` and `sqrt` for turning ones. VoiceOver
  adjusts a handle across and down, for the axes its sets read.
- **Shapes' and text's handles** are a handle set of their own
  (`ShapeHandles`), chosen in `ViewerHandleSets.active` like the
  others, rather than through `EffectDefinition.viewerHandles`: the
  shapes are the only built-in effects with handles, so a field on
  every definition would hold nothing elsewhere. See
  [graphic-layers.md](graphic-layers.md#editing-in-the-viewer) for what
  each shape gets.
- Not run yet: the code was written without a Swift toolchain, so the
  tests (`TransformHandlesTests`, `PointControlHandlesTests`,
  `ShapeHandlesTests`,
  `DeclaredHandlesTests`, `ViewerPackageTests`,
  `FineDragTests`, `ViewerMappingTests`,
  `ViewerCanvasInteractionTests`, the new `StructureKeyTests` case and
  the `viewerHandles`, `viewerZoomed` and `externalDisplaySynced`
  snapshots) need a build on a Mac before this is taken as working.

## Building it

Steps 1 to 11 are built (see [As built](#as-built)).

1. `ViewerMapping` with zoom and place, `ViewerHandleSet` and its types,
   the bounding box (moving `fitTransform`), and `TransformHandles` for
   Position, Scale, Rotation and the anchor with the target rule and the
   keyframe rule, with `TransformHandlesTests` and `ViewerMappingTests`.
2. Transform effects out of `StructureKey`, with its tests.
3. `ViewerCanvas` in `ViewerPanel` with nothing to draw yet, and
   `ViewerFraming`: the picture placed by the mapping, pinch, scroll,
   the Center and Fit chips, and `ViewerCommands` with their keys; the
   snapshot and event tests.
4. Handles on the canvas, and `ViewerCanvasState`: drawing, hit testing
   and zones, cursors and hover text, the drag's life (slop, hold,
   modifiers, Escape, readout, undo), hiding while playing or skimming;
   Show Handles (off by default), its preference, menu item and key;
   snapshots and event tests.
5. The keys and the accessibility elements, checked with the
   `accessibility-reviewer` agent.
6. The opacity chip.
7. The external display: the canvas in place of the markup, and the
   markup's removal.
8. `StackFolding.placement(after:)` and `PointControlHandles`.
9. The loupe: a press held still opens it, and the drag is slowed in
   it (`FineDrag`, `HandleDrag.fine`).
10. `viewer` in effect packages, expressions reading parts of a vector,
    and declarations for the shipped packages that gain from them.
11. Shape and text handles through `EffectDefinition.viewerHandles`
    (step 4 of [graphic-layers.md](graphic-layers.md#building-it)).
12. Docs, once built: this document's status; the README's row;
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

Steps 1 to 5 are the feature as asked (step 3 alone gives the viewer
its zoom, with no handles); 6 and 7 complete it; 9, the loupe, was
asked for later; 8, 10 and 11 are the framework's later users. This can't be built or run on Linux; it
needs full Xcode on a Mac. CI runs only when started by hand.
