# Motion designer

Status: **planned, not implemented**. Two things it needs come first,
and are described here too, and both are built: clips attached to the
music, and hold keyframes.

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
  - Another marker beyond P slides in time so P's pace holds, and a run
    of pace markers carries on, each placing the next.
  - A hit beyond P can't stay put and hold the pace too. The person is
    warned that the hit will become a marker and move to honour the
    pace; on OK it does, on Cancel the pace isn't set. Making the point
    right after a pace marker a hit asks the same way, and ends that pace.
  - Dragging the point right after P sets P's pace instead of bending the
    line at P. Taking away the point between P and a hit ends P's pace.
- Any marker can be made a hit, and a hit a marker.
- A drag stops where a stretch would play faster than 10000% or slower
  than 1%, or backwards; an edit that can't fit at all is refused.
- A new marker lands where its frame plays now, so adding one changes
  nothing until it is moved.

### Open ends

Past the outermost point on a side, the speed carries on at the speed of
the segment next to it, **to the end of that clip**. With H→M at 50%,
the rest of that clip plays at 50% too. The next clip keeps whatever
speed it already had. A lone point carries on at the speed the clip
played at before (a lone pace marker at its pace after it). Where an
eased corner nearby makes the stretch's steady part faster or slower
than its average, the open end carries on at that steady speed, so it
doesn't step at the outermost point.

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

The music can't move in the designer; only footage does. Retiming
changes a clip's length, never where other clips are.

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

**Built** (`ClipTimeMap(reading:frameDuration:)`).

- Each speed keyframe the clip plays becomes a **marker**, where it plays
  now; the person can turn any into a hit. Hits aren't kept on Done, so
  they come back as markers.
- A [hold keyframe](#hold-keyframes) followed by another keyframe is a
  step in speed: the keyframe after the hold becomes a **pace marker** at
  its speed.
- Two keyframes a frame or less apart with different speeds do the job
  of one pace marker, so they are read the same way: a pace marker at the
  second, and no marker for the first.
- What writing adds makes no point: a hold at the very start of the trim
  (the speed before the first point), and the keyframes that only shape
  an eased corner (linear, beside a keyframe eased toward them). A
  hand-made linear keyframe beside an eased one is taken for one of those.
- A keyframe with eases makes an eased point.
- A clip at one speed has no points; it plays at that speed until some
  are added.

Opening the designer and pressing Done without changing a clip leaves its
keyframes as they were: only clips that were changed are written (the
panel's part, step 5). A ramp
read from keyframes becomes markers at its ends, and if the person
changes that clip, the stretch between them is written steady (or eased,
if they ease its corners) rather than as the ramp's own curve.

## Writing keyframes

**Built** (`ClipTimeMap.writtenSpeed()`). On Done each changed clip's
time map becomes speed keyframes, in source time, and where the clip then
starts:

- Keyframes go only where the speed changes; a steady stretch needs none,
  and a clip at one speed throughout gets a single speed.
- A sharp corner, every pace marker included, is the keyframe before it
  set to **hold**, then a keyframe at the corner with the new speed: the
  pattern read back as a pace marker.
- An eased corner ramps over a third of the stretch on either side,
  through the speed of the line joining the two stretches, with Easy
  Ease on the corner's keyframe so the speed turns smoothly. The rest of
  each stretch plays steadily at the speed that keeps the stretch its
  length (solved against `SpeedIntegral`), so every point, and so every
  hit, lands where it was put, to within a placed time (1/240000 s). A
  corner whose speed doesn't change has nothing to ease.
- Each clip's start follows, in the same undo step.

The time map is one clip's (`ClipTimeMap`: the points in source order,
each with its frame, its time on the timeline, its kind and whether it is
eased), since open ends stop at the clip's edges; the panel keeps one for
each clip of the run. It and the rules above are pure functions, unit
tested like `BeatFitting`.

## Clips attached to the music

**Built** (`MusicAttachment`), not yet tried on screen. Video in a music
video depends on the music, so clips follow it.

- Each clip on a video or sound layer is **attached** to one song: one of
  its frames, and the moment of the song it plays on
  (`TimelineClip.music`). By default the frame is the clip's first. Moving
  the song's clip moves the clips attached to it, so that frame plays on
  that moment again (to the nearest frame for clips with pictures; the
  rounding never adds up, since each move starts again from the moment).
- The song is the clip on the **first Music layer** at that frame, or the
  second if the first has none there, and so on. A clip with no song under
  it waits unattached until one is put there.
- **One clip, one song.** A clip that runs across two songs follows the
  one under its frame; to tie the rest to the second song, cut it.
- Footage that would be covered by a clip following its song is pushed
  later on its layer, and attached again where it lands.
- Moving, trimming, slipping or retiming a clip attaches it again where it
  now sits, as does being pushed aside. Moving a song and its footage
  together keeps both where they were put.
- A cut song's pieces each carry their own footage: the attachment names
  the song's clip, and once a cut gives the pieces new IDs, the piece of the
  same file holding the moment.
- The clip's menu has **Follow Music**, on by default: off, the clip is
  never attached and stays put when songs move. **Attach to Music at
  Playhead** ties the frame under the playhead to the song there, for when
  a song is cut and moved with footage already on it, or a clip straddles
  two songs. Both are VoiceOver actions on the clip too.
- It is worked out after each edit, against the project as it was just
  before (`EditingProject.followMusic(from:)`), so every way of moving a
  song (dragging, nudging, trimming, slipping, rolling, pasting) is
  covered alike. It joins the edit's undo step; undo and redo put back
  snapshots that are already right, so nothing follows then.
- Saved in `project.json` on each clip: `music` (`song`, `asset`, `time`,
  and `frame` only when the person chose one), and `followsMusic` only when
  false.
- Not yet: footage following while the song is dragged (it follows on the
  drop), and a mark on the clip for a chosen frame.
- The designer's hits are forgotten on Done; the attachment is what keeps
  the hit frame on its beat afterwards.

## Hold keyframes

**Built.** A hold keyframe keeps its value until the next keyframe, then
jumps to that keyframe's value, as After Effects' hold keyframes do.

- `Keyframe.hold`, saved as `"hold": true` on the keyframe only when set.
  It is how the keyframe leaves: its `easeOut` and the next keyframe's
  `easeIn` do nothing while it holds.
- **Hold** is an ease preset (`KeyframeEase.Preset.hold`), so it is in
  every keyframe menu, the graph editor's toolbar and the keyframe's
  VoiceOver actions, and on ⌃⌥H at the playhead beside F9's eases.
  Linear, Ease Out and Easy Ease set how the keyframe leaves, so they end
  a hold; Ease In keeps it. `AnimatedValue.toggleHold(at:)` switches it,
  leaving that side linear.
- Its mark is squared off on the side it leaves by, on the lanes and in
  the graph; the graph draws the held piece flat with a step at the next
  keyframe, and shows no handles across it.
- A held speed is a constant speed between the two keyframes, which
  `SpeedIntegral` integrates exactly. Exports cut a ramped clip's pieces
  at the step too, so it lands on its frame instead of being spread over
  a piece.
- It works on every keyframed control, not only speed. Moving, copying,
  reversing and the graph editor's conversions keep it
  (`Keyframe.with(value:)`).

## Accessibility

Following [accessibility.md](accessibility.md): each point and clip on
the graph is an accessibility element with actions (move, make hit or
marker, set pace, delete); points and clips move from the keyboard; the
pace is typed.

## Building it

1. This document. **Done.**
2. Clips attached to the music: model, saving, moving with the song,
   re-attaching. **Built.**
3. Hold keyframes: model, saving, `SpeedIntegral`, the graph editor.
   **Built.**
4. The time map: solving, reading keyframes, writing them, unit tested.
   **Built** (`Model/MotionDesigner/`).
5. The panel (`UI/MotionDesigner/`), built on the beat match panel's
   shell, waveform, transport and zoom (`RubberBandZoom`), with the graph
   drawn like the keyframe graph.
6. Accessibility.
