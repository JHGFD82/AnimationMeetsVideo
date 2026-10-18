# Images, shapes and text

Status: stills are **built** (step 1, not yet tried in the running app);
shapes and text are **planned** (see [Building it](#building-it)).
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

A shape clip draws one or more paths made in the app. Its content is
stored on the clip itself, in the project file, as plain numbers.

- **Model.** A `ClipSource.graphic` clip holds a `Graphic`: a list of
  `ShapeItem`s drawn bottom first. Each has a path, a fill and a stroke.
- **Paths.** A path is a closed flag and a list of vertices, each a
  point with an in and an out tangent, in timeline pixels relative to the
  clip's center. A path is keyframed whole (an `AnimatedValue` of a path):
  between two keyframes with the same number of vertices each point and
  tangent blends with the keyframes' ease; with different counts it holds
  until the next keyframe.
- **Primitives.** Rectangle (size, corner radius), ellipse (size), polygon
  and star (points, radii, roundness) are parameters that make a path, so
  they animate by their numbers, not by vertices. Converting one to a free
  path keeps its current shape.
- **Fill and stroke.** Color and opacity, animated; stroke width, join,
  cap and dash pattern. Gradients (linear and radial, with stops) later.
- **Path operations.** Union, intersection, subtraction and exclusion of
  the items below (Core Graphics' `CGPath` boolean operations, macOS 13 and
  later), offset paths, and **trim paths** (start, end and offset in
  percent, for drawing a line on).
- **Drawing.** The paths are filled and stroked with Core Graphics into a
  pixel buffer the size of the picture's bounds in output pixels, then
  handed to the stack like a still. A still is decoded once; a shape is
  drawn again only when something it is drawn from changes, at the size
  the viewer draws at.
- **Staying sharp.** Scaling a shape with the Transform effect would
  enlarge pixels. As a nested timeline's move is pushed into its layers
  (see [effects.md](effects.md#keeping-it-sharp-and-cheap)), the stack's
  leading place step is applied to the paths before they are drawn, while
  everything before it in the stack works per pixel. A shape scaled to
  800% is as sharp as one drawn that size.
- **Size.** A shape's picture is the bounds of its paths with their
  strokes, kept within the canvas margin; it has no frame of its own.
  The anchor point is relative to the clip's center, which is the origin
  of its paths.

## Text

A text clip is a graphic whose item is a block of text, laid out with Core
Text and drawn as glyph paths through the same code as shapes, so it has
a fill and a stroke and stays sharp the same way.

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
- A graphic clip is `source: {"kind": "graphic"}` with a `graphic` object
  holding its items. Paths are arrays of vertices (`[x, y, inX, inY, outX,
  outY]`) so they can be read and edited by hand; primitives keep their
  parameters. Loading stays strict: an unknown item kind or field is an
  error that names where it is.
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
2. **Shapes.** `ClipSource.graphic`, the rectangle and ellipse, free paths
   and their keyframes, fill and stroke, drawing at the size the
   viewer draws at, pushing the leading move into the paths, and the
   inspector controls. Then path operations, trim paths and polygons.
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
