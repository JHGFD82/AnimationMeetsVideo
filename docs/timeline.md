# Timeline view

Status: **implemented**: zooming and scrolling, the ruler, the playhead,
and moving and trimming clips on the frame grid. The placement rules, the
viewport math and the ruler and beat grouping are unit tested. The view
itself has been checked in offscreen renders, not yet driven on screen
with a trackpad. What is not built is listed under
[Not implemented yet](#not-implemented-yet).

The timeline sits under the viewer: a label column on the left (layer
number and name, and transform property rows when shown), and the track
area on the right with the ruler across its top.

## Zoom and scroll

The track area scrolls itself sideways instead of sitting in a horizontal
scroll view, so a zoom can change the scale and the scroll offset in one
step. `TimelineViewport` holds both. The scale is either "fitted" or a
number of points per second. It is not stored relative to the fit, so a
drop that makes the timeline longer does not rescale the clips on screen.

- The track area spans the timeline plus a little room after its end (5%,
  at least one second) to drag clips into. The ruler shades that time.
- Fully zoomed out, that whole span fits the window. Fully zoomed in, one
  frame is 80 points wide.
- **Pinch** on a trackpad, or **Option-scroll**, zooms about the pointer:
  the moment under the pointer stays under it.
- The **zoom buttons** in the timeline's header, the **-** and **=** keys
  and the **zoom slider** in the view options zoom about the playhead. The
  playhead stays where it is on screen, or comes to the middle if it was out
  of view. The slider moves the zoom by the same ratio for each step.
  **\\** (or **Fit to Window**) fits the timeline again.
- Sideways trackpad scrolling, Shift-scroll on a mouse wheel and the
  scrollbar under the tracks scroll in time. Plain vertical scrolling moves
  through the layers. The ruler stays at the top.
- Zoom and scroll are view state: they reset when switching timelines and
  are not saved.

## Ruler

Ticks are grouped by whole frames. Every step splits a second into a whole
number of frames, or is a round number of seconds:

| Frame rate | Steps within a second, in frames |
| --- | --- |
| 24 (and 23.976) | 1, 2, 4, 6 (a quarter second), 8, 12 (a half second) |
| 25 | 1, 5 |
| 30 (and 29.97) | 1, 2, 5, 6, 10, 15 (a half second) |

Above a second the steps are 1, 2, 5, 10, 15 and 30 seconds, then minutes.
Labels go on the smallest step that is at least 80 points wide, with a
taller tick halfway and short ticks on the smallest step that divides the
label step and is at least 6 points wide. Labels are compact timecode
(`seconds:frames`, with minutes and hours added when needed), counted in
whole frames so NTSC rates line up with the timecode readout.

Beat markers (see [beat-detection.md](beat-detection.md)) are grouped in
the same spirit: once they would be closer than 10 points, only every 2nd,
4th, 8th… beat is drawn.

## Playhead

The playhead is a red line through the track area with a red tab at its
top, in the ruler. Clicking or dragging anywhere in the ruler, or in empty
track space, moves it there. It lands on frames and stays within the
timeline.

## Moving and trimming clips

Dragging the middle of a clip moves it; dragging within a few points of
either edge trims that edge without destroying anything. The rules for where
a clip may go are in `ClipPlacement.swift`:

- **Video and nested timelines lock to frames.** Their start and end land
  on whole frames of the timeline's rate, never between two. This uses
  exact frame counts, so it holds at 23.976 and 29.97.
- **Audio moves freely**, to 1/48000 of a second.
- Clips never start before zero and never overlap on a layer. A move onto a
  neighbor goes to the nearest free side of it, rounded off the neighbor
  onto a frame for video. A move onto a layer with no gap big enough is
  refused.
- Trimming the start keeps the clip's end fixed. A trim can't reveal media
  before the source's start or after its end, can't cross a neighbor, and
  can't make a clip shorter than one frame (a twentieth of a second for
  audio).

While dragging, the clip is drawn where it will land under these rules,
not under the pointer, so it does not jump on release. The functions that
work this out (`resolvedStart(ofMoving:…)`, `resolvedTrimStart(of:…)`,
`resolvedTrimEnd(of:…)`) do not change the project, and the editing
functions commit what they return.

## Not implemented yet

- **Snapping** to other clips' edges, the playhead or beat markers.
- Scrolling to follow the playhead during playback.
- Moving a clip to another layer by dragging it up or down.
