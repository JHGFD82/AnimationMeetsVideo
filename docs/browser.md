# The browser

Status: **being built**. See "Building it" for the stages and which are
done. Replaces the library sidebar described in
[scene-cuts.md](scene-cuts.md) ("In the browser") and the library parts of
[timeline.md](timeline.md); their scene editing (merge, split,
sensitivity, Find Scenes Again) carries over unchanged.

The browser is the panel left of the viewer that holds what can go into a
timeline. It and the panel right of the viewer can each be resized by
their inner edge whatever tab is open, down to a minimum width; the
right panel keeps a width per tab. It works like Final Cut Pro's browser: every clip is a filmstrip
of thumbnails, skimming one shows it in the viewer, and a range of it can
be picked and dragged in. The main difference is that a drag's job is
set by the selection: a drag on what is selected moves it, and a drag
anywhere else picks a range.

## Names

- The **Browser** is the panel left of the viewer (formerly the
  "Library"), with the tabs **Clips**, **Timelines** and **Generators**.
- The **Effects Library** is the panel at the right end of the timeline
  with the tabs **Effects**, **Transitions** and **Presets** (formerly
  the "browser", see [effects.md](effects.md)). Presets moved there from
  the browser, since like effects and transitions they go onto clips
  rather than making clips of their own.

## Tabs

The tabs sit at the top of the browser in the same tab bar as the side
panel's Inspector and Effects tabs (`PanelTabBar`). The chosen tab is
remembered; one no longer offered (a remembered Presets tab, from
before it moved) opens on Clips.

- **Clips**: the project's media, in import order. With none yet, the
  tab says how to begin (import, or drag files from the Finder) and has
  an **Import Media…** button, as the + button and File > Import Media…
  (⌘I) do; the viewer's empty message points there too. Until its scenes are
  found, a video is **one clip**, usable as any other, with **Detecting
  scenes** and a progress bar across the top of its filmstrip while they
  are being found (shortened to "Detecting", then the bar alone, when a
  single small thumbnail has no room). Once they are found the clip is
  **replaced by its scenes**: the video's name becomes a heading with its
  scene count and its own menu (Add Whole Clip to Timeline, Rename, Split
  Scenes, Cut Sensitivity, Find Scenes Again, Don't Detect Scenes,
  replacing the file), and **each scene
  is a clip** of its own (a "virtual clip", as in
  [scene-cuts.md](scene-cuts.md)) under it, in source order. Finding
  scenes again shows the whole clip until they are found. Audio files are
  clips with a waveform in place of thumbnails.
- **Timelines**: the project's timelines as a tree (`TimelinesList`): the
  main timeline first, then those no timeline embeds, each with the
  timelines it embeds under a disclosure triangle, open to start with.
  Each timeline is listed once: one embedded in several timelines sits
  under the one nearest the top. Each row has its name, its duration and
  its settings (frame size, rate and colour space). The active one is
  marked **Open**. Timelines are **selected as clips are** (see
  "Selecting"): a click selects one, Command-click adds or takes one out,
  Shift-click selects the run between, and Up and Down move the selection
  (Shift extends it). A **double-click opens** a timeline in the editor;
  clicking doesn't embed it. **Embed in Active Timeline**, **Embed In**
  (a submenu of the timelines that can take them, the same as dragging
  them onto one; see "Dragging") and **Duplicate
  Timeline** act on everything selected when the row under the menu is;
  timelines embedded together go back to back on one new layer, in the
  tab's order, as clips added together do. None goes in while any of them
  would put a timeline inside itself, however deep.
  A click on the name of the only timeline selected (after a moment, so a
  double-click still opens), Return, or **Rename Timeline** in its menu
  renames it: the name
  becomes a bordered field over it, Return or clicking away keeps the new
  name, Escape puts the old one back. Its menu also has **Open**,
  **Open in New Window** (a second editor on that timeline, sharing the
  project with its window: the same undo, so ⌘Z in either undoes the last
  edit made in either, and it closes when the project's window does;
  `TimelineWindow`), **Embed in Active Timeline** (disabled where it can't be: it is empty,
  or would contain the active one) and **Duplicate Timeline**, which
  puts a copy below it ("Main copy", "Main copy 2") with new IDs
  for its layers and clips, sharing the timelines it embeds, and
  **Delete Timeline** (see "Removing").

  **Layout**, in the view options under Sort by (`TimelinesLayout`,
  remembered between launches), shows the tab one of two ways:
  - **Filmstrips** (the default, `TimelineFilmstrips`): each timeline is a
    filmstrip as a clip is, in the tree's order read top to bottom, its
    name, **Open** mark and settings above it and its duration on its
    first thumbnail. The pictures are the timeline's own frames, made
    from a composition built of it (`TimelinePreview`) at the time per
    thumbnail and size the Clips tab uses. It is built again only when
    something it draws changes (its own clips, or the timelines it nests
    or its effects take), values included, so editing one timeline
    leaves the others' strips alone. It waits for edits to settle (half
    a second after the last) and builds once for a run of them, a build
    overtaken by a newer one is cancelled, and a strip keeps its old
    pictures until the new ones are made. Edits reach the previews from
    the editor (`TimelinePreviews.projectChanged`), since the browser
    isn't redrawn while only values change. With the tab out of sight
    no preview is kept or built. Skimming, ranges, Option-arrows, I, O and Escape work as on
    clips; a range picked of a timeline adds **Embed Range in Active
    Timeline** to its menu, which embeds only that stretch, the rest
    kept past the clip's trims for transitions to draw on. Timelines
    drag as clips do (see "Dragging").
  - **Tree**: the tree described above, each row its icon, name, duration
    and settings, with no pictures.
- **Generators**: **Text**, **Rectangle**, **Ellipse**, **Polygon** and
  **Star**, which aren't effects but clips of their own (a graphic clip,
  see [graphic-layers.md](graphic-layers.md)), so the Effects Library
  doesn't list them (`GeneratorsList`, `EffectKind.generators`).
  - **Dragged** onto the timeline's video area, one makes a five-second
    clip where it lands: on the layer under the pointer, landing as a
    clip moved there would (inside a clip it goes to the nearer edge and
    what follows moves right), or on a new layer at the top below the
    layers. A layer that can't take it (an adjustment layer) gets a new
    layer above it (`EditingProject.addGenerator`).
  - Dropped on **footage** (or a nested timeline), it goes on a new layer
    just above that clip's, at the drop, since only a text or shape clip
    takes one in its stack. Dropped on a **text or shape clip**, it joins
    that clip, below what it draws, so text can follow the path of a
    shape above it.
  - **Double-clicked**, or with **Add at the Playhead** from its menu, it
    makes a new layer at the top from the playhead and selects the clip.
    **Add to the Selected Clip** puts it in the selected text or shape
    clip instead. Both are VoiceOver actions too, the first the tile's
    default.
  - The drag travels as an `amv-generator:` URL (`GeneratorDragPayload`),
    which no effect drop target reads as an effect.

## Sorting

**Sort by**, at the top of the browser's view options, orders the clips
(`BrowserSort`, remembered between launches): **Date Added** (as imported,
the default), **Name** (as the Finder sorts, so "Shot 2" before "Shot 10"),
**Duration** (the longest first) or **Kind** (video, then stills, then
sound, each by name). A video's scenes stay in source order under it.
Sorted by name, the Timelines tab lists each level of its tree by name
too, the main timeline still first; the other orders leave timelines as
they were made.

## Filmstrips

Each clip is a filmstrip: one thumbnail for each stretch of its time, the
stretch set by **time per thumbnail** in the browser's settings. A
filmstrip wider than the browser wraps onto further rows, as in Final Cut
Pro, so a long clip takes more rows rather than a wider panel.

- **Time per thumbnail** steps, from the slider's right end to its left:
  **All** (one thumbnail per clip, its first frame), **1 min**, **30 s**,
  **10 s**, **5 s**, **2 s**, **1 s**. Each step
  is about two to three times the next, so each notch of the slider changes
  the view by a similar amount, the way the sensitivity slider is
  exponential. 1 s is the finest: finer steps make a 10-minute clip 1,200
  thumbnails and more, and skimming already gives frame-level detail.
- Each thumbnail shows the frame at the start of its stretch. Every
  thumbnail is full size: the last one, which may cover a shorter stretch,
  and a clip (or scene) shorter than one interval, which is one thumbnail.
  A shortened thumbnail is too small to read.
- **Thumbnail size** (in the settings): small, medium and large heights.
  Every thumbnail is 16:9, with the picture fitted inside on black: assets
  don't record their picture size, and one shape keeps strips aligned.
- The **duration** sits in the bottom-left corner of the clip's first
  thumbnail, in a shaded box, as a timecode at the clip's own frame rate.
- Scenes are found once for each change to what they come from (the
  asset's edits, the sensitivity, the scores) and remembered
  (`SceneCoverageCache`), not found again on every redraw.
- The list itself (each asset's clips, what the timelines use of them,
  and the lines they are drawn as) is worked out again only when what it
  comes from changes: the media, the sort, the sensitivity, the scores,
  the timelines, the width (in 4-point steps) or the thumbnail settings
  (`ClipsTabModel`, kept by `Memo`). Picking, skimming and dragging out a
  range redraw only the rows whose clip or pick changed (`ClipTitleRow`
  and `ClipStripRow` are Equatable).
- Thumbnails are made as they scroll into view, at the size drawn, and
  kept in memory only. Nothing is written to disk: small frames are cheap
  to make again, and storing them would go against keeping per-asset data
  small ([README](README.md), "Shared principles").
- The settings popover (a button in the browser's tab bar) holds time per
  thumbnail and thumbnail size. Both are app-wide preferences, not part of
  the project.

## Skimming

Moving the pointer over a filmstrip **skims**: the viewer shows the frame
under the pointer, following it continuously, with no click. The pointer's
position along the strip is time in the clip, row by row, on the clip's
nearest frame. Leaving the browser returns the viewer to the timeline at
its playhead, and nothing on the timeline changes. A thin line in the
playhead's colour marks the skimmed frame on the strip, and the viewer
shows the clip's name and the time skimmed to (in the asset's original
time, as the browser's ranges are).

Skimming in the browser's view options (and the Settings window's
Browser tab) turns following the pointer off. A click then shows the
frame clicked, and the arrow keys step from it; it stays shown when the
pointer leaves the browser, so it can be looked at, until the browser
loses the keyboard.

- Skimming plays from the clip's file with its own player (`BrowserSkim`)
  shown over the viewer's picture, seeking with zero tolerance, so frames
  follow the pointer without rebuilding the timeline's composition. Seeks
  go one at a time and only the newest waiting move is sought next, so a
  fast pointer skips frames rather than falling behind.
- Starting to skim stops the timeline if it is playing; its playhead
  stays where it was.
- Space while skimming plays the clip from the skimmed frame, in the
  viewer, to the end of the clip (or scene) and stops there; Space again
  stops it, and from the end it plays from the start. Moving the pointer
  again goes back to skimming.
- Skimming plays a grain of the clip's own sound at each frame skimmed
  to, as moving the timeline's playhead does (docs/audio.md,
  "Scrubbing"), read from the file (the reference movie for a Matroska
  file), out of the playback device. A frame is heard once however many
  moves of the pointer cross it. Skim Audio in the browser's view
  options turns it off; it is set under Skimming, and with skimming off
  it is greyed out and frames clicked or stepped to are silent. A sound clip skims with a waveform symbol in the
  viewer.
- Dragging out a range shows its moving end in the viewer, as skimming
  does. Dragging clips out of the browser returns the viewer to the
  timeline they're dropped on.
- Stills aren't skimmed: they have no time to move through.

## Selecting

- **Click** selects the whole clip.
- **Renaming** a clip works as in the Finder: a click on the name of a
  clip already selected (after a moment, so it isn't taken for a
  double-click) makes it a bordered field over the name, as does
  **Rename** in its menu or its heading's; Return or clicking away keeps
  the new name, Escape puts the old one back. It renames the asset, not
  its file. Scenes are numbered, so only whole clips and headings have a
  name to change.
- **Clicking off the clips** (between or below them) selects nothing.
  **Double-clicking** there, or on the empty tab of a project with no
  media, opens the import dialog.
- **Command-click** adds a clip to the selection or takes it out.
- **Shift-click** selects every clip from the last one clicked to this one,
  in browser order.
- **Dragging across a clip that isn't selected** selects a **range** of
  it: an outlined span with a handle at each end. So does dragging across
  a clip that has a range, outside the range, and Option-dragging across
  any clip, selected or not. Once the mouse is let go, the handles can be
  dragged to change the range's length, snapping to frames; the pointer
  becomes the resize cursor over them. A range belongs to one clip;
  making one clears any other selection. A press must move a few points
  before it picks a range, so a slightly unsteady click is still a click,
  and a range dragged out shorter than a frame picks the whole clip
  instead (sound, which has no frame rate, counts thirty frames a second).
- **Clicking** a clip outside its range selects the whole clip again,
  dropping the range. Clicking inside the range keeps it.
- **Command- or Shift-clicking** another clip while one has a range
  selects whole clips: the one with the range and the one clicked (or the
  run between them), dropping the range.
- **Show in Clips Browser** in a timeline clip's right-click menu (or
  **Shift-F** with the clip selected, as Final Cut's Reveal in Browser)
  switches the browser to its Clips tab, picks the footage the clip plays
  and scrolls to it: the whole clip or scene when the timeline clip plays
  all of it (to within half a frame), a range of it when only part, and
  every scene from first to last when it plays across several
  (`ClipsTab.reveal` and `ClipsTabInteraction.revealSelection`, through
  the `revealInBrowser` notification).

## Dragging

Timelines drag as clips do, from either layout of the Timelines tab: a
timeline (every selected one when it is selected), or a range picked of
one, goes onto the timeline as an embedded clip at the drop, on the layer
under the pointer or a new video layer, with the same preview and
pushing aside (`MediaPiece.timeline`, through `MediaDragPayload`). A
timeline can't go into itself or into a timeline it is drawn into, so
such a drop does nothing. In the tree, and by a timeline's name in
filmstrips, the drag carries whole timelines; on a strip it follows the
rules below. Dropped on an effect that takes an input, the first timeline
dragged becomes the input.

Dropped on **another timeline in the Timelines tab** (its row in the
tree, or its name or strip in filmstrips), the timelines dragged go into
that one, open or not, as **Embed in Active Timeline** puts them in the
open one: back to back on one new layer at its top, from its start
(`timelineDropTarget`, `EditingProject.canPlaceAll`). While the drag is
over a timeline that can take all of it, the timeline is outlined in the
accent colour; over one that can't (itself, or one inside what is
dragged) nothing lights and the drop does nothing. The first new clip is
selected when the timeline it went into is the one being edited. The
menu's **Embed In** does the same without dragging, listing the
timelines that can take everything the menu acts on.

- **Dragging** a selected clip drags the **whole clip**, wherever on it
  the drag starts, along with every other selected clip. A clip that
  isn't selected has to be clicked first; dragging it picks a range (see
  "Selecting"). Only the timeline takes a drag: one let go anywhere else
  adds nothing.
- **Dragging from inside a range** (its middle, not its handles) drags only
  that range.
- What follows the pointer is **one thumbnail**: the first clip's picture
  at its start, or for a range the nearest picture made (a range seldom
  starts where a thumbnail does); for sound or music, a tile of its colour
  with a waveform icon. With a count when several are dragged. Over an **existing layer** that would take them, the
  thumbnail goes and the layer draws the clips where the drop would put
  them (`landing(of:onLayer:in:at:)`, the drop's own rule), outlined;
  anywhere else, the new-layer row and zone included, it stays a
  thumbnail. Clips in the way move aside as they do for a clip dragged
  within the timeline, by the same rule. The drag's contents and the layer it is over are shared
  through `MediaDragSession`, since a drop target can't read a drag before
  the drop.
- **Several clips** are dropped back to back on one layer **in browser
  order** (the order of the Clips tab, scenes in source order), whatever
  order they were selected in. Drops follow the timeline's rules for where
  a clip lands ([timeline.md](timeline.md)).
- **Add to Timeline** (context menu, or Return) does the same for the
  selection without dragging.
- **Mute added video sound** (in the view options, and the Settings
  window's Browser tab; off by default) puts video clips that have sound
  on the timeline with it muted (`TimelineClip.soundMuted`). The sound
  stays linked, not removed: Unmute Sound in the clip's menu plays it
  again, and detaching it unmutes it on its new sound layer
  ([timeline.md](timeline.md#linked-and-detached-audio)). Video dropped
  in from the Finder follows it too; sound files are never muted.

### From the Finder

Movies, sound and still images dragged in from the Finder are imported
as **Import…** imports them (`MediaImportFlow`), copied into the project
when it copies imports (File > Project Settings), with the same question
before copying files that would use real disk space. Dropped on the
browser they go into the Clips list. Dropped on the timeline they go into
the Clips list and onto the timeline whole: on a clip, onto that clip's
layer at the drop time, landing as media from the browser would; in an
area, onto a new layer of the area's kind, or of each file's own kind
when the area's doesn't suit them all. Files of other kinds are refused.

However they come in, files being imported are listed at the end of the
Clips tab (`MediaImports`, `ImportingClips`), each under its name with a
progress bar, until it arrives or fails. Most take a moment; a long
Matroska file takes seconds to index (see [matroska.md](matroska.md)),
and reports how far it has got. Other files' bars run until they're in.

## Used media

The part of each clip that **any timeline** in the project uses, nested
timelines included, is underlined in **red** along the bottom of its
filmstrip (`usedRanges(ofMedia:)`). It follows edits as they happen:
trimming a clip on the timeline grows or shrinks the line, and deleting the
last use removes it. A scene shows the part of the asset inside the scene.
A timeline's filmstrip in the Timelines tab is underlined where another
timeline nests it (`usedRanges(ofTimeline:)`).

## Removing

**Remove from Project**, in a clip's menu and its heading's, takes an
asset out of the project; **Delete Timeline** in a timeline's menu
deletes a timeline. Delete (or ⌘Delete) does either for what is
selected, as does Edit > Delete while the browser is the active panel,
and ⌘A selects everything listed first. Its uses go with it, so no clip
or effect is left pointing at nothing (`removeMedia`,
`deleteTimelines`):

- An asset's clips are deleted, in every timeline (their layers stay),
  effects taking it as their input let go of it, and clips tied to it
  as their music are untied. Delete takes the assets wholly selected
  (every scene of one split into scenes); a range or some of a video's
  scenes remove nothing. Its file stays where it was and its analysis in
  the package, so importing it again brings them back
  ([project-package.md](project-package.md)).
- Any timeline but the main one can be deleted. The clips embedding it
  are deleted and effects taking it as their input let go of it; the
  timelines it embedded stay. One deleted while open in an editor leaves
  that editor on the main timeline.

What nothing uses goes at once. When the timelines use any of it, a
question comes first (`RemovalRequest`): it says how many times it is
used and in which timelines (or how many, past three), and what goes
with it, such as "It is used 3 times, in Main and Titles. Removing it
also deletes those 2 clips and takes it off the effect using it as an
input." Uses inside timelines deleted along with it aren't counted.
**Find All** there opens the list of those uses (see "Finding uses")
and removes nothing. Either removal is undone as any edit.

## Finding uses

**Find All**, in the menu of a clip, a heading, a scene or a timeline
(and a VoiceOver action on each), opens a floating panel listing where
the project's timelines use it (`UsesFinder`): one row per use, with the
timeline, the layer, whether it is a clip of it or the input of an
effect (named), and its start, end and duration on that timeline, as
timecodes at the timeline's rate. A scene lists the uses that play some
of it; with several things picked, each has its own heading. It is
disabled when nothing uses them.

The list follows edits, undo and redo, and drops what is removed.
Double-clicking a row, or Return on it, opens its timeline in the editor
with its clip selected (`TimelineClipFocus`): the timeline zooms so the
clip fills the tracks but for a tenth of their width either side (as
close as the zoom goes for a short clip), centers it, scrolls its area
to it (showing the area if it was hidden), and lays a white light over
it that fades out in about a second and a half. With reduced motion the
light stays for that time and goes out at once. It is a table, so the arrow keys move through it
and VoiceOver reads it by row and column.

## Previewing presets

Presets are in the Effects Library's Presets tab (see
[effects.md](effects.md), "Copying and presets"). Resting the pointer on
one shows a card of what it holds, top of the stack first: each effect's
name (and its kind when renamed), whether it is off, and the settings
that differ from a new effect of its kind, with animated ones marked.
VoiceOver reads the same as the row's hint. A preset's tile shows a thumbnail of the preset applied to **generated test
footage**: pictures the app draws itself (colour bars, a gradient and
moving shapes), so nothing is bundled and previews work in an empty
project. Skimming a preset shows that footage with the preset in the
viewer, playing in a loop.

When the bottom effect of a preset changes how the clip combines with what
is below it (a blend mode, a matte, or another effect that draws nothing
on its own), the preview uses **two pieces of test footage**: the preset is
applied to the upper one, over a different generated pattern below, so the
effect is visible.

The test footage is a few seconds long, made once per launch at a small
size into a temporary folder, and never saved with the project.

## Keyboard and VoiceOver

Following [accessibility.md](accessibility.md):

- The arrow keys move the selection between clips; Shift extends it;
  Return adds the selection to the timeline; ⌘A selects every clip;
  Delete removes what is selected, asking first when it is used (see
  "Removing").
- In the Timelines tab, Right and Left show and hide the timelines the
  selected one embeds, as the triangle does. The tree is drawn as a flat
  list with triangles of its own, so a click on a nested row is taken as
  on any other: rows in an outline view's disclosure groups had their
  clicks taken by it, and double-clicks on them often didn't open.
- With a clip selected, **Option-Left** and **Option-Right** move a skim
  position through it a frame at a time (ten with Shift), shown in the
  viewer as skimming is; it starts at the clip's range, or its start.
  **I** and **O** set the start and end of a range at the skim position,
  or at the skimmed frame under the pointer, keeping the range's other end
  (or the clip's own). **Escape** stops skimming, as does moving the
  selection or leaving the browser.
- Each clip is one accessibility element, read as its name, duration, how
  much of it is used, and its range when it has one, with actions for Add
  to Timeline (its range when it has one, else the selection it is in, as
  its menu does), Skim Forward and Skim Back (a second at a time), and Set
  Range Start and Set Range End at the skim position. The viewer reads as
  skimming the clip, with the time as its value.
- A clip and a heading have Remove from Project and Find All actions
  too. A timeline, in either layout, has actions for Embed in Active
  Timeline, Rename, Duplicate, Delete and Find All, as its menu does; its
  filmstrip's title adds the skimming and range actions clips have.

## Building it

1. **Tabs and names** (done). Clips, Timelines and Presets tabs in place of
   the sections, and the Effects Library rename. Lists stay as they are.
   Presets later moved to the Effects Library, and a Generators tab (text
   and shapes) took their place.
2. **Filmstrips** (built, Clips tab; not yet tried on screen). Thumbnails,
   wrapping, the settings popover (time per thumbnail, size), duration
   boxes, scenes as clips. Rendered offscreen to check layout only.
3. **Selecting and dragging** (built, Clips tab; not yet tried on screen).
   Click, Command-click and Shift-click; whole-clip drags of several
   assets in browser order; ranges dragged across unselected clips, with
   handles; arrows,
   Shift-arrows and Return. Built together with stage 2, since both
   needed the clips drawn by hand rather than in a list.
4. **Skimming** (built, Clips tab; not yet tried on screen) in the viewer,
   Space to play, Option-arrows, I and O.
5. **Used media** underlines (built, Clips tab; not yet tried on screen).
   The Timelines tab's line came with stage 6.
6. **Timelines** as filmstrips, with skimming (built; not yet tried on
   screen), or as the tree, chosen in the view options, and dragged onto
   the timeline as clips are.
7. **Presets** with generated test footage.
