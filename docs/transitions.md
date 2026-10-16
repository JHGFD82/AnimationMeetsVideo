# Transitions

Status: **implemented**. 25 kinds in five categories, each with the
settings it needs, drawn the same in the viewer, background renders and
export. How transitions are placed, joined across cuts, resized and
curved is in [timeline.md](timeline.md#transitions); this document covers
what each kind does and how it's drawn.

## Counting kinds

A kind is a different way of getting from one picture to the next. Two
transitions that differ only in timing (length, curve, keyframes) or in a
setting (direction, color, center, shape, count, amount) are the same
kind. So there is one Wipe with a direction, not four wipes.

## Categories and kinds

The transitions panel groups kinds by what they do to the pictures.
"Before" is the picture the transition starts on, "after" the one it ends
on (see [Two pictures](#two-pictures)).

### Dissolves: the pictures are blended; nothing moves

| Kind | What it does | Settings |
| --- | --- | --- |
| Cross Dissolve | Fades one picture into the other. | |
| Film Dissolve | The picture after shows brightest parts first (`LumaReveal`). | |
| Dip to Color | Fades out to a color, then in from it. | Color (black) |
| Additive Dissolve | Each picture stays at full strength through its half, so the middle is both added, as a film lab's. | |
| Channel Dissolve | Red crosses over first and blue last, so color fringes pass through. | |
| Blur Dissolve | Both pictures blur toward the middle while they cross, up to 6% of the width at full amount. | Blur (50%) |

### Wipes: a shape uncovers the picture after; neither picture moves

| Kind | What it does | Settings |
| --- | --- | --- |
| Wipe | A straight edge moves across. | Direction (right) |
| Iris | A shape grows from a point until it covers the frame. | Shape: circle, diamond or box; center |
| Clock Wipe | A hand sweeps clockwise from twelve o'clock. | Center |
| Blinds | Strips across the way it moves, each opening from its side. | Direction (right), strips (8) |
| Grid | Cells turn over one after another, each over 30% of the transition. | Columns (8), order: random or diagonal from the top left |
| Matte Wipe | Reveals the brightest parts of a map first. | Map: noise (a pixel dissolve) or the first frame of a video in the project |

### Moves: the pictures move flat on the screen

| Kind | What it does | Settings |
| --- | --- | --- |
| Slide | The clip slides in over the picture under it, or out off it. | Direction (right) |
| Push | Both move together, the picture after pushing the other off. | Direction (right) |
| Split | The picture before opens in two halves: sideways for left or right, up and down for up or down. | Direction (right) |
| Zoom | The clip grows from the center as it fades in. | |
| Cross Zoom | The picture before rushes toward the camera with a zoom blur and the one after settles out of the same rush. | Center, blur (50%) |
| Spin | The clip turns once about the center while it grows and fades. | |

### 3D: the pictures move in space, in perspective

| Kind | What it does | Settings |
| --- | --- | --- |
| Flip | Turns over like a card, the picture before on its front and the one after on its back. | Direction (right): left or right turns about an upright axis, up or down about a level one |
| Cube | Two faces of a cube turn a quarter turn; the pictures travel in the direction set. | Direction (right) |
| Page Curl | The picture before peels away like a page. | Direction (right) |

### Stylized: the pictures themselves are altered

| Kind | What it does | Settings |
| --- | --- | --- |
| Pixelate | Blocks grow to their largest halfway, where the pictures change, then shrink. Up to a tenth of the width at full size. | Block size (50%) |
| Ripple | Rings spread from a point and carry the picture after in. | Center, wave height (50%) |
| Glitch | Color channels pull apart and bands tear sideways, most in the middle; the cut is halfway. | Intensity (50%) |
| Morph | Both pictures are pulled along the motion between them while they dissolve, so a shape moves across instead of fading twice. | Motion (100%) |

Moves and 3D kinds start with the Easy Ease curve, the rest with Linear.

## Settings

Set in the inspector, under the transition's length. Every transition
carries the same fields (`TransitionOptions`); each kind lists those it
offers (`TransitionKind.settings`), and only those are saved, in the
transition's entry in `project.json`:

```json
{ "kind" : "iris", "duration" : "1s", "shape" : "diamond", "center" : [0.25, 0.5] }
```

Centers are fractions of the frame from its top left; colors are red,
green and blue from 0 to 1, in the timeline's encoded values. Changing a
transition's kind keeps the settings both kinds offer. Projects saved
when each wipe and slide direction was its own kind (`wipeLeft`,
`slideRight`, ...) load as Wipe or Slide with that direction.

## Rendering

Every transition is drawn by `LayeredCompositor`, in the viewer and in
export, below the clip's effect stack (see [effects.md](effects.md)).

### On the clip alone

Cross Dissolve, Wipe, Slide, Zoom and Spin set the opacity, transform and
crop of the clip's finished picture (`EdgeTransitions.effect`). The film
dissolve keys it on brightness (`LumaReveal`).

### Two pictures

The other kinds need the picture before as well as the clip
(`TransitionKind.drawsTwoPictures`). `LayeredCompositor` gives them two
whole pictures:

- On a way in, before is what's under the clip (lower layers, or the
  outgoing clip's extra frames at a joined cut) and after is the clip
  over that.
- On a way out, before is the clip over what's under it and after is
  what's under it.

`TransitionRenderer` draws the frame between them, which replaces both
(`Drawing` in `LayeredCompositor.swift`, after the clip's shutter). Each
frame's transition state (`TransitionFrame`) is part of the render
cache's key. On a pass-through nested clip, before is what's under it
and after is its layers drawn over that.

- **Wipes** draw a mask with Core Graphics (`TransitionMasks`), at most
  640 points wide and scaled up smoothly, and show the picture after
  through it.
- **Matte Wipe** maps are noise, generated by Core Image and the same
  every time, or a video's first frame. Video frames are loaded while
  the composition is built (`MatteMaps`), since the compositor draws
  synchronously, and kept until the file changes. That file's stamp is
  part of the render key. A map that can't be read falls back to noise.
- **Flip and Cube** turn each picture in space, project its corners from
  a camera twice the frame's size away, and place it with Core Image's
  perspective transform. Page Curl and Ripple use Core Image's own
  transitions.
- **Glitch** draws its breaks from a fixed sequence that changes 24 times
  over the transition, so every render of a frame is the same.
- **Morph** measures, for each frame, the motion at each point of that
  frame (`BlockMatchFlow`): the move that best lines up the picture
  before, looked at back along the share of the move made, with the
  picture after, looked at forward along the rest. It matches 4-pixel
  blocks of gray copies 192 points wide, coarse to fine. Where a shape
  crosses a plain background it prefers the move that lines up what
  stands out. Each picture is then warped part way along that motion
  (`MorphFlow`), by a kernel Core Image compiles at runtime from Metal,
  or from its older kernel language where it can't compile Metal, and
  the two dissolve. Optical flow such as Vision's isn't used: it gives
  motion at points of the picture before, which leaves nothing where a
  shape passes through, and it needs hardware a virtual Mac may lack.
  If the kernel can't compile, a morph is a cross dissolve.

### Limits

- A transition drawn from two pictures acts on the whole frame of the
  timeline the clip is in, even on a clip its stack has scaled down.
- It is drawn after the clip's Shutter, so motion blur covers the clip's
  own motion but not the transition's.
- Additive Dissolve, Channel Dissolve, Glitch, Flip and Cube draw over
  black where their pictures are transparent, so they are opaque.
- A Morph between shots that share nothing moves little and looks like
  a dissolve; it's for matched shots. Its motion is coarse, a block 1/48
  of the frame wide, so fine detail moving differently from its
  surroundings blurs rather than moves. It measures motion on every
  frame, on the CPU, so it's the slowest kind to preview until its
  render is done.

## Not yet

- A matte wipe that plays its video along with the transition, or reads
  another layer, rather than one still frame.
- Softness for Wipe, Iris and Clock Wipe edges.
- Previews of each kind in the panel.
