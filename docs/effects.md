# Effects

Status: **planned, not implemented**. This replaces the layer transforms
in [layer-transforms.md](layer-transforms.md): transforms move from layers
to clips and become effects. Keyframes, easing, the graph editor and
arithmetic in numeric fields carry over unchanged.

## Guiding principle: gravity

What is above acts on what is below. In a clip's stack, each control works
on the picture handed down from the ones above it. On the timeline, a clip
blends onto the layers below it. Every other rule follows from this:

- The anchor point is pinned at the top of the stack, so it affects every
  step.
- Transitions are pinned at the bottom of the stack, so they act on
  everything above them.
- A nested timeline is a closed container: what falls inside it never
  lands on the timeline it is placed in, except through its alpha.
- The one exception is an adjustment layer, which can set how far down its
  effect falls (see [Reach](#reach)).

When a new feature needs an order, it gets this one.

## The idea: the list is the render order

In After Effects, Final Cut Pro and Motion, where a control sits in the
interface decides when it is applied, and the order is fixed. Effects come
before the transform, blending comes after both, and changing that means
precomposing. Here every clip with pictures has an **effect stack**: an
ordered list of effects, each an ordered list of controls, applied top to
bottom. What the list shows is exactly what the renderer does. To scale
before blurring, put Scale above Blur. To blur first, drag it the other way.

- **Everything starts as a no-op.** A new effect changes nothing until one
  of its controls is moved off its default. Controls left at their default
  cost nothing; the renderer skips them.
- **Controls can be deleted and reordered.** A Transform effect can be
  reduced to just its Position control.
- **Effects can be duplicated and repeated.** A Transform holding only
  Position +5 px, duplicated fifty times, moves the clip 250 px. Two
  Blending effects apply two blend modes, one after the other. Other effects
  can sit between them.
- **Effects of any kind mix freely.** Effects added later (blurs, keys,
  generators) go in the same list.

## What has a stack

Every visual clip has one: a media clip with pictures, a nested timeline,
and later images, text and shapes. Audio-only clips have none. Layers no
longer have a transform; a layer keeps only its volume (see
[audio.md](audio.md)). Animation across several clips goes on an
adjustment layer (see [Adjustment layers](#adjustment-layers)).

Every visual clip also has an **anchor point**, the one control that isn't
an effect. It is the point that scale and rotation turn about, given as an
offset from the center of the clip's picture, in timeline pixels at 100%
scale. Its default is (0, 0), the center. Because it is relative to the
fitted picture, not to the media's pixels, replacing the media with a
different resolution keeps it in place. It can be keyframed.

## Foundations

Effects are grouped into categories in the effects panel. The first is
**Foundations**:

### Transform

| Control | Shown as | Default | Does |
| --- | --- | --- | --- |
| Position | Δx, Δy in pixels | 0, 0 | Moves the picture. |
| Scale | x %, y % (linked by default) | 100, 100 | Scales about the anchor point. Negative flips. |
| Rotation | degrees, clockwise | 0 | Turns about the anchor point. Values past 360 are kept. |
| Opacity | % | 100 | Multiplies the picture's alpha. Clamped to 0–100. |

New Transform effects list them in this order. Each control is one step:

- **Steps work on the picture as it is on screen.** Coordinates are the
  timeline frame's: pixels, origin top left, y down. Position after a
  rotation moves along the screen's x axis, not the rotated one. "Scale
  200%, then Position +5" moves the picture 5 pixels, not 10.
- **Repeats compound.** Positions and rotations add. Scales and opacities
  multiply: 102% fifty times is about 269%, and 50% opacity twice is 25%.
- **The anchor point moves with the picture.** Position moves it along, so
  later scales and rotations turn the picture about its own anchor, wherever
  the picture now is. Scale and rotation leave it where it is, since it is
  the point they turn about. As a result, Position, Scale and Rotation give
  the same picture in any order within a Transform effect. Order matters
  across effects with other steps between them, and when an effect doesn't
  move the anchor.
- **Moves Anchor** (in the effect's ⋯ menu, checked by default): unchecked,
  the effect's Position moves the picture but leaves the anchor at its spot
  in the frame. Later scales and rotations then turn the picture about that
  fixed spot, so a rotation after an unanchored move orbits it.

### Blending

Two controls:

| Control | Default | Does |
| --- | --- | --- |
| Mode | Normal (a no-op) | Darken, Multiply, Color Burn, Linear Burn, Lighten, Screen, Color Dodge, Add, Overlay, Soft Light, Hard Light, Difference, Exclusion, Subtract, Divide, Hue, Saturation, Color or Luminosity. |
| Amount | 100% | How much of the blend is applied: at 0% the step is a no-op, in between the clip's color is mixed toward the blended one. Unlike Opacity it doesn't change the clip's alpha. |

A blend mode combines the clip with its **backdrop**: everything below the
clip in its own timeline, fully drawn at this frame. The backdrop is never
moved or changed by the clip's own steps. A Blending step replaces the
clip's color with the blend and keeps the clip's alpha, as in the W3C
compositing model:

    blended = (1 − backdrop alpha) · clip color + backdrop alpha · B(backdrop color, clip color)
    color   = clip color + amount · (blended − clip color)

Steps after it work on that result. Two Multiply steps multiply by the
backdrop twice. Multiply followed by Position +50 px moves pixels that
already hold the backdrop, leaving a shifted ghost of it. At the end of the
stack the clip is drawn normally over the backdrop, so a Blending effect at
the end behaves like a layer blend mode in other apps.

The bottom clip of a nested timeline has nothing under it, so blending
there does nothing. The panel says so.

### Color

The controls other apps put under color correction, each a step of its own
and each a no-op by default: Exposure (stops), Contrast, Saturation,
Temperature, Tint, and Lift, Gamma and Gain (each per channel and overall).

Transform and Blending work on the frame's encoded values without color
management, as rendering does today. Color steps are the exception: they
convert to the working space each control needs and back. Exposure,
Temperature, Tint and Gain need linear light. Contrast, Saturation, Lift
and Gamma use the encoded values, as editors expect. The exact working
space for PQ and HLG timelines is settled when Color is built.

## How a clip is drawn

For each frame, each clip goes through:

1. **Source**: the media frame, oriented and fitted into its timeline's
   frame, centered (as 100% scale is today). A nested timeline is drawn
   first, on its own (see below).
2. **Stack**: each enabled effect, top to bottom, and within it each
   enabled control that isn't at its default.
3. **Transition**: the clip's transitions, if any. They aren't effects:
   they are pinned at the bottom of the list and always come last. A dissolve fades the stack's
   result, a wipe crops it in frame coordinates, and a film dissolve keys
   on it or on the backdrop.
4. **Composite**: drawn normally over the backdrop.

### Nested timelines are closed groups

A nested timeline draws over transparency, never over the timeline it is
placed in. Its result is one picture with an alpha channel, which then goes
through the nested clip's own stack and transitions like any other clip.
Nothing inside a nested timeline sees what is under it in the parent; only
its alpha shows through. The root timeline draws over black.

This replaces flattening. Today nested timelines are flattened into one
stack of tracks; instead the compositor gets a tree and draws each nested
timeline into an image of its own.

### Keeping it sharp and cheap

- **Transforms are math until a pixel step needs pixels.** Each run of
  Position, Scale and Rotation steps is folded into one matrix, and each
  run of Opacity steps into one factor. The picture is sampled once at the
  end of the run, from the full-size source, so fifty Transform effects
  cost no more than one.
- **Per-pixel steps don't sample either.** Blending, Color and Opacity
  change each pixel on its own, so moving a transform past them gives the
  same picture. Core Image evaluates the whole chain lazily: it maps each
  output pixel back through every step to the source and fuses per-pixel
  steps into as few GPU passes as it can. Scaling to 10%, color correcting
  and scaling back up stays sharp. A Blending step reads the backdrop where
  the pixel was at that step, which the same mapping gives.
- **Neighborhood steps sample.** Effects that read the pixels around each
  one (a blur, a glow, a sharpen) draw an intermediate image on the
  timeline frame's pixel grid (at the viewer's size while previewing).
  Scaling to 10%, blurring and scaling back up looks soft. That's what the
  stack asks for, and the panel's thumbnails make it visible.
- **Transforms are pushed into nested timelines.** A nested timeline scaled
  up 300% is drawn at that size, with the matrix applied to each layer
  inside, instead of drawing it at 100% and enlarging the result. This is
  only exact when every step inside is per pixel (transforms, blending,
  color). A future effect whose result depends on pixel size (a blur
  radius) stops the push at that nested timeline. Text and shapes, when they
  come, are drawn at their final size the same way.
- **The canvas has an edge.** Intermediate images keep pixels moved off the
  frame, so a later step can bring them back, up to a margin around the
  frame (one frame width and height on each side to start with). Chains
  without a neighborhood step have no such limit, since nothing is drawn
  until the end.

### One compositor

The viewer and export both draw through `LayeredCompositor`. The built-in
AVFoundation compositor is no longer used, and the test that the two match
goes away. A stretch with one clip whose stack and anchor point are at
their defaults, with no transition, still plays straight from its file.
Everything else is drawn by the compositor and rendered in the background
as today ([rendering.md](rendering.md)). The render key hashes each clip's
resolved steps on every frame, after folding, plus the nesting.

## Adjustment layers

An adjustment layer holds **adjustment clips**: stretches of time with an
effect stack and no picture of their own. While one plays, its stack is
applied to the layers below it, drawn together as one picture. A Transform
on it moves that whole picture, so animation that spans several clips or
layers goes here, keyframed in the adjustment clip's time.

### Reach

Other apps apply an adjustment to everything below it. Here each
adjustment layer has a **Reach**: All Layers Below (the default), or down
to a chosen layer. For example, it can reach only the one layer under it,
with all that layer's clips, or three of the five layers below.

- **Reach is stored as the bottom layer it reaches, not as a count.** Adding
  or moving layers changes which layers are in between, but never makes the
  adjustment stop at a different layer than the one picked. If the chosen
  layer is deleted, the reach goes back to All Layers Below. If the chosen
  layer is moved above the adjustment layer, the adjustment reaches nothing
  and is dimmed with a note.
- In the timeline, a bracket at the adjustment layer's left edge spans the
  layers it reaches.

### How it draws

Layers inside the reach still blend with everything beneath them,
including layers outside the reach, so adding an adjustment layer never
changes how the layers under it blend. Then the adjustment changes only
the pixels those layers put there:

1. **Below**: draw the layers under the reach.
2. **With**: draw the reached layers over that, as usual.
3. **Adjusted**: run the adjustment's stack on With.
4. **Coverage**: the alpha of the reached layers alone, drawn over
   transparency.
5. **Result**: Below mixed toward Adjusted by Coverage. Where the reached
   layers are opaque, the result is fully adjusted. Where they're empty,
   Below is untouched.

Where a reached layer is partly transparent, the part of Below showing
through it gets adjusted too, in proportion. That's the cost of letting the
reached layers keep blending with what's under them.

With All Layers Below, Below is empty and Coverage is the full frame, so
this matches other apps' adjustment layers.

## The effects panel

The effects panel opens at the right end of the timeline, where the
transitions panel goes, and replaces it while open. The two have buttons
side by side in the timeline's header.

Top: the **library**, grouped by category, Foundations first. Drag an
effect onto a clip, or double-click it to add it to the end of the selected
clip's stack.

Below: the selected clip's **stack**, with the anchor point pinned as the
first row and the clip's transitions, if any, pinned as the last. Neither
can be moved. Clicking a transition row selects it, as clicking it on the
timeline does.

- Each **effect** row has a drag handle, a disclosure arrow, an
  enable checkbox, its name and a **⋯** menu: Duplicate (Cmd-D), Reset,
  Enable/Disable, Delete, Show Up to Here, and, on Transform, Moves Anchor.
- Each **control** row has the stopwatch, its name, its values (fields
  take arithmetic) and the keyframe buttons ◀ ◆ ▶. It also has the graph
  button, which opens the existing graph editor HUD ("Clip 3 · Transform 2 ·
  Position"), and a **⋯** menu: Reset, Enable/Disable, Delete.
- Effects are dragged to reorder within the stack. Controls are dragged to
  reorder within their effect.
- The Delete key deletes the selected effect or control.

### Keyframes in the panel

The panel has its own ruler and playhead, spanning the selected clip. To
the right of each control row is its keyframe lane, with the same diamonds
and interactions as the timeline's lanes today: click to go to it, drag to
retime, right-click for ease presets and Delete Keyframe. The panel's
playhead is the timeline's: scrubbing either moves both.

Keyframes are in the clip's **source time**: media time for a media clip,
the nested timeline's time for a nested clip. Moving a clip carries its
animation along. Trimming its start doesn't shift the animation against
the picture. Keyframes outside the trimmed range are kept but don't play.

The timeline no longer has per-layer property rows or the P, S, R and T
keys. A clip block with effects shows a small badge with the count.

### Reading the stack

- **No-ops are dimmed**: a control at its default, a disabled control or
  effect, and an effect whose controls are all no-ops. A Blending step with
  nothing under it is dimmed with a note.
- **Each effect shows a thumbnail** of the clip's picture after it, at the
  playhead, drawn small and refreshed when the playhead stops.
- **Show Up to Here** shows the clip in the viewer as it is after that
  effect, with later effects and the transition skipped, until it is turned
  off. The viewer shows a banner while it is on.

## Saving

`formatVersion` becomes 2. A layer no longer has `transform`. A visual
clip has `anchorPoint` (written only when it isn't (0, 0) or is animated)
and `effects` (written only when the stack isn't empty):

```json
"effects": [
  {
    "id": "…",
    "kind": "transform",
    "movesAnchor": false,
    "controls": [
      { "id": "…", "kind": "position", "value": [5, 0] },
      { "id": "…", "kind": "rotation", "keyframes": [
        { "time": "0s", "value": 0, "easeOut": { "influence": 0.33, "speed": 0 } },
        { "time": "2s", "value": 90 }
      ] }
    ]
  },
  { "id": "…", "kind": "blending", "enabled": false,
    "controls": [{ "id": "…", "kind": "mode", "value": "multiply" }] }
]
```

Defaults are left out as everywhere else: `enabled` is written only as
`false`, `movesAnchor` only as `false`, and a Scale control's `linked`
only as `false`. Keyframes are written as layer transforms' are today
(`easeIn` and `easeOut` only when eased), with times in rational seconds
of source time.

### Loading is strict

Old projects aren't migrated. A file with `formatVersion` 1 isn't opened:
"This project uses format version 1, which this version of the app can't
open."

Beyond that, loading rejects anything it doesn't recognize instead of
skipping it: an unknown key, an unknown `kind` or blend mode, a value of
the wrong type, or a missing required field. The message names the
problem and where it is in the file, as a path:

> The project can't be opened. Unknown key "transform" at
> timelines[0].layers[2].

> The project can't be opened. Unknown effect kind "glow" at
> timelines[1].layers[0].clips[3].effects[2].kind.

This also replaces today's rule that an unknown transition kind is dropped
on load.

## Building it

In order, each step usable on its own:

1. **Model and saving**: anchor point and stacks on clips, layer transforms
   removed, format version 2, strict loading with path errors.
2. **Compositor**: the tree with closed nested timelines, Transform steps
   with folding and Moves Anchor, transitions last, one compositor for
   viewer and export, the new render key.
3. **Effects panel**: library, stack editing, keyframe lanes and playhead.
   Remove the timeline's property rows and the inspector's transform
   section.
4. **Blending**: one Metal kernel per mode, using the formula above.
5. **Color**, with its working spaces.
6. **Reading aids**: dimming, thumbnails, Show Up to Here.
7. **Pushing transforms into nested timelines.**
8. **Adjustment layers** with reach.

## Not decided yet

- The working space for Color on HDR timelines.
- The size of the canvas margin.
- Copying and pasting effects or whole stacks between clips, and saved
  presets.
- What a Blending step on an adjustment clip blends against (the adjusted
  picture with the unadjusted one, most likely).
