# Images, shapes and text

Status: stills, shapes (rectangle, ellipse, polygon and star) and strokes
are **built** (steps 1, 2a and 2b, not yet tried in the running app), as
is text (step 3: Illustrator's character, paragraph and OpenType
settings, styled runs, kerning by hand and optical kerning, hyphenation,
variable axes, animators and text on a path, set in the inspector);
gradients, free paths and path operations are **planned** (see
[Building it](#building-it)).
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

Shapes are **effects**: a Rectangle, Ellipse, Polygon or Star in a clip's stack draws
its shape over the picture handed down to it, and the steps below act on
both. That is the stack's own rule (see [effects.md](effects.md#the-idea-the-list-is-the-render-order)),
and it means keyframes, eases, the graph editor, presets, copy and paste,
and saving all work on shapes as they are.

- **Shape clips.** `ClipSource.graphic` is a clip with no picture of its
  own: it starts from transparency, so its picture is what its shapes
  draw. Like an adjustment clip it has no length to run out of. The
  timeline's toolbar makes one at the playhead on a new video layer
  (New Shape Layer: Rectangle, Ellipse, Polygon or Star), five seconds
  long, holding one shape sized to the frame; so does the browser's
  Generators tab, and a shape added to a shape clip is sized the same
  way. It is drawn in its own tone.
- **Generators, not effects.** Shapes and text make clips of their own
  and go only into a shape or text clip's stack
  (`EditingProject.stack(of:takes:)`): adding one to footage is refused,
  and pasting effects or a preset onto footage leaves them out. The
  Effects Library doesn't list them; the browser's **Generators** tab
  does (see [browser.md](browser.md#tabs)). Dragged onto the video area,
  one makes a clip where it lands, on the layer under the pointer or a
  new one (`addGenerator`); dropped on footage it goes on a new layer
  just above; dropped on a shape or text clip, it joins its stack, below
  what is there, which is how text comes to follow a shape's path.
  Double-clicked, it makes a layer at the playhead. A lower third over
  footage is a shape layer above it.
- **The clip's drawing in the effects panel.** On a shape or text clip,
  the shapes and text it draws are the clip itself, not effects applied
  to it: the effects panel shows them first, pinned above its other rows,
  each titled with its kind's symbol and name ("Text", "Rectangle"). They
  have no drag handle or enable checkbox, and their ⋯ menu has only
  Reset and Add Control, so they can't be moved, turned off, copied,
  duplicated or deleted from there; Delete, Cut, Copy and Duplicate
  ignore them (Delete still removes a selected control of theirs).
  Further shapes in the same clip (a circle for text on a path) show the
  same way. Effects added to the clip (a Transform, a Stroke) are its
  stack, listed below the anchor point as on any clip. Which effects are
  the drawing is `TimelineClip.drawingEffects`: on a `.graphic` clip, the
  effects of its stack that draw a shape (`EffectKind.drawsShape`), in
  stack order; `stackEffects` are the rest. It is the one place that
  says where a clip's drawing is kept. The model still keeps the drawing
  in the stack, where it draws in stack order.
- **Controls.** Rectangle and Ellipse have a Size (width and height,
  which can be linked, but aren't at first); Polygon and Star have Points
  (a whole number, 3 to 100), Radius, Rotation and, for a star, Inner
  Radius, with the first point straight up. Rectangle, Polygon and Star
  have Corners: the radius each corner is rounded to, as round as fits in
  half of each edge beside it. A rectangle's Corners menu has **Squircle**:
  each corner a quarter superellipse (exponent 5) reaching 1.6 times the
  radius along each edge, easing into it the way app icons do; at its
  roundest the whole rectangle is one squircle. Saved as `squircle` on the
  control. All have Position (an offset of the
  shape's center from the frame's center), Fill and Stroke (colors with
  opacity, picked with a color well), Stroke Width, and the stroke's Edge,
  Join, Cap and Dash (see [Strokes](#strokes)). Turning Fill or Stroke off
  leaves it out. Colors are the timeline's encoded values, as a
  transition's dip color is.
- **Drawing.** Fills and strokes alike are areas filled with a color
  (`ShapeRendering`), in 32-bit floats, into a picture the size of their
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

### Strokes

In most tools a stroke is an attribute of a path, so it can't be stroked
again, and putting it outside a letter's edge means turning the text into
outlines first. Here a stroke is an area worked out from an outline, and
anything with an outline can be stroked, however often:

- **Edge.** Center straddles the outline. Inside and Outside are a
  centered stroke twice as wide, cut to that side of the outline with
  Core Graphics' path operations, so an inside stroke keeps the shape's
  size, an outside one never covers it, and their corners follow the
  outline's own.
- **Join** (Miter, Round, Bevel), **Cap** (Flat, Round, Square, for the
  ends of dashes) and **Dash** (dash and gap lengths in pixels; solid while
  the dash is 0, and a gap of 0 is as long as the dash).
- **The Stroke effect** strokes the outline of everything the shapes above
  it in the stack drew, their strokes included, where they are by then.
  So a rectangle with a fill and a stroke, followed by a Stroke, has a
  stroke around its stroke; another Stroke goes around that one. Text
  (step 3) has the same outlines, so an outside stroke on text is one
  Stroke effect. A Matte or Blending step changes what the shapes cover,
  so a Stroke after one has nothing to follow, and the effects panel says
  so.

Still to come:

- **Free paths.** A closed flag and a list of vertices, each a point with
  an in and an out tangent, in pixels from the frame's center, keyframed
  whole: between two keyframes with the same number of vertices each point
  and tangent blends; with different counts it holds until the next.
  Converting a primitive to a free path keeps its current shape. Editing
  vertices needs the viewer's handles (step 4).
- **Gradient fills** (linear and radial, with stops), for fills and
  strokes alike.
- **Path operations.** Union, intersection, subtraction and exclusion of
  shapes (Core Graphics' `CGPath` boolean operations, macOS 13 and later),
  offset paths, and **trim paths** (start, end and offset in percent, for
  drawing a line on).

## Text

Text is a shape (`EffectKind.text`, in the Shapes category) whose
outline is a block of text, laid out with Core Text and drawn as glyph
paths through the same code as the other shapes (`ShapeStep`'s `.text`
outline), so it has a fill and a stroke, takes a Stroke below it, and
stays sharp through moves the same way. A text layer is a shape clip
holding one: New Shape Layer → Text, or Text from the browser's
Generators tab, dragged onto the timeline or double-clicked.

Built (step 3a):

- **Content.** `Effect.text` (`TextContent`) holds what isn't a control:
  the words and the font's PostScript name, one font for the whole block.
  Everything else is a control, keyframed like any other numbers are, in
  the groups of Illustrator's and InDesign's panels. Each applies to the
  whole block (`TextOutline.Setting`):
  - **Character.** Size (pixels; a new layer's is a ninth of the frame's
    height); Leading (baseline to baseline in pixels, 0 for Auto, 120% of
    the size); Kerning (Metrics, the font's pairs; Optical; or None); Tracking
    (thousandths of an em after each letter); Vertical and Horizontal
    Scale; Baseline Shift (up); Character Rotation (each letter about its
    middle, clockwise, as the app's other rotations turn); Case (Normal,
    All Caps, Small Caps, All Small Caps); Underline and Strikethrough.
  - **Paragraph.** Alignment (Align Left, Center or Right; Justify with
    the last line left, centered or right; Justify All Lines); Left, Right
    and First Line Indent (below 0 hangs the first line); Space Before and
    After, between paragraphs; Wrap Width (0 sets each paragraph on one
    line); Hyphenate; Anchor.
  - **OpenType.** Ligatures (Standard, None, or Standard and
    Discretionary); Contextual Alternates (on at first); Figures (Default,
    Tabular or Proportional, Lining or Oldstyle); Fractions; Ordinals;
    Swash; Stylistic Alternates; Stylistic Set (1 to 20, 0 for none).
  - And the shapes' Position, Fill and Stroke controls. The block's
    anchor (its middle at first) sits at the frame's middle plus Position.
- **Layout** (`TextLayout`). Each paragraph is wrapped with
  `CTTypesetterSuggestLineBreak` within the wrap width less its indents
  (allowing for horizontal scale), or set whole. Lines are stacked a
  leading apart, with paragraph spacing between paragraphs, and lined up
  within the block (as wide as the wrap width, or the widest line and its
  indents). Each glyph's outline comes from `CTFontCreatePathForGlyph`
  with its run's own font, so letters a font lacks fall back as Core Text
  picks, and is scaled, then turned about the middle of its advance, then
  shifted. Underline and strikethrough are rectangles added to the
  outline, as thick as the font's underline: the underline where the
  font puts it, the strikethrough half the x-height up. So they fill,
  stroke and stay sharp with the letters. A glyph with no outline (an
  emoji's picture) draws nothing. Laid-out blocks are kept by what was
  set, so layout is redone only when the words or styling change, not
  for every frame or move.
- **How Core Text is asked.** Tracking is `kCTTrackingAttributeName`,
  which leaves kerning pairs alone; Kerning None is a kern of 0 (the
  OpenType 'kern' feature turned off does nothing); All Caps draws the
  words uppercased. Small caps, ligatures, figures and the rest are
  OpenType features on the font (`kCTFontFeatureSettingsAttribute`), and
  Core Text keeps only those the font has, so a font without one draws as
  if it were off, as the inspector says. Small caps are the exception: a
  font without 'smcp' gets them made as Illustrator makes them, its
  lowercase letters drawn as capitals at 70% of the size (with All Small
  Caps, its capitals too); a font with it (Didot) draws its own.
- **The inspector** shows every shape and text of the selected clip, in
  stack order, laid out as Illustrator's and InDesign's panels are. A
  Text effect has a Text group (its words in a text editor), Character,
  Paragraph, Path and OpenType. Character has full-width Font and Style
  menus from `FontCatalog` (keeping the style's name when the family
  changes), the variable axes, then its numbers as fields with icons, two
  to a row (size and leading, kerning's method and tracking, vertical and
  horizontal scale, baseline shift and rotation), then Case as four
  buttons (Aa, AA, Aᴀ, ᴀᴀ) and Underline and Strikethrough as buttons
  that stay lit. Paragraph has the seven alignments as icon buttons, the
  indents, wrap width and spacing as fields two to a row, the anchor as
  the nine points of a box (Illustrator's reference point) and a
  Hyphenate checkbox. OpenType has Ligatures as three buttons, Figures
  as spacing (Auto, Tabular, Proportional) and style (Lining, Oldstyle)
  buttons, contextual alternates, swash, stylistic alternates, ordinals
  and fractions as buttons that stay lit, and the stylistic set. Another
  shape has a group of its own controls (`ShapeInspectorGroup`: a
  rectangle's size, corners and position, a star's points and radii),
  and a Stroke effect one of its stroke. Each drawn shape and text then
  has **Fill & Stroke** (`PaintInspectorGroup`): Fill and Stroke, each
  with a checkbox that leaves it out, a color well and its opacity, and
  while there is a stroke its width, Edge, Join and Cap (icon buttons
  drawn like the stroke they pick, as in Illustrator's Stroke panel) and
  Dash. With more than one shape, each group is titled with its effect's
  name. Every control is an `InspectorControlRow` (a name and fields, or
  in a grid a field with its icon); the shared buttons, fields and point
  grid are `PanelControls` in the design system. Leading reads "Auto" at
  0, a size has its link.
  - **No keyframing.** The inspector sets values outright; keyframes are
    the effects panel's. A control (or variable axis) animated there
    shows its value at the playhead read-only, dimmed, with an amber
    keyframe badge whose help says to change it in the Effects panel,
    rather than an edit quietly adding a keyframe. The selected
    letters' rows (styled runs, below) follow the same rule. One
    exception keeps the stopwatch and keyframe buttons: a **Text
    Animator**'s controls, since it exists only to animate.
  The effects panel shows the ones that can be keyframed, its numbers
  and colors, under headers
  (Character, with the font's variation axes after its controls;
  Paragraph, with Position; Path; OpenType; Fill & Stroke; then a
  **Letters “…”** header for each styled run, below), and leaves
  the choices (font and style, Kerning, Case, Alignment, Anchor, On
  Path, Flip, the OpenType on-or-offs, Edge, Join, Cap) to the
  inspector; a Text effect with no words says so there. Reset keeps the
  words and font.
- **Styled runs.** `TextContent.runs` set some letters apart from the
  block: each a range of UTF-16 code units (as the text editor counts)
  and a `TextStyle` of optional settings: font, size, tracking, baseline
  shift, vertical and horizontal scale, case, underline, strikethrough,
  and fill and stroke colors. The words are typed in an AppKit text view
  (`TextWordsEditor`), since SwiftUI's editor doesn't say what is
  selected. With letters selected, the inspector's Character group sets
  theirs (`TextSelectionRows`): each row shows the first selected
  letter's own setting, or the block's dimmer, a button gives the
  block's back, and Clear Styling gives back all of them. Leading,
  Kerning and Character Rotation stay the block's. Typing keeps runs on
  their letters: what is typed takes the style of the letter before it,
  and an edit the editor makes itself (an undo) keeps the styles of what
  is unchanged at either end. Adjacent letters styled alike are one run.
  - **Keyframes.** A run's numbers (size, tracking, baseline shift,
    scales, kerning by hand, stroke width) and colors are values that can
    be keyframed in the clip's source time (`TextRunStyle`). The
    inspector gives letters their own of a setting; the effects panel
    keyframes it: after the text's other sections, each run with a
    setting of its own has a header of its letters ("Letters “Hello”",
    `TextContent.quotedLetters`) and a row for each such setting
    (`TextRunSetting`, `EffectsPanel.runRow`) with its stopwatch,
    keyframe buttons, lane and graph editor
    (`AnimatedParameter.textRun`, which names the run by the code unit
    it starts at). Its ⋯ menu gives the letters the block's setting back,
    which takes the row away. Editing a run's keyframes there
    (`TextContent.changeRun`) keeps it a run of its own even if it comes
    to match a neighbour, so its row stays put. Its font,
    case, position, underline and strikethrough are choices and hold
    still. They combine with the block's by replacing: a setting a run
    has replaces the block's for its letters, its own keyframes with it,
    so the block's keyframes don't reach those letters; a setting it
    lacks follows the block's keyframes. Setting one starts from the
    block's value at the playhead. The layout gets each run's values at
    its moment (`TextStyleRun`). Run keyframes count as animation for
    the render cache, F9's eases reach them, and they are saved as a
    control's are (`{"value": …}` or `{"keyframes": […]}`). Not yet: they
    show in neither the effects panel's lanes nor the graph editor.
  - **Colors.** A run's own fill or stroke color paints its letters
    whether or not the block's fill or stroke is on, and letters without
    one take the block's, or nothing while it is off. A run's stroke is
    drawn as the block strokes (its Edge, Join, Cap and Dash, kept even
    while the block's stroke is off: `ShapeStroke(geometryOf:)`), at the
    run's own Stroke Width or the block's; giving letters a stroke color
    while their width is 0 gives them a width, a thirtieth of the size,
    so the color shows. The letters are drawn as pieces, one per style,
    all the fills first and then the strokes, so a stroke may overlap a
    neighbouring letter's fill as in Illustrator.
  - **Layout.** Each letter's scale is its font's matrix, so Core Text
    measures, wraps and draws it scaled; a run's positions come back
    without that scale and are scaled from where the line puts the run
    (`CTLineGetOffsetForStringIndex`). Auto leading is 120% of the
    largest size in each line, and a line is as tall as its tallest font.
    Letters whose styles differ only in color, tracking, rules or kerning
    share one font, so Core Text still kerns pairs across them.
- **Kerning by hand.** With the cursor between two letters, Character
  has a Kern row for that pair, in thousandths of an em, saved as the
  first letter's run's `kerning`. It moves every later letter of the line
  along, after the font's own pair kerning and the tracking, and widens
  the line for alignment. It is added after Core Text sets the line,
  since Core Text's tracking puts half its space before a letter, so a
  line wraps as if it weren't there and may reach past the wrap width by
  that much.
- **Superscript and subscript** are a run's Position. A font with the
  OpenType 'sups' or 'subs' feature draws its own (checked with
  `FontCatalog.supports`, which asks Core Text for the feature and sees
  whether it keeps it); otherwise they are made as Illustrator makes
  them, at 58.3% of the size, raised or lowered by a third of it.
- **Hyphenation** is a Paragraph setting, off at first. Core Text's line
  breaking doesn't hyphenate, so where it breaks a wrapped line before a
  word that would partly fit, or inside a word too long for a line, the
  latest place the word can be hyphenated
  (`CFStringGetHyphenationLocationBeforeIndex`, in the Mac's language
  where it hyphenates, else English) whose part and a hyphen fit the
  line is taken, and the hyphen drawn in the last letter's style. Words
  shorter than four letters aren't broken.
- **Optical kerning** is Kerning's third choice. Core Text has none, so
  `OpticalKerning` approximates it from the letters' shapes: each glyph is
  rasterized once (cached by font, size and glyph) into 48 horizontal
  bands across the font's height, giving how far in its ink starts from
  either side. A pair's space is the mean over the bands of the gap
  between the first's right ink and the second's left, a band where
  either has no ink counting as a quarter em (so an open side doesn't
  read as a gulf), and each pair moves so its space matches a reference
  pair's, "HH" between capitals and "nn" otherwise, by at most 0.15 em.
  It starts from plain advances (the font's pairs off) and goes through
  the same per-letter offsets as kerning by hand, which add to it. Tested
  against Helvetica Neue's designed pairs, it closes "AV", "To", "Ty" and
  "LT" by between half and twice as much as the designer did, and leaves
  "HH" and "nn" as they are; it is a heuristic, not Adobe's algorithm.
- **Variable fonts.** A variable font's axes (`FontCatalog.axes`, from
  `CTFontCopyVariationAxes`, hidden axes left out) each get a field
  under Style in Character, keyframed in the effects panel like the
  controls, so a word can animate from light to black. They aren't controls, since a
  font's axes aren't known until it is picked: `TextContent.variations`
  keeps each by its four-letter tag with its `AnimatedValue`, saved as
  `"variations": [{"axis": "wght", "value": …}]`. They last through a
  change of font, and a font without an axis ignores it. They apply to
  every letter, a run's font too (`kCTFontVariationAttribute`). Their
  keyframes behave as a control's: each axis is a parameter
  (`AnimatedParameter.textVariation`, by tag), so it has a row under the
  Text effect's Character header in the effects panel, after its
  controls and apart from the font's named styles (which are presets of
  the axes, picked in the inspector and never keyframed), with its lane of
  keyframes (moved, deleted and eased there) and its graph editor; F9's
  eases reach it; and its keyframes count as animation for the render
  cache. Resetting it gives the font's default.
- **Animators.** A Text Animator effect (`"textAnimator"`, in Shapes)
  animates the Text effect directly above it, other Text Animators
  between, as After Effects' animators with a range selector do; with no
  Text effect there, the effects panel says so. Its controls, keyframed
  like any other: **Start**, **End** and **Offset** (percent of the units),
  **Based On** (Characters, Characters Excluding Spaces, Words, Lines),
  **Shape** (Square, which selects a unit the range's edge crosses
  partly; Ramp Up, wholly after the range; Ramp Down, wholly before it;
  Triangle, Round, Smooth), and what it does to each glyph in proportion
  to how much it is selected: **Position** (pixels), **Scale** and
  **Rotation** about the middle of the glyph's baseline, **Opacity**,
  **Fill** and **Stroke** (off at first; on, the glyphs' fill or stroke
  color mixes toward it, where they have one), and
  **Tracking** (thousandths of an em after each, the line kept to its
  alignment). Several apply in order. They work on the glyphs as laid out
  (`TextOutline.Animator`, applied in `pieces`), so animating them never
  lays the block out again; glyphs drawn alike are still one piece.
  Underlines and strikethroughs are drawn as a piece under each glyph,
  reaching to the next so they join, and placed with it, so they move,
  scale, turn and fade with the letters they are under (and follow a
  path); Character Rotation alone leaves them level, as in Illustrator.
- **Text on a path.** With **On Path** (the inspector's Path group) a
  Text effect follows the outline of the last shape drawn above it in the
  stack (a Rectangle, Ellipse, Polygon or Star, not other text), from
  **Path Offset** pixels along it, which can be animated to run the words
  round. The outline's first subpath is flattened (`TextPath`, curves cut
  into 24 pieces) in the frame's pixels. A closed outline is turned to
  start at its topmost point and run clockwise on screen, whatever way
  Core Graphics drew it (an ellipse from its right, counter-clockwise),
  so text sits outside the shape and reads clockwise from its top, as in
  Illustrator. Each glyph's baseline middle goes at its distance along
  the path, turned to the path's direction there, standing on its
  outside; later lines run parallel to it. **Flip** runs the text the
  other way from the same start, on the other side: inside a shape.
  Left-aligned text starts at the offset; centered text centers on the
  path's length, right-aligned ends at its end. A closed path goes round
  again; past an open one's ends the letters run on straight. Animators
  still apply, along the path. Position and Anchor don't place text on a
  path; underlines and strikethroughs follow it in pieces, one under each
  glyph.
  - **After moves.** A Transform between the shape and the text moves the
    shape, and the text follows it where it went: the compositor keeps
    the outline of the last shape it drew, moves it with every move after
    it as it does the shapes it hasn't drawn yet, and maps it back into
    the frame's pixels where the text is drawn
    (`ShapeRendering.following`), as the Stroke effect follows the edges
    above it. Only the outline moves: a Transform that scales the shape
    up makes the path longer, not the letters bigger. Stack folding still
    gives the text the outline as drawn, for its render key and wherever
    no compositor draws it.
  - **Its own path.** Text can't have a path of its own yet: that needs
    free paths (step 2d), which aren't built, so it follows a shape's.
- **Anchor** is a Paragraph choice of nine points (Top Left to Bottom
  Right, Middle at first): which point of the block, as wide as its wrap
  width or widest line and as tall as its lines, sits at the frame's
  middle plus Position.
- **Naming.** A shape clip with a Text effect is named by the first line
  of its words on the timeline, in the inspector and in undo steps
  (`resolvedInfo(for:)` of the clip), and VoiceOver calls it a text clip.
- **Missing fonts.** The project stores the font's name, not its file.
  Without the font, Core Text draws with a substitute, the name is kept
  and saved, and the inspector says which font is missing and what draws
  in its place. As with missing media, the viewer draws (with the
  substitute) and export, and background renders, stop with the font's
  name (`CompositionError.missingFont`), so a substitute is never written
  out: `missingFonts(in:)` finds every font a Text effect that is on uses,
  its own and its runs', in the timeline and those nested in it.
- **Render key.** The words, font and every setting are part of the
  shape's key, so changing any of them re-renders and moving the clip
  doesn't.

Still to come:

- **Editing in the viewer.** Typing in place, and a handle for the wrap
  width.

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
  (`"rectangle"`, `"ellipse"`, `"polygon"`, `"star"`, `"stroke"`) written
  like any other, their controls as numbers (colors as `[r, g, b, a]`)
  or, for Edge, Join and Cap, the option's name. A size's link is written only when
  it differs from a new control's. A Text effect (`"text"`) also has
  `"text": {"string": …, "font": <PostScript name>}`; its Alignment is
  saved as the option's name like the other choices. Free paths, when they come, will be
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
   case `shapeEffectsPanel` shows the controls. (b, done) Polygon and
   Star with rounded corners, stroke Edge, Join, Cap and Dash, and the
   Stroke effect; `ShapeTests` checks inside and outside strokes, a
   stroke around a stroke, a star's notches against a pentagon, dashes,
   and saving the choices. Choice controls now list their own options,
   which also fixes Matte's Take listing blend modes. (c) Gradients.
   (d) Free paths and their keyframes. (e) Path operations and trim
   paths.
3. **Text.** (a, done) The Text effect, `TextContent`, Core Text layout
   and glyph paths (`TextLayout`) with the Character, Paragraph and
   OpenType settings, the inspector's groups for text and for every
   shape's settings, fill and stroke, `FontCatalog`, missing fonts in the
   inspector, naming clips by their text, and saving. `TextTests` checks
   centering, leading, paragraph spacing, wrapping, alignment against the
   wrap width, each justification, indents and a hung first line,
   tracking, kerning off, scale, baseline shift, character rotation, All
   Caps, underline and strikethrough, the OpenType features asked for and
   kept, reading the controls, empty text, a missing font, the font
   catalog, a text layer drawn over black, render keys, saving, naming,
   Reset and the empty-text note; the `UISnapshots` cases `textInspector`
   and `shapeInspector` show the inspector, and `inspectorSoundRows` its
   read-only animated values. (b, done) Styled runs: the
   text editor, selection rows, runs kept through edits, drawing and
   saving; `TextTests` checks editing, joining runs, a run's size, shift,
   scale, case, colors and underline, and saving, and `UISnapshots`'
   `textSelectionInspector` shows the selection's rows. Then, done: kerning
   by hand, superscript and subscript, hyphenation, optical kerning, made
   small caps, the anchor, and (c) variable axes, each tested in
   `TextTests` (`textPairKerningInspector` and
   `textVariableFontInspector` show their rows). (f, done) Missing fonts
   stop export. (d, done) Animators: `TextTests` checks each range
   shape, moving, fading and recoloring a range, scale and rotation about
   the baseline, tracking kept centered, ranges by words and lines, an
   animator drawn and saved, and its note with no text above;
   `textAnimatorInspector` shows its controls. (e, done) Text on a path:
   `TextTests` checks measuring and walking paths, following one from
   its offset, turning with it, centering on it, and following the shape
   above in a stack; `textOnPathDrawing` draws words round a circle with
   an animator.
4. **Viewer handles.** Selecting a graphic clip in the viewer, handles for
   vertices and primitives, and their keyboard paths.
5. **Stills as effect inputs**, so a PNG can be a Matte's input.

## Not in this plan

- Importing SVG or PDF artwork as editable vectors. A PDF page could be
  a still drawn at the size it ends up, later.
- 3D text or extrusion.
- Animated GIF and APNG playback; they show their first frame.
