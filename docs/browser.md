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
  "Library"), with the tabs **Clips**, **Timelines** and **Presets**.
- The **Effects Library** is the panel at the right end of the timeline
  with the tabs **Effects** and **Transitions** (formerly the "browser",
  see [effects.md](effects.md)). Only its name changes.

## Tabs

The tabs sit at the top of the browser in the same tab bar as the side
panel's Inspector and Effects tabs (`PanelTabBar`). The chosen tab is
remembered.

- **Clips**: the project's media, in import order. With none yet, the
  tab says how to begin (import, or drag files from the Finder) and has
  an **Import Media…** button, as the + button and File > Import Media…
  (⌘I) do; the viewer's empty message points there too. Until its scenes are
  found, a video is **one clip**, usable as any other, with **Detecting
  scenes** and a progress bar across the top of its filmstrip while they
  are being found (shortened to "Detecting", then the bar alone, when a
  single small thumbnail has no room). Once they are found the clip is
  **replaced by its scenes**: the video's name becomes a heading with its
  scene count and its own menu (Add Whole Clip to Timeline, Split
  Scenes, Cut Sensitivity, Find Scenes Again, replacing the file), and **each scene
  is a clip** of its own (a "virtual clip", as in
  [scene-cuts.md](scene-cuts.md)) under it, in source order. Finding
  scenes again shows the whole clip until they are found. Audio files are
  clips with a waveform in place of thumbnails.
- **Timelines**: the project's timelines as a tree (`TimelinesList`): the
  main timeline first, then those no timeline embeds, each with the
  timelines it embeds under a disclosure triangle, open to start with (one
  embedded in two shows under both). The active one is marked **Open**.
  Clicking one embeds it into the active timeline; one that can't be (it
  is empty, or would contain itself) beeps, with its tooltip saying why.
  Its menu has **Embed in Active Timeline**, **Rename Timeline** (the
  name becomes a field in its row: Return or clicking away keeps the new
  name, Escape puts the old one back) and **Duplicate Timeline**, which
  puts a copy below it ("Main copy", "Main copy 2") with new IDs
  for its layers and clips, sharing the timelines it embeds. Planned:
  thumbnails drawn from the timeline itself.
- **Presets**: saved effect presets (see [effects.md](effects.md),
  "Presets"). They have no duration; see "Previewing presets". Resting
  the pointer on one shows a card of what it holds, top of the stack
  first: each effect's name (and its kind when renamed), whether it is
  off, and the settings that differ from a new effect of its kind, with
  animated ones marked. VoiceOver reads the same as the row's hint.

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
- **Clicking off the clips** (between or below them) selects nothing.
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
  before it picks a range, so a slightly unsteady click is still a click.
- **Clicking** a clip outside its range selects the whole clip again,
  dropping the range. Clicking inside the range keeps it.
- **Command- or Shift-clicking** another clip while one has a range
  selects whole clips: the one with the range and the one clicked (or the
  run between them), dropping the range.
- **Show in Clips Browser** in a timeline clip's right-click menu (or
  **Shift-F** with the clip selected, as Final Cut's Reveal in Browser)
  switches the browser to its Clips tab, picks the footage the clip plays
  and scrolls to it: the whole clip or scene when the timeline clip plays
  all of it, a range of it when only part, and every scene from first to
  last when it plays across several (`ClipsTab.reveal`, through the
  `revealInBrowser` notification).

## Dragging

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
  viewer as skimming is; it starts at the clip's range, or its start.
  **I** and **O** set the start and end of a range at the skim position,
  or at the skimmed frame under the pointer, keeping the range's other end
  (or the clip's own). **Escape** stops skimming, as does moving the
  selection or leaving the browser.
- Each clip is one accessibility element, read as its name, duration, how
  much of it is used, and its range when it has one, with actions for Add
  to Timeline, Skim Forward and Skim Back (a second at a time), and Set
  Range Start and Set Range End at the skim position. The viewer reads as
  skimming the clip, with the time as its value.

## Building it

1. **Tabs and names** (done). Clips, Timelines and Presets tabs in place of
   the sections, and the Effects Library rename. Lists stay as they are.
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
   The Timelines tab's line comes with stage 6.
6. **Timelines** as filmstrips, with skimming.
7. **Presets** with generated test footage.
