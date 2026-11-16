# The pen tool

Status: **planned, not implemented**. Nothing here is built. The
document says what the person sees, then the model and the drawing
underneath, then where each piece goes in the code and the order to
build it in. Choices the request didn't settle are listed under
[Decisions made here](#decisions-made-here); the ones worth a second
look before building are marked **(open)**.

A **pen** in the viewer draws **paths**: Bezier outlines of points and
curves, drawn as Adobe Illustrator's pen draws them. A path is either a
**shape** (a Path effect in a shape clip, filled and stroked like a
Rectangle) or a **mask** (a Path Mask effect, in Keying & Masks beside
the Box, Ellipse and Corner Masks). It is the pen that
[viewer-handles.md](viewer-handles.md#tools) left room for, and it
brings the free paths that [graphic-layers.md](graphic-layers.md) and
[effects-keying.md](effects-keying.md) were waiting on.

## What the person sees

### Picking the pen

- The viewer's rail gains a **tool picker** (`ViewerToolPicker`, built
  as `TimelineToolPicker` is): Arrow (`cursorarrow`) and Pen
  (`pencil.tip`).
  **P** picks the pen and P again puts the arrow back, while the viewer
  or the timeline has the keys (left alone while text is typed). The
  timeline's own tools keep A, B and Y.
- Beside the picker, while the pen is picked: **Shape | Mask**, which
  says what a new path becomes, and a color well for the
  [path color](#the-path-color).
- **The pen shows its handles whatever Show Handles says.** Picking it
  is asking for them. The arrow goes back to the preference.
- The pen draws only where handles could show: the viewer paused on the
  timeline's picture. While playing or skimming it takes no presses and
  the path isn't drawn over the picture; the pen stays picked.
- Each viewer's canvas has the same tool (`ViewerCanvasState.tool`), so
  a path can be drawn on the external display too.

### What a new path becomes

Decided when its first point is placed:

1. **The effect selected in the effects panel is a Path or a Path Mask
   with no path yet**: the draw is that effect's path. This is how a
   Path Mask added from the library gets drawn.
2. Otherwise, **Shape**: a new **Path** effect. In the selected clip, if
   it is a shape clip under the playhead (below the shapes it has, as a
   generator dropped on it goes); if not, on a new shape layer at the
   top holding a five second clip at the playhead, as New Shape Layer
   makes one.
3. Otherwise, **Mask**: a new **Path Mask** at the end of the selected
   clip's stack, above trailing Blending effects (where a drag adds a
   Transform). With no clip selected that can take one, the press is
   refused with a notice: "Select a clip to mask."

What the draw made is selected (the clip in the timeline, the effect in
the effects panel), so its handles show when the pen is put down. This
is the one place the viewer changes the selection: it selects what it
has just made, never what was clicked.

### Drawing

As Illustrator's pen, with one path being drawn at a time:

| Do | Get |
| --- | --- |
| Click | A **linear** point (a corner): the path runs straight into and out of it. |
| Press and drag | An **ease** point (smooth): the out tangent follows the pointer and the in tangent mirrors it, same length, opposite way. |
| Shift-click | The point on a multiple of 45° from the one before. |
| Shift while dragging | The tangents on a multiple of 45°. |
| Option while dragging | The pair **breaks**: the out tangent follows the pointer and the in tangent stays where it was when Option went down (a cusp). |
| Space while dragging | **Moves the point** being placed, tangents and all, until Space is let go; then the drag shapes the tangents again. |
| Click the first point | **Closes** the path. Dragging as it closes shapes the closing curve (the first point's in tangent; its out tangent mirrors unless Option is held). The draw is done. |
| Click the last point | Removes its out tangent, so the next stretch leaves it straight. Dragging from it pulls a new one. |
| Return (or Enter) | Ends the draw, **open**. A shape stays a line; a mask is closed with a straight stretch, since an open mask cuts nothing. |
| Escape | **Cancels the draw** ([below](#escape)). |

- A press becomes a drag at the canvas's 3 points of movement, as every
  drag there does.
- **The next stretch is previewed**: while a path is being drawn and the
  button is up, a thinner line runs from the last point to the pointer,
  curved by the last point's out tangent. It follows the pointer through
  a scroll or a pinch.
- Points land on **whole pixels** of the timeline; tangents to a tenth.
- Ending a shape's draw open turns its Stroke on if the shape would
  otherwise draw nothing (an open path has no fill).
- A draw ended with fewer than two points is removed, as Escape would.
- Closing or ending a draw leaves the pen picked, ready for another.

On a path that is selected (the one being drawn, or the Path or Path
Mask picked in the effects panel), the pen also edits, and the pointer
says which before the press:

| Over | Pointer | A click |
| --- | --- | --- |
| Nothing | Pen | Places a point (starting a new path if none is being drawn). |
| The first point of the path being drawn | Pen with a ring | Closes it. |
| The last point of the path being drawn | Pen with a caret | Removes its out tangent. |
| An end of an open path that isn't being drawn | Pen with a slash | **Carries on** drawing from that end. |
| Any other point | Pen with a minus | **Removes** it. The points either side keep their tangents. |
| A stretch between points | Pen with a plus | **Adds** a point there. The path keeps its shape (the curve is split, not bent). |

With **Command** held the pen is the arrow for as long as it is held:
points and tangents drag as they do with the arrow
([Editing a path](#editing-a-path)).

### Option: linear and ease

With **Option** held the pen converts points between **linear** and
**ease**, as Illustrator's Anchor Point tool converts between corner
and smooth:

- **Option-click a point**: switches it. An ease point becomes linear:
  its tangents go and the path runs straight through it. A linear point
  becomes ease, with tangents worked out for it: in line with each
  other, parallel to the line between its two neighbours, each a third
  of the way to its neighbour. An end point gets one, toward its
  neighbour.
- **Option-drag from a point**: pulls fresh mirrored tangents out of it
  by hand, whatever it was.
- **Option-drag a tangent's handle**: moves that tangent alone, breaking
  the pair.
- **Option-drag a stretch**: bends it to pass under the pointer, by
  changing the two tangents that shape it.

The pointer is a caret (Illustrator's convert pointer) while Option is
held over a point, a handle or a stretch. Whether a point is linear,
ease or broken isn't saved as such: it is read from its tangents (none;
in line; not in line), as Illustrator reads it.

### Space: the hand

**While the pen is picked, holding Space turns it into a hand.** The
pointer is an open hand; a drag moves the picture in the well (a closed
hand), by the same rules as a two-finger scroll (48 points of the frame
always stay in the well). Letting go of Space gives the pen back with
the draw exactly as it was. Nothing is placed, nothing plays.

- **Space never plays while a path is being drawn.**
- With the pen picked and nothing being drawn, a **tap** of Space (down
  and up within 300 ms, no press of the mouse between) still plays or
  pauses. Held longer, or with a drag, it is only the hand. **(open)**
- Space going down **during** a point's drag moves that point instead
  (the table above); the hand is for when the button is up.
- If the window stops being the key window while Space is down, the
  hand ends, since the key's release would never arrive.
- With the arrow picked, Space plays as it always has.

### Zoom and scroll

Pinch and two-finger scroll **work while the pen is picked and while a
path is being drawn**, as do ⌘+, ⌘−, ⌘0 and ⇧⌘0. The path is kept in
the timeline's pixels, so it stays on the picture; its points, handles
and lines keep their size on screen at any zoom. As for every drag on
the canvas, a pinch or a scroll **during** a press and drag is ignored;
between presses it is always live.

### The path color

**A bright line with a dark casing, not a difference blend.** The path
is a 1.5 point line in the **path color** over a 3.5 point line of
black at 50%; the preview of the next stretch is 1 point over 3. The
color starts as a hot magenta (`#FF2DC8`), a color footage almost never
holds and one that can't be mistaken for the accent blue of a clip's
box. It is changed from the color well beside the tool picker, which
opens the Color menu bars already have (the 64 presets and the Mac's
color picker, `BarColorMenu`), and is remembered per Mac
(`Preferences.penColor`).

Why not difference, which was the other idea:

- **It disappears on mid tones.** Difference turns a color into its
  opposite, and the opposite of middle gray is middle gray. Over fog,
  concrete, an overcast sky or a gray card the line would be all but
  gone, which is the one thing it mustn't do.
- **It has no color of its own.** Over busy footage the line changes
  color every few pixels along its length, so it stops reading as one
  line, and "this is the path" stops being a color the eye can look
  for.
- **The casing already does what difference promises.** A bright line
  with a dark edge has contrast against anything: the line carries it
  over dark footage, the casing over bright. It is what the handles'
  box does today.
- **It costs the viewer its fast path.** The picture is a video layer
  kept out of offscreen passes
  ([viewer-handles.md](viewer-handles.md#the-main-viewer)). Blending an
  overlay against it means compositing the video with the window every
  frame, HDR included.

Points are 7 point squares: hollow (dark fill, path color edge), and
filled with the path color when picked. Tangent handles are 6 point
dots at the end of a 1 point line. The first point wears a ring while a
click on it would close the path.

### No fill until the path is complete

- **A shape is filled only once its path is closed.** While it is being
  drawn, and for as long as it stays open, the compositor draws its
  stroke if it has one and never its fill. The fill appears the moment
  the path closes.
- **A mask masks nothing until its path is closed**: the whole picture
  shows while it is drawn, so what is being traced stays in view.
- The pen's own drawing over the picture is always lines, never a fill.

### Undo

**Each press of the pen is one undo step**: a point, with the tangents
its drag gave it; a point added to or removed from a stretch; a
conversion. So **⌘Z goes back one point**, never the whole shape, and
⇧⌘Z puts it back. The steps are named for the Edit menu ("Undo Add
Point", "Undo Close Path", "Undo Convert Point").

- The first point's step is also the one that made the effect (and the
  clip and layer, for a new shape layer), so undoing it leaves nothing
  behind.
- After an undo the draw carries on from what is left: the pen draws
  whatever open path it last worked on.
- **Undo after closing reopens the path**, and the next undo takes its
  last point, as in Illustrator. Finishing a shape doesn't fold its
  points into one step.

### Escape

- During a point's drag: cancels **that point** (the canvas's rule for
  every drag).
- While a path is being drawn: **cancels the draw**. What the draw
  added goes: the effect it made (with its clip and layer), or the
  points it added to a path that was already there. This is one step of
  its own ("Cancel Path"), so ⌘Z brings the whole draw back to carry
  on, in case Escape was a slip.
- With nothing being drawn: puts the arrow back.

This departs from Illustrator, where Escape ends the path and keeps it;
here Return does that.

### Editing a path

With the **arrow**, and a Path or Path Mask selected in the effects
panel, the clip shows that path's handles (`PathHandles`) in place of
the Transform handles, as a shape or a mask shows its own today:

- the outline, in the path color;
- every point, and the tangent handles of the picked point and the
  point either side of it (the ones that shape the stretches it
  touches). A click on a point picks it;
- a drag moves a point, in whole pixels: Shift keeps it to one axis and
  Option takes a tenth, as for every point on the canvas. A tangent's
  drag on an ease point keeps the opposite tangent in line with it (at
  its own length); on a broken point it moves alone;
- a press held still opens the loupe, as for any handle.

The arrow moves; the pen adds, removes and converts. Each edit is one
undo step.

**Keyframes.** A path is one value, keyframed whole. Moving a point or a
tangent sets a keyframe at the playhead where the path is animated, and
only there, as every handle does. **Adding or removing a point acts on
every keyframe**, at the same place along the same stretch, so a
keyframed path keeps one count of points and blends everywhere.
Closing is not keyframed.

A path a Keyframing effect drives, or on a clip the Motion Designer has
locked, refuses the pen's presses with the notices those give today.

### In the effects panel and the library

- **Path Mask** is in the Effects Library's Keying & Masks, after Corner
  Mask (`BuiltInEffects.libraryOrder`). Its controls: **Path**,
  **Feather** (pixels, centered on the edge, as the other masks'),
  **Expand** (pixels; negative shrinks), **Keep** (Inside or Outside)
  and **Amount**.
- **Adding a Path Mask picks the pen**, set to Mask, with the new effect
  selected, so the next click in the viewer starts its path. A chip in
  the well says so until the first point: "Click in the viewer to draw
  the mask".
- **Path** is in the browser's Generators tab and the New Shape Layer
  menu with the other shapes. Made from there it has no path yet, and
  picks the pen the same way. Its controls: Path, Position, Fill,
  Stroke, Stroke Width, Edge, Join, Cap and Dash.
- The **Path control's row** in the panel says what it holds ("No path",
  "12 points, closed", "5 points, open") and has a **Draw with Pen** or
  **Edit with Pen** button, which picks the pen with that effect as the
  one it works on. It has a keyframe button like any control; its
  values aren't typed.
- A Path Mask with no closed path draws nothing, and its row says
  "Draw its path with the pen to cut the picture."

A mask's path is in the frame's pixels at its place in the stack, as
the other masks' points are: a Transform below it in the list moves the
mask with the picture, one above it doesn't.

## The model

### A path

`FreePath` (`Model/Effects/FreePath.swift`): a list of vertices, each a
point with an in and an out tangent, and whether it is closed.

- A point is in pixels from the frame's center, down positive, as a
  point control is. Tangents are **offsets from their point**, so a
  moved point takes its tangents along and two keyframes blend
  sensibly.
- It is held by a control of a new kind, **path** (`ControlKind.path`),
  in the control's numbers as a tone curve's points are
  (`[x, y, inX, inY, outX, outY]` for each vertex in turn), so it
  keyframes, eases, copies, pastes and goes into presets as every
  control does. `closed` is a flag on the control, beside `linked` and
  `squircle`.
- Between two keyframes with the same number of vertices every number
  blends. With different numbers the earlier holds until the next
  (`ComponentValue.interpolate` would cut the longer short, so the path
  control reads its value through a rule of its own). The pen never
  makes such keyframes; a hand-edited file or a script can.
- `FreePath` does the geometry, with no views: the `CGPath`; splitting a
  stretch at a point (de Casteljau, keeping the shape); removing a
  vertex; the nearest point on the path to a place; a vertex's kind
  read from its tangents; the tangents an Option-click gives; bending a
  stretch through a point.
- Self-crossing paths fill by the nonzero rule, as Illustrator's do.

### The two effects

- **Path** (`EffectKind.path`, category shapes, `drawsShape`):
  `ShapeStep.Outline` gains `.path(FreePath)`. Everything a shape
  already has follows: Fill and Stroke, the Stroke effect, text on its
  path, staying sharp through the moves after it, the Transform
  handles' box, the render key. `ShapeStep.paints` leaves the fill out
  while the path is open.
- **Path Mask** (`EffectKind.pathMask`, category keying). It is Swift,
  not a package: a package's kernel takes numbers, and a path is a
  drawing. `ResolvedStep` gains `.pathMask`: the compositor fills the
  path white with Core Graphics at the size it ends up
  (`ShapeRendering.draw`), grown or shrunk by Expand with Core
  Graphics' path operations (the stroke's outline joined to it or taken
  from it), softened across Feather with a Gaussian blur whose ramp is
  centered on the edge, and cuts the picture with it through the
  Matte's own `cut(_:by:mode:amount:frame:)`. Like a Matte it needs pixels,
  so shapes above it in the stack are drawn first. An open or empty
  path makes no step.

### Saving

Additions, so the format version stays, as for the other shapes
([graphic-layers.md](graphic-layers.md#saving)): effects of kind
`"path"` and `"pathMask"`, whose Path control is written as
`"vertices": [[x, y, inX, inY, outX, outY], …]` and `"closed": true`
(left out while open), each keyframe with its own `vertices`. Loading
stays strict: six finite numbers a vertex. An older version of the app
reports a file with them as invalid, naming the kind.

### One step per press

A path being drawn **is in the project from its first point**; there is
no draft kept to one side. Each press runs as every canvas drag does
(`ProjectState.beginHold`, `hold`, `endHold`,
`ProjectHistory.endGesture`), which already records it as a step of its
own that nothing merges into. That is the whole of "undo goes back one
point": the Edit menu, ⌘Z, redo and autosave need nothing new, and a
project closed mid-draw opens with the open path, which the pen carries
on from its end.

What the pen keeps is small (`ViewerCanvasState.pen`): Shape or Mask,
the effect it is working on, and for Escape what the draw added (the
effect it made, or the number of points the path had when it was picked
up). "Being drawn" is read from the project each time: the effect is
still there and its path is open. So an undo that takes the effect away
ends the draw without the pen being told.

`ProjectChange` names the steps (Add Point, Remove Point, Convert
Point, Move Point, Close Path, Draw Path for the first point, Cancel
Path).

## Where it goes in the code

- **`ViewerTool.pen`** (`Model/ViewerHandles/ViewerTool.swift`), with a
  name, glyph and key as `TimelineTool` has. `ViewerHandleSets.active`
  returns `PathHandles` for a selected Path or Path Mask, and for the
  pen's path.
- **`PathHandles`** (`Model/ViewerHandles/PathHandles.swift`): a
  `ViewerHandleSet` for vertices and tangents, in the effect's
  coordinates through `StackFolding.placement(after:)` as
  `PointControlHandles` is. `HandleGlyph` gains `vertex` and `tangent`;
  `ViewerOutline`, which is straight lines today, gains curves and a
  style in the path color.
- **`PenTool`** (`Model/ViewerHandles/PenTool.swift`): the pen as plain
  logic, tested without a window. Given the path, what is under the
  pointer, the modifiers and a press, drag or release, it returns the
  edit (a `HandleEdit`) and the pointer to show. The canvas gives a
  press that hits no handle to the tool, as the framework planned, and
  with the pen picked asks the tool first.
- **`ViewerHandlesOverlay`** runs the pen's presses through its existing
  drag bookkeeping (`HandleDragBook`: the slop, modifiers as they
  change, `DragEscape`, the hold), draws the preview stretch, and shows
  with the pen picked whether or not Show Handles is on. The pen's
  pointers are drawn by `HandleCursors` from `pencil.tip` with a small
  badge (ring, caret, slash, plus, minus).
- **`KeyHoldMonitor`** (`UI/Components/`, new): key down and key up for
  one key in the view's window, repeats dropped, standing aside while
  text is typed as `KeyPressMonitor` does. `ViewerCanvas` uses it for
  Space while the pen is picked. It takes the key down before the play
  button's shortcut sees it (`ViewerPanel`'s
  `.keyboardShortcut(.space)`), and plays itself on a tap.
  `ViewerCanvas` already owns the pinch and the scroll; the hand's drag
  goes through the same `framing.apply(mapping.scrolled(by:))`.
- **`ViewerToolPicker`** (`UI/Viewer/`) in `ViewerPanel`'s rail and the
  external display's top bar, with the Shape | Mask choice and the
  color well. **P** is taken where **H** is (`toggleKey`).
- **Effects**: the kinds, controls and library order in
  `BuiltInEffects`; `EffectRegistry`; the Path row in
  `UI/Effects/EffectsPanelControls.swift` (a view of its own,
  `PathControlRow`); `GeneratorsList` and `NewShapePopover` list Path by
  themselves, since they list every kind that draws a shape.
- **Compositor**: `ShapeGeometry` (the outline), `StackFolding` (the
  step) and `LayeredCompositor` (drawing the mask).
- **`Preferences.penColor`**, in `App/Preferences.swift`.

## Accessibility

Following [accessibility.md](accessibility.md#rules-for-new-ui):

- The tool picker's buttons have labels ("Arrow", "Pen") and a selected
  value; Shape | Mask is a labelled picker; the color well says "Path
  Color" and its color's name.
- **Each point is an adjustable element** in the canvas's container
  ("Point 3 of 12, ease"), across and down as a point control's are,
  from `PathHandles.keyTargets`, so **Tab** picks points and the
  **arrows** nudge the picked one (a pixel; ten with Shift; a tenth with
  Option).
- Everything the pen does by pointer has a named action on a point, and
  a key while the canvas has the keys and the pen is picked:

  | Action | Key | Does |
  | --- | --- | --- |
  | Add Point After | ⌘Return | A point halfway along the stretch after the picked one, or past the end of an open path, picked so the arrows can place it. With no path yet, the first point, at the middle of the frame. |
  | Remove Point | ⌫ | Removes the picked point. While a path is being drawn this is the last point. (With the arrow, Delete still deletes the clip.) |
  | Make Linear / Make Ease | ⌥Return | The Option-click. |
  | Close Path / Open Path | on the path's element | |
  | End Path | Return | |

- The pen's lines, points and the preview are `.decorative()`; the
  hand, the pinch and the scroll already have ⌘+, ⌘−, ⌘0, ⇧⌘0 and the
  canvas's scroll actions.
- The row's Draw with Pen button is labelled, and the chip in the well
  is read once when it appears.
- Nothing animates: points and the fill appear at once.

## Tests

- `FreePathTests` (`Model/Effects/`): numbers to path and back; the
  `CGPath` of corners and curves; a split keeping the shape at every
  sample; removing a point; the kind read from tangents; Option-click's
  tangents; bending a stretch through a point; blending with equal
  counts and holding with unequal ones.
- `PenToolTests` (`Model/ViewerHandles/`): a click and a drag; Shift on
  a point and on a tangent; Option breaking the pair mid-drag; Space
  moving the point mid-drag; closing, with and without a drag; the last
  point's tangent removed; Return on a shape and on a mask; fewer than
  two points; adding and removing points on a keyframed path (every
  keyframe, same count); carrying on from either end; each conversion;
  what a new path becomes in each of the three cases; what Escape takes
  away in each.
- `PathHandlesTests`: points and tangents through a Transform below the
  effect; an ease point's tangents kept in line; the keyframe rule; a
  driven path refusing.
- `ShapeTests` and `KeyingTests` (`Rendering/`): an open path stroked
  and not filled, a closed one filled; sharp at 800%; a mask opaque
  inside, clear outside and half at the edge of its feather; Expand each
  way; Keep Outside; Amount 0 and an open path doing nothing; through
  the compositor over a layer below; saving both, and strict loading
  refusing a short vertex.
- `PenInteractionTests` with `EventHarness` (`UI_EVENTS=1`,
  `.eventsOneAtATime`): clicks placing points with the pen picked and
  Show Handles off; one undo step a point, and undo after closing
  reopening; Escape mid-drag, mid-draw and with nothing drawn; Space
  held and dragged scrolling the picture, placing nothing and not
  playing; a tap of Space playing only when nothing is drawn; a scroll
  and a pinch between two points leaving both on the picture; P; no
  presses taken while playing.
- `UISnapshots`: `penDrawing` (a path half drawn with its preview, over
  dark, bright, middle-gray and busy pictures, which is the check on the
  path color), `pathHandles` (a picked point's tangents) and
  `pathMaskPanel` (the rows, with and without a path).

## Decisions made here

- **The path color is solid with a casing, not difference.** Reasons
  under [The path color](#the-path-color). Magenta is the default; it
  is a preference, not a color per path.
- **Escape cancels the whole draw** and Return ends it, where
  Illustrator's Escape ends it. The cancel is itself undoable.
- **A tap of Space still plays when nothing is being drawn. (open)**
  The alternative is that Space never plays while the pen is picked,
  which is simpler to explain and means reaching for the play button or
  putting the pen down to watch what was drawn.
- **The path is in the project from its first point**, not a draft.
  That is what makes each point an undo step and lets undo after
  closing reopen the path. The cost is that an unfinished path is
  autosaved like any other edit.
- **An open path is never filled**, finished or not: "no fill until
  complete" as a rule of the shape, not of the tool, so the compositor
  needs to know nothing about the pen.
- **Option-click on a linear point gives it tangents**, where
  Illustrator needs a drag. It makes Option-click a switch between
  linear and ease, as asked; Option-drag still sets them by hand.
  **(open)**
- **Option means convert only with the pen.** With the arrow it stays
  "a tenth", as on every other handle.
- **Space during a point's drag moves the point**, as in Illustrator,
  and is the hand only when the button is up.
- **A point's kind is read from its tangents**, not saved.
- **Adding or removing a point changes every keyframe.**
- **The pen ignores Show Handles**, and Escape with nothing drawn puts
  the arrow back.
- **A new path selects what it made.**
- **Path Mask is Swift, not a package.**
- **P** for the pen, as in Illustrator; no key of its own for the
  viewer's arrow, since A is the timeline's.

## Not in this plan

- **Several outlines in one path** (compound paths, holes), and **mask
  modes**. Two Path Masks on a clip each cut what the one above left,
  so two set to Keep Inside leave only where they overlap. Add,
  Subtract and Intersect belong with path operations
  ([graphic-layers.md](graphic-layers.md#strokes)).
- **A `path` control in effect packages**, handed to a kernel as a
  drawn picture.
- **Selecting several points**, a marquee, and moving a whole path by
  dragging inside it (a shape has Position; a mask moves with a
  Transform below it).
- **A color per path** and Illustrator's rubber band preference.
- **Per-point feather** and **tracking** a mask to footage.
- **Turning text or the other masks into paths.** Turning a Rectangle,
  Ellipse, Polygon or Star into a Path is the last build step, and can
  be left out.
- **A hand tool** outside the pen: Space with the arrow still plays.
- **Rectangle, ellipse and text tools** in the viewer.

## Building it

Each step leaves the app working.

1. **Free paths in the model**: `FreePath`, the path control and its
   keyframe rule, the Path effect drawn by the compositor (open:
   stroke only), saving, the panel's row without its button;
   `FreePathTests` and the `ShapeTests` cases. Step 2d of
   [graphic-layers.md](graphic-layers.md#building-it).
2. **Path Mask**: the effect, its step in the compositor, the library;
   the `KeyingTests` cases.
3. **`PathHandles`** with the arrow: points, tangents, the outline in
   the path color (the default; no well yet), keys and VoiceOver;
   `PathHandlesTests`, the `pathHandles` snapshot.
4. **The pen**: `ViewerTool.pen`, the picker and P, `PenTool` for
   placing linear and ease points, the preview, closing, Return,
   Escape, what a new path becomes, the pointers, showing without Show
   Handles; `PenToolTests`, `PenInteractionTests`, `penDrawing`.
5. **Space**: `KeyHoldMonitor`, the hand, moving a point mid-drag, and
   the checks that pinch and scroll hold a draw in place.
6. **Editing with the pen**: add and remove on a stretch and a point,
   carrying on from an end, Command for the arrow, and Option's
   conversions.
7. **The panel and the library**: Draw with Pen, adding a Path Mask or
   a Path picking the pen, the chip, Shape | Mask, the color well and
   `Preferences.penColor`; `pathMaskPanel`. Checked with the
   `accessibility-reviewer` agent.
8. **Convert to Path** in a primitive's ⋯ menu, keeping its shape.
9. **Docs, once built**: this document's status; the README's row;
   [viewer-handles.md](viewer-handles.md) (Tools, An effect's own
   handles, Not in this plan); [graphic-layers.md](graphic-layers.md)
   (Shapes, Editing in the viewer, Saving, Building it);
   [effects-keying.md](effects-keying.md) (the table, Masks, Not yet);
   [effect-packages.md](effect-packages.md) (What stays in Swift);
   [accessibility.md](accessibility.md) (the keys and the VoiceOver
   list); `KeyboardShortcutsView`.

Steps 1 to 5 are the feature as asked for shapes and masks; 6 is
Illustrator's editing with the same tool, Option included; 7 is "the
pen as an option for a mask in effects". None of it can be built or run
on Linux: it needs full Xcode on a Mac, and CI runs only when started
by hand.
