# Motion designer

Status: **planned, not implemented**. Two things it needs come first,
and are planned here too: clips attached to the music, and hold
keyframes.

Music videos are cut to the music, and the project already knows the
music's timing from the beat map ([beat-matching.md](beat-matching.md)).
A clip's speed today is a keyframed percentage in source time
([effects.md](effects.md#time-and-shutter)): it says how fast the
footage plays, never which frame lands where. The motion designer lets
the person say "this frame happens on this beat" and retime everything
else around it, by dragging frames along a time graph.

## Overview

- **A tool, not stored data.** The designer is a session. **Done** writes
  ordinary speed keyframes to the clips, as one undo step, and every
  marker is forgotten. Opening it again rebuilds markers from those
  keyframes (see [Opening on keyframed clips](#opening-on-keyframed-clips)).
  **Cancel** leaves the project as it was, asking first if anything
  changed.
- **The panel** floats over the editor like the beat match panel: the
  editor is darkened and takes no input while it is open, and the panel
  works on a draft with its own undo.
- It shows the footage above the music it is attached to (the song's
  waveform and its beat markers) over the same span, and a **time
  graph** between them: across is timeline time (the music), up is
  source time (the footage). The line's slope is the speed; a straight
  line is a steady speed.
- It opens on one clip or several selected clips (the clip's menu,
  **Motion Designer…**).

## Several clips as one piece

Selected clips are laid end to end on the graph and retimed as one run;
on Done each clip gets its own share of the keyframes.

- **All on one layer.** If the selection spans layers the designer
  doesn't open; it suggests nesting the clips into a nested timeline
  ([effects.md](effects.md)) and opening that clip instead.
- **Gaps** between selected clips are segments of the run of their own.
  They take no markers, and retiming may safely close them: a clip that
  grows eats into the gap, one that shrinks widens it.

## Points on the graph

- **Hit.** A frame of the footage pinned to a beat of the music: it plays
  on that beat whatever else changes. A fixed point on the graph.
- **Marker.** Grabbing any other frame drops a marker there. Dragging it
  along time retimes the footage on both sides: the line bends at the
  marker and still passes through every hit.
- **Pace marker.** A marker that sets the speed *after* it to a typed
  value (**Set Pace…**). With hit H and marker M dragged so H→M plays at
  50%, a pace marker P past M at 200% makes the footage after P play at
  200%.
  - Another marker beyond P slides in time so P's pace holds.
  - A hit beyond P can't stay put and hold the pace too. The person is
    warned that the hit will become a marker and move to honour the
    pace; on OK it does, on Cancel the pace isn't set.
- Any marker can be made a hit, and a hit a marker.

### Open ends

Past the outermost point on a side, the speed carries on at the speed of
the segment next to it, **to the end of that clip**. With H→M at 50%,
the rest of that clip plays at 50% too. The next clip keeps whatever
speed it already had.

### Easing

Corners between segments can be eased as in the graph editor (the same
eases and presets, `KeyframeEase`), so the speed ramps instead of
stepping. Eases bend the curve between points without moving them, so
hits still land on their beats. Speeds are held to what Time allows
(1% to 10000%, never through zero).

### Beat markers and snapping

The song's beats are drawn on the graph and the music lane, thinned by
zoom as on the timeline, and points snap to them (and to the playhead and
the clips' edges) as on the timeline. A toggle turns the beat markers
off, as the timeline's view options do.

## Lengths and positions

Retiming changes a clip's length, never where other clips are.

- A clip that grows stops against the next clip; moving that clip is up
  to the person.
- Clips can be **moved** in the designer: dragged along time, or moved
  from the keyboard, which lengthens or shortens the gaps around them.
  Unselected clips on the layer are shown but never move, and bound how
  far a selected clip can go.
- The designer's span grows and shrinks with the run: retiming or moving
  the first or last clip extends or contracts the time shown, and the
  music under it.

### Footage available

A growing clip extends its trim into the footage around it, as far as
there is footage:

- A clip of a **scene** grows only to that scene's edges
  ([scene-cuts.md](scene-cuts.md)), even where the file carries on into
  the next shot. Merging scenes in the browser is how the person makes
  more footage available, so the designer reads scene edges as they are
  now.
- A clip of a whole file grows to the file's ends.
- Where retiming would need footage past the edge, the graph shows the
  edge and the run stops there, with a note pointing to merging scenes.

## Opening on keyframed clips

A clip's speed keyframes become points:

- Each speed keyframe becomes a **marker**; the person can turn any into
  a hit.
- A [hold keyframe](#hold-keyframes) followed by another keyframe is a
  step in speed: the keyframe after the hold becomes a **pace marker** at
  its speed.
- Two keyframes on **adjacent frames** with different speeds do the job
  of one pace marker, so they are read the same way: a pace marker at the
  second, and no marker for the first.

Opening the designer and pressing Done without changing anything leaves
the keyframes as they were.

## Writing keyframes

On Done the run's time map becomes speed keyframes, per clip, in source
time:

- Keyframes go only where the speed changes; a steady stretch needs none.
- A sharp corner, every pace marker included, is the keyframe before it
  set to **hold**, then a keyframe at the corner with the new speed: the
  pattern read back as a pace marker.
- An eased corner is keyframes with eases chosen so the speed's integral
  (`SpeedIntegral`) over each segment equals the segment's length on the
  timeline, so each hit lands on its beat to within a placed time
  (1/240000 s).
- Each clip's start and trim follow, in the same undo step.

The time map itself (ordered points, each a source time across the run, a
song time, a kind and its eases) and the rules above are pure functions,
unit tested like `BeatFitting`.

## Clips attached to the music

Video in a music video depends on the music, so clips follow it.

- Each visual clip is **attached** to one song: a point in the clip's
  source and the song time it sits on. Moving the song's clip moves the
  clips attached to it.
- The song is the clip on the **first Music layer** at that point, or the
  second if the first has none there, and so on.
- **One clip, one song.** A clip that runs across two songs is cut, so
  the second piece attaches to the second song.
- The person can **re-attach** a clip (change which of its frames ties to
  which point of the song) for when a song is cut and moved with footage
  already on it.
- The designer's hits are forgotten on Done; the attachment is what keeps
  the hit frame on its beat afterwards.

## Hold keyframes

A hold keyframe keeps its value until the next keyframe, then jumps to
that keyframe's value, as After Effects' hold keyframes do (listed as not
implemented in [layer-transforms.md](layer-transforms.md)).

- `Keyframe` gains a hold flag, saved only when true.
- `SpeedIntegral` treats a held piece as a constant speed, exactly.
- The graph editor draws a held piece as a step and offers **Hold** with
  the eases in a keyframe's menu.
- It works on every keyframed control, not only speed.

## Accessibility

Following [accessibility.md](accessibility.md): each point and clip on
the graph is an accessibility element with actions (move, make hit or
marker, set pace, delete); points and clips move from the keyboard; the
pace is typed.

## Building it

1. This document. **Done.**
2. Clips attached to the music: model, saving, moving with the song,
   cutting at a song change, re-attaching.
3. Hold keyframes: model, saving, `SpeedIntegral`, the graph editor.
4. The time map: solving, reading keyframes, writing them, unit tested.
5. The panel (`UI/MotionDesigner/`), built on the beat match panel's
   shell, waveform, transport and zoom (`RubberBandZoom`), with the graph
   drawn like the keyframe graph.
6. Accessibility.
