# Motion designer

Status: **built** except where noted (see [Building it](#building-it));
the panel is compile-checked and was rendered offscreen, but hasn't been
used on screen yet. Two things it needs came first and are described
here too: clips attached to the music, and hold keyframes.

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
  **Motion Designer…**, or **Motion Designer for Selection…** on a clip
  lassoed with others). Songs, and clips that play backwards, are refused
  with the reason.

## The panel

**Built** (`UI/MotionDesigner/`). The transport runs across the top:
play the music, the playhead's timecode, **Beats** (show them) and
**Snap**, and zoom. The sidebar is on the left, and the lanes fill the
rest, on one timeline across: a ruler, the footage, the time graph and
the music.

- **The footage strip** places each frame where it plays in the draft:
  frames are taken at even steps of the footage, one tile's width apart
  at 100%, so a stretch played slowly spreads them out with the lane
  showing between, and one played fast crowds them into slivers. It is
  the one thing in the panel that shows retiming at a glance.
- **The graph** runs up through the run's footage clip after clip, so
  the run reads as one line in each clip's own colour: steep where fast,
  shallow where slow, flat (dashed) over a gap. Each stretch's speed is
  read out over it, once for stretches either side of a point at one
  speed. Points use the keyframes' marks: hits in the bright "placed"
  tone, markers quieter, a pace marker squared off where the speed steps
  with its pace beside it, an eased point pinched; the selected one is
  ringed in the accent.
- **A hit's pin** runs from its frame in the strip, through the graph,
  to its beat in the music lane.
- **The music lane** shows the first Music layer under the run: its
  waveform and its beats, which are also drawn faintly across the graph.
  Play plays that layer alone, laid out in timeline time.
- Grabbing the line drops a marker on that frame and drags it; grabbing a
  point drags it. Drags snap, within 8 points, to the beats (while shown),
  the playhead and the edges of the layer's other clips; the snap line
  shows where. A click elsewhere moves the playhead, as a drag on the
  ruler or the music scrubs.
- Dragging a clip in the strip moves it by whole frames, unless a hit
  holds it.
- **The sidebar** shows the frame under the playhead, then what is
  selected: a point's kind (Hit, Marker, Pace), its pace (typed), Ease
  and its ramps in and out,
  a frame earlier or later and Remove; or a clip's start and end and a
  frame earlier or later. With nothing selected it says what to do.
  Warnings sit under that; Cancel and Done at the foot.
- A pace marker before a hit, or a hit right after a pace marker, asks
  first, naming what it costs.
- Keys: Space plays, M puts a marker under the playhead, H makes the
  selected point a hit, P edits its pace, E eases it, Delete removes it,
  ← → move it (or the selected clip, or the playhead) a frame and ⇧ ten,
  Escape lets go (or cancels a drag), ⌘= ⌘- ⌘0 zoom, ⌘Z undoes in the
  draft, ⌘Return is Done. Scrolling scrolls; ⌥ or ⌘ scrolling, or a
  pinch, zooms.

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

A point can be eased, so the speed ramps through it instead of stepping
(E, the sidebar's **Ease through this point**, or the menu). Its ramps
are shaped by **handles**: with an eased point selected, the graph shows
a handle on the line where each ramp ends, with a stem back to the
point, as the graph editor's do. Dragging a handle along the line
lengthens or shortens that ramp, from 5% to 90% of the stretch on its
side (`TimeEase`), so a ramp can be short and sharp on one side and long
on the other. Two ramps meeting in one stretch share 90% of it, each
held to what the other leaves. The handles move only along the line,
never up or down: bending it would move frames off their places. However
the ramps are shaped, the rest of each stretch is solved to keep its
length, so hits still land on their beats. The sidebar's **Ramp in** and
**Ramp out** sliders, and the point's VoiceOver actions (longer or
shorter ramp in or out, a tenth of the stretch at a time), do the same
from the keyboard. Speeds are held to what Time allows (1% to 10000%,
never through zero).

### Beat markers and snapping

The song's beats are drawn on the graph and the music lane, thinned by
zoom as on the timeline, and points snap to them (and to the playhead and
the clips' edges) as on the timeline. A toggle turns the beat markers
off, as the timeline's view options do.

## Lengths and positions

The music can't move in the designer; only footage does, and never
where other clips are.

- **Retiming keeps a clip's edges.** When moving a point, setting a pace
  or removing a point changes the speed at a clip's open ends, the clip
  takes in footage or gives it back so its start and end stay where they
  were (`MotionRun.hold`): speeding up draws on more footage, slowing
  down returns some. Only once its footage runs out does an edge move:
  in, as a clip sped up past its footage gets shorter, or out, when
  giving footage back would cut past its outermost point. An edge moving
  out stops against the next clip; moving that clip is up to the person.
- **Trimming.** Dragging a clip's edge in the strip reveals or hides
  footage at the speed it plays there, snapping as points do, as far as
  its footage goes, never past its outermost point or to under a frame,
  and stopping against a neighbour (`MotionRun.trim`). The sidebar and
  the clip's VoiceOver actions trim a frame at a time.
- Clips can be **moved** in the designer: dragged along time, or moved
  from the keyboard, which lengthens or shortens the gaps around them.
  Unselected clips on the layer are shown but never move, and bound how
  far a selected clip can go.
- The view fits the run when it opens and scrolls freely past it, so
  retiming or moving the first or last clip never runs out of room to
  show it.

### Footage available

**Built.** A clip's trim reaches only the footage of its scene
(`EditingProject.sceneFootage(of:track:)`, `MotionRun.Piece.footage`):

- From the start of the scene its first frame is in to the end of the
  scene its last frame is in ([scene-cuts.md](scene-cuts.md)), even where
  the file carries on into the next shot. A clip already spanning a cut
  reaches both scenes, and one placed whole reaches the whole file.
- The scenes are the browser's: detected cuts with the person's edits,
  read when the designer opens. Merging scenes in the browser is how the
  person gives a clip more footage; a video not yet analyzed is one
  scene.
- Anything but video (stills, shapes, nested timelines) may use all of
  its source.
- Where a clip's trim has reached its scene's edge, the strip draws a
  bracket at that edge, and the sidebar says there is no more of its
  scene that way and to merge scenes for more.
- Done rounds a clip's start onto a frame by moving its trim, rounding
  later instead if earlier would leave its footage.

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
- A keyframe with eases makes an eased point, whose ramps reach as far
  as the ramp keyframes beside it (a third of each stretch without them).
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
- An eased corner ramps over the share of each stretch its handles reach
  (a third by default), shrunk to share a stretch where two ramps would
  cross, through the speed of the line joining the two stretches, with
  Easy Ease on the corner's keyframe so the speed turns smoothly. A
  linear keyframe ends each ramp. A point beside an eased one keeps its
  keyframe even where the speed doesn't change there, since reading
  skips the ramp keyframes and needs both ends of each stretch; so a
  shaped ramp reads back with the reach it was given. The rest of
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

Following [accessibility.md](accessibility.md). The graph is a group
named with its clips and hits; each point is an element read as its kind
and time, then its frame and the speed after it, adjustable a frame at a
time, with Make hit, Make marker, Set pace, Ease (or Sharpen) and Remove
as actions; the graph adds Add marker at playhead. Each clip in the strip
reads its name and span, with a frame earlier or later as actions. The
ruler is the playhead, adjustable a frame at a time. Everything a drag
does has a key, a button or an action.

## Building it

1. This document. **Done.**
2. Clips attached to the music: model, saving, moving with the song,
   re-attaching. **Built.**
3. Hold keyframes: model, saving, `SpeedIntegral`, the graph editor.
   **Built.**
4. The time map: solving, reading keyframes, writing them, unit tested.
   **Built** (`Model/MotionDesigner/`).
5. The panel (`UI/MotionDesigner/`), on the shared `DraftPanel` Beat
   Match now uses too. **Built** (`MotionRun` for the rules across clips,
   unit tested; `MotionDesignSession` for the draft, its undo and the
   player; the views).
6. Accessibility. **Built** with the panel.

Not yet: the monitor shows stills, not moving footage, while the
music plays; the zoom has no rubber-band edge; and the panel hasn't been
used on screen.
