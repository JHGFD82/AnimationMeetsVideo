# Images, shapes and text

Status: stills and the first shapes (rectangle and ellipse) are **built**
(steps 1 and 2a, not yet tried in the running app); the other shapes and
text are **planned** (see [Building it](#building-it)).
Pictures that don't come from footage:
still images imported from files, and shapes and text made in the app,
drawn as vectors.

## What they share

All three are visual clips like any other (see
[effects.md](effects.md#what-has-a-stack)): they have an effect stack, an
anchor point, transitions, Time and Shutter, and sit on video layers and
in nested timelines. Nothing about effects, keyframes or transitions is
special to them.

- **Source time** is the time since the clip's start, plus its trim start,
  as effects.md already says for stills. Keyframes count in it, so moving
  the clip moves its animation with it.
- **No end to run out of.** A still, shape or text clip can be trimmed as
  long as anyone wants, the way an adjustment clip can. Speed changes
  nothing a still shows, but still changes how its keyframes play.
- **No sound.** They never have volume, pan or sound effects, and never
  go on Sound or Music layers.
- **Drawn by the compositor.** They have no composition track. The
  compositor gets their picture from the drawing tree instead of from
  `request.sourceFrame(byTrackID:)`.

## Stills

A still is an asset like a video or an audio file: imported into the
browser, kept by path, never modified, and replaceable.

- **Kinds.** `MediaKind.image`, `"Image"` in the project file. Anything
  ImageIO reads as an image: PNG, JPEG, HEIC, TIFF, GIF, WebP, PSD (flattened)
  and camera raw files. An animated GIF or PNG shows its first frame.
- **Import.** The browser's Import panel takes image files.
  `MediaImporter` asks ImageIO for the picture's size, orientation and
  color profile without decoding it. The asset's codec is the file's type
  ("PNG", "HEIC") and its color space is Rec. 709 unless the picture is
  HDR (a gain map or a PQ or HLG profile), when it is the matching HDR
  space, just as for footage.
- **Length.** The asset's duration is the length a still gets when placed
  from the browser: 5 seconds. Its clips can then be trimmed out to any
  length (`sourceDuration(for:)` is unbounded, as for adjustments), and a
  transition at a cut has as much of a still as it wants on either side.
  Not yet: like an adjustment clip, a still's leading edge can't be
  dragged earlier than its source time 0, where it started.
- **Orientation.** The EXIF orientation is applied when decoding, so the
  picture is upright as the person sees it in Finder.
- **Color.** The compositor works on encoded values without color
  management (see [rendering.md](rendering.md)), so a still is converted
  once, when it is decoded, into the encoding of the timeline it is drawn
  in: Rec. 709 for SDR, PQ or HLG for HDR. On an HDR timeline an HDR
  picture's gain map is applied, so it stays bright; on an SDR timeline
  the SDR rendition is used.
- **Size.** Decoded at most at twice the size that fits the timeline's
  frame, and never more than 8192 pixels on its long side. Scaling a still
  up past 200% softens it; a 50-megapixel photo on an HD timeline doesn't
  hold 400 MB of half floats.
- **Transparency** is kept, premultiplied, as footage's alpha is.
- **Fitting.** A still is fitted into the frame like footage: as large as
  fits, centered, its aspect kept.

### How a still is drawn

`MediaDraw` gains a `still`: the decoded picture, held by a shared cache
(`StillImages`) keyed by the file, its stamp on disk, the timeline's color
space and the decoded size. It is decoded while the composition is built,
off the main actor, never while a frame is drawn. A media draw with a
still has no track: `trackIDs` leaves it out, and `sourcePicture` returns
the still instead of reading a frame. Everything after that (the stack,
transitions, motion blur, trails) is the same code footage goes through.

- **Composition length.** A composition ends with its last track's media,
  so a timeline of stills alone would have no length and no video track
  for the player to draw. When nothing else gives it pictures there, a
  black frame movie written once to the app's caches folder (like the
  silence file `padSound` uses) is stretched under the stills. No
  instruction draws that track.
- **Never passthrough.** A still has no frames to pass through, so a
  stretch holding one still is drawn by the compositor even in export.
- **Render key.** A still is keyed by its file and stamp, not by a file
  time, so moving a still keeps its render.
- **Blend, echo and trails** of a still have no other frames to mix in:
  frame blending and echo leave it unchanged; trails still work, since they
  draw the finished clip at earlier moments and a moving still moves.
- **Missing file.** As for footage: the viewer leaves a gap, and export
  stops with the asset's name.

### Not analyzed

Stills have no scenes, beats, filmstrip or reference data. The browser
shows one thumbnail (ImageIO's `CGImageSourceCreateThumbnailAtIndex`), and
a timeline clip shows the same picture. Replacing a still takes another
image, which needs no alignment; replacing it with footage, or footage with
a still, is refused.

## Shapes

Shapes are **effects**: a Rectangle or an Ellipse in a clip's stack draws
its shape over the picture handed down to it, and the steps below act on
both. That is the stack's own rule (see [effects.md](effects.md#the-idea-the-list-is-the-render-order)),
and it means keyframes, eases, the graph editor, presets, copy and paste,
and saving all work on shapes as they are.

- **Shape clips.** `ClipSource.graphic` is a clip with no picture of its
  own: it starts from transparency, so its picture is what its shapes
  draw. Like an adjustment clip it has no length to run out of. The
  timeline's toolbar makes one at the playhead on a new video layer
  (New Shape Layer, Rectangle or Ellipse), five seconds long, holding one
  shape sized to the frame. It is drawn in its own tone.
- **Shapes on anything.** A shape can go in any visual clip's stack: a
  box drawn over footage for a lower third, below a Transform that moves
  both, is one clip. The effects library lists them under Shapes.
- **Controls.** Size (width and height, which can be linked, but aren't
  at first), Corners (Rectangle only: the radius, at most half the shorter
  side), Position (an offset of the shape's center from the frame's
  center), Fill and Stroke (colors with opacity, picked with a color
  well) and Stroke Width (centered on the outline). Turning Fill or Stroke
  off leaves it out. Colors are the timeline's encoded values, as a
  transition's dip color is.
- **Drawing.** A shape is filled and stroked with Core Graphics
  (`ShapeRendering`), in 32-bit floats, into a picture the size of its
  bounds in output pixels, kept within the canvas margin.
- **Staying sharp.** While only moves (Transform's Position, Scale and
  Rotation) follow a shape in the stack, they are applied to its outline,
  not to pixels, and it is drawn once, at the size it ends up, when a step
  needs pixels (Color, Blending, Matte) or the stack ends. A shape scaled
  to 800% is as sharp as one made that size. Opacity after a shape is
  applied as it is drawn. Transitions and nested timelines still move the
  drawn picture.
- **Render key.** A shape's step is part of the key, so changing a shape
  re-renders it, and moving the clip doesn't.

Still to come:

- **Polygon and star** (points, radii, roundness): parameters that make a
  path, so they animate by their numbers.
- **Free paths.** A closed flag and a list of vertices, each a point with
  an in and an out tangent, in pixels from the frame's center, keyframed
  whole: between two keyframes with the same number of vertices each point
  and tangent blends; with different counts it holds until the next.
  Converting a primitive to a free path keeps its current shape. Editing
  vertices needs the viewer's handles (step 4).
- **Stroke joins, caps and dashes**, and gradient fills (linear and
  radial, with stops).
- **Path operations.** Union, intersection, subtraction and exclusion of
  shapes (Core Graphics' `CGPath` boolean operations, macOS 13 and later),
  offset paths, and **trim paths** (start, end and offset in percent, for
  drawing a line on).

## Text

Text is a shape effect whose outline is a block of text, laid out with
Core Text and drawn as glyph paths through the same code as the other
shapes, so it has a fill and a stroke and stays sharp the same way. A
text layer is a shape clip holding one.

- **Content.** An attributed string: runs of font family, style, size,
  tracking, line height, fill and stroke. Alignment, a box width for
  wrapping (or none, for one line), and the anchor's place in the box.
- **Layout.** `CTFramesetter` sets the lines, and `CTFontCreatePathForGlyph`
  gives each glyph's path. Layout is redone only when the text or its
  styling changes, not for every frame.
- **Variable fonts.** A font's variation axes (weight, width, slant,
  optical size) are controls like any other, so a word can animate from
  light to black.
- **Animators.** As in After Effects, an animator applies offset, scale,
  rotation, opacity, fill and tracking to a range of characters, words or
  lines, with the range's start, end and offset keyframed and a shape for
  how it falls off (square, ramp, smooth). Each glyph is drawn at its own
  transform about its own anchor.
- **Text on a path.** A text item can follow one of the clip's shape paths,
  with a start offset that can be animated.
- **Missing fonts.** The project stores font names, not files. Opening a
  project on a Mac without one of its fonts keeps the name, draws with a
  substitute, and reports the missing font in the inspector and before
  export, as missing media is reported.
- **Editing.** Text is typed in the inspector (TextKit 2) and, later, in
  place in the viewer.

## Editing in the viewer

Shapes and text are moved and reshaped by handles drawn over the viewer:
vertices and tangents, a primitive's size and corners, a text box's
width. The freehand ink of the external display (`Annotations.swift`) can
be turned into a shape. Following [accessibility.md](accessibility.md),
every handle is an accessibility element with actions, and the selected
vertex can be nudged by the arrow keys (ten pixels with Shift).

## Saving

- A still is an asset with `kind: "Image"`, written like any other.
- A shape clip is `source: {"kind": "graphic"}`. Its shapes are effects
  (`"rectangle"`, `"ellipse"`) written like any other, their controls as
  numbers (colors as `[r, g, b, a]`). A size's link is written only when
  it differs from a new control's. Free paths, when they come, will be
  arrays of vertices (`[x, y, inX, inY, outX, outY]`) so they can be read
  and edited by hand. Loading stays strict.
- These are additions, so the format version stays the same: files
  without them read as before, and an older version of the app reports a
  file with them as invalid (strict loading names the unknown kind)
  rather than misreading it.

## Building it

1. **Stills** (done). `MediaKind.image`, import through ImageIO, the
   still cache (`StillImages`) and color conversion, `MediaDraw.still`,
   spare frames under transitions at cuts, the black frame for
   compositions without footage (`BlankFrame`), the render key, thumbnails
   in the browser and on timeline clips, skipping analysis, the project
   file, and replacement. `StillTests` draws a still alone and over
   footage, checks transparency, orientation, trimming past the placed
   length, the render key after a move, missing files, saving (offline
   too) and replacement. Not yet: no UI snapshot (thumbnails load
   asynchronously), and HDR stills are untested.
2. **Shapes.** (a, done) `ClipSource.graphic`, the Rectangle and Ellipse
   effects with fill and stroke, keeping shapes as outlines through moves,
   the New Shape Layer menu, color wells in the effects panel, and saving.
   `ShapeTests` draws shapes alone, over footage and in footage's own
   stack, checks an ellipse against its bounds, translucency, a stroke
   alone, sharpness at 800% (an edge that rasterizing first would blur
   across eight pixels), render keys, and saving; the `UISnapshots`
   case `shapeEffectsPanel` shows the controls. (b) Polygon and star,
   stroke joins, caps and dashes, gradients. (c) Free paths and their
   keyframes. (d) Path operations and trim paths.
3. **Text.** Core Text layout and glyph paths, styling runs, the inspector
   editor, missing fonts, variable axes, then animators and text on a path.
4. **Viewer handles.** Selecting a graphic clip in the viewer, handles for
   vertices and primitives, and their keyboard paths.
5. **Stills as effect inputs**, so a PNG can be a Matte's input.

## Not in this plan

- Importing SVG or PDF artwork as editable vectors. A PDF page could be
  a still drawn at the size it ends up, later.
- 3D text or extrusion.
- Animated GIF and APNG playback; they show their first frame.
