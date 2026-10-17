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
be picked and dragged in. The main difference is what a plain drag does:
here it always grabs the whole clip.

## Names

- The **Browser** is the panel left of the viewer (formerly the
  "Library"), with the tabs **Clips**, **Timelines** and **Presets**.
- The **Effects Library** is the panel at the right end of the timeline
  with the tabs **Effects** and **Transitions** (formerly the "browser",
  see [effects.md](effects.md)). Only its name changes.

## Tabs

The tabs sit at the top of the browser in the same tab bar as the side
panel's Inspector and Effects tabs (`PanelTabBar`). The chosen tab is
remembered.

- **Clips**: the project's media, in import order. Until its scenes are
  found, a video is **one clip**, usable as any other, with **Detecting
  scenes** and a progress bar across the top of its filmstrip while they
  are being found (shortened to "Detecting", then the bar alone, when a
  single small thumbnail has no room). Once they are found the clip is
  **replaced by its scenes**: the video's name becomes a heading with its
  scene count and its own menu (Add Whole Clip to Timeline, Cut
  Sensitivity, Find Scenes Again, replacing the file), and **each scene
  is a clip** of its own (a "virtual clip", as in
  [scene-cuts.md](scene-cuts.md)) under it, in source order. Finding
  scenes again shows the whole clip until they are found. Audio files are
  clips with a waveform in place of thumbnails.
- **Timelines**: the project's timelines other than the active one, as
  clips whose thumbnails are drawn from the timeline itself. Dropping one
  nests it, as today. One that can't be embedded (it would contain itself)
  is shown dimmed and can't be dragged.
- **Presets**: saved effect presets (see [effects.md](effects.md),
  "Presets"). They have no duration; see "Previewing presets".

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
position along the strip is time in the clip, row by row. Leaving the
browser returns the viewer to the timeline at its playhead, and nothing on
the timeline changes. A thin line marks the skimmed frame on the strip.

- Skimming plays from the clip's file with its own player layered over the
  viewer (as the trim preview is), seeking with zero tolerance, so frames
  follow the pointer without rebuilding the timeline's composition.
- Space while skimming plays the clip from the skimmed frame, in the
  viewer; moving the pointer again goes back to skimming.
- Sound is not played while skimming, only while playing.

## Selecting

- **Click** selects the whole clip.
- **Command-click** adds a clip to the selection or takes it out.
- **Shift-click** selects every clip from the last one clicked to this one,
  in browser order.
- **Option-drag** across a filmstrip selects a **range** of that clip: an
  outlined span with a handle at each end. The handles can be dragged to
  set the range more exactly, snapping to frames; the pointer becomes the
  resize cursor over them. A range belongs to one
  clip; making one clears any other selection.
- **Clicking** a clip outside its range selects the whole clip again,
  dropping the range. Clicking inside the range keeps it.

## Dragging

- **Dragging** a clip drags the **whole clip**, wherever on it the drag
  starts, or every selected clip if it is part of the selection. Only the
  timeline takes it: a drag let go anywhere else adds nothing.
- **Dragging from inside a range** (its middle, not its handles) drags only
  that range.
- What follows the pointer is **one thumbnail**: the first clip's picture
  at its start (a tile of its colour for sound), with a count when several
  are dragged. Over an **existing layer** that would take them, the
  thumbnail goes and the layer draws the clips where the drop would put
  them (`landing(of:onLayer:in:at:)`, the drop's own rule), outlined;
  anywhere else, the new-layer row and zone included, it stays a
  thumbnail. The drag's contents and the layer it is over are shared
  through `MediaDragSession`, since a drop target can't read a drag before
  the drop.
- **Several clips** are dropped back to back on one layer **in browser
  order** (the order of the Clips tab, scenes in source order), whatever
  order they were selected in. Drops follow the timeline's rules for where
  a clip lands ([timeline.md](timeline.md)).
- **Add to Timeline** (context menu, or Return) does the same for the
  selection without dragging.

## Used media

The part of each clip that **any timeline** in the project uses, nested
timelines included, is underlined in **red** along the bottom of its
filmstrip (`usedRanges(ofMedia:)`). It follows edits as they happen:
trimming a clip on the timeline grows or shrinks the line, and deleting the
last use removes it. A scene shows the part of the asset inside the scene.
A timeline in the Timelines tab is underlined where another timeline nests
it.

## Previewing presets

A preset's tile shows a thumbnail of the preset applied to **generated test
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
  Return adds the selection to the timeline.
- With a clip selected, **Option-Left** and **Option-Right** move a skim
  position through it a frame at a time (ten with Shift), shown in the
  viewer as skimming is. **I** and **O** set the start and end of a range
  at the skim position, or at the skimmed frame under the pointer.
- Each clip is one accessibility element, read as its name, duration, how
  much of it is used, and its range when it has one, with actions for Add
  to Timeline, Set Range Start and Set Range End.

## Building it

1. **Tabs and names** (done). Clips, Timelines and Presets tabs in place of
   the sections, and the Effects Library rename. Lists stay as they are.
2. **Filmstrips** (built, Clips tab; not yet tried on screen). Thumbnails,
   wrapping, the settings popover (time per thumbnail, size), duration
   boxes, scenes as clips. Rendered offscreen to check layout only.
3. **Selecting and dragging** (built, Clips tab; not yet tried on screen).
   Click, Command-click and Shift-click; whole-clip drags of several
   assets in browser order; option-drag ranges with handles; arrows,
   Shift-arrows and Return. Option-arrows and I and O wait for skimming
   (stage 4). Built together with stage 2, since both needed the clips
   drawn by hand rather than in a list.
4. **Skimming** in the viewer, and Space to play.
5. **Used media** underlines (built, Clips tab; not yet tried on screen).
   The Timelines tab's line comes with stage 6.
6. **Timelines** as filmstrips, with skimming.
7. **Presets** with generated test footage.
