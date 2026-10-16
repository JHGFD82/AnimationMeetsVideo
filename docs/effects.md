# Effects

Status: **built** (see [Building it](#building-it) for each step and what
it leaves out). This replaces the layer
transforms in [layer-transforms.md](layer-transforms.md): transforms move
from layers to clips and become effects. Keyframes, easing, the graph
editor and arithmetic in numeric fields carry over unchanged.

## Guiding principle: gravity

What is above acts on what is below. In a clip's stack, each control works
on the picture handed down from the ones above it. On the timeline, a clip
blends onto the layers below it. Every other rule follows from this:

- Time is the top of everything: a clip's speed, frame blending and echo
  decide which source frames the rest of the clip receives (see
  [Time and Shutter](#time-and-shutter)).
- The anchor point is pinned at the top of the stack, so it affects every
  step.
- An effect only reads from above: a Blending step can blend against an
  earlier step's picture, never a later one (see [Against](#against)).
- Transitions are pinned at the bottom of the stack, so they act on
  everything above them, and the Shutter (motion blur) sits below them,
  blurring the motion of all of it.
- A nested timeline is a closed container: what falls inside it never
  lands on the timeline it is placed in, except through its alpha, unless
  it is set to [pass through](#pass-through).
- Pictures an effect uses as input (a matte, a map) aren't layers, so
  they're nowhere in the order: they come from the browser (see
  [Inputs](#inputs)).
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
longer have a transform. Animation across several clips goes on an
adjustment layer (see [Adjustment layers](#adjustment-layers)). Volume
moves to clips too (see [Volume](#volume)).

Every visual clip also has an **anchor point**, the one control that isn't
an effect. It is the point that scale and rotation turn about, given as an
offset from the center of the clip's picture, in timeline pixels at 100%
scale. Its default is (0, 0), the center. Because it is relative to the
fitted picture, not to the media's pixels, replacing the media with a
different resolution keeps it in place. It can be keyframed.

### Source time

Keyframes, inputs and Time all count in a clip's **source time**:

- For a media clip, the media's **original** time, the same time trims and
  scenes are stored in. Replacing the media with a version that has an
  alignment offset (see [media-replacement.md](media-replacement.md))
  shifts the frames read, not the animation, so moves stay on the picture.
- For a nested timeline, that timeline's time.
- For a still (and later text and shapes), which has no time of its own,
  the time since the clip's start.

**Splitting** a clip gives each half a full copy of its stack, anchor
point, Time, Shutter and volume. Since keyframes are in source time, each
half keeps exactly the animation it showed before; nothing is lost, so no
[paste changes](#paste-changes) are raised.

## Volume

Planned changes to [audio.md](audio.md):

- **Every clip with sound has a volume**: media clips with sound, audio
  clips and nested timelines. It works as layer volume does today
  (decibels, −60 to +6, keyframed in source time, blending in decibels).
- **Sound and Music layers keep a layer volume** as well, applied after
  the clip's: the clip sets its own level, the layer acts as a fader over
  everything on it. This leaves room for buses and other mixing that a
  DAW does at the track level.
- **Video layers have no layer volume**, only their clips do.
- Detaching a video clip's sound gives the new sound clip the same clip
  volume.
- A clip's volume is a pinned row at the bottom of the effects panel, below
  Shutter, since sound comes after pictures. An audio clip, which has no
  stack, shows only this row. The **L** key's row in the timeline stays
  the layer volume on Sound and Music layers; clip volume is drawn as a
  line across each clip block while L is on.

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
  the same picture in any order within a Transform effect, as long as
  Scale is uniform: a stretch (x and y apart) works along the screen's axes,
  so it doesn't commute with a turn. Order matters across effects with
  other steps between them, and when an effect doesn't move the anchor.
- **Moves Anchor** (in the effect's ⋯ menu, checked by default): unchecked,
  the effect's Position moves the picture but leaves the anchor at its spot
  in the frame. Later scales and rotations then turn the picture about that
  fixed spot, so a rotation after an unanchored move orbits it.

### Blending

Three controls:

| Control | Default | Does |
| --- | --- | --- |
| Mode | Normal (a no-op) | Darken, Multiply, Color Burn, Linear Burn, Lighten, Screen, Color Dodge, Add, Overlay, Soft Light, Hard Light, Difference, Exclusion, Subtract, Divide, Hue, Saturation, Color or Luminosity. |
| Amount | 100% | How much of the blend is applied: at 0% the step is a no-op, in between the clip's color is mixed toward the blended one. Unlike Opacity it doesn't change the clip's alpha. |
| Against | Backdrop | What the clip is blended with: the backdrop, or the clip's own picture before an earlier effect in the stack (see [Against](#against)). |

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
there against the backdrop does nothing. The panel says so.

#### Against

A Blending step can also blend the clip with **an earlier version of
itself**: Against lists the effects above the step, and picking one blends
against the picture as it was just before that effect. The classic use is a
glow: Blur, then Blending set to Screen against "Before Blur" screens the
blurred picture over the sharp one, in one stack, with no duplicate layer.

The formula is the same with the earlier picture in place of the backdrop.
One difference: both pictures are the clip's own, so the result keeps both,
drawn as the current picture blended over the earlier one (alpha as in
normal compositing over it). Against the backdrop only the clip's alpha is
kept, since the backdrop is drawn under it at the end anyway.

Against stores the effect's ID. If that effect is deleted, or dragged
below the Blending step, the step can't read it (it only reads from
above), so it does nothing and is dimmed with a note until it is pointed
somewhere else.

On an adjustment clip, Backdrop means the picture the adjustment receives,
unadjusted, so a Blending step there blends the adjusted picture with the
unadjusted one.

### Color

The controls other apps put under color correction, each a step of its own
and each a no-op by default: Exposure (stops), Contrast, Saturation,
Temperature, Tint, and Lift, Gamma and Gain (each per channel and overall).

Transform and Blending work on the frame's encoded values without color
management, as rendering does today. Color steps are the exception: they
convert to the working space each control needs and back, so a grade
looks the same whatever the timeline's color space (which matters, since
footage gets replaced):

- **Exposure, Temperature, Tint and Gain** work in linear light, on every
  timeline.
- **Contrast, Saturation, Lift and Gamma** work on one log curve shared by
  SDR, PQ and HLG timelines (one like ACEScct), not on the timeline's own
  encoding. On a timeline's stored values the same Contrast would look
  different on PQ than on HLG or Rec. 709.

## Mattes

The second category is **Mattes**, effects that take an input (see
[Inputs](#inputs)). **Matte** cuts the clip with its input.

- **Mode** picks what is read from the input: **Alpha** shows the clip
  where the input is opaque, **Luma** where it is bright (Rec. 709 weights,
  over black where the input has no picture), and **Inverted Alpha** and
  **Inverted Luma** the opposite. Gray is a partial cut.
- **Amount** mixes the cut in, 0% to 100%. At 0% the step does nothing.
- The input is fitted into the frame and stays there. Outside its own
  picture it is empty: transparent for Alpha, black for Luma.
- Without an input, or when the input's media is missing, the effect does
  nothing and is dimmed with a note in the stack.
- Drawing: a Matte step ends a run of moves, like a Blending step, since it
  needs the picture as it is at that point.

## How a clip is drawn

For each frame, each clip goes through:

1. **Time**: which source frames the clip shows at this moment, after its
   speed, frame blending and echo.
2. **Source**: those frames, oriented and fitted into the timeline's
   frame, centered (as 100% scale is today). A nested timeline is drawn
   first, on its own (see below).
3. **Stack**: each enabled effect, top to bottom, and within it each
   enabled control that isn't at its default.
4. **Transition**: the clip's transitions, if any. They aren't effects:
   they are pinned below the stack. A dissolve fades the stack's result, a
   wipe crops it in frame coordinates, and a film dissolve keys on it or on
   the backdrop.
5. **Shutter**: with motion blur or trails on, steps 1–4 are drawn at
   several moments and combined.
6. **Composite**: drawn normally over the backdrop.

### Nested timelines are closed groups

A nested timeline draws over transparency, never over the timeline it is
placed in. Its result is one picture with an alpha channel, which then goes
through the nested clip's own stack and transitions like any other clip.
Nothing inside a nested timeline sees what is under it in the parent; only
its alpha shows through. The root timeline draws over black.

This replaces flattening. Today nested timelines are flattened into one
stack of tracks; instead the compositor gets a tree and draws each nested
timeline into an image of its own.

#### Pass through

A nested clip can be set to **Pass Through** (in its ⋯ menu; off by
default). Its timeline's layers are then drawn straight into the parent, as
if they were on the parent's timeline at that spot, so they blend with
whatever is under the nested clip. With no single group picture, the
nested clip's own stack can only hold steps that work layer by layer:

- **Position, Scale and Rotation** are applied to each layer inside, which
  gives the same picture.
- **Opacity**, a dissolve, and motion blur are applied to each layer
  inside. Where those layers overlap this differs from applying them to the
  group, and the panel notes it.
- **Time** retimes the nested timeline as usual.
- **Everything else** (Blending, Color, neighborhood effects, wipes, the
  film dissolve) needs one combined picture, so it is dimmed with a note
  and does nothing while Pass Through is on.

Pass-through nested clips cost no more to draw than the layers they hold.

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
  frame, so a later step can bring them back, up to a margin of half the
  frame's width and height on each side (twice the frame's area). A
  project setting, **Canvas Margin**, allows more for the rare stack that
  needs it; a full frame on each side is nine times the area, which is a
  lot of memory at 4K. Chains without a neighborhood step have no such
  limit, since nothing is drawn until the end.

### One compositor

The viewer and export both draw through `LayeredCompositor`. The built-in
AVFoundation compositor is no longer used, and the test that the two match
goes away. A stretch with one clip whose stack and anchor point are at
their defaults, with no transition, still plays straight from its file.
Everything else is drawn by the compositor and rendered in the background
as today ([rendering.md](rendering.md)). The render key hashes each clip's
resolved steps on every frame, after folding, plus the nesting.

## Time and Shutter

Effects that change time aren't in the stack. They sit above it and below
it, set on the clip in the timeline (its ⋯ menu, with a small mark on the
clip block) and shown in the effects panel as pinned rows: Time above the
anchor point, Shutter below the transitions.

**Time** decides which source frames the clip receives, so everything else
works on frames already chosen:

- **Speed**: a percentage, which can be keyframed for speed ramps, with
  the same eases and graph editor as any control. Speed keyframes are in
  source time like all others. Speed decides how much source time passes,
  so the clip's length on the timeline follows from it: dragging the
  clip's end trims the source, it never stretches the clip.

  How long a ramp lasts is the integral of 100 / speed over the source
  time it plays, taken from the curve itself (its eases included, speed
  clamped to 1%...10000%). `SpeedIntegral` computes it once per speed curve
  with adaptive Gauss-Kronrod and keeps the edges of its cells and the
  integral up to each, so a lookup finds its cell by binary search and
  integrates only the part of it before the query, and the inverse
  (timeline time to source time) solves inside one cell by Newton's method
  with a bisection fallback. The accuracy budget, in seconds of timeline
  time: each piece between keyframes within 1e-8 of the true integral
  (`pieceTolerance`, split among its cells), a query inside a cell within
  another 1e-8, the curve read at exact `Double` times rather than a CMTime
  grid, and the inverse within 1e-9 of its target. All of it sits far below
  the 1/240000 s a placed time is rounded to. Tests check it against a
  separate reference (its own Bézier, a fine partition cut at the clamp's
  kinks, adaptive Gauss-Kronrod), for whole pieces, partial cells, cell
  edges and the inverse, on curves that stress it (1% to 10000% in half a
  second, sharp and full-width handles, overshoot past the clamp). An
  earlier fixed 24-step Simpson sum read 5% to 3000% over 40 s as 16.3 s
  for 8.54 s; project files saved with it keep their stored times, so a
  ramped clip's end moves to the true length, and nothing migrates them.
- **Frame Blending**: Off, Blend (mix the two nearest frames when the
  speed doesn't land on whole frames), or Optical Flow (build in-between
  frames from Vision's optical flow). Optical Flow is too slow to draw
  live, so it is drawn only in background renders and export; until a
  stretch is rendered, the viewer shows it with Blend.
- **Echo**: earlier source frames layered under the current one, with a
  count, a delay and a decay.

- **Sound**: what a retimed clip's sound does when Speed isn't 100%.
  **Keep Pitch** (the default) plays it at the new speed at its own pitch.
  **Change Pitch** speeds it up and slows it down like tape, pitch and all.
  **Mute** silences it while the speed isn't 100%. Keep Pitch and Change
  Pitch map to AVFoundation's time-pitch algorithms on the clip's audio
  mix track (`.spectral` and `.varispeed`), so they work in playback and
  export alike.

Keyframes are in [source time](#source-time), so retiming a clip retimes its animation too:
at 50% the clip and its moves both play at half speed. To animate at a
steady speed over retimed footage, animate an adjustment layer instead.

**Shutter** acts on the finished clip, so it covers motion from every step
above, the transition included:

- **Motion Blur**: a shutter angle (180° to start) and a number of samples
  (8 to start, 2 to 64). The clip is drawn at that many moments across the
  shutter and averaged. While playing, the viewer draws 2 samples, or none
  at Quarter quality. Paused frames, background renders and export use the
  full count, so a rendered stretch plays back fully blurred. **Motion Blur
  in Preview**, in the viewer's menu and remembered per Mac like the
  quality setting, turns it off in the viewer altogether.
- **Trails**: copies of the finished clip from earlier moments, with a
  count, a delay and a decay. Unlike Echo, these include the clip's
  movement, which After Effects can only do by precomposing.

Both cost as many draws of the clip as they have samples or copies, and are
rendered in the background like everything else.

## Inputs

Some effects take a second picture: a matte that cuts the clip, a map that
displaces it, a source for a light wrap. That picture comes from the
**browser**, not the timeline. It is dragged from the browser into the
effect's drop zone in the effects panel. It can be a media clip
or a nested timeline, and it never takes up a layer: it belongs to the
clip, as part of the step.

- **Where it sits follows the order.** The input is fitted into the frame
  at its step and stays put. A Matte step above a Transform cuts the clip
  before it moves, so the mask travels with the clip. Below the Transform,
  the clip moves under a fixed mask.
- **When it plays**: a moving input starts with the clip, with an offset,
  and either holds its last frame or loops at its end.
- **Animating it**: an input has no stack of its own. To animate a mask,
  drop in a nested timeline that animates it.
- An input is tracked like any other use of its media: replacing the media
  updates it, missing media is reported, and a nested timeline used as an
  input inside itself is rejected as a cycle.

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

- **Reach stops at the edge of its own timeline**, even inside a nested
  timeline set to pass through, so an adjustment inside a nested timeline
  never reaches into the timeline it's placed in.
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

The area to the right of the viewer has two tabs, **Inspector** and
**Effects** (the effects panel), and a button in the timeline's header
shows or hides it. Picking a tab is the only thing that changes it, apart
from applying an effect to the selected clip, which shows the Effects tab.
The Effects tab is resizable by its left edge.

The **browser** at the right end of the timeline has tabs too: **Effects**
(the library, grouped by category, Foundations first) and **Transitions**.
One button in the timeline's header shows or hides it, and opening it
changes nothing else. Drag an effect onto a clip or into the stack, or
double-click it to add it to the end of the selected clip's stack.
Dropped on an effect row, it goes in at that place; dropped anywhere else
on the stack, or on a clip, it goes at the end. Either way it is selected.
VoiceOver's Add to the Selected Clip action does what double-clicking
does.

A clip, the stack and each effect row take every kind of drag they use
through one drop target, since the app's drags all travel as URLs: with
one target per kind, only one of them ever received a drop, and effects
dragged onto a clip or the stack were refused.

The Effects tab is the selected clip's **stack**, framed by pinned rows that can't be
moved: Time and the anchor point above it, the clip's transitions (if any)
and Shutter below it, in the order they are drawn. Clicking a transition
row selects it, as clicking it on the timeline does.

- Each **effect** row has a drag handle, a disclosure arrow, an
  enable checkbox, its name and a **⋯** menu: Duplicate (Cmd-D), Reset,
  Rename, Enable/Disable, Delete, Show Up to Here, and, on Transform, Moves
  Anchor. New effects are numbered by kind ("Transform 2") so that rows
  and graph editor titles can be told apart; renaming replaces the number.
- Each **control** row has the stopwatch, its name, its values (fields
  take arithmetic) and the keyframe buttons ◀ ◆ ▶. It also has the graph
  button, which opens the existing graph editor HUD ("Clip 3 · Transform 2 ·
  Position"), and a **⋯** menu: Reset, Enable/Disable, Delete.
- Effects are dragged to reorder within the stack. Controls are dragged to
  reorder within their effect.
- The Delete key deletes the selected effect or control.
- The panel opens with **Shift-E** or its button in the timeline's header.

### Changing values by dragging

Every numeric value in the panel, and every other value field that takes
arithmetic, can also be **dragged**: press on it and drag left or right to
lower or raise it. A press without a drag still opens the field for typing.

- One point of drag is one step of the value's unit: a pixel, a percent, a
  degree, a tenth of a stop or a decibel. **Shift** makes it ten steps,
  **Option** a tenth of one.
- The pointer is hidden and held in place while dragging, so a drag can go
  on past the edge of the screen, and reappears where it started.
- The viewer follows the drag live. Letting go saves it as one undo step.
  On an animated control it sets the keyframe at the playhead, as typing
  does. Escape during a drag puts the value back.
- Linked Scale changes both axes; a value with two parts (Position x and
  y) drags the part pressed.
- The project settings sheet's width, height and frame rate don't drag:
  a slip there would change the whole timeline.

### Keyframes in the panel

The panel has its own ruler and playhead, spanning the selected clip. To
the right of each control row is its keyframe lane, with the same diamonds
and interactions as the timeline's lanes today: click to go to it, drag to
retime, right-click for ease presets and Delete Keyframe. The panel's
playhead is the timeline's: scrubbing either moves both.

Keyframes are in the clip's [source time](#source-time). Moving a clip
carries its animation along. Trimming its start doesn't shift the animation against
the picture. Keyframes outside the trimmed range are kept but don't play.

The timeline no longer has per-layer property rows or the P, S, R and T
keys. A clip block with effects shows a small badge with the count.

### Reading the stack

- **No-ops are dimmed**: a control at its default, a disabled control or
  effect, and an effect whose controls are all no-ops. A Blending step with
  nothing under it, or Against an effect that is gone or below it, is
  dimmed with a note, as are steps a pass-through nested clip can't apply.
- **Each effect shows a thumbnail** of the clip's picture after it, at the
  playhead, drawn small and refreshed when the playhead stops.
- **Moved from the timeline.** The graph editor HUDs, the F9 ease keys
  (which act on the keyframes at the playhead in the panel's shown rows),
  the keyframe buttons and Reset (in each ⋯ menu) work on effect controls
  as they work on layer properties today.
- **Show Up to Here** shows the clip in the viewer as it is after that
  effect, with later effects and the transition skipped, until it is turned
  off. The viewer shows a banner while it is on.

### Copying and presets

- **Copy and paste** work on the effects selected in the panel. Pasting
  onto a clip adds them below the selected effect, or at the bottom of the
  stack. **Paste Effects** with clips selected on the timeline replaces
  their whole stacks.
- **Presets**: selected effects can be saved as a preset, which is shared
  by every project. Presets are files in `~/Library/Application Support/
  AnimationMeetsVideo/Presets/`, one JSON file each, and appear in the
  browser's **Presets** section, where they can be renamed, deleted or
  shown in the Finder. Drag one onto a clip, or into a stack at a spot.
- **What travels.** Keyframe times are stored from the start of the
  source clip's trimmed range and land at the same distance from the start
  of the clip they're pasted onto. Effects get new IDs, and Against follows
  them when the effect it reads came along, or goes back to Backdrop when
  it didn't. Inputs stay behind, since their media belongs to a project:
  a pasted or preset effect's drop zone is empty.
- **Every change is flagged** (see [Paste changes](#paste-changes)).
- A preset file uses the same JSON as effects in `project.json`, with its
  own `formatVersion`, and is read just as strictly. One that can't be read
  shows in the browser with the same message and path, and isn't used; it
  never stops anything else from loading.

### Paste changes

Pasting or applying a preset can't always bring an effect over exactly.
When it doesn't, the effect is flagged, as Track Changes would in Word, so
nothing is lost silently. A **paste change** is recorded for each of these:

- An input was left behind: "Input left behind (was Logo matte.mov)."
- Against went back to Backdrop: "Against reset to Backdrop: Before Blur
  wasn't pasted."
- Keyframes landed outside the clip it was pasted onto, so they don't play:
  "3 keyframes fall past the end of this clip."

A flagged effect has a marked edge in the stack, and its changes are
listed under its name, each with a **Mark Resolved** button. Fixing the
problem (dropping in a new input, for example) doesn't resolve it by
itself; the person marks it once they're satisfied. The effect renders as
it stands meanwhile, so the result can be checked while fixing it. A clip
with unresolved changes shows a mark on its block in the timeline.

**Unresolved changes block export.** The editor's toolbar shows how many
there are, across every timeline the export draws (nested ones too).
Clicking that count, or trying to export, opens the **Paste Changes**
list: each change with its timeline, clip and effect, a button to go to
it (selecting the clip and opening the effects panel at that effect), and
Mark Resolved. **Accept All** resolves every change in the list and lets
the export go ahead. Marking and accepting can be undone.

Paste changes are saved with the project, so they survive closing it.

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
only as `false`. A Blending step's `against` holds the effect ID it reads,
written only when it isn't the backdrop. An effect with an input has
`input` (`{"asset": "…"}` or `{"timeline": "…"}`, plus `offset` and
`"loops": true` when set). An effect has `pasteChanges` only while
some are unresolved, each with its `kind` (`"inputLeftBehind"`,
`"againstReset"` or `"keyframesOutside"`) and what it was (the input's
name, the effect read, the keyframe count). A clip has `time` and
`shutter` only when they aren't off, and a nested clip `"passThrough": true` only when set. The
project has `canvasMargin` only when it isn't 0.5 (of a frame, on each
side). Keyframes are written as layer transforms' are today
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

## Testing

The test that the built-in and custom compositors draw the same picture
goes away with the built-in compositor. In its place:

- Reference frames for each effect and blend mode, compared within a small
  tolerance.
- Folding, pushing transforms into nested timelines and skipping
  equivalent intermediates each checked against drawing every step
  separately, on the same stacks.
- Strict loading checked against a file per kind of error, for the message
  and the path.

## Not in this plan

- **Dragging in the viewer** (on-screen handles for position, scale,
  rotation or the anchor point). Handy as a shortcut, but easy to trigger
  by mistake; left out until there's a design that avoids that.

## Building it

In order, each step usable on its own:

1. **Model and saving** (done): anchor point, stacks and volume on clips,
   layer transforms and video layers' volume removed, format version 2,
   strict loading with path errors. The renderer already draws a clip's
   Transform steps (folded into one matrix per clip, through the existing
   compositors); there is no editing UI for stacks until step 3, so the
   timeline's property rows and the inspector's transform section are gone
   for now and a stack can only be written in `project.json`. Clip volume
   is set in the inspector.
2. **Compositor** (done): the tree with closed nested timelines and Pass
   Through, Transform steps with folding and Moves Anchor, transitions below
   the stack, one compositor for viewer and export, the new render key.
   The model has `passThrough` on a nested clip and saves it; the toggle
   in the clip's menu comes with the panel in step 3. Pass Through applies
   a nested clip's Position, Scale, Rotation, Opacity and its dissolve,
   slide and zoom to each layer inside (a Blending step inside a pass-through
   group that has its own placement blends in the placed frame).
3. **Effects panel** (done): library, stack editing, keyframe lanes and
   playhead, dragging values, clip volume. The timeline's property rows and
   the inspector's transform section were removed in step 1. The panel
   shows what exists so far: Pass Through, the anchor point, the stack,
   the transitions and Volume; Time and Shutter, Against, dimming,
   thumbnails and Show Up to Here come with their steps, and copy, paste
   and presets with step 12. It is resizable by its left edge. Moving or
   dropping an effect, deleting it (Delete) and duplicating it (⌘D) are
   undoable, and a value drag is one undo step.
4. **Blending** (done): one Metal kernel per mode, using the formula above,
   and Against. The kernels (`BlendKernels`, compiled from source at run
   time) run inside the Core Image graph as an image processor
   (`BlendProcessor`), over the part of the picture within the canvas. They
   are checked against a separate restatement of the formulas for every
   mode. A step blends with the backdrop as it was drawn when the clip's
   turn came; a layer inside a pass-through nested clip is placed first,
   so it blends with what is under it where it lands. The
   panel's Against row lists the effects above the step; one that is gone or
   below shows "Unavailable" and the step does nothing (dimming and notes
   come with step 6). A stretch with a Blending step is rendered in the
   background like other costly stretches.
5. **Color** (done), with its working spaces. One Metal kernel
   (`ColorKernels`) grades a run of Color steps in the order listed,
   converting between encoded values, linear light and the log curve only
   when a step needs a different one. Linear light is scaled so 1.0 is
   reference white (100% on Rec. 709, 203 nits on PQ, a 75% signal on HLG)
   and the log curve is ACEScct's. Exposure is in stops, Temperature and Tint
   run -100...100 (up to half a stop of red against blue, and of green
   against red and blue), Contrast and Saturation are percentages, and Lift,
   Gamma and Gain have four values (all, then red, green and blue). Contrast
   pivots about mid gray; Lift adds to the blacks, fading to nothing at white
   (the log curve's value for 1.0); Gamma bends the tones between them. A run
   of Position, Scale, Rotation, Opacity and Color steps is one move and
   one grade, since neither depends on the other. Checked against a
   double-precision restatement of the math in each space, and for the same
   light giving the same result in every space.
6. **Reading aids** (done): dimming, thumbnails, Show Up to Here. A control
   at its default, a disabled control or effect, and an effect whose
   controls are all no-ops are drawn faded. A Blending step is faded with a
   note when its Against effect is gone or below it, when it is on the
   bottom clip of a nested timeline (nothing under it), or when the clip
   passes through, as are Color and anything else that needs one picture
   (and wipes and the film dissolve among the transitions); an Opacity on a
   pass-through clip only gets a note, since it still applies, to each
   layer inside. Each effect row shows a thumbnail of the clip after it, at
   the playhead, refreshed about a third of a second after the playhead
   stops or the stack changes. Thumbnails draw the clip's own picture
   through the stack up to that effect over black, so what is under the clip
   isn't drawn and a Blending step blends with black. Show Up to Here is in
   each effect's ⋯ menu: the viewer builds the project with that clip's
   stack cut after the effect and its transitions dropped, shows a banner
   with a way back, and background renders wait; export is never affected.
7. **Pushing transforms into nested timelines** (done). A closed nested
   clip's leading Position, Scale and Rotation (with its transition's move,
   when nothing follows) are applied to each layer inside, drawn over
   transparency in the outer frame, and the result is limited to the nested
   frame (cropped, or masked when it is turned), with the nested clip's
   opacity on the whole. Core Image already folds plain moves through
   composites, so the difference shows when a pixel step (Blending or Color)
   sits inside: those run as their own passes, and would otherwise run at
   the nested frame's size and be enlarged. To get that, a layer's placement
   in the frame it is drawn into (here, and for pass-through) is applied to
   its picture first, and its own moves are conjugated to work in the placed
   frame, which is the same picture. `EffectKind.dependsOnPixelSize` (false
   for every effect so far) stops the push at a nested timeline holding an
   effect whose result changes with pixel size.
8. **Adjustment layers** with reach (done). An adjustment layer is a video
   layer flagged `isAdjustment`, holding adjustment clips (`ClipSource.adjustment`:
   no media, any length, and keyframes count from the clip's own start). The
   timeline header's button adds one at the top of the stack, spanning the
   timeline, and its header menu sets Reach to every layer below or down to
   any layer under it. Reach is saved as the layer's ID (`reach`, written only
   when it isn't every layer below), goes back to every layer below when that
   layer is deleted, and reaches nothing, with a note in the panel, when the
   layer is moved above the adjustment. A bracket along the adjustment
   layer's left edge spans the layers it reaches. Drawing follows the
   Below / With / Adjusted / Coverage / Result steps above: the tree gives
   each adjustment the clips of the layers it reaches (`DrawClip.assembled`,
   lowest adjustment first, so one reaching down to another gets it as it is
   adjusted), the layers are drawn once over Below and once alone for their
   alpha, and the result is a Core Image alpha-mask blend of Adjusted over
   Below. Reaching every layer below uses a full-frame coverage. Inside a
   pass-through nested clip an adjustment adjusts only that timeline's
   layers, which then go over what is there. An adjustment's Opacity,
   dissolve, slide and wipe act on the coverage and the adjusted picture; the
   film dissolve isn't applied to it. A stretch where one plays is rendered
   in the background, and the timeline is cut where it starts and ends.
   Adjustment layers take only adjustment clips and other layers none.
9. **Time and Shutter** (done): speed with its three Sound choices, Blend,
   Echo, Motion Blur and Trails. A clip's `time` (speed, frame blending, echo,
   sound) and `shutter` (motion blur, trails) are on the clip, set from its
   menu and in the effects panel's pinned Time rows (above the anchor point)
   and Shutter rows (below the transitions). `trimmedDuration` is still the
   source range's length; the new `placedDuration` is how long that lasts on
   the timeline, and `timelineTime(forSourceTime:)` and
   `sourceTime(atTimelineTime:)` map between the two for constant speeds
   (exactly, for whole percents) and for ramps (by integrating the reciprocal
   speed). Trimming, splitting, moving, slipping, waveforms, beat markers
   and the panel's keyframe lanes all go through them. Retiming a clip
   (`editTime`) keeps its end on a frame and moves the clips after it by as
   much as its end moved. Retimed clips don't join transitions. In the
   composition a retimed clip's footage is a piece scaled to its length on
   the track (`scaleTimeRange`), or for a ramp a piece every four frames,
   each at the speed it has there. Blend adds a track of the same footage one
   source frame later and mixes the two by how far between frames the moment
   falls; Echo and Trails add tracks of the footage later by each copy's
   delay, so each moment has the earlier one to show. They're
   drawn only where all their tracks have frames, so the timeline is cut
   where they start and end. Echo layers the earlier source frames under
   the current one before the stack (time is above it); Trails draw the
   finished clip, stack and transitions evaluated at the earlier moment,
   under the current finished clip. Motion Blur draws the finished clip at
   that many moments across the shutter (`frameDuration × angle / 360`,
   centered on the frame) and averages them. While playing, the viewer
   draws two, or none at Quarter quality, and Motion Blur in Preview
   (the viewer's camera menu, remembered per Mac) turns it off there;
   `DrawingOptions` carries this to the compositor without rebuilding
   anything. Sound at other speeds is the host's audio time-pitch algorithm
   (Keep Pitch is `.spectral`, Change Pitch `.varispeed`) on a track of its
   own, or no track for Mute. A clip's volume keeps counting in source time
   through its speed (at the speed it starts at, for a ramp). Speed
   keyframes are in source time and can be set now (stopwatch and graph in
   the panel). Not yet drawn: Time (speed, blend, echo, sound) and trails on a
   nested timeline's clip, whose Time rows aren't offered
10. **Inputs**, with the first effect that takes one (a matte) (done). The
    Matte effect and its Mode and Amount; an input is footage or a nested
    timeline dropped on the effect's drop zone, with Offset and Loop. Footage
    gets a track of its own in the composition that starts with the clip
    (holding its last frame, or looping), and a timeline is drawn as one
    picture. The project file writes it as the effect's `input`
    (`asset` or `timeline`, `offset`, `loops`), allowed only on effects that
    take one. Missing footage leaves the effect dimmed and is reported
    with the asset, and inputs count as uses of the media when it is
    replaced. Not yet: stills are not a media kind, so an input is video
    footage or a timeline
11. **Speed ramps and Optical Flow** (done). Ramps came with step 9 (keyframed
    speed, with its eases and graph, integrated into the clip's length and
    drawn as a piece every four frames); this step checks them against
    footage and adds Optical Flow. Vision's `VNGenerateOpticalFlowRequest`
    estimates the motion from a frame to the next one on a copy at most 640
    pixels wide (accuracy High), and a Metal kernel (`interpolate_flow`)
    moves both full-size frames along it, the first back by the fraction
    and the second forward by the rest, and mixes them. It is drawn only
    when the compositor has no `DrawingOptions`, which is how background
    renders and export draw, so the viewer fades (Blend) while it plays or
    is paused on an unrendered stretch and shows the optical result once
    the stretch is rendered (a note under the Frames row says so). Where
    Vision or the Metal kernel can't run (a virtual Mac may lack the
    hardware), the motion is measured by block matching and the frames
    warped as a morph's are (see [transitions.md](transitions.md#two-pictures)),
    with the search kept to about a sixth of the width, since a far match
    in a repeating texture would only be wrong.
    Frames of different sizes fade.
    The flow is estimated again for each frame drawn between the same two
    source frames, which slow motion repeats; a cache of fields is the first
    thing to add if renders prove slow. Vision's flow runs a little short of
    large motions, so a frame is closer to its neighbors than the true
    in-between one when the footage moves fast
12. **Copy, paste and presets**, with paste changes and the export check
    (done). An `EffectBundle` is a set of effects taken from a clip's stack
    with their keyframe times counted from the source clip's trim start
    (`origin`), what their inputs and Against were called, and nothing
    else; `paste` puts one into a clip at an index or in place of the whole
    stack, giving every effect and control new IDs, shifting keyframes by
    the difference between the two clips' trim starts, numbering names that
    were automatic, and recording a `PasteChange` on the effect for each
    thing that didn't come along (`inputLeftBehind`, `againstReset`,
    `keyframesOutside` with its count, on the start or end side). Copy and
    paste work on the one effect selected in the panel (⋯ menu or
    Command-C and Command-V, which paste below it, or at the end of the
    stack with none selected); a clip's menu on the timeline has Copy
    Effects (the whole stack) and Paste Effects (replacing the stack).
    Presets are `PresetStore`'s files, one JSON each, with a `formatVersion`
    of their own and the effects as a project writes them (plus, for what
    was left behind, `inputName` and `againstName`), with times from the
    start of the clip. They are checked as strictly as a project, so a bad
    one is listed in the browser's Presets section with the path of the
    problem and skipped. Save as Preset and Save Whole Stack as Preset are in
    the effect's ⋯ menu; presets are dragged onto a clip's block or into the
    stack, renamed, shown in the Finder, or moved to the Trash from the
    browser. Unresolved changes are saved on the effect as `pasteChanges`;
    flagged effects get a marked edge and the changes listed under their
    name with Mark Resolved, and a flagged clip a warning mark on its
    block. The toolbar shows how many there are across the timelines the
    export draws (`timelineIDsDrawn`: nested ones and ones used as inputs)
    and opens the Paste Changes list, which Export opens too, instead of
    exporting, until nothing is left; Accept All resolves them all and
    carries on with the export. Go To selects the clip on its timeline and
    opens the effects panel at the effect. Not yet: selecting several
    effects at once, so copying several means copying the stack and
    deleting what isn't wanted
