# Loop region

Status: **planned, not implemented**. Nothing here is built. This
document is written for whoever builds it: it says what the person sees,
then where each piece goes in the code as it stands today, then the
order to build it in. Choices made while writing it that the request
didn't settle are listed under [Decisions made here](#decisions-made-here).

A **loop region** is a stretch of a timeline that playback repeats, as
the cycle range in Logic Pro does. It is drawn in a slim bar of its own,
the **loop bar**, in the main timeline, the Motion Designer, the Keyframe
Designer and the graph editors. Every one of them shows the same region
of the same timeline, because they all play through the same player.

Colors for the region (its right-click **Color** menu) are described in
[bar-colors.md](bar-colors.md).

## What the person sees

### The bar

- A row 20 points high, the height of the sections row
  (`SectionLane.height`), with the same sunken background
  (`Color.black.opacity(0.22)`).
- The region is a chip drawn exactly as a section's chip is
  (`SectionLane.sectionView`): `Design.Radius.chip` corners, a
  `Design.clipFill` fill, a one point outline in the tone at 85%, and a
  `Design.bevelEdge` rim, inset two points top and bottom.
- Its tone is `Design.loop`, a new token, **not** `Design.section`:
  `hex(0x3DB8D0)`, a cyan. Sections are bronze, so the two rows never
  read as one. Beat Match already tints its own loop in a cool color
  (`Design.accent.opacity(0.08)` in `BeatMatchWaveform`), so "loop is
  cool" holds across the app. The person can give the region any other
  color, the section bronze included ([bar-colors.md](bar-colors.md)).
- **On**, the chip is filled as an unselected section is
  (`Design.clipFill(tone, selected: false)`). **Off**, it is greyed, as
  a clip turned off is (`Design.clipFill(tone, selected: false, enabled: false)`,
  outline in `tone.greyed()`).
- On the chip: the `Design.Symbol.loop` glyph, then the region's length
  as timecode (`CMTime.timecode(frameRate:)`), in
  `Design.Typeface.numericMicro`, one line, cut off when the chip is too
  narrow. The ink is the one [bar-colors.md](bar-colors.md#ink) picks
  for the fill.
- There is at most **one region per timeline**. Each timeline has its
  own.

### Drawing, adjusting and moving

- **Drag across empty bar** to draw a region. It starts where the
  pointer went down and follows the pointer; dragging left of where it
  began works too. Nothing is drawn until the pointer has moved 3
  points. Releasing makes the region and turns it **on**. A region
  already there is replaced (it stays drawn, dimmed, until the release;
  Escape puts it back). The new region keeps the old one's color.
- A release shorter than the minimum length (below) makes nothing, and
  leaves what was there.
- **Drag an edge** of the region to resize it. The grab zone is 6 points
  wide, narrower on a tiny chip so a middle is left
  (`min(6, max(2, width / 3))`, as `SectionLane` does), and the pointer
  shows `.columnResize` over it.
- **Drag the middle** to move the region, its length kept.
- **Click** the region (press and release within 3 points, anywhere on
  it, edges included) to turn it off or on.
- **Escape** during any of these drags cancels it (`EscapableDrag`).
- **Right-click** the region: **Turn Loop Off** / **Turn Loop On**,
  **Color** ▸, **Remove Loop Region**.
- While a drag runs, the bar draws a draft; the region itself changes
  once, on release. Playback keeps looping the old range until then.

Rules for where a region may be (`Timeline` extension, see
[Model](#model)):

- Both ends are on frames (`Timeline.frameAligned(_:.nearest)`).
- It is at least `LoopRegion.minimumDuration` long: a quarter of a
  second, rounded up to whole frames. Shorter than that the player would
  do nothing but seek.
- It lies within what the bar's host shows: `0...timeline.duration` in
  the main timeline, less elsewhere (see [Where it appears](#where-it-appears)).
  A resize stops at those limits and at the minimum length; a move stops
  at the limits.

### Snapping

With snapping on, the edge being dragged lands on a snap target within 8
points, on creation, on a resize and on a move:

- **Creation**: the press point snaps, then the moving end snaps.
- **Resize**: the dragged edge snaps.
- **Move**: whichever end is nearer a target snaps, as a section or a
  clip does (`SnapTargets.snappedStart`).

Snapping happens before the frame and limit rules, as for sections. The
region never snaps to its own edges. What "snapping on" means and what
the targets are depends on the host; see each under
[Where it appears](#where-it-appears). The loop region's own edges are
**not** added to anyone else's snap targets.

### Playback

- With the region **on**, playback that reaches its end goes back to
  its start and plays on.
- **Pressing play** with the region on: if the playhead is inside it
  (from its start up to a frame before its end), playing starts where
  the playhead is. Anywhere else, playing starts at the region's start.
- **Turning it on while playing** (a click on the region, the loop
  button, C): the playhead goes to the region's start at once and plays
  on from there, wherever it was.
- **Drawing a new region while playing** does the same on release,
  since a new region is on.
- **Turning it off while playing**: playing carries on from where it
  is, past the region's end.
- **Resizing or moving it while playing and on**: on release, playing
  carries on if the playhead is inside the new range, and goes to its
  start otherwise.
- Paused, none of these move the playhead.
- Moving the playhead by hand (ruler, keys, a click in the tracks)
  pauses, as it always has; the region doesn't hold the playhead in.
- The region doesn't change what is exported, rendered or how long the
  timeline is. Skimming, the Tape Scrubber and frame stepping ignore it.
- While a take is being recorded with the timeline playing
  (`AudioRecorder`, `RecordPopover`), the loop is suspended: the
  timeline plays straight on, so the take lines up with it.

### Buttons, keys and menus

Clicking and dragging need a path without the pointer
([accessibility.md](accessibility.md), "Rules for new UI"), and the main
timeline's bar can be hidden, so each host also has:

- A **loop button**: an icon toggle with `Design.Symbol.loop`, on while
  the region is on. Help: "Loop playback over the loop region (C)".
- **C** does the same (Logic's key). Not while text is being typed.
- With **no region yet**, the button and C make one and turn it on:
  over the stretch the host is about (each host says which, below).

The main timeline's **Timeline** menu (`TimelineCommands`) gets, in a
group after Play/Pause:

| Item | Does |
| --- | --- |
| Loop Playback  C | Toggles, with a checkmark while on; makes a region when there is none |
| Set Loop Start to Playhead | Moves the region's start to the playhead; with no region, makes one from the playhead to the timeline's end |
| Set Loop End to Playhead | Moves its end to the playhead; with no region, makes one from the start of the timeline to the playhead |
| Remove Loop Region | Enabled while there is one |

The two Set items follow the resize rules (frames, minimum length,
limits) and are disabled where they would do nothing. They are the
keyboard path for drawing and resizing.

## Where it appears

| Host | Bar sits | Snapping is on when | Snaps to | C with no region loops |
| --- | --- | --- | --- | --- |
| Main timeline | Under the ruler, above Sections | `Preferences.snapping` (N) | The timeline's targets (`liveSnap.targets`): start, clip and section edges, playhead, beats drawn | The selected clips' span, else the whole timeline |
| Motion Designer | Under its ruler, above the filmstrip | `MotionDesignSession.snaps` (N) | `MotionDesignSession.snapped`: beats while shown, playhead, the layer's clip edges | The run (`run.span`) |
| Graph editor panel | Under the time row (`GraphTimeRow`) | `Preferences.snapping` | The timeline's start, clip and section edges, the playhead, and the keyframes of the panel's graphs | The parameter's clip, or the whole timeline for a layer's parameter |
| Keyframe Designer | Same: it embeds `KeyframeGraphView` | Same | Same | Same |

Not given a loop bar, on purpose:

- **Beat Match** plays the song alone through its own player and has
  its own loop (two measures around the selected beat, L). Unchanged.
- **The scene splitter** plays a media file, not a timeline.
- **The effects panel's keyframe lanes**, the EQ graph, tone graphs and
  the Audio Keys spectrum aren't graph editors with a transport.

A region can lie partly or wholly outside what a host shows (the Motion
Designer's window, a graph's clip). It is drawn clipped to what shows,
an edge out of view can't be grabbed, and the bar draws nothing for a
region wholly outside.

## Model

New file `Sources/AnimationMeetsVideo/Model/LoopRegion.swift`. Foundation
and CoreMedia only, no SwiftUI.

```swift
/// A stretch of a timeline that playback repeats while it is on.
struct LoopRegion: Equatable {
    var start: CMTime
    var end: CMTime
    var isOn = true
    /// Nil for `Design.loop`. See docs/bar-colors.md.
    var color: BarColor?

    enum Edge { case start, end }
    var duration: CMTime { CMTimeSubtract(end, start) }
}
```

`BarColor` comes from [bar-colors.md](bar-colors.md); build that
document's model step first, or leave `color` out until it exists.

Pure functions in an extension on `Timeline`, each taking the `limits`
(a `CMTimeRange`) the host allows, so they can be unit tested without a
view. Model them on the section functions in `TimelineSections.swift`
(`resolvedSectionMove`, `resolvedSectionEdge`):

- `loopMinimumDuration: CMTime`: 0.25 s rounded up to whole frames
  (6 frames at 24 fps, 8 at 30).
- `resolvedLoop(from: CMTime, to: CMTime, within limits: CMTimeRange) -> (start: CMTime, end: CMTime)?`:
  orders the two times, puts each on a frame, clamps them to the
  limits; nil when what is left is shorter than the minimum.
- `resolvedLoopEdge(_ region: LoopRegion, edge: LoopRegion.Edge, to: CMTime, within: CMTimeRange) -> LoopRegion`:
  the dragged edge on a frame, within the limits, never closer to the
  other edge than the minimum.
- `resolvedLoopMove(_ region: LoopRegion, toStart: CMTime, within: CMTimeRange) -> LoopRegion`:
  start on a frame, length kept, held inside the limits.

The region is **not** part of `Timeline` or `EditingProject`. It is view
state (see [Saving](#saving)): changing it is not an edit, adds no undo
step and doesn't bump `editCount`.

## Playback

The region lives with the player, because the player is what every host
already shares: `TimelineView.playback`, `KeyframeGraphHUDs.playback`
and `MotionDesignSession.playback` are the same `PlaybackModel` for one
editor surface. A second window on the timeline, or the external
display's own editor, has its own player and so its own loop.

New file `Sources/AnimationMeetsVideo/Playback/PlaybackLoop.swift`:

```swift
/// The loop region of the timeline a player shows, and the jump back
/// at its end. Owned by `PlaybackModel` (`playback.loop`).
@MainActor @Observable
final class PlaybackLoop {
    private(set) var region: LoopRegion?
    /// What may play here: the whole timeline, or less while a
    /// designer narrows it.
    private(set) var limits: CMTimeRange
    private(set) var frameDuration: CMTime
    /// A take is recording over the playing timeline.
    var isSuspended = false

    /// The stretch that repeats now: the region cut to `limits`, when
    /// it is on, not suspended, and still at least the minimum long.
    var activeRange: CMTimeRange? { … }

    /// Another timeline is shown: its region, with no jump.
    func show(_ region: LoopRegion?, limits: CMTimeRange, frameDuration: CMTime)
    /// The timeline's length or frame rate changed.
    func update(limits: CMTimeRange, frameDuration: CMTime)
    /// A designer plays only part of the timeline; nil gives it back.
    func narrow(to window: CMTimeRange?)

    /// A region drawn, in place of any there was. It is on.
    func draw(_ region: LoopRegion)
    /// The region resized, moved or recolored.
    func adjust(to region: LoopRegion)
    func remove()
    func toggle()
}
```

`PlaybackModel` makes it in `init`, beside `beatClicks`, handing it the
player and a way to jump (`BeatClickPlayer(player:)` is the pattern).

**The jump.** `PlaybackModel.seek(to:)` can't be used: it pauses
("the playhead is the master"). Add:

```swift
/// A loop's turn back while playing: the player seeks and plays on.
func jump(to time: CMTime) {
    currentTime = time
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
}
```

It skips the paused-seek queue (`pendingSeek`, `drainSeeks`), which is
for scrubbing. What follows a jump already works, since each watches the
player rather than a caller:

- the playhead line (`PlayheadRail.Following`, an `AVSynchronizedLayer`)
  and the page turn when it lands out of view (its
  `AVPlayerItem.timeJumpedNotification` observer calls `checkInView`);
- the beat tick (`BeatClickPlayer` restarts on the same notification);
- the audio taps, which reset on a jump in time
  ([audio.md](audio.md), "a seek or a loop").

The seek is exact but not seamless: expect a short gap in the sound at
the turn. That is accepted; a sample-accurate loop would need the range
composed twice, which isn't worth it for a working aid.

**The watch.** As `BeatMatchSession.refreshLoop` does it:

- One private `refresh()` recomputes `activeRange` and compares it with
  the range being watched (`watchedRange`, readable for tests). When
  they differ it removes the old boundary observer and, **only while
  playing**, adds one at the range's end
  (`player.addBoundaryTimeObserver(forTimes:queue:)` on `.main`) whose
  block calls `jump(to: start)`.
- It runs when the region, the limits, the suspension or the play state
  changes. `PlaybackModel.playStateChanged` tells the loop
  (`loop.playingChanged(_:)`, not private, so tests can drive it without
  sound, as `BeatMatchSession.playingChanged` is).
- A range ending at the item's end is watched `PlaybackLoop.endMargin`
  (20 ms, Beat Match's `loopEndMargin`) short of it: the player pauses
  at the end of its item, and that pause would take the watch down
  before it could jump.
- The observer belongs to the player, not the item, so a rebuilt item
  swapped in while playing (`PlaybackModel.swap`) keeps looping.

**The rules** from [Playback](#playback) above, in code terms:

- `toggle()` turning the region on while playing: `jump(to: start)`.
- `draw(_:)` while playing: `jump(to: start)`, whether or not a region
  was on before.
- `adjust(to:)` while playing, with the region on: jump to its start
  only when the player's time is outside `[start, end)` of the new
  active range. A change of color alone never jumps.
- `toggle()` turning it off, and `remove()`: no jump.
- `PlaybackModel.togglePlayback()`, before `player.play()`: when
  `loop.activeRange` exists and the time it is about to play from
  (after the skim rule already there) is before its start or within a
  frame of its end, seek the player to the start first. This replaces
  the "at the item's end, start from zero" rule only while a loop is
  active.

## Saving

In `view-state.json`, with the playhead and zoom of each timeline
([project-package.md](project-package.md), "View state"), so that
looping is never an edit: no undo step, no unsaved project, nothing in
backups.

- `ViewState.Timeline` (`Project/ViewStateFile.swift`) gains
  `var loop: LoopRegion?`.
- `FileShape.Timeline` gains an optional `loop`:

  ```json
  "loop": { "start": "12s", "end": "16s", "on": true, "color": "#3DB8D0" }
  ```

  `start` and `end` are `ProjectFile.TimeEntry` (exact rationals, as
  `playhead` is), `color` is left out for the default. A region whose
  times don't read, or with `end` not after `start`, is dropped rather
  than shown.
- The key is optional, so `formatVersion` stays 1: a file without it
  reads as no region, and an older build reading a newer file ignores
  it (the file is decoded with `Codable`, not the strict loader).
- `TimelineEditorSurface` already parks and shows each timeline's
  playhead through `TimelineViewMemory`. It does the same for the loop:
  - `showParked(_:)`: `playback.loop.show(memory.parked(id)?.loop, limits: 0...duration, frameDuration:)`.
  - `park(_:playhead:selection:in:)` and the `"surface"` capture
    registered in `showParked`: `parked.loop = playback.loop.region`.
  - When the shown timeline's duration or frame rate changes (an edit),
    `playback.loop.update(limits:frameDuration:)`.
- An edit never moves the region: it is two times, not tied to clips. A
  timeline made shorter than the region leaves it where it is;
  `activeRange` cuts it to the timeline, and it stops looping if too
  little is left.

## The shared view

One view draws the bar and runs its gestures for every host. It is
shared, so it goes in `UI/Components/` (as `ZoomControls` and
`SecondsViewport` do): `UI/Components/LoopBar.swift`.

```swift
struct LoopBar: View {
    let region: LoopRegion?
    let timeline: Timeline              // frames and the rules above
    let limits: CMTimeRange             // where a region may be, here
    /// Timeline time to x in the bar, and back. Not a zoom factor: a
    /// graph of a retimed clip isn't linear in timeline time.
    let x: (CMTime) -> CGFloat
    let time: (CGFloat) -> CMTime
    /// The target near a time; nil with snapping off or nothing near.
    let snap: (CMTime) -> CMTime?
    let onSnapIndicator: (CMTime?) -> Void
    let onDraw: (LoopRegion) -> Void    // PlaybackLoop.draw
    let onAdjust: (LoopRegion) -> Void  // PlaybackLoop.adjust (and Color)
    let onRemove: () -> Void            // PlaybackLoop.remove
    let onToggle: () -> Void            // PlaybackLoop.toggle
    let onPickColor: () -> Void         // "Other…", see bar-colors.md

    static let height: CGFloat = SectionLane.height
}
```

Take from `SectionLane`, which solved the same problems:

- A `draft` state drawn instead of the region during a drag, and kept
  for a moment after the drop until the new region arrives
  (`commitDrop` / `pendingDrop`), so it doesn't flash back.
- Gestures measure from the region as the host has it, never from the
  draft.
- The move is the chip's own `.gesture`; the edge handles are views
  inside it with their own, so an edge's resize wins over the move.
- `EscapableDrag` for Escape, and `DragTimecodeReadout` from the
  environment (optional; only the main timeline installs one) to show
  the dragged time.

Differences from `SectionLane`:

- Every time comes from the pointer's x through `time`, then `snap`,
  then the `Timeline` rule. Don't divide a translation by a zoom.
- `x(start)` may be greater than `x(end)`: a reversed clip's graph runs
  backwards in timeline time. Take the min and max of the two.
- A click is told from a drag on release (moved less than 3 points),
  not on mouse-down: a click toggles, and toggling on mouse-down would
  toggle at the start of every drag.
- No selection, no rename, no Option-copy, no double-click.

## Hosting it

### Main timeline

- `TimelineAreaLayout` gains `showsLoop = true`, decoded with
  `decodeIfPresent … ?? true` as `showsSections` is, and a **Loop row**
  checkbox in `ViewOptionsPopover` beside **Sections row**.
- `TimelineTrackSurface.trackSurface(in:)`: add `LoopBar.height` to
  `railHeight` while shown, and a row between the ruler and the
  sections row, laid out like the sections row: the label **Loop** in
  the names column (`Design.Typeface.micro`, `textTertiary`), then a
  `TimelineLoopLane(parent:width:)` beside `TimelineSectionLane`, with
  the same `rubberBandStretch`, `rubberBandScroll` and `clipped`.
- `TimelineLoopLane` reads `parent.playback.loop.region` in its own
  body. `TimelineView` is `Equatable` and must not read the loop as its
  body is built, or toggling would rebuild the whole timeline; that is
  why the playhead has `PlayheadReader`.
- Mapping: `viewport.x(atSeconds:)` and `viewport.seconds(atX:)`.
  Limits: `0...timeline.duration`. Snap:
  `liveSnap.targets?.nearest(to:within:)` with `snapTolerance(viewport)`.
  Snap indicator: `viewportModel.snapIndicator`.
- The loop button goes in the header beside the snapping toggle, as a
  small view of its own that reads the loop (`PlayheadTimecode` is the
  pattern), not in `TimelineView.body`.
- `TimelineKeyboard.handleKey`: `c` without modifiers toggles; with no
  region it makes one over the selected clips (`selection` or
  `groupSelection`: earliest start to latest end), else `0...duration`.
- `TimelineActions`, `TimelineCommands`, `TimelineMenuState`: the four
  menu items, enabled as the table says.
- `TimelineRecording.startRecording(_:playing:)` sets
  `playback.loop.isSuspended` while a take records with the timeline
  playing, and clears it when the take stops.

### Motion Designer

- `MotionDesignLanes`: a `LoopBar` between `ruler(width:)` and
  `RetimedFilmstrip`. Everything measured from the top assumes the
  filmstrip starts at `rulerHeight`: `graphHeight`, the notice's top
  padding, and `graphTop` and the hit pins in `markings`. Give the
  lanes one `filmTop` (`rulerHeight + LoopBar.height`) and use it in
  each.
- Mapping: the session is a `SecondsViewport` (`x(of:)`,
  `seconds(atX:)`). Limits: `session.window`. Snap:
  `session.snapped(_:tolerance:)` with 8 points' worth of seconds; show
  it with the lanes' `snapTime`.
- `MotionDesignSession`: `playback.loop.narrow(to: window)` when it
  opens and whenever `window` changes (the run moved or grew), and
  `narrow(to: nil)` in `end()`. Its `togglePlayback()` keeps its own
  window rule and its stop at the window's end; the loop's start rule
  runs inside `playback.togglePlayback()` after it.
- `MotionDesignView`: the loop button in the transport's toggle group,
  and `c` in `handleKey` (with no region: `run.span`).
- The loop is the timeline's, not the draft's: Cancel doesn't undo it.

### Graph editors and the Keyframe Designer

- `KeyframeGraphView` puts `GraphTimeRow` over the first graph of a
  panel (`showsTimeRow`). The `LoopBar` goes right under it, under the
  same condition, so a linked panel has one bar and the Keyframe
  Designer, which embeds a `KeyframeGraphView`, gets it for free. The
  height it takes from the plot becomes
  `GraphTimeRow.height + LoopBar.height`.
- Mapping, as `GraphTimeRow` does it: x is
  `layout.x(axis.keyTime(atTimeline: t).seconds)`; time is
  `timeline.snappedToFrame(axis.timelineTime(atKey: layout.seconds(atX: x)))`
  with x held inside `layout.plot`.
- Limits: the clip's `startOffset...endOffset` for a clip's parameter,
  `0...timeline.duration` for a layer's, cut to the timeline.
- Snap: on when `UserDefaults` has `Preferences.snapping` on (absent
  means on). Targets: `hud.project.snapTargets(in:playhead:markers: [])`
  plus the keyframe times of the panel's graphs in timeline time. The
  nearest one within 8 points, measured in x through the mapping.
- Hidden when `hud.playback` is nil.
- A `GraphLoopToggle(hud:)` beside each `GraphSkimToggle(hud:)`: the
  graph's toolbar, the linked panel's `presetBar`, and
  `KeyframeDesignerTransport`.
- `KeyframeGraphHUDs.watchSpace` already listens for Space in the
  panels; have it take `c` too (same guards: no modifiers, not while a
  text view has the keyboard, not for a focused control).

## Accessibility

Following [accessibility.md](accessibility.md), "Rules for new UI":

- The bar: `.accessibilityElement(children: .contain)`, label "Loop".
- The region: one element, label "Loop region", value
  "On, from 00:00:12:00 to 00:00:16:00" (or "Off, …"), `.isButton`, its
  default action toggles.
- Its named actions, which are also its context menu's commands and
  the drags a frame at a time: Move start one frame earlier / later,
  Move end one frame earlier / later, Move region one frame earlier /
  later, Remove loop region, Choose color…, Use default color.
- The loop button: `accessibilityLabel("Loop")`, value On or Off.
- The chip's fill and rim are `.decorative()` where they sit over the
  edge handles.
- Turning the loop on or off posts an announcement ("Loop on",
  "Loop off"), since nothing else tells VoiceOver.

## Tests

Mirror the source folders (`Tests/AnimationMeetsVideoTests/…`):

- `Model/LoopRegionTests`: drawing right to left, frame alignment at
  23.976 and 30, the minimum length, the limits; an edge stopping at
  the minimum and at a limit; a move held inside the limits.
- `Playback/PlaybackLoopTests`: `activeRange` when off, suspended,
  narrowed, cut by a shorter timeline; the watch exists only while
  playing; turning on while playing jumps; resizing with the playhead
  inside doesn't; a range to the item's end is watched 20 ms short;
  the start rule for play.
- `UI/TimelineViewMemoryTests`: a loop survives a write and read; a
  file without `loop` reads as none; a damaged one is dropped.
- `UI/LoopBarInteractionTests` with `EventHarness` (`UI_EVENTS=1`):
  a drag draws; a drag on an edge resizes and snaps; a click toggles
  and a drag doesn't; Escape cancels.
- `UI/UISnapshots`: a `loopBar` case showing the rail with a section
  and a region on, off and recolored, to check by eye that the two
  rows read apart. The existing `keyframeGraph`, `linkedKeyframeGraphs`,
  `keyframeDesigner` and `motionDesigner` cases will show the bar; look
  at each again.

## Decisions made here

The request didn't settle these. Each is cheap to change before the
build starts.

1. **One region per timeline**, replaced by drawing another, as Logic
   has one cycle range.
2. **Dragging the middle moves it.** The request names drawing and
   edges only; a drag on the body has to do something, and this is
   what Logic does.
3. **It is view state, not project data**: per timeline, in
   `view-state.json`, no undo. Logic saves its cycle with the project,
   and so does this, but as where things were left.
4. **Only turning on jumps to the start.** "If clicked during
   playback, the playhead goes back to the start" is read as the click
   that turns it on; turning it off lets playing run on.
5. **Play starts at the region's start only from outside it.**
6. **The default tone is cyan** (`0x3DB8D0`), chosen to be far from
   the sections' bronze.
7. **Graph editors follow the timeline's snapping setting**, having
   none of their own.
8. **The loop button, C and the menu items** are added so the feature
   works without a pointer and with the timeline's bar hidden.
9. **Beat Match keeps its own loop.**

## Building it

1. `BarColor` from [bar-colors.md](bar-colors.md) (its model step).
2. `LoopRegion` and the `Timeline` rules, with `LoopRegionTests`.
3. `PlaybackLoop`, `PlaybackModel.jump(to:)`, the play rule, with
   `PlaybackLoopTests`.
4. Saving in the view state and the surface's park and show.
5. `Design.loop`, `LoopBar`, and the main timeline's row, button, key
   and menu items; the snapshot case and the event tests.
6. The Motion Designer's bar, button and key.
7. The graph editors' and the Keyframe Designer's bar, toggle and key.
8. Accessibility, checked with the `accessibility-reviewer` agent.
9. Docs, once built: this document's status; the README's row;
   [timeline.md](timeline.md) (a "Loop region" section after Sections,
   Snapping's list of what snaps, and its "Not implemented yet");
   [accessibility.md](accessibility.md) (the C row in the keys table
   and the VoiceOver list); `KeyboardShortcutsView`;
   [project-package.md](project-package.md), "View state";
   [motion-designer.md](motion-designer.md), "The panel";
   [layer-transforms.md](layer-transforms.md), "Graph editor";
   [keyframing-effects.md](keyframing-effects.md), "The Keyframe
   Designer"; and the `Design` comment in `DesignSystem.swift`, which
   says nothing but categories and times gets a color.

This can't be built or run on Linux; it needs full Xcode on a Mac. CI
runs only when started by hand.
