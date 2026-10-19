# Layer transforms and keyframes

Status: **replaced** by [effects.md](effects.md). Layers no longer have a
transform: position, scale, rotation and opacity are the controls of the
Transform effect on a clip, and the timeline's property rows and the
inspector's transform section (P, S, R and T) are gone. Everything this
document says about **keyframes, eases, the graph editor and arithmetic in
numeric fields** still holds, and applies to effect controls, the anchor
point and volume. The sections on layer properties below describe how the
layer transform worked and are kept for reference until the effects panel
replaces them.

## Properties

Every layer that draws pictures (a layer holding video or a nested
timeline) has a `LayerTransform`. Audio-only layers have none and show no
controls. The properties follow After Effects:

| Property | Shown as | Default | Notes |
| --- | --- | --- | --- |
| Position | x, y in timeline pixels, origin at the frame's top-left, y down | the frame's center | Where the layer's center is drawn. |
| Scale | x %, y % | 100, 100 | 100% is the size the content is fitted to (aspect-fit into the timeline frame, as before). Negative flips. Linked by default: changing one axis scales the other in proportion. The link button turns that off. |
| Rotation | degrees | 0 | Clockwise. Values past 360 are kept, so 0 → 720 keyframes spin twice. |
| Opacity | % | 100 | Clamped to 0–100. |

The layer scales and turns about the center of its timeline's frame. Fitted
content is centered in the frame, so this is also the content's own center.
There is no anchor point yet.

Transforms belong to the **layer**, not to individual clips, so every clip
on the layer moves together, and keyframe times are in the **timeline's
time**. Moving or trimming a clip doesn't move the keyframes (unlike After
Effects, where a layer is one clip and its keyframes travel with it).

### Only 2D for now

Position and scale are 2D and rotation is about the z axis only. 3D layers
(z position, x/y rotation, orientation, a camera) may come later. The model
is set up for that: `Vector2` would gain a `Vector3` sibling, and each 3D
property would be one more `AnimatedValue` on `LayerTransform`. Rendering
3D would need a custom compositor (see [Rendering](#rendering)), since the
built-in one takes only an affine transform.

## Keyframes

Each property is an `AnimatedValue`: either a single value, or a list of
keyframes (time, value, and how the value arrives and leaves). A layer's
volume (see [audio.md](audio.md)) is keyframed the same way.

- Before its first keyframe a property holds the first keyframe's value,
  after its last it holds the last one's, and in between it blends,
  linearly unless either keyframe is eased (see [Easing](#easing)).
- A property has at most one keyframe per time. Keyframes are identified by
  their time, which is snapped to the timeline's frames (exactly, so 23.976
  fps keyframes land on 1001/24000 s steps). Editing a value with the
  playhead on a keyframe changes that keyframe.
- **Stopwatch.** Clicking it turns animation on, adding a keyframe at the
  playhead with the current value. Clicking it again turns animation off and
  keeps the value that was showing at the playhead.
- While a property is animated, typing a value adds or updates a keyframe at
  the playhead. While it isn't, typing sets the single value.
- Next to an animated property are ◀ ◆ ▶: go to the previous keyframe,
  add or remove a keyframe at the playhead (filled when there is one), go to
  the next keyframe.
- Removing the last keyframe leaves the property set to that keyframe's
  value, not animated.

### Easing

Each side of a keyframe may have an ease (`KeyframeEase`), as After
Effects' temporal ease: a bezier handle reaching some share of the way to
the neighboring keyframe (its **influence**) at some **speed** relative to
a steady blend (0 stops at the keyframe, 1 is steady, more overshoots).
Between two keyframes the value follows a cubic bezier, time across and
progress up, whose inner control points are the first keyframe's outgoing
handle and the second's incoming one. A side with no ease is linear: its
handle sits on the straight line a third of the way along, so two linear
sides blend steadily, as before. All components of a value (position's x
and y) share the keyframe's ease.

Presets, named as on transitions:

| Preset | Key | Sets |
| --- | --- | --- |
| Linear | | Both sides linear |
| Ease In | Shift-F9 | The incoming side to Easy Ease (slows into the keyframe); the other side stays |
| Ease Out | Cmd-Shift-F9 | The outgoing side (leaves the keyframe slowly) |
| Easy Ease | F9 | Both sides: speed 0, 33% influence |

They're in each keyframe's right-click menu on the timeline and in the
graph editor. The F9 keys ease the keyframes at the playhead in every
property row that is showing, under the selected clip's layer or under
every layer when nothing is selected (on a laptop keyboard, with Fn
unless the function keys are set to act as standard keys). Setting a
keyframe's value or retiming it keeps its eases.

The shape of an ease is set by dragging its handle in the parameter's
graph editor (see [Graph editor](#graph-editor)).

### Graph editor

Each animated property has a graph button (a small chart) after its
keyframe buttons, in the timeline and the inspector; volume does too. It
opens that parameter's graph editor in a floating **HUD panel** of its
own, titled with the layer and the parameter ("Video 1 · Position"), so
several can be open side by side: one per parameter, and pressing the
button again brings the existing panel forward (`KeyframeGraphHUDs`).
Panels move only by their title bar, so every drag inside goes to the
graph, and the first click on one goes to the graph too. They float over
the window, hide while the app is in the background,
follow renames and close when their layer is deleted or the editor goes
away.

The panel is a value graph (`KeyframeGraphView`): time across in the
parameter's own time (a clip's source time, so its keyframes stay put
when the clip moves, or the timeline's for a layer's volume and pan),
labelled with the timeline's timecode, with the clip's ends marked; the
value up as the editor shows it; one line per component (position's X in
red and Y in green, a single property in yellow); and each keyframe a
mark on each line, pinched where eased. The playhead is drawn in red at
the moment of the parameter's time it plays, and follows the player while
it plays. **Space** plays and pauses in a graph's panel, as in the main
window.

- **Click a keyframe** to select it. The handles of its eased sides
  appear, drawn against the component that changes most over that
  segment. A linear side has no handle.
- **Drag a handle** to shape that side's ease: across sets its influence,
  up and down its speed. A handle can't leave its segment in time; it can
  overshoot in value. Over a segment whose value doesn't change only its
  influence can be set, since the curve is flat whatever the speed.
- **The two handles stay in line.** While one is dragged, the keyframe's
  other handle (if that side is eased) swings to stay on one straight line
  through the keyframe with it, keeping its own length on screen. Hold
  **Option** to move the dragged handle alone; letting go of Option
  mid-drag brings the other back into line.
- **Drag a handle onto its keyframe** (within 6 points) and it goes: that
  side turns linear and the keyframe is eased on one side only. Dragged
  back out before letting go, it returns.
- **Option-drag a keyframe** to pull a handle out of a linear side: drag
  right for the outgoing side, left for the incoming one. It moves alone.
- **Option-click a keyframe** to switch it between linear and bezier: a
  linear one gets Easy Ease on both sides, and one with either side eased
  goes linear (`AnimatedValue.toggleBezier`).
- **Drag a keyframe** to move it in time (on frames, never past a
  neighbor) and in that component's value; Shift keeps the drag to
  whichever direction it moves most.
- **Click elsewhere** to move the playhead there, and drag to scrub.
  **Double-click** to add a keyframe there (or remove the one there).
- The **preset buttons** along the top, and the right-click menu (with
  **Delete Keyframe**), act on the selected keyframe, or else the one at
  the playhead.

The graph starts fitted to the keyframes, their curves and their handles
(`KeyframeGraphLayout`), and keeps its scale while a drag is in progress,
so nothing moves under the pointer. How it is zoomed and scrolled is the
panel's `KeyframeGraphViewport`:

- **Zoom dials** meeting in the graph's bottom right corner, each along
  the axis it zooms: time along the bottom, values up the right, with the
  Fit button where they meet. They are drawn as the Tape Scrubber's ridged
  dial (`RidgedDial`, `ZoomDial`), 200 points long at most, so they never
  outgrow it and a turn feels the same in any size of panel. Dragging
  along one turns it; rightward or upward zooms in. Every point turned
  changes the zoom by the same ratio (e every 150 points), so a turn
  does as much zoomed far out as far in, and turning back returns
  exactly. Time zooms about the playhead while it is in view, no further
  out than the clip (padded 4% so points at its ends show) and no closer
  than four frames; values zoom from a quarter of the fitted range to a
  thousandth. Past either limit the plot stretches and springs back when
  the dial or pinch lets go (the shared zoom edge, see timeline.md).
  Double-click a dial to fit its axis, or press Fit for both.
- **Pinch** zooms time about where the pinch started, or values with
  Option. **Scrolling** moves the view: across in time, inside the clip,
  and up and down in value.
- **Components.** With more than one, each has a chip in the toolbar (its
  color, name and value) that shows or hides its line and points; at
  least one stays shown, and hidden ones leave the fit. **Separate
  Scales** draws each on a scale of its own, fitted to it, so a small
  move in one isn't flattened by a large one in another; the value axis
  is then labelled for the first shown component, in its color. A drag is drawn as it goes and saved
when it ends, as one undo step; in-between states don't rebuild the
player. After release the graph keeps drawing the drag's result until the
project has it, so the old curve never shows for a frame.

## In the timeline

Each visual layer has a disclosure arrow left of its number. The arrow shows
all four properties under the layer, or hides them. The keys work like After
Effects:

| Key | Does |
| --- | --- |
| P, S, R, T | Show only position, scale, rotation or opacity (T is opacity, as in After Effects). Pressing it again hides it. |
| Shift + P/S/R/T | Add or remove that property, keeping the others shown. |

The keys act on the selected clip's layer, or on every visual layer when no
clip is selected. They are ignored while a text field is being edited, so
typing a layer name or a value is never interrupted.

Each shown property gets a row: the stopwatch, its name, its values at the
playhead, and the keyframe buttons. The label column widens from 150 to 300
points while any property row is showing. To the right, under the layer's
clips, the row's lane shows its keyframes as diamonds (yellow when the
playhead is on one). An eased side is pinched in, so a keyframe eased on
both sides reads as an hourglass, as in After Effects:

- Click a diamond to move the playhead to it.
- Drag a diamond to retime it; it snaps to frames and replaces any keyframe
  where it lands.
- Right-click for the ease presets and **Delete Keyframe**.

Which properties are shown is view state, not saved in the project.

## In the inspector

With a clip selected, the inspector's **Layer Transform** section has the
same four rows for that clip's layer, plus **Reset Transform**.

## Numeric fields take arithmetic

Values are shown as text and turn into a field when clicked. Return or
clicking away enters what was typed; Escape cancels. What's typed may be
arithmetic, evaluated by `NumericExpression`:

- `+ - * /` with the usual precedence, parentheses, unary minus and
  decimals: `100+25` enters 125, `1920/2-40` enters 920.
- `x` or `×` also multiply, `÷` divides, spaces and commas are ignored.
  The decimal point is always `.`.
- Text that isn't a complete expression, or a result that isn't a finite
  number (such as `1/0`), beeps and leaves the value unchanged.

This applies to all fillable numeric fields: the transform values and the
timeline settings' width, height and frame rate. In the settings sheet the
field shows the result when Return is pressed or focus leaves, and the form
reads it the same way, so pressing Create without leaving a field still
works. New numeric fields should use `NumericField`, or
`.evaluatesArithmetic(_:)` with `NumericExpression.evaluate` for a field
bound to text.

## Rendering

The preview and export share `CompositionExporter.buildComposedTimeline`,
so animation looks the same in both.

- While flattening nested timelines, each placement collects a
  `PlacementAnimation`: its own orient-and-fit transform, then one
  `TransformStage` per enclosing layer, innermost first. A stage holds that
  layer's transform, the center of its timeline's frame, the time shift
  from that timeline to the root, and the fit from that timeline's frame
  into the next one out. A nested timeline's layers are transformed inside
  it, then the whole result by the layer that holds the nested timeline.
- The built-in AVFoundation compositor is kept (it handles HDR and runs on
  the GPU). Each layer instruction gets the transform and opacity at the
  start of its time range, then again on every frame inside a keyframe span,
  wherever the value changed. Outside all keyframe spans a layer gets one
  value per range, so unanimated layers cost nothing extra.
- Matrix ramps (`setTransformRamp`) aren't used: they blend matrix entries,
  which shrinks a layer midway through a turn. Per-frame values are exact
  at every rendered frame.
- Opacity of nested layers is group opacity: a nested timeline's layers are
  stacked first and the layer holding it fades the result as one picture,
  so its overlapping layers don't show through each other. The built-in
  compositor can only fade layer by layer, so a timeline where a fading
  nested timeline shows two of its layers at once is drawn by
  `LayeredCompositor`, in preview and export alike.

## Saving

Each layer in `project.json` may have a `transform` object. It is absent for
untransformed layers, and each property in it is absent while it has its
default, so old files load unchanged and untouched layers add nothing to
diffs.

```json
"transform": {
  "position": { "keyframes": [
    { "time": "0/1s", "value": [0, 0] },
    { "time": "1001/24000s", "value": [-200, 35.5] }
  ] },
  "rotation": { "value": -30 },
  "scale": { "value": [50, 75] },
  "scaleLinked": false
}
```

- A property has either `value` or `keyframes`.
- A keyframe's `easeIn` and `easeOut` (`{"influence": 0.333, "speed": 0}`)
  are written only on eased sides.
- `position` is stored as the offset of the layer's center from the frame's
  center, so an untouched layer stays centered if the timeline's frame size
  changes. The editor shows it as an absolute position.
- Times are exact rationals like everywhere else in the file.

The format version stays 1; the field is optional. An older build would
ignore it, and drop the transforms if it saved the project.

## Not implemented yet

- **Hold keyframes**, spatial (curved) motion paths for position, and
  separate easing per component.
- In the graph editor: a speed graph, selecting several keyframes, and keeping linked scale's aspect when
  dragging one component.
- **Image layers.** Still images can't be imported yet. When they can, they
  are visual layers and get the same transform.
- **Anchor point**, and **3D** (see [Only 2D for now](#only-2d-for-now)).
- **Dragging in the viewer** to move, scale or rotate a layer, and dragging
  across a value to scrub it.
- **Selecting several keyframes**, copying and pasting them, and deleting
  with the Delete key.
- **U** to show only animated properties, as in After Effects.
- **Motion blur** for nested timelines.
- Each edit rebuilds the player item, as other edits do. Fine for typed
  values; live dragging in the viewer will need a cheaper update path.
