# Viewer handles

Status: **planned, not implemented**. Nothing here is built. This
document is written for whoever builds it: it says what the person sees,
then the framework the handles are built on, then where each piece goes
in the code as it stands today, then the order to build it in. Choices
made while writing it that the request didn't settle are listed under
[Decisions made here](#decisions-made-here).

Selecting a clip with pictures in the timeline puts **handles** over it
in the viewer: drag them to move, scale, turn and fade the clip. The
handles edit the same Transform controls the effects panel shows
([effects.md](effects.md#transform)), adding a Transform effect when the
clip has none. They are the first user of a framework, the **viewer
canvas**, that later tools (a pen for masks and shapes, an effect's own
controls) draw and edit through. The synced external display gets the
same canvas, in place of its freehand markup.

[effects.md](effects.md#not-in-this-plan) left dragging in the viewer out
as "easy to trigger by mistake; left out until there's a design that
avoids that". What this design does about it is under
[Not by mistake](#not-by-mistake).

## What the person sees

### When handles show

Handles show for the clip selected in the timeline (`TimelineSelection`)
when all of these hold:

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
- **Show Handles** is on (below).

Scrubbing or stepping the playhead keeps them: they follow the clip's
keyframes as its values change.

A clip the Motion Designer has locked (`ProjectState.lockedClipIDs`)
shows its box without handles, and a press on it gives the locked-clip
notice, as any other edit of it does.

### The handles

Everything is drawn in view points at a fixed size, whatever size the
picture is drawn at.

- **The box**: the outline of the clip's picture as its Transform
  effects place it (a rectangle, turned, or a parallelogram when a
  stretch is followed by a turn). A one point line in `Design.accent`
  over a three point line of black at 35%, so it reads on any footage.
- **Corners and edge middles**: eight squares, 8 points, white with an
  accent edge, turned with the box. They **scale**.
- **The anchor**: a 10 point crosshair where the clip's anchor point is,
  the point scale and rotation turn about. Shown, not dragged (see
  [Not in this plan](#not-in-this-plan)).
- **The rotation handle**: a round handle on a 72 point stalk from the
  anchor, pointing along the clip's own "up", so it also shows the
  clip's angle. It **rotates**. Being by the anchor rather than outside
  the box, it is in reach when the clip fills the frame, which most
  clips do, and on the external display, which has no margin.
- **Inside the box**: a drag **moves** the clip.
- **The opacity chip**: a small chip under the middle of the box's bottom
  edge, kept inside the view, with the `circle.lefthalf.filled` glyph and
  the clip's opacity ("100%"). Drag it left or right to **fade**.

Handles are found before the inside of the box, nearest first, within 6
points. The pointer shows what a press would do: a resize cursor along
the handle's direction over a scale handle (`NSCursor.frameResize`), a
rotate cursor (drawn from `arrow.trianglehead.2.clockwise.rotate.90`)
over the rotation handle, `.resizeLeftRight` over the chip, the arrow
inside the box.

### Dragging

A drag begins once the pointer has moved 3 points; a press without a
drag changes nothing. While it lasts the viewer follows it live, the
other handles are hidden, and a **readout** chip by the pointer (the
style of the timeline's drag timecode label) says the value it has
reached. Releasing saves it as one undo step. **Escape** puts everything
back, a Transform effect the drag added included. Modifiers are read as
they change, so pressing or releasing Shift mid-drag takes effect at
once, with the pointer still.

| Drag | Does | With Shift | Readout |
| --- | --- | --- | --- |
| Inside the box | Position follows the pointer, in whole pixels | Kept to one axis: the one the drag from its start is nearer (the 45° line decides), free to change as the pointer crosses it | `120, −40` |
| A corner | Scale, **proportional**: both numbers grow by the same factor, keeping whatever ratio they had | **Free**: x and y apart, the corner under the pointer | `150%`, or `150% × 120%` when apart |
| An edge's middle | Scale, proportional, as a corner | That axis only | the same |
| The rotation handle | Rotation follows the pointer round the anchor; turns past 360° are kept | **Snapped to multiples of 15°** | `37.5°`, always shown, to a tenth of a degree |
| The opacity chip | Opacity, one point of drag for 1%, 0 to 100 | Ten per point (and **Option** a tenth), as a value drag in the effects panel | `80%` |

- Scale and rotation turn about the anchor point, as the controls do. A
  scale handle dragged across the anchor flips the clip (negative
  scale), as the control allows.
- Scale is kept to a tenth of a percent, rotation to a tenth of a
  degree, opacity to whole percents (tenths with Option).
- A Shift drag that leaves Scale's x and y apart turns the control's
  link off (`EffectControl.linked`), so the effects panel shows the two
  numbers as separate; a proportional drag leaves the link as it is.
- On a control with keyframes the drag sets the keyframe at the
  playhead, making one when there is none, as typing in the panel does
  (`EffectControl.setComponent(_:to:at:)`), in the clip's source time.
- A control a Keyframing effect drives refuses hand edits
  ([keyframing-effects.md](keyframing-effects.md)). Its handle is drawn
  dimmed, and a press on it gives the same notice the panel's field does
  (`ProjectState.Refusal.drivenKeyframes`).
- Starting playback mid-drag (Space) ends the drag as letting go would,
  and the handles go.

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
  first step of a drag (or a key) that changes a value.

The box always shows where **all** the Transform effects together put
the picture (`StackFolding.fold`). The drag is worked out so the handle
stays under the pointer whatever else is in the stack (see
[The arithmetic](#the-arithmetic)).

### Not by mistake

- **The viewer never selects.** Handles belong to the clip chosen in the
  timeline; a click in the viewer on another clip's picture, or on
  nothing, does nothing. So nothing in the viewer can be dragged until a
  clip was picked on purpose.
- **A drag needs 3 points of movement** before anything changes.
- **Escape** cancels a drag, and a finished one is a single undo step.
- **Show Handles** turns the whole thing off: a toggle in the viewer's
  rail (`viewfinder` glyph, beside the preview options), in the View
  menu, and on the **H** key while the viewer or timeline has the keys.
  Remembered per Mac (`Preferences.viewerHandles`, on by default).
- **Nothing is added to the stack** until a value really changes.

### Keys

A click in the canvas gives it the keyboard (it is focusable, and wears
the active panel's border as the viewer does). While it has it, it
claims these keys (`claimsKeys`), so the arrows don't step the playhead
and Delete doesn't delete the clip:

| Keys | Does |
| --- | --- |
| Tab / ⇧Tab | Pick the next or previous handle: Position, Scale, Rotation, Opacity. The picked one is ringed. |
| ← → ↑ ↓ | Nudge the picked handle: Position one pixel that way; Scale 1% (→ and ↑ up); Rotation 1° (→ and ↓ clockwise); Opacity 1% |
| with Shift | Ten pixels, 10%, 15°, 10% |
| Escape | During a drag, cancel it; otherwise give the keys back to the timeline |

Position is picked to begin with, so a click in the viewer and an arrow
key nudges the clip. Each nudge is an edit of its own, as a nudge on the
tone graph is. Space still plays, and the handles go.

## The framework

Three pieces, so that the next thing drawn over the viewer is a new
handle set or a new tool and nothing else.

### The canvas

`ViewerCanvas` (`UI/Viewer/ViewerCanvas.swift`) is the one view laid
over the picture, in the main viewer and on the external display. It
knows nothing about transforms. It:

- maps between the timeline frame's pixels and its own points
  (`ViewerMapping`: the frame size and the rectangle the picture is
  drawn in). It covers the whole well, not just the picture, so handles
  on or past the frame's edge can be reached;
- asks the active **handle set** what to draw at the playhead and draws
  it: handles, outlines, guides;
- finds the handle under the pointer and sets the cursor;
- runs every drag the same way: the 3 point slop, the modifiers as they
  change, the hold to one side of the project
  (`ProjectState.beginHold`, `hold`, `endHold`), Escape (`DragEscape`),
  the readout, and the single undo step (`ProjectHistory.endGesture`);
- runs the keys and VoiceOver the same way, from what the handle set
  says a nudge does;
- hides itself and takes no presses while the viewer plays or shows
  something other than the timeline.

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
    /// Frame pixels per view point, for sizes and slop given in points.
    var pixelsPerPoint: Double
}

struct ViewerHandle: Identifiable {
    var id: HandleID                 // stable through a drag and between frames
    var place: CGPoint               // frame pixels, origin top left
    var glyph: Glyph                 // square, round, crosshair, chip(text), vertex, tangent
    var direction: Double?           // for the cursor and the glyph's turn
    var isEnabled = true             // false: drawn dimmed, refuses with `refusal`
    var name: String                 // "Scale", "Top Left Corner", "Center"
    var value: String                // "150%", read by VoiceOver and the readout
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
    func nudge(_ handle: HandleID, _ direction: Direction, big: Bool, _ context: HandleContext) -> HandleEdit?
}

struct HandleEdit {
    var change: (inout TimelineClip) -> Void
    var readout: String
    /// The undo step's name: "Move", "Scale", "Rotate", "Change Opacity".
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
    // hand (drags the view), each with its own key.
}
```

With one tool there is no picker. The second tool brings one into the
viewer's rail, built as `TimelineToolPicker` is.

### State

`ViewerCanvasState` (`@Observable`, `UI/Viewer/`) holds what the two
displays share: the tool, the picked handle, and the drag in progress
(which handle, its readout), so a drag made on one display is drawn on
both. `EditorView` owns it beside `playback` and hands it to the
surface's viewer and to the external display; an independent external
editor makes its own, as it makes its own `PlaybackModel`.

## Transform handles

`TransformHandles` (`Model/ViewerHandles/TransformHandles.swift`).

### The box

- The **picture rectangle** is the clip's picture before its stack, in
  the frame's pixels:
  - footage and stills: the oriented size fitted into the frame and
    centered (`CompositionFlattening.fitTransform`, moved out of
    `Export/` to where both can use it);
  - a nested timeline: its frame fitted the same way;
  - shapes and text: the bounds of what its shapes draw at the source
    time, each with its own Position, Size and Rotation
    (`ShapeStep.path`), or the frame when it draws nothing.
- `StackFolding.fold(effects:anchorPoint:at:center:)` gives the
  placement: a matrix, the anchor and the opacity. The box is the
  rectangle's corners through the matrix; the handles are its corners
  and edge middles; the crosshair is the anchor; the chip reads the
  opacity of the target's control, not the folded one.
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
fold itself**. `fold(with:)` below is `StackFolding.fold` of the stack
with the target's control set to a trial value.

- **Position.** Where a point of the picture lands is affine in
  Position's two numbers. Fold at the start value, at +1 in x and at +1
  in y; the three give a 2×2 matrix `J` from a change in Position to a
  change on screen. The new Position is `start + J⁻¹ · (now − press)`
  (after the Shift lock, which is applied to the pointer's movement on
  screen), rounded to whole pixels. `J` is the identity for a lone
  Transform, so this is the plain case too.
- **Scale.** Where the dragged corner lands is affine in Scale's two
  numbers as well. With the same three folds: free (Shift), solve the
  2×2 for the pointer; proportional, the one factor `k` on both numbers
  that brings the corner nearest the pointer (a projection onto the
  line the corner moves along). An edge handle with Shift solves its
  one number. A handle that Scale can't move (it sits on the anchor's
  axis) is drawn dimmed.
- **Rotation.** The angle the pointer has swept round the anchor on
  screen since the press, added up from step to step so it runs past
  360°, times the direction the picture turns on screen for a positive
  Rotation (measured from two folds, so a flipped clip still follows the
  pointer). Shift snaps the resulting **value**, not the change, to a
  multiple of 15°.
- **Opacity.** `start + points dragged × step`, through
  `ValueDrag.value(from:distance:step:flags:range:)`, the panel's own
  rule.

Each returns the control's new numbers, written with
`setComponent(_:to:at:)` at the source time. Scale's link is switched
off first when the numbers are to differ, since `setComponent` moves
both while it is on.

### Following the drag without a rebuild

A held drag is drawn by patching the frame's clips with the drag's
values (`LiveValues`, `DrawClip.withValues`), which works while the
project's `StructureKey` is unchanged. **Adding an effect changes the
key today**, so the first drag on a clip with no Transform would let the
hold go (`ProjectState.letGo`) and wait for the player's item to be
built again before the picture moved.

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

- **Point controls** (stage 6). A package's `point` control is "a
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
- **Declared handles** (stage 7). A `viewer` key in effect.json, the
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
their hit testing. It is a view of its own that reads the playhead
through `PlayheadReader`, so `ViewerPanel.body` still reads nothing that
changes as the playhead moves (`ViewerPanelTrackingTests`).
`TimelineEditorSurface` passes it the project, the timeline, the
selection, `effectsState` and the playhead. `ViewerPicture`'s
accessibility element stays; the canvas's elements sit beside it.

The rail gains the Show Handles toggle.

### The external display

Synced, `ExternalViewerContent` shows `ViewerCanvas` over the picture in
place of `AnnotationOverlay`, with the primary's timeline and selection
(it already has both bindings) and the shared `ViewerCanvasState` and
`PlaybackModel`. Edits land in the one project through the
`ProjectState` the window already has in its environment; the window is
also given the history (`\.projectHistory`) for the undo step, and ⌘Z
already reaches the editor's undo manager (`editorUndoManager`).

The picture there fills the screen with no margin, so a full-frame
clip's corner handles sit on the screen's corners, half showing; the
rotation handle, the chip and the inside of the box are in reach, which
is why they are where they are.

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
  Position Y, Scale, Rotation, Opacity, with the number as its value
  ("120 pixels", "150 percent"). Increment and decrement are the arrow
  keys' nudges (`ViewerHandleSet.nudge`), so VoiceOver gets every later
  handle set for free.
- Named actions for the ten-fold steps (Move 10 pixels left…), and
  Reset on each.
- The readout isn't announced during a drag; the element's value is
  read after.
- The Show Handles toggle is a toggle with a label and an on or off
  value. Handle glyphs and the box are `.decorative()`.
- Everything a drag does has the keys above.
- No animation: handles appear and go at once.

## Tests

- `TransformHandlesTests` (`Tests/.../Model/ViewerHandles/`): the box
  for footage, a still of another shape, a nested timeline and shapes;
  for each drag, that folding the edited clip puts the handle at the
  pointer, with a lone Transform, with a second Transform after the
  target, with an effect that doesn't move the anchor, and with a flip;
  proportional against free; the 45° lock and its change of axis; 15°
  snapping of the value; turns past 360°; keyframed controls getting a
  keyframe at the source time; the target rule (selected, last, added,
  above a trailing Blending, a missing control put back); nudges.
- `ViewerMappingTests`: frame to view and back, letterboxed both ways.
- `ViewerCanvasInteractionTests` with `EventHarness` (`UI_EVENTS=1`):
  the 3 point slop, a drag as one undo step, Escape putting back a
  Transform the drag added, Shift pressed with the pointer still, no
  response while playing, Tab and the arrows, the keys going back to the
  playhead after Escape.
- `HeldDragFollowTests` and `StructureKeyTests`: a Transform added
  mid-drag keeps the key, and the held frame is drawn with it.
- `ViewerPanelTrackingTests`: the panel's body still isn't invalidated
  by the playhead or by a drag.
- `UISnapshots`: `viewerHandles` (a turned clip, a stretched one, a
  dimmed driven handle, the readout) and the external display's synced
  view.
- Stage 6 on: `PointControlHandlesTests` over the shipped packages, and
  the loading checks for `viewer` beside those for `graph`.

## Decisions made here

- **Rotation handle on a stalk from the anchor**, as Final Cut Pro,
  Motion and Resolve do, not zones outside the corners: it is always in
  reach, it shows the pivot, and it is something VoiceOver and Tab can
  land on.
- **Opacity is a chip dragged sideways**, the panel's value drag moved
  onto the picture, not a handle on the box: opacity has no place in
  space to grab. It is a build step of its own so it can be left out.
- **Edge handles follow the same Shift rule as corners** (proportional
  without, one axis with), as Photoshop now does, so "proportional
  unless Shift" has no exceptions.
- **Shift on rotation snaps the value**, so a clip at 7° goes to 0° or
  15°, not 22°.
- **The last Transform effect is the target**, and a new one goes at the
  end above trailing Blending effects.
- **The viewer doesn't select clips**, and Show Handles defaults to on.
- **Scale turns about the anchor**, as the control does; scaling from
  the opposite corner would mean a handle that changes Position too.
- **Handles hide during any skim**, not only playback.
- **Arrow keys nudge only while the canvas has the keyboard**, so the
  playhead keys stay what they are everywhere else.

## Not in this plan

- **Dragging the anchor point** (moving it while the picture stays, by
  changing Position to match).
- **Selecting a clip by clicking it in the viewer.**
- **Several clips at once.**
- **Snapping** to the frame's middle and edges, and guides.
- **Motion paths**: a keyframed Position drawn as a path with its
  keyframes as handles.
- **Zooming and panning the viewer.** Until then a clip scaled past the
  view has corners out of reach; the rotation handle, the chip, the
  inside of the box, the keys and the panel still work. A zoom menu
  (Fit, 100%, 50%, 25%) and a hand tool fit the framework as a mapping
  that is no longer fitted.
- **Crop and corner pin** handles.
- The pen, shape and text tools themselves, and free paths; this plan
  only makes room for them.

## Building it

1. `ViewerMapping`, `ViewerHandleSet` and its types, the picture
   rectangle (moving `fitTransform`), and `TransformHandles` for
   Position, Scale and Rotation with the target rule, with
   `TransformHandlesTests` and `ViewerMappingTests`.
2. Transform effects out of `StructureKey`, with its tests.
3. `ViewerCanvas` and `ViewerCanvasState`: drawing, hit testing,
   cursors, the drag's life (slop, hold, modifiers, Escape, readout,
   undo), hiding while playing or skimming; in `ViewerPanel`, with Show
   Handles, its preference, menu item and key; snapshots and event
   tests.
4. The keys and the accessibility elements, checked with the
   `accessibility-reviewer` agent.
5. The opacity chip.
6. The external display: the canvas in place of the markup, and the
   markup's removal.
7. `StackFolding.placement(after:)` and `PointControlHandles`.
8. `viewer` in effect packages, expressions reading parts of a vector,
   and declarations for the shipped packages that gain from them.
9. Shape and text handles through `EffectDefinition.viewerHandles`
   (step 4 of [graphic-layers.md](graphic-layers.md#building-it)).
10. Docs, once built: this document's status; the README's row;
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
    holds.

Steps 1 to 4 are the feature as asked; 5 and 6 complete it; 7 to 9 are
the framework's later users. This can't be built or run on Linux; it
needs full Xcode on a Mac. CI runs only when started by hand.
