# Loop region

Status: **built, not yet run**. Built: the model and its rules
(`Model/LoopRegion.swift`), the loop in the player
(`Playback/PlaybackLoop.swift`, `PlaybackModel.jump(to:)` and the play
rule), saving it in the view state, its suspension while a take
records; in the main timeline the bar (`UI/Components/LoopBar.swift`),
the header button that shows or hides it, C and the Timeline menu's
items (`UI/Timeline/TimelineLoop.swift`); in the Motion Designer the
bar, its loop button and C (`UI/MotionDesigner/MotionDesignLoop.swift`);
in the graph editors and the Keyframe Designer the bar, its toggle, C
and Delete (`UI/Keyframes/GraphLoopBar.swift`); and one region per
timeline in every window of the project (`Playback/LoopRegions.swift`).
The region's color is built with the other bar colors
([bar-colors.md](bar-colors.md)): its right-click menu's Color, kept in
`view-state.json` with the region and the same in every window. See [Building it](#building-it) for
what is left. The rest of this document is written for whoever builds
it: it says what the person sees, then where each piece goes in the
code, then the order to build it in. Choices made while writing it that the
request didn't settle are listed under
[Decisions made here](#decisions-made-here).

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
  as compact timecode (`CMTime.compactTimecode(frameRate:)`, "4:00"), in
  `Design.Typeface.numericMicro`, one line. Too narrow for both, the
  chip shows the glyph alone, and too narrow for that, nothing
  (`ViewThatFits`): a label cut off at the chip's edge ran over its
  outline, so the chip looked cut off. The ink is the one [bar-colors.md](bar-colors.md#ink) picks
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
- **Click** the region (anywhere on it, edges included) to select it,
  as a section is selected: drawn brighter with a light outline, and
  nothing else stays selected. **Delete** then removes it, and Escape
  or a click elsewhere lets go of it. Selecting a clip, a layer or a
  section lets go of it too. The press selects; a drag from it moves or
  resizes the region as well.
- **Escape** during any of these drags cancels it (`EscapableDrag`).
- **Right-click** the region: **Turn Loop Off** / **Turn Loop On**,
  **Color** ▸ (not built yet), **Delete Loop Region**.
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
- **Turning it on while playing** (C, the menu, its right-click menu,
  or showing the main timeline's bar): the playhead goes to the region's start at once and plays on
  from there, wherever it was.
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

- **C** turns the loop on or off (Logic's key). Not while text is being
  typed.
- With **no region yet**, C makes one and turns it on: over the stretch
  the host is about (each host says which, below).
- In the **main timeline**, a **loop button** in the header shows or
  hides the loop bar, as the sections button beside it does its row
  (an icon toggle with `Design.Symbol.loop`; help "Hide the loop row
  and turn the loop off" / "Show the loop row and turn the loop on").
  The loop is on only while its bar shows, as Logic's cycle shows only
  while on: hiding the bar (the button, or **Loop row** in the view
  options) turns the loop off, and showing it turns the region on
  again. Turning it on with C or the menu shows the bar. A region saved
  on, in a project opened with the bar hidden, is turned off
  (`TimelineLoopVisibility`).
- The **Motion Designer**'s loop button, in the transport beside
  Snapping, does the same as the timeline's: it shows or hides the
  designer's loop bar, turning the loop on or off with it. The two bars
  are one setting (`TimelineAreaLayout.showsLoop`), so hiding one hides
  both, and the loop is on only while they show. Each host keeps that
  rule with its own `TimelineLoopVisibility`; both can act on one
  change, which is why they use `PlaybackLoop.setOn`, where asking
  twice does nothing, rather than `toggle`. Turning the loop on there
  with C, or drawing a region, shows the bars.
- The **graph editors** and the **Keyframe Designer** have the same
  loop button (`GraphLoopToggle`), beside their Skimming toggle: it
  shows or hides their loop bar, the same setting again.

The main timeline's **Timeline** menu (`TimelineCommands`) gets, in a
group after Play/Pause:

| Item | Does |
| --- | --- |
| Loop Playback  C | Toggles, with a checkmark while on; makes a region when there is none |
| Set Loop Start to Playhead  [ | Moves the region's start to the playhead; with no region, makes one from the playhead to the timeline's end |
| Set Loop End to Playhead  ] | Moves its end to the playhead; with no region, makes one from the start of the timeline to the playhead |
| Delete Loop Region | Enabled while there is one. Delete Selection (⌫) removes it too while it is selected |

The two Set items follow the resize rules (frames, minimum length,
limits) and are disabled where they would do nothing. With their keys,
**[** and **]** (Beat Match's keys for the same), they are the keyboard
path for drawing and resizing; the Motion Designer and the graph panels
take [ and ] too, within what they show (`PlaybackLoop.setEdge`),
since the Timeline menu rests while they are open. An empty bar also
has a Create loop region action for VoiceOver.

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
    /// A quarter second in whole frames, at a frame length.
    static func minimumDuration(frameDuration: CMTime) -> CMTime
}
```

`BarColor` comes from [bar-colors.md](bar-colors.md). A color is
changed with `PlaybackLoop.setColor` (an `adjust`, so every window has
it and playing never jumps) and `pickColor` (the color picker).

Pure functions in an extension on `Timeline`, each taking the `limits`
(a `CMTimeRange`) the host allows, so they can be unit tested without a
view. Model them on the section functions in `TimelineSections.swift`
(`resolvedSectionMove`, `resolvedSectionEdge`):

- `loopMinimumDuration: CMTime`: 0.25 s rounded up to whole frames
  (6 frames at 24 fps, 8 at 30).
- `resolvedLoop(from: CMTime, to: CMTime, within limits: CMTimeRange) -> (start: CMTime, end: CMTime)?`:
  orders the two times, puts each on a frame, clamps them to the
  limits; nil when what is left is shorter than the minimum. The
  limits are first rounded inward to whole frames, since a timeline's
  duration can end between frames.
- In all three, nothing past the limits' frames is allowed; a region
  longer than the limits keeps its start at theirs on a move.
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
display's own editor, has its own player; their loops are kept the same
region (see [In every window](#in-every-window)).

New file `Sources/AnimationMeetsVideo/Playback/PlaybackLoop.swift`:

```swift
/// The loop region of the timeline a player shows, and the jump back
/// at its end. Owned by `PlaybackModel` (`playback.loop`).
@MainActor @Observable
final class PlaybackLoop {
    private(set) var region: LoopRegion?
    /// What may play here: the whole timeline, or less while a
    /// designer narrows it.
    var limits: CMTimeRange { … }
    private(set) var frameDuration: CMTime
    /// A take is recording over the playing timeline.
    var isSuspended = false

    /// The stretch that repeats now: the region cut to `limits`, when
    /// it is on, not suspended, and still at least the minimum long.
    var activeRange: CMTimeRange? { … }

    /// Another timeline is shown, 0 to `duration`: its region, with no
    /// jump. A designer's window is kept; the designer gives it back.
    func show(_ region: LoopRegion?, duration: CMTime, frameDuration: CMTime)
    /// The timeline's length or frame rate changed.
    func update(duration: CMTime, frameDuration: CMTime)
    /// A designer plays only part of the timeline; nil gives it back.
    func narrow(to window: CMTimeRange?)
    /// Where play starts from `time`: see the play rule below.
    func playStart(from time: CMTime) -> CMTime?

    /// A region drawn, in place of any there was. It is on.
    func draw(_ region: LoopRegion)
    /// The region resized, moved or recolored.
    func adjust(to region: LoopRegion)
    func remove()
    func toggle()
}
```

`PlaybackModel` makes it in `init`, beside `beatClicks`, handing it the
player, and sets its `jump` to `jump(to:)`. Tests set `jump` and
`playerTime` to stand in for the player.

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
for scrubbing.

The playhead line (`PlayheadRail.Following`, an `AVSynchronizedLayer`
bound to the item) did **not** follow the jump: tried in the app, the
sound and picture turned back and the line ran on, as it had after an
item swapped in while playing. So once the jump's seek has landed,
`jump(to:)` counts it (`PlaybackModel.playingJumps`), and the line's
`Following.generation` is `followGeneration`, the swaps and the jumps
together, which binds it to the item again.

What else follows a jump already works, since each watches the player
rather than a caller:

- the page turn when the playhead lands out of view (the rail's
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
  frame of its end, the playhead moves to the start first
  (`loop.playStart(from:)`). This replaces the "at the item's end,
  start from zero" rule only while a loop is active.
- Where the item's end is: the timeline's duration, or the player
  item's own duration when that is shorter.

## In every window

Built (`Playback/LoopRegions.swift`). One region per timeline, the same
in every window of the project that shows it: the project window, a
timeline window, and the external display's own editor (synced, the
external display shares the project window's player already).

- `ProjectState`, which the project's windows share, holds a
  `LoopRegions`: each timeline's region, and the `PlaybackLoop` of every
  player. `TimelineEditorSurface.showParked` joins its player's loop to
  it (`PlaybackLoop.shared`) and shows the timeline with its ID.
- A change through one loop (`draw`, `adjust`, `setOn` or `toggle`,
  `remove`) goes through `PlaybackLoop.apply(_:publishing:)`, which
  hands it to `LoopRegions.changed`; that keeps the region and applies
  the same change, not published again, to every other loop showing
  that timeline. So a player in another window turns back as its own
  change would have it: a region drawn, or turned on, while it plays
  takes it to the start; one moved around where it plays doesn't.
- A timeline shown for the first time seeds the shared region from what
  the window showing it saved (`region(of:seeding:)`); after that, a
  window opening it shows the shared region, not its own older one.
  The project window parks the region it shows, so the one saved in
  `view-state.json` is the shared one.
- What stays each player's own: whether it plays, a designer's window
  (`narrow`), and the suspension while a take records. Selection stays
  each view's own, too.
- "On only while its bar shows" is one app setting
  (`TimelineAreaLayout.showsLoop`) for every bar, and each host keeps
  it with `setOn`, which does nothing when asked twice, so two windows
  acting on one change don't undo each other.
- Players are held weakly; a closed window's is let go.

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
  - `showParked(_:)`: `playback.loop.show(memory.parked(id)?.loop, duration:, frameDuration:)`.
  - `park(_:playhead:selection:in:)` and the `"surface"` capture
    registered in `showParked`: `parked.loop = playback.loop.region`.
  - When the shown timeline's duration or frame rate changes (an edit),
    `playback.loop.update(duration:frameDuration:)`, from the surface's
    `onChange(of: project)`.
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
    var onPickColor: () -> Void         // "Other…", see bar-colors.md

    static let height: CGFloat = SectionLane.height
}
```

Take from `SectionLane`, which solved the same problems:

- A `draft` state drawn instead of the region during a drag. Unlike a
  section's, it isn't kept past the drop: the region is the player's and
  changes as soon as it is handed over, so there is no edit to wait for.
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
- The region and its edges take a drag with no minimum distance: its
  press selects the region (`isSelected`, `onSelect`; the host keeps
  the selection), and it follows the pointer only once it has moved 3
  points, so a click only selects.
- No rename, no Option-copy, no double-click.

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
- `TimelineLoopLane` (`TimelineLoop.swift`) reads
  `parent.playback.loop.region` in its own body. `TimelineView` is
  `Equatable` and must not read the loop as its body is built, or
  toggling would rebuild the whole timeline; that is why the playhead
  has `PlayheadReader`.
- Mapping: `viewport.x(atSeconds:)` and `viewport.seconds(atX:)`.
  Limits: `0...timeline.duration`. Snap:
  `liveSnap.targets?.nearest(to:within:)` with `snapTolerance(viewport)`.
  Snap indicator: `viewportModel.snapIndicator`.
- The loop button goes in the header beside the sections toggle, bound
  to `areaLayout.showsLoop` as that one is to `showsSections`.
- With both the loop bar and the sections shown, a `Groove` parts them,
  `separatorHeight` high, counted in `railHeight`.
- Over empty bar the pointer is the crosshair (`.pointerStyle(.rectSelection)`),
  as over the keyframe graph, to say that a drag there draws.
- `TimelineKeyboard.handleKey`: `c` without modifiers toggles; with no
  region it makes one over the selected clips (`selection` or
  `groupSelection`: earliest start to latest end), else `0...duration`
  (`Timeline.defaultLoop(over:)`).
- `TimelineActions`, `TimelineCommands`, `TimelineMenuState`: the four
  menu items, enabled as the table says. What the Set items make is
  `Timeline.loopSettingStart(of:to:)` and `loopSettingEnd(of:to:)`, so
  the menu state and the actions agree. `TimelineMenuStatePublisher`
  reads the loop, so the menu follows it without the timeline's body.
- `TimelineRecording.startRecording(_:playing:)` sets
  `playback.loop.isSuspended` while a take records with the timeline
  playing, and clears it when the take stops.

### Motion Designer

Built (`MotionDesignLanes`, `MotionDesignLoop.swift`, `MotionDesignView`).

- `MotionDesignLanes`: a `LoopBar` between `ruler(width:)` and
  `RetimedFilmstrip`, in a view of its own (`MotionLoopLane`) that reads
  the loop, on the ruler's raised surface, while the loop row shows.
  Everything measured from the top goes from one `filmTop`
  (`filmTop(showsLoop:)`: `rulerHeight`, plus `LoopBar.height` while
  the bar shows): `graphHeight`, the notice's top padding, and
  `graphTop` and the locked marker pins in `markings`.
- Mapping: the session is a `SecondsViewport` (`x(of:)`,
  `seconds(atX:)`). Limits: the window (`session.loopLimits`). Snap:
  `session.snapped(_:tolerance:)` with 8 points' worth of seconds;
  shown with the lanes' `snapTime`.
- `MotionDesignSession`: `playback.loop.narrow(to: loopLimits)` when it
  opens and whenever the run changes (which moves the window), and
  `narrow(to: nil)` in `end()`. Its `togglePlayback()` keeps its own
  window rule; the loop's start rule runs inside
  `playback.togglePlayback()` after it. Its stop at the window's end
  stands aside while a loop is active: a region running to the window's
  end has both observers fire together, and a pause there would end the
  loop.
- Selecting: a click on the region selects it (`isLoopSelected`), and
  picking a marker or a clip lets go of it (and the other way round).
  Delete removes the selected region, Escape or hiding the bar lets go
  of it.
- `MotionDesignView`: the loop button in the transport's toggle group,
  bound to `showsLoop`, with `TimelineLoopVisibility` behind the panel;
  and `c` in `handleKey` (with no region: over `run.span`, within the
  window).
- The loop is the timeline's, not the draft's: Cancel doesn't undo it,
  and the region drawn here is the timeline's region.

### Graph editors and the Keyframe Designer

Built (`GraphLoopBar.swift`, `KeyframeGraphView`, `KeyframeGraphHUDs`).

- `KeyframeGraphView` puts `GraphTimeRow` over the first graph of a
  panel (`showsTimeRow`). The `LoopBar` goes right under it, under the
  same condition, so a linked panel has one bar and the Keyframe
  Designer, which embeds a `KeyframeGraphView`, gets it for free; and
  only while the loop row shows. The height it takes from the plot
  becomes `GraphTimeRow.height + LoopBar.height`. The bar spans the plot
  alone (`GraphLoopBar`), so a region can't be drawn in its margins.
- Mapping, as `GraphTimeRow` does it: x is
  `layout.x(axis.keyTime(atTimeline: t).seconds)`; time is
  `timeline.snappedToFrame(axis.timelineTime(atKey: layout.seconds(atX: x)))`
  with x held inside `layout.plot`.
- Limits: the clip's `startOffset...endOffset` for a clip's parameter,
  `0...timeline.duration` for a layer's, cut to the timeline.
- Snap: on with the timeline's snapping (`Preferences.snapping`, on
  when absent). Targets: `hud.project.snapTargets(in:playhead:markers: [])`,
  the parked playhead, and the keyframes of the graph with the bar (the
  top one of a linked panel), in timeline time. The nearest within 8
  points, measured in x through the mapping.
- Hidden when `hud.playback` is nil.
- A `GraphLoopToggle()` beside each `GraphSkimToggle(hud:)`: the
  graph's toolbar, the linked panel's `presetBar`, and
  `KeyframeDesignerTransport`. It shows or hides the bar, as the
  timeline's loop button does.
- Selecting: a click on the region selects it
  (`KeyframeGraphHUDs.isLoopSelected`) and lets go of the graph's
  keyframes; picking keyframes lets go of it.
- `KeyframeGraphHUDs.watchSpace` listens in the panels for Space, `c`
  (with no region, one over the panel's parameter's clip, or the whole
  timeline for a layer's) and, while the region is selected, Delete,
  which otherwise goes on to the graph's keyframes. Same guards: no
  modifiers, not while a text view has the keyboard, not for a focused
  control.

## Accessibility

Following [accessibility.md](accessibility.md), "Rules for new UI":

- The bar: `.accessibilityElement(children: .contain)`, label "Loop".
- The region: one element, label "Loop region", value
  "On, from 00:00:12:00 to 00:00:16:00" (or "Off, …"), `.isButton`
  (and `.isSelected` while selected); its default action selects it,
  as a click does.
- Its named actions, which are also its context menu's commands and
  the drags a frame at a time: Turn loop on / off, Move start one
  frame earlier / later, Move end one frame earlier / later, Move
  region one frame earlier / later, Delete loop region, Choose color…,
  Use default color.
- The main timeline's loop button: `accessibilityLabel("Loop row")`,
  as the sections button is "Sections row".
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
- `Project/ViewStateFileTests`: a loop survives a write and read; a
  file without `loop` reads as none; a damaged one is dropped, and the
  rest of the file still reads.
- `UI/LoopBarInteractionTests` with `EventHarness` (`UI_EVENTS=1`):
  a drag draws; a drag on an edge resizes and snaps; a click selects
  and never toggles; a drag of the middle moves; Escape cancels.
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
10. **The loop button shows or hides the bar**, in the main timeline
    and, the same setting, the Motion Designer, as the
    sections button does its row; asked for once the bar was tried.
    Hiding the bar turns the loop off (asked for too), and showing it
    turns the region on again, so the button works as Logic's cycle
    button and there is a pointer path back to on. C and the menu turn
    it on or off as well.
11. **A click selects the region, for Delete**, as a section's does
    (asked for once the bar was tried), instead of turning it on or
    off. Its right-click menu, C and the menu turn it on or off.

## Building it

Every step is built, the region's color included, and the region
is the same in every window ([In every window](#in-every-window)). None of it has
been compiled or run yet: it was written where there is no Xcode, so
build it, run the tests and look at the snapshot before going on.

1. Built: `BarColor` from [bar-colors.md](bar-colors.md), and `color`
   on `LoopRegion`, through `PlaybackLoop.adjust`, and in the view
   state's `loop`.
2. Built: `LoopRegion` and the `Timeline` rules, with `LoopRegionTests`.
3. Built: `PlaybackLoop`, `PlaybackModel.jump(to:)`, the play rule, with
   `PlaybackLoopTests`.
4. Built: saving in the view state and the surface's park and show,
   with `ViewStateFileTests`.
5. Built: `Design.loop`, `LoopBar`, and the main timeline's row,
   button, key and menu items; `TimelineRecording` suspending the loop
   while a take records; the `loopBar` snapshot case and
   `LoopBarInteractionTests`.
6. Built: the Motion Designer's bar, button and key, with
   `MotionDesignLoopTests`; `MotionDesignLanesInteractionTests` measure
   from `filmTop`.
7. Built: the graph editors' and the Keyframe Designer's bar, toggle
   and key; and `LoopRegions`, with `LoopRegionsTests`.
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
