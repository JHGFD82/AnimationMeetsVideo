# Rendering and smooth playback

Status: **viewer quality implemented**; the render cache is **planned**.

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

## Render cache (planned)

- **Segments, not clips.** The timeline is split where what is drawn
  changes. A transition spans two clips, and a layer above (or an
  adjustment layer) changes everything under it, so caching by clip would
  be wrong. A segment that is one untransformed clip plays straight from
  its source and is never rendered.
- **Keyed by content.** Each segment's key hashes everything that affects
  its frames: source files and their stamps, trims, transforms and
  keyframes, transitions, effects, frame size, frame rate and color space.
  An edit invalidates only the segments whose hash changes. Old renders
  stay until evicted, so undo finds them again.
- **Format.** ProRes in `Cache/`, the codec export writes, so export can
  reuse finished segments. The folder is size-capped and evicts least
  recently used first (see [project-package.md](project-package.md)).
- **Playback.** A finished segment plays from its cached file instead of
  being composited live, at full size whatever the viewer quality.
- **Background rendering only when idle.** Any edit, scrub or playback
  pauses rendering; it resumes after about two seconds of quiet. A segment
  whose key changes mid-render is cancelled. Rendering also backs off
  under thermal pressure or on battery.
- **Indicators.** A thin strip under the ruler shows each segment as
  needing a render, rendering, or done. The clip, transition or
  adjustment layer that causes a render shows a progress bar on its own bar
  in the timeline.
