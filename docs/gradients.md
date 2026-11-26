# Gradients

Status: **partly built** (steps 1 to 4 of [Building it](#building-it):
shapes', text's and the Stroke effect's Fill and Stroke and their
handles in the viewer, not yet tried in the running app). The rest is
planned.

One gradient builder for everything that has a fill or a stroke, so any
of them can be painted with a gradient instead of a single color. It is
step (c), Gradients, of [graphic-layers.md](graphic-layers.md), widened
to the whole app. It was talked through in ideas.md first.

### Where it is offered

Everywhere a fill or stroke is a color today, the color is replaced by
a **paint**: a solid color, as now, or a gradient.

- **Shapes and free paths** (built): Fill and Stroke in Fill & Stroke
  (`PaintInspectorGroup`), each followed by a line of its own, **Fill
  Type** or **Stroke Type** (`PaintType`): Color, Linear, Radial or
  Angular, as words in a row of buttons. A gradient takes the color's
  place, and its stops go under that line (`GradientEditor`). The
  effects panel has the same Type row, a pop-up, under each Fill and
  Stroke of a shape, text, Waveform or Stroke effect
  (`Effect.offersGradients`), and the color's row then says what it is
  ("Linear gradient, 3 stops"), with no graph, since its numbers are
  points and stops; the stops are set in the inspector. (The choice was
  first an icon menu beside the checkbox, which read as a swatch and
  went unfound.)
- **Text** (the block built, runs not yet): the block's Fill and Stroke,
  in the same group. The letters painted in the block's own colors take
  its gradient; a styled run's own color stays one color, and so do
  letters a Text Animator recolors, mixed from the gradient's first
  stop. A run's own gradient is not built yet.
- **The Stroke effect** (built): its stroke, which goes around
  everything above it, in its own group, the gradient laid over what it
  outlines.
- **The Waveform effect** (built): its Fill and Stroke are the shapes',
  so Along and By Level are this builder ([waveform-effect.md](waveform-effect.md)).
- **Effect packages** (not yet): a new `gradient` control type, handed to the
  kernel as a 256 × 1 picture of the gradient to sample, as Gradient
  Map draws its stops today
  ([psychedelic-effects.md](psychedelic-effects.md)). Gradient Map moves
  to it, so it has as many stops as it likes rather than three.

### Kinds

- **Linear**: from a start point to an end point.
- **Radial**: from a center out to an edge point, whose distance is the
  radius, with a **focal point** that can move off the center for a
  lit-sphere look, and an **aspect** that stretches it across into an
  ellipse lying along the edge point's direction (so that direction is
  its angle).
- **Angular**: round a center, starting in the direction of the edge
  point, as a conic gradient, which suits a radial waveform's ring.
- **Repeat**: past its ends a gradient holds its end colors (the
  default), repeats, or reflects back and forth.

### Stops

- **A bar of stops** under the gradient's preview (over a checkerboard,
  so opacity shows), as in Illustrator:
  each stop a color with opacity, at a location from 0 to 100%. Click
  the bar to add a stop with the color the gradient has there, drag a
  stop to move it, drag it off the bar or press Delete to take it out,
  Option-drag to copy it. Two stops at the same place make a hard edge.
  A drag shows as it goes and is set when it ends, as one change. A
  gradient keeps at least two stops.
- **A midpoint** between each pair of stops, a diamond dragged to where
  the two colors are half and half, for a gradient that leans one way.
- **The picked stop** has its color (the Mac's color picker, with its
  eyedropper), its opacity and its location as fields, and Remove.
- **Reverse**, which mirrors the midpoints too, and **Distribute** to
  space the stops evenly, in the order they lie.
- **Blend in**: the timeline's own values (as colors are drawn today)
  or a perceptual space (OKLab), whose middles don't go gray or muddy
  between saturated colors.

### Where it lies

- **Relative to the item** (the default): its points are in the item's
  bounds, so it moves, scales and turns with the shape or text, and a
  gradient copied to another shape fits it. **Relative to the frame**
  keeps it still while the item moves through it.
- **Handles in the viewer** (built,
  [viewer-handles.md](viewer-handles.md), `GradientHandles`): the
  effect selected in the effects panel, when its Fill (else its Stroke)
  paints a gradient, shows its line over the picture (for a Stroke
  effect, over the bounds of the outline it strokes, worked out from
  the stack as the compositor does, `GradientHandles.strokedOutline`), a round handle at
  its start and end (or center and edge), a diamond at a radial one's
  focal point (kept inside the edge), and each stop just below the
  line (14 points on screen, on a short guide back to its place on it),
  as Illustrator's gradient annotator does: a stop at an end would
  otherwise cover the end and take its press. Where a gradient handle
  meets the shape's own (its ends sit on a rectangle's edge handles by
  default), the gradient's is drawn on top and takes the press, as the
  viewer draws every set's handles in the order a press asks them. A drag moves an end or the
  focal point by its share of the bounds, with the pointer (Shift to an
  axis, Option a tenth; the loupe slows the pointer itself), and a stop along the line to where the pointer is nearest; the
  arrows move a point a pixel and a stop a percent, ten with Shift, and
  VoiceOver's Reset puts an end back. A keyframed gradient gets a
  keyframe at the playhead, as the inspector would give it.
- **Text**: over the whole block (built), each group of letters faded
  as it is; over **each letter**, each painted with the whole gradient,
  is not built yet.

### On strokes

A stroke's gradient can lie three ways, as Illustrator's can; Within is
built, Along and Across not yet:

- **Within**: in space, as a fill's does, the stroke showing the part of
  the gradient under it.
- **Along**: following the path from its start to its end, so a line
  drawn on changes color as it goes.
- **Across**: from one edge of the stroke to the other, the same all
  along it.

Along and Across need how far along the path and how far across the
stroke each pixel is, which Core Graphics doesn't give; the stroke is
drawn with those as a second picture, from the path cut into short
pieces, and the gradient looked up from it.

### Animating

Every stop's color, opacity, location and midpoint, the points, aspect
and focal point are keyframed like any control: a Fill or Stroke
holding a gradient keeps its keyframes, its numbers the gradient's
rather than a color's (see [Model and saving](#model-and-saving)), so
its lane in the effects panel keyframes it as it keyframed the color.
Stops are matched by their order, so two keyframes always blend stop by
stop: adding or removing a stop does it in every keyframe at once (each
at the color it has there, in the place it takes at the playhead), and
the count never differs between keyframes. As everywhere in the
inspector, a keyframed gradient reads there as it is at the playhead,
and is changed in the effects panel; adding and taking out stops still
work. A Keyframing method can't drive a gradient
(`EffectControl.isDrivable`), whose numbers are points, not values to
move.

### Presets

Not yet. The paint popover keeps **saved gradients**, kept for the Mac rather
than the project, beside a set that ships: a few neutrals, a sunset, a rainbow, a metal sheen and
transparent-to-color fades. Saving the one being edited adds it. Each
is copied in when picked, so changing a saved gradient later doesn't
change what was painted with it.

### Drawing and saving

- **Drawing** (`GradientRendering`): Core Graphics draws linear,
  radial and conic gradients clipped to each fill or stroke's area, in
  32-bit floats as fills are drawn (`ShapeRendering`), from 256 colors
  a length, sampled with the midpoints and the blending space, so every
  macOS the app runs on draws all three alike. A repeat or reflection is
  drawn as whole lengths covering the area, at most 64. A **Dither**
  setting, a little noise so a slow gradient doesn't band once exported
  at 8 bits, is not built yet.
- **Sharpness**: a gradient follows its item through the moves that
  keep shapes sharp, as its outline does.
- **Render key**: the paint is part of the shape's step, so changing a
  stop re-renders it.
- **Saving**: see [Model and saving](#model-and-saving).

### Accessibility

Following [accessibility.md](accessibility.md): the stop bar is an
accessibility element with each stop a child, adjustable for its
location, with actions to add a stop after it, remove it, and pick the
next or previous. Tab moves between stops, ← → move the picked one a
percent (ten with Shift), and Delete takes it out (Return opening its
color is not built yet). Each Type button is named (Color, Linear,
Radial, Angular) and the row is named for its color ("Fill Type"), and the viewer's gradient
handles have the actions the other handles have (`keyTargets`).

## Model and saving

A Fill or Stroke color control (`ControlKind.takesGradient`) keeps its
place, ID and keyframes. A `PaintStyle` on it (`EffectControl.paint`:
the kind, repeat, blending space and where it lies, none of them
keyframed) says it holds a gradient, and its numbers are then the
gradient's (`PaintGradient`): the start (or center) and end (or edge)
points as shares of the item's bounds or the frame, the focal point's
offset from the center in radii, the aspect, then for each stop its
red, green, blue and alpha, location and midpoint. Picking a gradient
(`setPaint`) turns the color, at every keyframe, into a gradient from
it to black, across the item from left to right or out from its
middle; another kind keeps the stops and points; Color takes the first
stop's color.

Saved, the control adds a `"paint"` object (`kind`, `repeats`, `blend`,
`space`, each absent at its default) and its numbers are as many as
the gradient's. A project saved before gradients has no paint and loads
as it was; numbers that don't fit what the paint says (a color's four
with a paint, or a gradient's without) load as a new control's.

## Testing

- `PaintGradientTests`: numbers to a gradient and back; colors between
  stops, leaning to a midpoint, and a hard edge; hold, repeat and
  reflect past the ends; perceptual blending keeping red and green's
  middle bright, and OKLab round trips; Reverse and Distribute.
- `GradientPaintTests`: a color to a gradient and back, at every
  keyframe; a stop added and taken out at every keyframe, never fewer
  than two; a gradient isn't drivable.
- `GradientDrawingTests`: a linear gradient across a rectangle, a
  radial one out from its middle, repeat against reflect past the end,
  and saving the gradient and its style.
- `TextGradientTests`: a block's gradient over the whole block, and a
  run's own color left as it is.
- `GradientHandlesTests`: a linear gradient's ends and stops on its
  line, an end dragged by its share of the bounds, a stop dragged along
  the line, and a radial one's focal point kept inside its edge.
- `UISnapshots.shapeInspectorGradients`: the inspector's Fill and Stroke Type rows and
  gradient editors.

## Building it

1. **Shapes' Fill and Stroke** (done): the model, drawing and saving
   above, the Type rows and the gradient editor in Fill & Stroke, the
   effects panel's summary, and the keys and VoiceOver of the stop bar.
2. **Text** (the block done): the block's Fill and Stroke over the
   whole block. Runs' own gradients and Each Letter are not built yet.
3. **The Stroke effect in the inspector** (done). Dither is not built
   yet.
4. **Viewer handles** (done) for a selected item's gradient.
5. **Packages' `gradient` control** (not yet), with Gradient Map moved
   to it. The Waveform effect's colors are done, through its Fill and
   Stroke.
6. **Strokes Along and Across** (not yet), and saved gradients.
