# Rendering and smooth playback

Status: **implemented**: viewer quality, the render cache, and export
reusing renders.

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
  player has settled on a frame, that frame is drawn at full size
  separately (`AVAssetImageGenerator`) and shown over the video until
  playback or a scrub starts. Scrubbing shows the smaller size until it
  stops. While Auto is below full, the menu shows ½ or ¼.

Starting playback: whenever the player is paused (after a pause, a seek,
a new item or a size change) it is prerolled, so its pipeline is already
full when play is pressed, and it doesn't wait to judge its buffer full
enough (`automaticallyWaitsToMinimizeStalling` is off; media is local).
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

## Render cache (implemented)

- **Segments, not clips.** Every build of the timeline splits it where any
  picture's footage starts or ends (`RenderSegment`). A transition spans two
  clips, and a layer above changes everything under it, so caching by clip
  would be wrong. A stretch with one picture drawn the same way throughout
  (whatever fixed transform it has) is never rendered; one with several
  pictures, or with anything keyframed or transitioning, is. Those are cut
  into pieces of at most 96 frames, so a render stopped by an edit loses
  little and finished pieces play as soon as they're done.
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
  is cheap since there is one layer to draw.
- **Background rendering only when idle.** `RenderScheduler` renders one
  piece at a time, starting at the playhead and running to the end, then
  the pieces before it. Any edit, scrub or playback stops the
  render in progress (it starts over later); rendering resumes after two
  seconds of quiet. It also waits while the Mac is hot (serious or
  critical thermal state) or in Low Power Mode. A piece that fails to
  render is not retried until the project is reopened. Each finished piece
  rebuilds the viewer's composition so it is used at once. Rendering
  only happens while paused, so the new player item is seeked to the
  playhead before it is swapped in, and the viewer keeps showing the old
  item's frame until the new one draws, so the picture doesn't blink.
  That can take half a second or more, since a paused player holds back
  a new item's first picture until its sound is ready. The player is
  prerolled as soon as the new item is ready, which usually makes it draw
  at once. If it still hasn't drawn after five seconds it is seeked to
  where it is and prerolled again, and only if that fails too is the old
  frame let go (both are logged), since an uncovered layer shows black
  until the next play or scrub. A render that finishes just as play is
  pressed waits for the next pause, since swapping the item mid-play
  freezes the picture.
- **Export.** A ProRes 422 export plays every stretch that has a render
  from the cache instead of compositing it again, which is much faster for
  stacked or animated stretches. The render is encoded a second time, which
  costs very little with ProRes 422. A ProRes 4444 export always
  composites from the sources, since a 422 render would lose the extra
  color detail 4444 is chosen for. Background rendering waits while an
  export runs.
- **Indicators.** A thin strip along the bottom of the ruler shows each
  piece as needing a render (orange), rendering (filling in green), or
  rendered (green); stretches that need no render show nothing. Each clip
  that takes part in a piece still to render has a progress bar along its
  bottom edge until all of its pieces are done. Clips inside a nested
  timeline count toward the nested timeline's clip.

Not yet done:

- Only the timeline in the main window is rendered; the external display's
  own editing mode doesn't render.
- A render stopped partway starts over rather than resuming.
- Adjustment layers and effects don't exist yet; their settings will need to
  join the key, and their progress bar will go on the adjustment layer.
