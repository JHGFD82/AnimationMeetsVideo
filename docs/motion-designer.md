# Motion designer

Status: **built** except where noted (see [Building it](#building-it));
the panel is compile-checked and was rendered offscreen, but hasn't been
used on screen yet. Two things it needs came first and are described
here too: clips attached to the music, and hold keyframes. The graph uses one kind of marker, with saved locks.

Music videos are cut to the music, and the project already knows the
music's timing from the beat map ([beat-matching.md](beat-matching.md)).
A clip's speed today is a keyframed percentage in source time
([effects.md](effects.md#time-and-shutter)): it says how fast the
footage plays, never which frame lands where. The motion designer lets
the person say "this frame happens on this beat" and retime everything
else around it, by dragging frames along a time graph.

## Overview

- **A tool, not stored data.** The designer is a session, and it edits
  the timeline as it goes: each change writes ordinary speed keyframes
  and starts to the clips at once (`MotionDesignSession.onDraftChange`),
  so the timeline shows a moved clip where it now is and its markers as
  keyframes. The editor's history holds the changes back meanwhile
  (`ProjectHistory.beginGesture(quietly:)`). **Done** keeps them, as one
  undo step, and closes. Each changed clip keeps its points with the
  keyframes (`ClipTime.design`), so opening it again brings back its
  markers, locks and handles as they were (see
  [Opening on keyframed clips](#opening-on-keyframed-clips)). **Cancel**
  puts the clips back as they were when the panel opened, asking first if
  anything changed, and leaves no undo step. Quitting with a changed run
  open asks whether to keep the retiming, discard it, or stay.
- **The run's clips are locked** while the panel is open: nothing but
  the panel may change them. The lock is in the project's state, which
  every window, panel and command writes the project through
  (`ProjectState.lock`, `write(as:)`): a write that would change a locked
  clip in any way (move, trim, delete, split, effects, inspector values,
  a paste or drop over it, a media replacement that retimes it, a menu
  command, the scene splitter), from the editor or a Timeline window, is
  refused whole, with a beep and a VoiceOver announcement
  (`ClipLockRefusal`); a held drag is refused at each step and beeps once.
  Undo and redo that would change one are refused too
  (`ProjectHistory.canRestore`); a refused undo goes back on the stack
  (which clears the redo stack, as any new step would), and a refused
  redo is lost.
  What follows from an edit rather than being one (keyframing effects
  making their keyframes again, package effects refitted) still reaches
  them (`writeDerived`). A clip attached to a song moved elsewhere
  doesn't follow it; that is refused like an edit.
- **Locked clips look locked, and nothing offers them an edit**, so the
  refusal is a backstop. In a Timeline window a locked clip's block is
  hatched, with a lock in a dark chip ("Motion Designer" where it fits;
  `LockedClipMark`), and takes no move, slip, trim, transition handle,
  music point drag, drop or blade (no blade line; a blade click beeps);
  its menu and VoiceOver actions offer only Copy and Show in Clips
  Browser, and VoiceOver reads it as open in the Motion Designer. The
  Timeline menu's Split, Split All, Nudge, Delete Selection and Turn Off
  or On rest when they would touch a locked clip (a split, whenever the
  playhead is in one it would cut; `TimelineMenuState.make`'s `locked`),
  as do the Edit menu's Cut, Duplicate, Delete and Paste (Paste and
  Duplicate tried on a copy of the project, as they move other clips to
  make room). The inspector and effects panel show a locked clip's
  controls disabled under "Open in the Motion Designer"
  (`lockedForMotionDesigner`). Keys (B, Delete, the nudge keys) still
  reach the refusal, which beeps.
- **Only the clips' timing is written**: where each clip the run changed
  plays, its trim, and its speed with its points (`MotionRun.write(into:over:)`,
  `TimelineClip.takeTiming`), onto the project as it is at that moment.
  So an edit made elsewhere to other clips while the panel is open (in a
  timeline window, or an import finishing) stays, whether the run is
  kept or cancelled. The history holds it back with the panel's changes;
  when the panel closes it is recorded as a step of its own, under the
  retiming's, so undoing the retiming keeps it.
- **The panel** floats over the editor like the beat match panel: the
  editor is darkened and takes no input while it is open, not even
  hovering or skimming (`WindowInputBlock`); the Timeline menu and the
  Edit menu's commands for the timeline and effects rest
  (`focusedSceneValueUnlessDrafting`), and the panel
  has an undo of its own for its changes, which the timeline follows.
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

**Built** (`UI/MotionDesigner/`). The transport has playback, timecode,
Skimming, Snapping, Beats and zoom. The sidebar holds the editor's own
viewer player, selection controls, Undo, Redo, Cancel and Done. The lanes
share one timeline: ruler, footage strip, time graph and music.

- The footage strip places thumbnails where their frames play. Slower
  stretches spread them apart; faster ones crowd them together. Drag a
  clip to move it by whole frames; drag its strip edge to trim footage.
  A scene bracket marks an edge with no further footage to reveal.
- The graph shows timeline time across and source time up. Its slope is
  speed, read out over each stretch. Each clip has its own colour; gaps
  are dashed. A locked marker is larger and brighter, with a pin from
  its frame through the graph to the music. Unlocked markers have no pin.
  Eased sides pinch the marker's shape; selection rings it in the accent.
- Click the line to add an unlocked marker and seek to it; grab the line
  to add and drag one. Click a marker to select it alone and toggle its
  lock. Command-click toggles selection, Shift-click selects a range,
  and a lasso selects several, without changing locks. Right-click picks
  for the menu without locking. A press moving 3 points becomes a drag.
- Dragging picked markers moves the unlocked ones and leaves the locked
  ones behind. A locked drag announces: “This marker is locked. Click it
  to unlock it.” Option-drag pulls out the handle on the side dragged
  toward, or takes the existing handle alone, even on a locked marker.
  An edge marker has only its side inside the clip.
- A clip with a locked marker cannot move. It tugs up to 6 points and
  springs back, announcing: “This clip is held by a locked marker.
  Unlock its markers to move it.” A trim at a locked edge announces:
  “This edge is locked. Click its marker to unlock it.” Any click puts
  away the notice. Reduced motion skips the bounce.
- Dragging snaps within 8 points to shown beats, the playhead and other
  clip edges. Each drag step applies to the run as it was at its start,
  so dragging back restores it. Escape cancels the entire drag, and a
  sheet opening over the panel cancels it too.
- For two touching clips, pick both markers on the cut to move it
  together, retiming both. Equal-time markers move in the order that
  makes room: the later clip first moving later, the earlier first
  moving earlier (`MotionDesignSession.movePoints`).
- A marker's sidebar shows Locked, its time and frame, the speeds either
  side read only, Ease and handles, and a frame earlier or later.
  Interior markers have Remove, disabled while locked. Edge markers are
  headed First frame or Last frame and have no Remove. Several markers
  have Lock, Unlock, Ease, nudges and Remove. Clip controls show its span,
  trims and movement; the strip has no lock buttons.
- The menu offers Lock or Unlock (both commands for several), eases and
  Remove. Removing a locked or edge marker is disabled. Delete on an
  unlocked edge marker takes its handle away; on a locked marker it
  asks to unlock it first. Locks are saved edits with undo names Lock
  Marker, Unlock Marker, Lock Markers and Unlock Markers.
- Keys: Space plays, M adds a marker at the playhead, L toggles picked
  locks (all locked if any is unlocked), E toggles Easy Ease and Linear,
  Delete removes, arrows nudge picked unlocked markers or the playhead
  by one frame (Shift ten), N toggles snapping, Escape lets go.
  ⌘A picks all, ⌘= / ⌘- / ⌘0 zoom, ⌘Z / ⇧⌘Z undo and redo,
  ⌘Return keeps the draft and ⌘. cancels. Keys wait while typing.
- Skimming shows the hovered frame without moving the playhead, never
  during a drag. Its preference and the Beats preference persist between
  sessions. Beats come from the first Music layer with a song at each
  moment. Each music layer has a waveform lane, dimmed where another
  song leads; marker pins end on the leading song's lane.
- The window is the run as opened plus where it has grown or moved,
  with 10% (at least half a second) spare either side. Playback stops at
  its end. Zoom and scroll use the timeline's shared rubber band edges;
  reduced motion simply stops them. The view does not scroll mid-drag.

## Several clips as one piece

Selected clips are laid end to end on the graph and retimed as one run;
on Done each clip gets its own share of the keyframes.

- **All on one layer.** If the selection spans layers the designer
  doesn't open; it suggests nesting the clips into a nested timeline
  ([effects.md](effects.md)) and opening that clip instead.
- **Gaps** between selected clips are segments of the run of their own.
  They take no markers, and retiming may safely close them: a clip that
  grows eats into the gap, one that shrinks widens it.

## Markers on the graph

A clip's line is a chain of markers, each a source frame and the timeline
moment it plays. The first and last are always present on the trim's
edge frames. Every stretch lies between neighbouring markers and has
only its own speed. There are no open ends, pace markers or borrowed
speeds (`ClipTimeMap.points`, `stretches`).

A marker moves only when dragged or when its clip moves. Dragging an
interior marker changes the two stretches it touches; its neighbours
stay, locked or unlocked, as do the cuts and footage. Every marker starts
unlocked. Locking holds its frame on its moment: it cannot be dragged,
nudged or removed, and its clip cannot move, but its handles remain free.

An edge marker cannot be removed and has only its handle inside the clip.
Dragging it retimes the adjacent stretch and moves the cut by whole
frames, keeping its source frame. It stops at zero, another clip, or the
speed limits. Removing an interior marker joins its neighbours with
their handles. A new marker must be strictly inside the edges and lands
where its frame plays now, with handles aligned to the line's speed.
On a curve, insertion preserves the curve approximately.

Every stretch stays between 1% and 10000% and plays forwards. A clip
opening without interior markers has one stretch at its existing speed.

For footage 2 s to 6 s playing at 0 s to 4 s, let A and B be locked on
source 3 s and 5 s, playing at 1 s and 3 s, with unlocked M on source
4 s playing at 2 s:

| M dragged to | A to M | M to B | Start to A, B to end | Cuts | Source trim |
| --- | --- | --- | --- | --- | --- |
| 2 s | 100% | 100% | 100% | 0 s, 4 s | 2 s, 6 s |
| 1.5 s | 200% | 66.7% | 100% | 0 s, 4 s | 2 s, 6 s |
| 2.5 s | 66.7% | 200% | 100% | 0 s, 4 s | 2 s, 6 s |

Dragging the last edge marker to 5 s instead plays B to the end at 50%,
keeping source 6 s. A neighbour at 4.5 s stops it there. Trimming the
strip's end to 3.5 s instead changes the last frame to source 5.5 s.

### Easing

A point's sides are eased as a keyframe's are, with the same
`KeyframeEase` (influence and speed) and the same presets: the sidebar's
**Ease** menu, the graph's menu, the point's VoiceOver actions, or E,
which sets Easy Ease and back to Linear as F9 eases a keyframe. On the
time graph a side's handle reaches its influence of the stretch on that
side along the timeline, at its speed times the stretch's straight-line
speed, so the line between two points is the cubic the graph editor
draws between two keyframes.

- **Linear**: the handle sits on the straight line, a third of the way
  along. Where both sides are linear the speed steps at the point.
- **Ease In**: the footage slows into the point (the handle in lies
  flat: the speed there is 0).
- **Ease Out**: the footage leaves the point slowly.
- **Easy Ease**: both, so the footage all but stops on the point. On a
  locked marker, that lands the beat on a near-freeze; the rest of each
  stretch plays faster to keep the markers where they are.

Hold isn't offered. Any marker can ease on a side with a neighbouring
stretch, including locked markers and edges' inward sides.

With a point selected, the graph shows the **handles** of its eased
sides on its tangent, with a stem back to the point, as the graph
editor's do, and they work the same way:

- Dragging a handle along shapes how far it reaches; tilting it sets the
  speed at the point. The handle on the other side swings to stay in
  line with it, so the speed carries through the point without a step.
  With **Option** it moves alone, and the speed steps there; the
  sidebar's **Handles in line** does the same from the keyboard, and
  turned back on brings them into line again.
- A handle dragged onto its point goes, leaving that side linear.
- Handles are held inside their stretch, so the footage never stops
  for longer than an instant or runs backwards.
- Points dropped on the line keep their handles in line as the stretches
  around them change speed, at the speed the two share by their reach.

The sidebar's **Ease In** and **Ease Out** sliders and **Speed** fields,
and the point's VoiceOver actions (Longer and Shorter Ease In and Ease
Out, a tenth of the stretch at a time, and Faster and Slower, a quarter
at a time), do the same from the keyboard. Speeds are held to what Time
allows (1% to 10000%) where they are written.

### Beat markers and snapping

The song's beats are drawn on the graph and the music lane, thinned by
zoom as on the timeline, and points snap to them (and to the playhead and
the clips' edges) as on the timeline. A toggle turns the beat markers
off, as the timeline's view options do; like the timeline's choice, it
is remembered between launches (`Preferences.motionDesignerShowsBeats`).

## Lengths and positions

The music can't move in the designer; only footage does, and never
where other clips are.

- **Retiming keeps the footage.** Interior edits keep both cuts. Dragging
  an edge marker moves only that cut and retimes its stretch, with no
  source change. Nothing overlaps, and no footage is cut to make room.
- **Trimming.** Dragging a clip's edge in the strip reveals or hides
  footage at the speed it plays there, snapping as points do, as far as
  its footage goes, stopping a source frame short of its nearest interior marker,
  and stopping against a neighbour (`MotionRun.trim`). A locked edge
  refuses trimming until unlocked. The sidebar and
  the clip's VoiceOver actions trim a frame at a time.
- Clips can be **moved** in the designer: dragged along time, or a frame
  at a time with the sidebar's buttons or the clip's VoiceOver actions,
  which lengthens or shortens the gaps around them. Unselected clips on
  the layer are shown but never move, and bound how far a selected clip
  can go.
- The view fits the run when it opens, and scrolls across the window,
  which grows as the run is moved or grown, so retiming or moving the
  first or last clip never runs out of room to show it. The view doesn't
  scroll along during a drag.

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
- Writing rounds a clip's start onto a frame by moving its trim, rounding
  later instead if earlier would leave its footage.

## Opening on keyframed clips

**Built** (`ClipTimeMap(reading:frameDuration:)`). The edge markers come
from the clip's current trim and span. Saved design points come back
while their saved speed matches the clip's speed, at the moments the
clip now plays their frames. Points outside the trim are left out.
Otherwise speed keyframes strictly inside the trim become unlocked,
linear markers; of two keys a frame or less apart with different speeds,
only the second makes a marker. Keys on the edges add none. An unchanged
clip keeps its original keyframes exactly.

`time.design` keeps its shape and project formatVersion stays 2:

- Interior points store source, eases, smooth and `locked: true` only
  while locked. New files omit kind and pace.
- A locked edge is stored as a point on its frame without eases. Its
  handle is stored in startEase or endEase. A clip with no interior
  points, edge handles or locks has no design.
- Old `kind: hit` and new `locked: true` both lock a marker. Old pace
  points become unlocked markers; their outgoing handle and the next
  point's incoming handle are removed. Their typed pace is ignored
  because the saved speed already plays it.
- A point on an edge frame merges into that edge, taking its lock and,
  if no edge handle is saved, its inward handle. An outward trim on the
  timeline leaves the old locked edge as an interior marker and creates
  a new unlocked edge. Locks hold only in the designer: ordinary timeline
  movement and trimming still work, with music attachment keeping sync.

## Writing keyframes

**Built** (`ClipTimeMap.writtenSpeed()`). With each change, each changed clip's
time map becomes speed keyframes, in source time, and where the clip then
starts:

- A straight stretch is one keyframe at its speed; a clip at one speed
  throughout gets a single speed.
- A curved stretch is held steps (`ClipTimeMap.steps(of:)`): its time cut
  into parts about 1/24 s long, each playing the footage the curve plays
  over that time, on the keyframes' timescale (1/240000 s). Neighbouring
  steps are then joined wherever playing them as one keeps every frame
  within a quarter of a frame (`stepTolerance`) of where they played it,
  so a gentle ease is a few keyframes and a near-stop more. Each step
  starts and ends on the line, so every marker lands
  where it was put, to within a tick.
- Where the curve slows past 1% (a stop on a point), those steps are held
  at 1% and the others in the stretch play a little faster, so it still
  keeps its length.
- Every keyframe holds; consecutive ones at one speed are one.
- Each clip's start follows, in the same undo step, and its points are
  kept with the speed (`MotionDesign`) for the next opening.

The time map is one clip's (`ClipTimeMap`: the points in source order,
each with its frame, its time on the timeline, its lock and its handles;
`TimeStretch` for the line between two of them), including both edge markers; the panel keeps one for each clip of the run. It and
the rules above are pure functions, unit tested like `BeatFitting`.

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
- **The music point** shows where a clip is tied: a line through the
  clip at its frame, in `Design.musicLink`, with a point at its foot
  toward the Music area. The selected clip's point has a knob along the
  clip's bottom edge: dragging it ties another frame to the music there,
  on frames and snapping to beats and edges as the blade does; the clip
  stays put (`attachToMusic` at the time let go). The songs mark where
  the selected clips hold on, with the point at the top
  (`LayerClipRow.musicMarks`). Without the pointer: **Attach to Music at
  Playhead**, after clicking the frame, or the clip's VoiceOver actions
  Music point one frame earlier and later; its value reads where it is
  tied.
- Not yet: footage following while the song is dragged (it follows on the
  drop).
- The designer's markers and locks are kept on the clip with its keyframes, so they
  come back when it opens again; the attachment is what keeps the clip on
  its beat when the song moves afterwards.

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

Following [accessibility.md](accessibility.md). The graph reads how many
markers are locked. Each marker reads Marker, First frame marker or Last
frame marker, locked or unlocked, time, source frame and speed after it.
Adjust nudges an unlocked marker a frame. Actions select, Lock or Unlock,
name the eases, shape each eased side (Longer, Shorter, Faster, Slower)
and Remove for interior markers. The graph keeps Add marker at playhead.
Clips read their name and span and offer movement and trims by a frame.
Sidebar checkboxes and L expose locks without the pointer. Icon buttons
have labels; marker size and pins show locks beyond colour alone. Notices
are announced, and the shared motion helpers honour reduced motion.

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
   unit tested; `MotionDesignSession` for the run, its undo and the
   player; the views).
6. Accessibility. **Built** with the panel.
7. One kind of marker, with persistent locks and draggable edges, replacing
   hits, pace markers and session-only cut locks. **Built**; covered by
   model, saving, session and event tests and offscreen snapshots.

Not yet: the panel hasn't been used for editing a real project on screen.
