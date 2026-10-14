# Rendering and smooth playback

Status: **implemented**: viewer quality and the render cache. Export
doesn't reuse renders yet.

Transitions, keyframed layer transforms, and soon video effects and
adjustment layers make some stretches of a timeline too expensive to draw
live at full size. The approach has two halves: draw live at a reduced size
when needed, and render full-size frames in the background when the
timeline is idle.

## Viewer quality (implemented)

The viewer always draws through `LayeredCompositor`, which composites with
Core Image on a Metal context. Its instructions keep the timeline's frame
size and scale into whatever size the player asks for, so the viewer can
draw at full, half or quarter size (a quarter of the pixels per step) by
swapping the player item's video composition for a scaled copy.

Export is unchanged: it uses the built-in compositor, and `LayeredCompositor`
only for a timeline with a film dissolve. The two are tested to draw the
same picture.

The setting is in the viewer's transport bar and remembered per Mac, not
per project:

- **Full / Half / Quarter** always draw at that size, paused or playing.
- **Auto** draws paused frames at full size. While playing, it measures
  twice a second how many frames the compositor finishes. Two
  measurements in a row under 90% of the frame rate step down a level.
  Stepping back up waits until playback has kept up for five seconds and
  drawing a frame takes so little time that four times the pixels would
  still fit in under 40% of a frame. The next play starts at the level the
  last one settled on. While Auto is below full, the menu shows ½ or ¼.

Limits:

- A smaller size makes compositing cheaper, not decoding: every source is
  still decoded at full size and converted to half float. A stack of 4K
  sources can stutter at quarter size. Decoding SDR timelines to 8-bit
  would halve that cost and is the next step if it matters.
- The external display shows the same player, so it drops size too.
- Changing size during playback swaps the composition, which can cause a
  brief hitch. Auto changes rarely for that reason.

## Render cache (implemented)

- **Segments, not clips.** Every build of the timeline splits it where any
  layer's footage starts or ends (`RenderSegment`). A transition spans two
  clips, and a layer above changes everything under it, so caching by clip
  would be wrong. A stretch with one layer drawn the same way throughout
  plays straight from its file and is never rendered; one with several
  layers, or with anything keyframed or transitioning, is. Those are cut
  into pieces of at most 96 frames, so a render stopped by an edit loses
  little and finished pieces play as soon as they're done.
- **Keyed by content.** Each piece's key is a hash of everything that
  decides its frames: each layer's file, its size and date on disk, the
  file time it starts at, and the transform, opacity, crop and film-dissolve
  state on every frame, plus the frame size, rate and color space. Where the
  piece sits in the timeline is left out, so moving clips keeps their
  renders, and old renders stay until evicted, so undo finds them again.
  `RenderSegment.formatVersion` is bumped when drawing changes in a way the
  key can't see. Effects will add their settings to the key.
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
  piece at a time, in timeline order. Any edit, scrub or playback stops the
  render in progress (it starts over later); rendering resumes after two
  seconds of quiet. It also waits while the Mac is hot (serious or
  critical thermal state) or in Low Power Mode. A piece that fails to
  render is not retried until the project is reopened. Each finished piece
  rebuilds the viewer's composition so it is used at once.
- **Indicators.** A thin strip along the bottom of the ruler shows each
  piece as needing a render (orange), rendering (filling in green), or
  rendered (green); stretches that need no render show nothing. Each clip
  that takes part in a piece still to render has a progress bar along its
  bottom edge until all of its pieces are done. Clips inside a nested
  timeline count toward the nested timeline's clip.

Not yet done:

- Export doesn't reuse renders yet.
- Only the timeline in the main window is rendered; the external display's
  own editing mode doesn't render.
- A render stopped partway starts over rather than resuming.
- Adjustment layers and effects don't exist yet; their settings will need to
  join the key, and their progress bar will go on the adjustment layer.
