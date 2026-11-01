# Rendering and smooth playback

Status: **implemented**: viewer quality, the render cache, export
reusing renders, clips' pictures kept between frames and drawn ahead of
the playhead.

Transitions, effect stacks, and soon more effects and
adjustment layers make some stretches of a timeline too expensive to draw
live at full size. The approach has two halves: draw live at a reduced size
when needed, and render full-size frames in the background when the
timeline is idle.

## Viewer quality (implemented)

The viewer and export both draw through `LayeredCompositor`, which
composites with Core Image on a Metal context; the built-in AVFoundation
compositor is no longer used. Its instructions keep the timeline's frame
size and scale into whatever size the player asks for, so the viewer can
draw at full, half or quarter size (a quarter of the pixels per step) by
swapping the player item's video composition for a scaled copy. Every
picture, and every nested timeline, is drawn straight to that size.

Each stretch's instruction holds a tree (`DrawClip`): the clips of the
timeline's layers from the top down, where a nested timeline is a group
holding the clips of its own layers. A group is drawn on its own over
transparency and placed as one picture, which is what makes it closed; one
set to Pass Through has its layers drawn straight into the timeline above,
placed as the group's Position, Scale, Rotation, Opacity and dissolve
would place them (wipes and the film dissolve need one picture and are
skipped).

One exception to drawing: a stretch of a single picture with nothing done
to it and no fitting needed (the media is the frame's size, upright) is a
passthrough instruction in export, so its frames go through as they are.
The viewer always draws, since it may draw smaller.

The setting is in the viewer's transport bar and remembered per Mac, not
per project:

- **Full / Half / Quarter** always draw at that size, paused or playing.
- **Auto** shows paused frames at full size. While playing, it measures
  twice a second how many frames the compositor finishes. Two
  measurements in a row under 90% of the frame rate step down a level.
  Stepping back up waits until playback has kept up for five seconds and
  drawing a frame takes so little time that four times the pixels would
  still fit in under 40% of a frame, and then happens at the next pause:
  changing size during playback freezes the picture for 350–600 ms on the
  test project, which only a step down (after a stutter anyway) is worth.
  The player stays at the level it
  settled on when paused, so pressing play doesn't swap the composition
  and throw away what the player had buffered. Instead, once a paused
  player has settled on a frame, that frame is drawn again at full size
  from the frames the player decoded for it (`FrameRedrawer`, see "The
  viewer's picture" below), and the smaller one is never shown. Scrubbing
  shows the smaller size until it stops. While Auto is below full, the
  menu shows ½ or ¼.

Within a size, what a playing frame draws follows how heavy frames are:
the compositor tells `RenderMeter` how long each playing frame took
against how long it is on screen, and `DrawingOptions` moves the motion
blur samples it draws by that smoothed load (see effects.md, "Time and
Shutter"). That needs no new composition, so it can go both ways while
playing, and it gives way before the size does.

Starting playback: whenever the player is paused (after a pause, a new
item or a size change, and once the playhead has rested for 250 ms after
a seek) it is prerolled, so its pipeline is already full when play is
pressed, and it doesn't wait to judge its buffer full enough
(`automaticallyWaitsToMinimizeStalling` is off; media is local). A seek
drops a preroll under way or waiting: a preroll decodes ahead of the
playhead, and a drag's next seek waited behind it. On a timeline nesting
another over long-GOP HEVC that held the viewer to 3 to 5 frames a
second; waiting for the playhead to rest brought it to about 50.
On the test project that cut the wait for the first moving frame from
about 920 ms to about 310 ms. What remains is AVPlayer holding the
picture back to keep it in sync with the sound device, which takes longer
on Bluetooth output (160 ms of latency on AirPods); without sound the
first frame moves after about 45 ms.

Limits:

- A smaller size makes compositing cheaper, not decoding: every source is
  still decoded at full size. To keep that cheap, the viewer decodes SDR
  (Rec. 709) timelines into 8-bit BGRA (`SDRLayeredCompositor`), half the
  memory traffic of the half floats HDR timelines and export use. A stack
  of 4K sources can still stutter at quarter size; renders fix that.
- The external display shows the same player, so it drops size too.
- Changing size during playback swaps the composition, which can cause a
  brief hitch. Auto changes size during playback only to step down, and
  never on play.

## The viewer's picture (implemented)

One thing draws the viewer's picture, paused or playing: `ViewerDisplay`,
a pixel buffer shown by a plain layer (and by the synced external
display's, the same buffer). There is no `AVPlayerLayer` and nothing drawn
over it, so nothing can show through, be handed over to, or differ from
it. A picture stays until a newer one replaces it: a new player item, an
emptied timeline or a slow frame never shows black in between.

- **Where frames come from.** Every player item gets an
  `AVPlayerItemVideoOutput` asking for the compositor's own pixel format
  (8-bit BGRA for SDR timelines, half floats otherwise,
  `ComposedTimeline.viewerPixelFormat`), so the frames it hands over are the
  compositor's, unconverted, tagged with the timeline's colors. A display
  link pulls the frame for each refresh while playing; paused, it looks for
  a frame for a moment after a seek, a new item or a changed composition,
  and otherwise waits for the output to say it has one.
- **Frames drawn again.** The viewer's compositions keep the frames the
  paused frame was drawn from (`SourceCapture`), armed for the paused time
  only, since a paused player draws the next frames ahead and a playing one
  needs none. `FrameRedrawer` composes that frame again from them with the
  same Core Image options, into the same pixel format, tagged the same way,
  so its picture is the compositor's: a value edit (see "Values without a
  build") and the full-size paused frame under Auto are drawn this way and
  put on screen in place of the output's frame with nothing else changing.
- **Swapping the item.** The new item is seeked to the playhead and put in
  the player, and the viewer keeps its picture until the new item's output
  has a frame (`PlaybackModel.swap`); an output only gets frames from its
  player's current item, so the item goes in first and the picture changes
  once its frame is there. A paused player holds back a new item's first
  picture until its sound is ready, which prerolling usually ends at once;
  if it hasn't drawn after two seconds it is seeked where it is and
  prerolled again (logged). Playing, the new item is started at an exact
  host time (`setRate(_:time:atHostTime:)`) at the time the timeline has
  reached by then, so the playhead neither falls behind nor jumps, and its
  first frame fades in over the last one in 80 ms.
- **When items are built and swapped.** `ViewerPipeline`, outside any
  view, takes everything the viewer follows as events, in order, on one
  loop. An edit that leaves the `StructureKey` the same never builds (see
  "Values without a build"). One of structure asks for a build of the
  latest project: there is one request, which a newer edit overwrites, and
  one build at a time. A build is never cancelled by a newer edit, so
  something always finishes; a result whose key is no longer the latest is
  dropped and the latest built, so a burst of edits builds at most the
  first and the last. A 75 ms pause before a build lets a burst land; it
  only saves work. A build is swapped in only while no value drag is under
  way, and one for renders alone only while paused. Another timeline
  stops the build under way (`CompositionExporter` checks for cancellation
  between its stages and clips) and builds the new one at once. The editor
  only tells it what it shows (`ViewerPipeline.show`), once per edit; it
  works out the keys itself, skips an edit the picture doesn't show (a
  rename, a volume), and follows renders finishing, the package, motion
  blur in the viewer, play and pause and value drags on its own. The
  timeline below compares what it shows by edit stamps (`EditStamp`: every
  write to `ProjectState` gets a number never given out before, and so does
  each timeline it changed), so it isn't redrawn for a tick of the
  playhead, and an edit of another timeline's values costs one comparison
  of the project's structure rather than a redraw.
- **An emptied timeline** lets go of the player's item, and the viewer
  says there are no clips over its last picture, so emptying and filling a
  timeline again (an undo) shows no black.

## Render cache (implemented)

- **Segments, not clips.** Every build of the timeline splits it where any
  picture's footage starts or ends (`RenderSegment`). A transition spans two
  clips, and a layer above changes everything under it, so caching by clip
  would be wrong. A stretch with one picture drawn the same way throughout
  (whatever fixed transform it has) is never rendered; one with several
  pictures, or with anything keyframed or transitioning, is. Those are cut
  into pieces of at most 96 frames, so a render stopped by an edit loses
  little and finished pieces play as soon as they're done.
- **One grid for the edges.** The places a picture starts or ends come in
  any timescale (a retimed clip's can be in nanoseconds), and two whose
  common timescale doesn't fit CoreMedia's 32 bits leave a stretch between
  them rounded a fraction of a nanosecond past or short of the next.
  AVFoundation turns down a video composition whose instructions overlap
  or leave a gap, so renders fail at once and the player never draws. Each
  stretch's range is therefore put on one grid of about a microsecond, a
  multiple of the frame's timescale
  (`CompositionExporter.instructionTimescale`), so frame times stay exact
  and every stretch ends where the next begins; what a stretch draws is
  still decided from the exact edges.
- **Hidden layers.** A layer drawn only where a picture above it covers
  solidly is left out of the stretch (`withoutHidden`), as is one drawn
  wholly off the frame, so two opaque clips stacked in the same place
  (full frame or letterboxed alike) count as one picture: drawn live, or
  passed through in export, never rendered. A picture covers solidly when
  its footage can't be transparent (by codec: H.264, HEVC, ProRes 422,
  and ProRes 4444 written 24 bits deep; anything else counts as
  transparent), it has nothing done to it throughout (no effects,
  opacity, transition, Blend, Echo, Trails or Motion Blur), and it isn't
  enlarged: an enlarged picture's edge pixels are mixed with the
  transparency past them, so what is under it shows faintly there. Only
  the pixels it covers whole count, so an edge between pixels leaves that
  row to show what is under it. A layer below is left out only when it
  is drawn plainly the same way, so where it lands is known. Stills never
  cover anything yet, and only a timeline's own layers are looked at, not
  those inside nested timelines or reached by adjustment layers.
- **Time and Shutter.** A clip with Blend, Echo, Trails or Motion Blur draws
  the clip more than once, so its stretches are rendered like others, and
  its key holds the file time each frame comes from (when retimed), the
  extra footage's delays and strengths, and the shutter settings. The
  viewer draws fewer motion blur samples while playing (see effects.md).
- **Keyed by content.** Each piece's key is a hash of everything that
  decides its frames: each layer's file, its size and date on disk, the
  file time it starts at, and each clip's resolved steps on every frame
  (after folding, with its transition's opacity, transform, crop and
  film-dissolve state), in the structure the clips are nested in, plus the
  frame size, rate and color space. Where the
  piece sits in the timeline is left out, so moving clips keeps their
  renders, and old renders stay until evicted, so undo finds them again.
  `RenderSegment.formatVersion` is bumped when drawing changes in a way the
  key can't see. Effects add their settings to the key through the resolved
  steps.
- **Format.** ProRes 422 without sound in `Cache/Renders/<key>.mov`, drawn
  by the export compositor. A render is written as `<key>.partial.mov` and
  renamed when done; leftovers are deleted when the project opens. The
  folder is capped at 20 GB and evicts least recently used first (playing
  a render counts as using it), never a render the current timeline uses.
- **Playback.** When the viewer's composition is built, each piece with a
  render plays it from its own track instead of compositing the layers.
  Renders play through the same compositor at the viewer's quality, which
  is cheap since there is one layer to draw. A render can be a fraction
  of a frame shorter than its piece, whose ends are clip edges that at
  rates such as 29.97 fall between frame times; one short by under a
  frame is stretched to fit.
- **Background rendering only when idle.** `RenderScheduler` renders one
  piece at a time, starting at the playhead and running to the end, then
  the pieces before it. Any edit, scrub or playback stops the
  render in progress (it starts over later); rendering resumes after two
  seconds of quiet. It also waits while the Mac is hot (serious or
  critical thermal state) or in Low Power Mode. A piece that fails to
  render shows red on the timeline and isn't tried again by itself.
  **Timeline > Render Now** (Option-Cmd-R) renders what is left at once,
  from the playhead, without waiting for quiet, a cool Mac or Low Power
  Mode to end, and tries the failed pieces again; playing, exporting, or
  any edit or scrub stops it, and rendering goes back to waiting. Each finished piece
  rebuilds the viewer's composition so it is used at once, swapped in as
  any item is (see "The viewer's picture"). A render that finishes just as
  play is pressed waits for the next pause, since a swap mid-play holds
  the picture for a moment.

  Rendering several pieces at once was tried and isn't worth it: the GPU
  is already the limit. On an M4 Pro, rendering 16 s of three
  blurred, graded 1080p layers took 2.34 s one piece at a time and 2.22 s
  two at a time (7.04 s and 6.24 s with motion blur on the top layer),
  while the first piece, at the playhead, was ready after 1.09 s instead
  of 0.57 s (3.39 s instead of 1.98 s); three at a time was slower than
  two. `RenderThroughputBenchmark` measures this (run it with
  `RENDER_BENCHMARK=all`, in release; see the test for the commands).
- **Values without a build.** An edit that leaves the project's
  `StructureKey` the same (effect controls and anchor points, which the
  compositor takes, and volume and pan, which the sound taps read) never
  builds anything, paused or playing. Its values go into `LiveValues`, the
  player's own store, which the compositor reads for every frame it draws
  and puts into each clip's drawing (`DrawClip.withValues`). Paused, the
  frame on screen is drawn again from the frames it was drawn from
  (`FrameRedrawer`, see "The viewer's picture"), about 6 ms on an HD
  timeline of three layers and a shape against about 46 ms to build and
  draw; with nothing to draw it from yet (the player paused on a frame it
  drew while playing), the player is asked to draw it again, through the
  compositor, which keeps it for the next edit. A stretch that plays from
  a render holds the values it was made with, so the item draws every
  stretch from its clips instead (`PlaybackModel.playWithoutRenders`):
  only its video composition changes, so the sound plays on and the
  picture stays until the new frame is there. A value drag does that when
  it starts, so none of its steps waits on anything. The renderer's plan
  is made again once value edits pause for 0.3 s, or when a drag ends,
  without swapping the item, since its pieces are named for what they show;
  a finished render then swaps in an item built with it, which shows the
  same picture.
- **Dragging a value.** While a value field is dragged
  (`ProjectHistory.beginGesture`), each step is a write to `LiveValues` and
  a frame drawn again. A change of structure during it (a clip's speed) is
  built when the mouse is released, since retiming is judged by playing,
  and no item is swapped before then. Nothing renders from the drag's start
  until what follows its end (a build swapped in, or the renderer's plan
  made again) is done.
- **Clips' pictures kept between frames.** A clip's finished picture (put
  into the frame and run through its stack and transitions, before it is
  drawn over what is below) is drawn into memory and kept when a later
  frame will draw it again (`ClipPictureCache`), least recently used
  going first past a budget: a sixteenth of the Mac's memory, at most
  1 GB, for the viewer; 512 MB for each export or render. It is kept
  for a clip with Trails, whose copy `delay` later is the picture the
  clip finished as then, so sequential playback and export take the copy
  rather than draw it again; and, for a paused frame drawn again with new
  values, for each clip drawn the same way as the last time
  (`Keeping.steady`), so a drag draws only the clip being changed: 7.0 ms
  a frame to 2.7 ms for one of three graded, blurred 1080p layers. A
  picture is found by everything that decides it (the clip, its footage's
  file time, its resolved steps and transition, its placement, the frame
  and output size, the color space, playing or not), so a frame drawn from
  kept pictures is the frame drawn without. A clip whose picture depends on
  more (what is below it through Blending or a transition's reveal, an
  input, other moments of its footage, a nested timeline) is never kept,
  nor one only moved, which costs no more to draw. The viewer's pictures
  are let go when a build of another structure is played, since a
  replaced file or a changed package isn't in what finds them.
- **Drawing ahead of the playhead.** Half a second after the paused player
  settles (after a pause, seek, new item or change of size),
  `PlayheadPrerenderer` draws the next two seconds from the playhead, then
  half a second before it, through the player's own composition at the
  size it draws, keeping every clip's picture it can (`Keeping.all`).
  They are drawn as playing draws them (the playing motion blur budget,
  looks that draw less while playing), so pressing play there takes them
  instead of drawing the clips again; paused frames draw at their own
  quality and don't. Stretches with nothing worth keeping (plain pictures,
  renders) are skipped, a pass stops once it has kept three quarters of
  the budget so it doesn't push out its own first pictures, and it waits
  while the Mac is hot or in Low Power Mode. Any seek, play, edit or
  change of size stops it. It reaches only as far as it got before play
  was pressed, so it covers a heavy stretch's first seconds at once;
  background renders cover the rest once the timeline is idle.
- **Following other edits.** An edit that changes the structure builds
  a new composition, swapped in once it is built, playing or paused (see
  "The viewer's picture").
- **Drawing frames at once.** The viewer's compositor draws one frame at a
  time, in the order asked for, so a seek lets go of everything queued.
  Export and background renders, which draw without `DrawingOptions`,
  draw two at once (`LayeredCompositor.exportConcurrency`), so one
  frame's work on the processor overlaps the last one's on the GPU: a
  96-frame 1080p export of three blurred, motion-blurred layers went from
  1.39 s to 1.00 s; three or four at once were no faster.
- **Export.** A ProRes 422 export plays every stretch that has a render
  from the cache instead of compositing it again, which is much faster for
  stacked or animated stretches. The render is encoded a second time, which
  costs very little with ProRes 422. A ProRes 4444 export always
  composites from the sources, since a 422 render would lose the extra
  color detail 4444 is chosen for. Background rendering waits while an
  export runs.
- **Indicators.** A thin strip along the bottom of the ruler shows each
  piece as needing a render (orange), rendering (filling in green),
  rendered (green) or failed (red); stretches that need no render show nothing. Each clip
  that takes part in a piece still to render has a progress bar along its
  bottom edge until all of its pieces are done. Clips inside a nested
  timeline count toward the nested timeline's clip.

Not yet done:

- Only the timeline in the main window is rendered; the external display's
  own editing mode doesn't render.
- A render stopped partway starts over rather than resuming.
- Adjustment layers and effects don't exist yet; their settings will need to
  join the key, and their progress bar will go on the adjustment layer.
