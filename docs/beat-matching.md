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
  darkened and wholly inactive: no clicks, hovering, skimming, scrolling
  or pinching reach it (`WindowInputBlock`), and a click on it brings the
  panel back. The panel plays the song on its own: only its audio, so a
  video's picture is never decoded.
- The person marks one tempo for the whole song, or switches to
  **sections** at the start. Either way the result is a **beat map**: the
  song's beats, each with its place in the measure, saved with the project.
- The panel works on a draft with its own undo (⌘Z and ⇧⌘Z, or the
  footer's buttons). **Confirm**, offered once a section has its beats
  filled, puts it on the
  timeline as one undo step there, and turns on that song's beat markers
  (the view options' picker chooses its Music layer). **Cancel**, or the
  close button, leaves the timeline as it was, asking first if anything
  changed, so a fill gone wrong never touches the project.
- The person can come back at any time to move, add or delete beats,
  reanalyze a section, or start over. Starting over on a song that had
  beats turns Confirm into **Remove Beats**, which takes them off the
  timeline (back to the detected beats) as one undo step there. The
  Music clip's context menu also has **Remove Beats**, for a song with a
  beat map, without opening the panel.

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
   end. Once the first is down, the panel says roughly what tempo the
   music around it has (`BeatFitting.provisionalTempo`, from the 12
   seconds around it), worked out off the main thread a moment after
   the anchor stops moving. Each anchor is dropped on the waveform or at the playhead (M), and
   is beat 1 unless the person picks another position. While the song
   plays, M can be tapped along with it: each tap drops a pinned beat
   where the song is, and taps in a row count on through the section's
   measure (1, 2, 3, 4, 1…), in ramps too. A run starts again after a
   pause, a seek, a new section or more than 4 seconds between taps; its
   first tap is 1 in a section not filled yet, and follows the beat before
   it in a filled one. Tapped beats are pinned, so a fill keeps them (each
   moved onto its onset within 15 ms); one tapped well off the beat bends
   the grid until it is moved or deleted. Any note on a MIDI pad or
   keyboard taps the same way (see [Tapping on MIDI](#tapping-on-midi)).
2. **Line them up.** The tick plays on each anchor while the song plays.
   Drag the anchor on the waveform, which zooms down to single samples.
   From the keyboard (and VoiceOver), ← → move the selected anchor by
   1 ms, ⌥ by one sample of the file, and ⇧ by 10 ms; there are no nudge
   buttons. A loop toggle repeats the
   two bars around the selected anchor.
3. **Confirm.** The number of beats between the anchors comes from a rough
   tempo estimate. Dividing the time between the anchors by that number
   gives the exact period. The panel shows the tempo with two decimals; the
   person can type a tempo, which fills again at it. **×2** and **÷2** work
   on the beats themselves instead of fitting again, so nothing else moves:
   ×2 puts a beat half way between each two (and half a beat past each end
   where the section reaches), snapped like any other; ÷2 keeps every
   other beat, on the side of the pinned beats (or of the downbeats when
   none is pinned). ÷2 is refused when pinned beats sit on both sides, so
   halving would drop one, or below 30 BPM; ×2 above 400.
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
  as detection does, over at most a minute from the middle of that
  stretch. The estimate is kept on the curve, so filling the same stretch
  again doesn't work it out again.
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
  onsets. The candidates are taken in blocks of 17, each scored first by
  a bound no grid in it can beat (the onsets in a window wide enough for
  all of them), so only blocks that could hold the best are scored step
  by step: the same answer as trying every step, at a fraction of the
  work. Then a least-squares fit of the onset peaks near that grid.
  Beats past the anchors step at this period; between pinned beats they
  stay evenly spaced.
- **Refining** (intent and ramps) is Ellis's dynamic programming held at
  both ends: each beat is searched within a quarter of a gap of its even
  place, scoring the onset there against how far each gap strays from the
  expected one. Peaks are placed between frames with a parabola. A beat
  is searched at most 0.28 s either side, which only limits
  tempos under 54 BPM.
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
  it was put. A pinned beat that snapping moved keeps where the person
  put it: the panel says how far it moved, and **Undo Snap** puts it back,
  where fills then leave it (saved as `heard` and `unsnapped` on the
  beat), and leaves it out of lining up the curve (see Onset timing):
  it is meant to sit where it is, not where its onset is heard. **Snap
  Again** snaps that one beat back onto its onset without filling again.
  Moving it by hand forgets where it was heard.
- **Onset timing.** Spectral flux peaks about 14 ms before a sharp hit,
  because it rises as soon as the hit enters the analysis window. The
  anchors are lined up by ear, so the curve is shifted by the median
  distance from each anchor to its nearest clear peak. That also takes in
  how soft the song's attacks are. With no anchor on a clear onset, it is
  shifted by the measured 14.3 ms.
- **Ramps** try every count within 15% of what an even change of tempo
  holds. A count away from that costs a little (a tenth of the chain's
  tightness), because ramps are seldom even.

- **What can't be filled.** Pinned beats are sorted and any on the same
  sample count once. A fill stops with a message saying what to do when
  it has too few anchors, when no usable tempo comes out (*Couldn't find
  a tempo here. Try pinning two beats farther apart.*), or when a
  consistent section is shorter than two beats at its tempo.
- **Off the main thread.** A fill runs detached and its result lands in
  one assignment, as one undo step. Editing the draft while it runs, or
  filling again, cancels it: the long searches check for cancellation.
- **After a fill** the panel notes what the person might not expect,
  from the fill's report (`BeatFitting.FillReport`): that the anchors'
  places in the measure settled the count over the onsets, that over a
  quarter of the beats had no clear onset to snap to, that the beats stop
  where the music does before the edge, and whether the edges snapped.

## Sections

When the song has more than one tempo, the person picks **Sections** at the
start, and draws them before marking any:

- Pick a kind (consistent, ramp, none), then drag across the waveform, or
  the strip of sections above it, to draw a section of it. Over unmarked
  song the pointer is a crosshair, and over a section in the strip a
  pointing hand, since a click there selects it. A click on the waveform still moves the
  playhead, and a drag inside a section scrubs. The ends need not be exact
  at the start and end of the song, but should be close between two
  sections.
- While drawing, the new section is shown where it will land, with a
  dashed outline: it stops at the sections either side, so one never
  covers another.
- Drag a section's edge to move it. Pinch to zoom in for the in-between
  edges. Drawn ends and dragged edges snap as on the timeline, within
  8 points, to the other sections' edges, beats, the playhead and the
  song's ends. The timeline's snap line shows where an edge caught, and
  also where it stopped against a neighbour. Where two sections meet, the
  edge of the one the pointer is over is the one that moves.
- **M** marks the unmarked stretch up to the playhead with the chosen
  kind, back to the section before it (or the song's start)
  (`BeatMap.drawSection(_:upTo:duration:)`). Pressed at each change while
  the song plays, it marks the sections one after another.
- **Option-drag a section** in the strip to copy it (`BeatMap.copySection`):
  the copy is drawn where it will land, as a drawn section is, with the
  snap line at its start, which snaps like a drawn end. It takes the
  section's kind, length, beats per measure and steadiness, in the
  unmarked stretch under its start, or, dropped inside a section, the one
  on the nearer side of it, cut short to fit; the beats pinned in it come
  along. A filled consistent section's copy is filled at its tempo, as
  **Paste Tempo** fills one (from its start as beat 1 when no pinned beat
  came along); any other copy waits to be filled.
- **Option-drag a beat** to copy it: the beat stays, and a dashed line
  with a ring shows where the copy goes. The copy is pinned and takes the
  beat's place in the measure (`BeatMap.copyBeat`); it can't land on
  another beat or outside every section.
- **Double-click** empty waveform to fill it, like a paint bucket, with
  the chosen kind, from the nearest section edge (or the start or end of
  the song) on the left to the nearest one on the right. Double-clicking
  inside a section changes its kind to the chosen one.
- Click inside a section to select it; picking a kind then changes it to
  that kind and lets go of it, so the next pick only sets what is drawn
  next, and Delete removes it. A section just drawn, filled or marked
  with M is selected, so picking a kind next changes it once. Outside
  drawing, a lone section (as with one tempo) is selected without asking.
- **Continue**, in the footer where Confirm is otherwise, ends drawing and
  goes on to marking beats.
- The strip looks like the timeline's section lane, with chips named by
  their kind, then the beats per measure once set, then the tempo once
  filled. Each kind has its colour: consistent sections the timeline's
  bronze, ramps violet, none grey. The colour also tints the section's
  stretch of the waveform. A section that starts left of the view keeps its
  name at the view's left edge.
- Keyboard: F fills the gap at the playhead, and [ and ] move the
  selected section's start and end to the playhead, so none of it needs a
  drag. The same are buttons in the panel.

Then each consistent section is marked as above, one after another.
A filled consistent section's details (its tempo, beats per measure and
steadiness) can be copied (**Copy Tempo**, ⌘C) and pasted (**Paste
Tempo**, ⌘V) onto another consistent section that keeps that tempo. The
paste takes the section's start to be beat 1: it pins a downbeat there
(snapped onto its onset like any pinned beat), drops the beats the section
had, and fills the rest at the copied tempo, as one undo step. Ramps
change tempo and unanalyzed sections have none, so neither copies or
takes a paste.
Switching sections in the panel's picker, or moving on to the next one
after a fill, scrolls the section into view, centred if it fits; the zoom
is left alone. The
first time a consistent section is filled its edges snap to its first and
last beats, so neighbouring sections meet on a beat. Filling it again
(reanalyzing, or at a typed tempo) leaves the edges where they are.

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

The panel's transport has the song's own **volume**, apart from the
timeline's mix and remembered across launches. Once a beat or anchor is
placed, it also shows the tick's on/off toggle (a metronome), and a
popover beside it for the tick's **pitch** and **volume**; before that
there is nothing to tick on. The transport stays one line either way, so
the waveform under it never moves. The downbeat (position
1) plays an octave above the other beats. The same two settings are in the
timeline's view options; they are one pair of settings, remembered across
launches. The pitch slider stops at 2000 Hz, so the downbeat goes no higher
than 4000 Hz.

## Tapping on MIDI

While the Beat Match panel is open, a note-on (with a velocity) on any
channel of any MIDI source taps as M does: from a pad, a keyboard or a
DAW, plugged in before or while the panel is open (`MIDITaps`, through
Core MIDI). A key press is placed wherever the song is when the main
thread gets to it, tens of milliseconds late at times; a MIDI note carries
the host time it arrived at, which is converted through the song player's
timebase to the song's time, so it lands where it was played. While the
song is paused a MIDI tap drops a beat at the playhead, as M does.

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
   clip's menu or the inspector. Left of the waveform, the sidebar shows
   the three steps (Tempo, Sections, Beats; Sections struck through for
   one tempo) and how many sections are filled, then what to do as one
   line with tips under it, then the controls in labelled groups. Each
   command shows its key as a keycap rather than in its name. Start Over,
   Undo, Redo, Cancel and Confirm (Continue while drawing) sit in a footer
   that doesn't scroll. Filling a section selects the next to mark without
   scrolling the view. Resizing the
   panel keeps the same stretch of
   song in view. The waveform is drawn to the song's loudest sample and
   clipped to its area, and the panel's size is the window's alone (the
   hosting view only sets its minimum). The green zoom button widens the
   panel to the screen and leaves its height alone. Over a section's edge
   or a beat, the pointer is a resize arrow, since those are what a drag
   moves; a section never moves as a whole. Each beat's line hangs from a
   tag with its number in the measure: brighter for pinned beats and
   anchors, the accent for the selected beat. When the beats are too close
   for every tag, only downbeats keep theirs, and closer still none do,
   though a pinned beat keeps a small handle. While it is open the editor is
   darkened and takes no pointer input at all, the Timeline menu rests,
   and a click on the editor brings the panel back. Edits change the draft in place, so a
   nudge or drop never shows the old beat for a frame. While the song
   plays nothing in the panel is rebuilt: the playhead (Core Animation
   layers, as on the timeline) and the timecode read the player on each
   display frame, and the waveform is drawn on its own, redrawn only by
   zooming and scrolling. The view doesn't follow the playhead, so the
   person can browse the song and click where to hear while it plays. The
   view stops at the song's ends, with nothing shown before 0:00 or past
   the end. Zooming out past the whole song squeezes the waveform toward
   the pointer, over a darker surround, and zooming in past the closest
   stretches it, against more resistance the further it goes; it springs
   back when the pinch ends, and the zoom buttons and ⌘- give the same
   bump. This is the editor's shared zoom edge (`RubberBandZoom`, see
   timeline.md). With reduced motion it simply stops. Clicking a beat
   selects it and moves the playhead where the click landed, so clicks
   seek however close the beats are. Keys: Space plays, M drops a
   beat or anchor at the playhead (while drawing, marks up to it), ⌘Z
   and ⇧⌘Z undo and redo, ← → nudge the selected beat (⌥ one
   sample, ⇧ 10 ms; without a selection they move the playhead a second),
   ↑ ↓ select the previous and next beat, Delete, L loops, Return fills,
   ⌘= ⌘- ⌘0 zoom, ⌘C and ⌘V copy and paste a consistent section's tempo. Not yet tried on screen: drag feel, the dimming, and
   focus moving between the panel and the editor.
6. Timeline thinning by measures, and the Music-only picker. **Built.**
