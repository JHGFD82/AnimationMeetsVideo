# Beat matching

Status: **built** except where noted; the panel is compile-checked and
was rendered offscreen, but hasn't been used on screen yet. Built in steps. Each step below says whether
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
    counts 3, 6/8 counts 6. It is 4 until the person sets it, and the
    section is labelled "4 beats a measure" only once they have
    (`isMeasureSet`, saved as `measureSet`).
  - **Steady by**: *click* (produced to a click track; the default) or
    *intent* (played live, meant to be steady but drifting).
- **Beats**, in order, each with its time, its **position** in the measure
  (1 is the downbeat), and whether it is **pinned**. A pinned beat was
  placed or moved by the person. Analysis moves it only onto a clear
  onset within 15 ms (see Onset timing below), never further. Positions
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

### How a section is filled

Built in `BeatFitting`, as pure functions over an `OnsetCurve`, and unit
tested on synthetic curves and a decoded click file. The panel reads the
song once when it opens (`BeatMatchAudio`): its samples at the file's own
rate, for the waveform, and an onset curve with a hop of 64 samples
(2.9 ms frames, against detection's 11.6 ms). Both are in the asset's
original time.

- **Tempo.** A typed tempo wins. Otherwise, when reanalyzing, it is the
  median gap of the beats already there. Otherwise it is estimated from the
  onsets around the anchors, by autocorrelation weighted toward 120 BPM
  as detection does.
- **Count between the anchors.** Every count within 12% of the gap over
  that tempo is tried. *Click*: the score is the mean onset under an even
  grid carried two measures past each anchor, leaving out the anchors
  themselves (they sit on onsets whatever the count, which made close
  anchors look best with nothing between them). *Intent*: the score is the
  refined chain's, since drift takes an even grid off the beats. Anchors
  given different places in the measure (beats 1 and 3, say) are the
  person's word: the count must keep them. Two anchors both left at 1 may
  just not have been numbered, so a count that keeps them is taken if it
  scores within 80% of the best.
- **The section's period.** The anchors give the period only roughly when
  they are close: anchors a beat or two apart and a few milliseconds off
  give a period a millisecond off, which adds up to a beat by the end of a
  song. So, unless a tempo was typed or the section is being reanalyzed,
  the period is fitted to the whole section. First a search near it, as
  wide as the anchors' uncertainty (5 ms each) over their span allows, for
  the grid stepping out from the outer anchors that lands on the strongest
  onsets. Then a least-squares fit of the onset peaks near that grid.
  Beats past the anchors step at this period; between pinned beats they
  stay evenly spaced.
- **Refining** (intent and ramps) is Ellis's dynamic programming held at
  both ends: each beat is searched within a quarter of a gap of its even
  place, scoring the onset there against how far each gap strays from the
  expected one. Peaks are placed between frames with a parabola.
- **Past the outer anchors** the beats step on a period at a time, to the
  section's edge. For intent each step moves to the strongest onset within
  15% of the gap. Steps stop where the music does: after two measures (eight
  steps) with no onset anywhere in them, which are dropped; silent steps
  at the edge are dropped too. A beat with no hit of its own but
  something between it and the last, such as a held chord or a vocal,
  counts as music.
- **Snapping.** Every beat a fill or reanalysis sets, pinned ones
  included, moves onto the strongest clear onset within 15 ms: closer
  than anyone places a beat by ear, and far short of the next beat. A beat
  with no clear onset near stays put, which keeps a click section's grid
  through quiet beats. A beat moved further than that by hand stays where
  it was put.
- **Onset timing.** Spectral flux peaks about 14 ms before a sharp hit,
  because it rises as soon as the hit enters the analysis window. The
  anchors are lined up by ear, so the curve is shifted by the median
  distance from each anchor to its nearest clear peak. That also takes in
  how soft the song's attacks are. With no anchor on a clear onset, it is
  shifted by the measured 14.3 ms.
- **Ramps** try every count within 15% of what an even change of tempo
  holds. A count away from that costs a little (a tenth of the chain's
  tightness), because ramps are seldom even.

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
  panel, and Delete removes it. A lone section (as with one tempo) is
  selected without asking.
- The strip looks like the timeline's section lane: bronze chips named by
  their kind, then the beats per measure once set, then the tempo once
  filled.
- Keyboard: F fills the gap at the playhead, and [ and ] move the
  selected section's start and end to the playhead, so none of it needs a
  drag. The same are buttons in the panel.

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

Once a beat or anchor is placed, the panel's transport shows the tick's
**pitch** and **volume**; before that there is nothing to tick on. The downbeat (position
1) plays an octave above the other beats. The same two settings are in the
timeline's view options; they are one pair of settings, remembered across
launches. The pitch slider stops at 2000 Hz, so the downbeat goes no higher
than 4000 Hz.

## Saving

An asset's `beatMap` in `project.json`, left out while it has no section:
`usesSections` (only when true) and `sections`, each with its `id`, `kind`
(`consistent`, `ramp` or `none`), `start` and `end`, `beatsPerMeasure`,
`measureSet` (only when true),
`steadiness` (`click` or `intent`), `confirmed`, and `beats`. Each beat has
a `time`, its `position` and, only when true, `pinned`. Times are exact,
so a beat nudged by a sample stays on that sample. Loading sorts the
sections and the beats, drops a beat that falls on another's time (keeping
the pinned one), and wraps positions into the measure.

## On the timeline

- The Beat Markers picker lists only Music layers. **Built.**
- Once any section of a song is filled, its clips show the beat map's
  beats instead of the detected ones (`EditingProject.beatMarkers`). They
  are drawn solid, with taller ticks on downbeats, and the click plays
  downbeats an octave up. Detected beats that haven't been confirmed are
  drawn dimmer and dashed. **Built.**
- Zooming out shows fewer beats: every beat while they are at least 10
  points apart, then only downbeats, then the first beat of every 2nd,
  4th… measure. Snapping uses what is drawn. Detected beats have no
  measures, so they keep thinning by powers of two as before. **Built.**

## Building it

1. Only music is analyzed. **Built.**
2. Tick volume, and the downbeat an octave up. **Built** in
   `BeatClickPlayer`; nothing marks downbeats until the beat map exists.
3. The beat map: model, saving, undo, and timeline markers from it.
   **Built** (`BeatMap`, on `MediaClip`, so undo comes with project edits).
4. Filling sections: grid, refining, ramps, reanalyze. Pure functions over
   an onset curve, unit tested. **Built** (`BeatFitting`, `BeatMatchAudio`).
5. The beat match panel: waveform, transport, anchors and nudging, beat
   editing, then sections. **Built** (`UI/BeatMatch/`): opened from a Music
   clip's menu or the inspector. The step's instructions and controls sit
   left of the waveform, and resizing the panel keeps the same stretch of
   song in view. The waveform is drawn to the song's loudest sample and
   clipped to its area, and the panel's size is the window's alone (the
   hosting view only sets its minimum). While it is open the editor is darkened
   and disabled, the Timeline menu rests, and a click on the editor brings
   the panel back; its undo is the editor's. Keys: Space plays, M drops a
   beat or anchor at the playhead, ← → nudge the selected beat (⌥ one
   sample, ⇧ 10 ms; without a selection they move the playhead a second),
   ↑ ↓ select the previous and next beat, Delete, L loops, Return fills,
   ⌘= ⌘- ⌘0 zoom. Not yet tried on screen: drag feel, the dimming, and
   focus moving between the panel and the editor.
6. Timeline thinning by measures, and the Music-only picker. **Built.**
