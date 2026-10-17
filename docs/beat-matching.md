# Beat matching

Status: **planned**, being built in steps. Each step below says whether
it is built yet. Automatic detection ([beat-detection.md](beat-detection.md))
is the starting point. It is often wrong, even on easy songs, so the
person confirms the beats in a guided process, the **beat match** panel,
and the beats they confirm are what the timeline uses.

## Overview

- Only music is analyzed (built): an asset is detected once a clip of it
  sits on a Music layer. Audio files go on Sound layers by default, and a
  video's sound gets to Music only once it is detached and dragged there.
- Until the person beat matches a song, the timeline shows the detected
  beats in a dimmer, dashed style, marked "not confirmed".
- **Beat match** (the music clip's context menu, or the inspector) opens a
  floating panel for the clip's asset. While it is open the main window is
  darkened and takes no input; the panel plays the song on its own.
- The person marks one tempo for the whole song, or switches to
  **sections** at the start. Either way the result is a **beat map**: the
  song's beats, each with its place in the measure, saved with the project.
- The person can come back at any time to move, add or delete beats,
  reanalyze a section, or start over.

## The beat map

A `BeatMap` belongs to the asset (`MediaClip.beatMap`), like scene edits,
so every clip of the song shares it and trimming changes nothing. Times
are in the asset's **original** time, like trims, so an aligned
replacement keeps its beats; detection, which reads the current file,
converts with the alignment offset. It is the person's work, so unlike
detected beats it is saved in `project.json` and every change is one undo
step.

- **Sections**, in order and never overlapping. A song with one tempo has
  one section covering all of it.
  - **Kind**: *consistent* (one tempo), *ramp* (tempo moving from one
    section's to the next), or *none* (not analyzed, the same as unmarked;
    it is there so the person can say so).
  - **Beats per measure**: only the count. 4/4 and 4/8 both count 4, 3/4
    counts 3, 6/8 counts 6.
  - **Steady by**: *click* (produced to a click track; the default) or
    *intent* (played live, meant to be steady but drifting).
- **Beats**, in order, each with its time, its **position** in the measure
  (1 is the downbeat), and whether it is **pinned**. A pinned beat was
  placed or moved by the person, and analysis never moves it. Positions
  are counted out from the nearest pinned beat that has one. Setting a
  beat's position pins it.

## Marking a consistent section

1. **Place two anchors.** The panel asks for a beat near the middle of the
   section, then a second one well away from it, ideally near the far
   end. Each anchor is dropped on the waveform or at the playhead (M), and
   is beat 1 unless the person picks another position.
2. **Line them up.** The tick plays on each anchor while the song plays.
   Arrow keys move the selected anchor by 1 ms, Option-arrow by one sample
   of the file, and Shift-arrow by 10 ms. Dragging works on the waveform,
   which zooms down to single samples. A loop toggle repeats the
   two bars around the selected anchor.
3. **Confirm.** The number of beats between the anchors comes from a rough
   tempo estimate. Dividing the time between the anchors by that number
   gives the exact period. The panel shows the tempo with two decimals; the
   person can type a tempo or halve or double it, which changes the count
   between the anchors, not the anchors.
4. **Fill.** Beats are laid out at that period across the whole section.
   - *Steady by click*: that grid is the result. Nothing is moved by
     detection.
   - *Steady by intent*: detection then moves each beat to the strongest
     onset near it, keeping each gap close to the period. Between two
     pinned beats the chain must start and end on them. Past the last
     pinned beat it steps on from the beat before.
5. **Check.** The person listens through, and can move a beat (which pins
   it), add or delete one, or set its position. **Reanalyze** keeps every
   pinned beat and fills the rest again between them: evenly for click,
   evenly then refined for intent.

Between two pinned beats the count is the nearest whole number of periods,
so a pinned beat a little off the grid bends the grid through it rather
than shifting every later beat.

## Sections

When the song has more than one tempo, the person picks **Sections** at the
start, and draws them before marking any:

- Pick a kind (consistent, ramp, none), then drag across the waveform to
  draw a section of it. The ends need not be exact at the start and end of
  the song, but should be close between two sections.
- Drag a section's edge to move it. Pinch to zoom in for the in-between
  edges. An edge dragged close to a neighbour's clicks in against it. A
  drag that starts on empty waveform always draws, even right next to a
  section, so drawing and resizing never conflict: draw beside a section,
  then drag the new edge until it clicks in.
- **Double-click** empty waveform to fill it, like a paint bucket, with
  the chosen kind, from the nearest section edge (or the start or end of
  the song) on the left to the nearest one on the right. Double-clicking
  inside a section changes its kind to the chosen one.
- Click inside a section to select it; its kind can be changed in the
  panel, and Delete removes it.
- Keyboard: **Fill gap at playhead**, and moving the selected section's
  edges by a frame, are menu commands with keys, so none of it needs a
  drag.

Then each consistent section is marked as above, one after another. Once a
consistent section is filled its edges snap to its first and last beats,
so neighbouring sections meet on a beat.

### Ramps

A ramp is filled once the sections either side of it are. It starts from
the last beat (and period) of the section before and ends on the first
beat (and period) of the section after. Ramps in songs are rarely even, so
detection decides: the beat chain is run between the two fixed beats, for
each count of beats near what an even ramp would hold, expecting a period
that moves from one end's to the other's, and the count whose chain lands
on the strongest onsets wins. Ease and unevenness come out of the onsets,
and when detection gets it wrong the person moves beats and reanalyzes,
as for any section.

A ramp at the start or end of the song, or next to an unmarked stretch,
has only one neighbour. The panel then asks the person to mark **every
beat of one measure** at the open end, which gives that end its beat and
period.

### Positions across sections

Positions carry on from the section before, using each section's own
beats per measure, unless a pinned beat in the section says otherwise.

## Hearing it

The panel has the tick's **pitch** and **volume**. The downbeat (position
1) plays an octave above the other beats. The same two settings are in the
timeline's view options; they are one pair of settings, remembered across
launches. The pitch slider stops at 2000 Hz, so the downbeat goes no higher
than 4000 Hz.

## On the timeline

- The Beat Markers picker lists only Music layers.
- Confirmed beats are drawn solid; detected beats that haven't been
  confirmed are drawn dimmer and dashed.
- Zooming out shows fewer beats: every beat while they are at least 10
  points apart, then only downbeats, then the first beat of every 2nd,
  4th… measure. Snapping uses what is drawn. Detected beats have no
  measures, so they keep thinning by powers of two as before.

## Building it

1. Only music is analyzed. **Built.**
2. Tick volume, and the downbeat an octave up.
3. The beat map: model, saving, undo, and timeline markers from it.
4. Filling sections: grid, refining, ramps, reanalyze. Pure functions over
   an onset curve, unit tested.
5. The beat match panel: waveform, transport, anchors and nudging, beat
   editing, then sections.
6. Timeline thinning by measures, and the Music-only picker.
