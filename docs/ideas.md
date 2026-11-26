# Ideas

Status: **planned, not designed**. Features to add, each short enough to
talk through before it gets a design doc of its own. When an idea is
taken up, move it into the document it belongs to (or a new one) and
take it out of here.

## Smoother scrubbing on laptops

Scrubbing and skimming H.264 and HEVC footage on the timeline is too
heavy for a laptop. The first idea was to turn each clip into ProRes
when it is added to the timeline; this entry checks that against how
the app works and proposes doing without the copies first.

### Why scrubbing is heavy now

- **Every scrub was an exact seek.** Moving the playhead or skimming
  seeked the player to the exact frame (`PlaybackModel`, tolerances of
  zero), one seek at a time with the newest move next; step 1 below now
  seeks roughly while it moves fast. H.264 and HEVC
  are long-GOP: a frame can only be decoded from the keyframe before it,
  often a second or more back, so each step of a scrub decodes up to a
  whole GOP to show one frame. Playing forward is cheap, since the
  hardware decoder goes frame by frame; jumping around is what costs.
- **Sources are decoded at full size.** Half and Quarter make
  compositing cheaper, not decoding
  ([rendering.md](rendering.md#viewer-quality-implemented)), so a 4K
  clip costs a 4K decode per seek, and each layer of a stack adds its
  own.
- **Drawing ahead skips plain clips.** `PlayheadPrerenderer` keeps the
  pictures of the two seconds after the playhead, but only of stretches
  worth keeping (effects, stacks), not plain footage.

### ProRes copies, checked

It would work technically: clips point at assets, not files, so
decoding could read another file behind an asset, and the app already
writes ProRes for its render cache. But:

- **It reverses a stated rule.** The shared principles say the app
  never makes proxies, optimized copies or transcodes of footage
  ([README.md](README.md#shared-principles)), and
  [media-replacement.md](media-replacement.md) chose replacing files
  over proxies because of disk space.
- **Disk is acceptable.** ProRes 422 is about 147 Mb/s at 1080p30
  (66 GB an hour) and about 590 Mb/s at 4K30 (265 GB an hour), roughly
  ten times the H.264 or HEVC it comes from; 10-bit and HDR footage
  needs 422 HQ, larger again. But projects average about three minutes,
  and only the clips used on a timeline are copied, not the browser's,
  so a typical project's copies are 13 GB or so of 4K; an hour-long one
  at about 300 GB is reasonable too.
- **The laptop pays first.** Every clip added starts an encode. Macs
  with a ProRes engine (M1 Pro and Max, and later chips) do it faster
  than real time; others encode in software, slowly and on battery.
- **Timing has to match exactly.** Phone footage is often variable
  frame rate; a copy must keep every frame's own time or cuts, beats
  and keyframes drift against the original.
- **Export still reads the originals**, both for quality (ProRes 422 is
  not lossless) and because untouched stretches pass through as they
  are, so there would be two decode paths to keep alike. Replacing a
  file must throw its copy away.
- **It doesn't make effects faster.** An effect's cost is compositing,
  which is the same over ProRes. Heavy stretches are already rendered to
  ProRes in the background ([Render cache](rendering.md#render-cache-implemented)),
  and clips' pictures are kept between frames.

### Without copies

In order, each measured on a laptop before the next:

1. **Rough, then exact** (built, not yet measured on a laptop): see
   [rendering.md](rendering.md#rough-then-exact). Fast moves of the
   playhead or the skimmer seek with a tolerance, and the player lands
   on the exact frame 100 ms after they stop. A change to the seek queue
   alone, costing no disk.
2. **A scrub cache** (built, see
   [rendering.md](rendering.md#scrub-cache)). Paused, decode the footage around the playhead,
   forward from each keyframe as the hardware decoder likes, at the
   viewer's size, and keep the frames in memory, as
   `PlayheadPrerenderer` does for stretches with effects. Moving back
   and forth over that stretch then draws from memory. A quarter-size
   1080p frame is about half a megabyte, so ten seconds of 30 fps is
   150 MB.
3. **Decoding at the viewer's size**, where VideoToolbox can scale in
   the decoder, so a Quarter viewer stops paying for a full 4K decode.
4. **Thumbnails while catching up.** The asset's reference thumbnails
   and filmstrips are already on disk; while a seek is behind, a plain
   clip can show the nearest one until its frame arrives.

### If that isn't enough: ProRes copies of the clips used

The ProRes idea itself, as the fallback if the steps above still leave
laptops behind. Disk being acceptable, the copies are full size rather
than small proxies, so they serve playing as well as scrubbing:

- **Full size and all-intra**: ProRes 422, or 422 HQ for 10-bit and
  HDR footage, at the footage's own size and frame times, so any frame
  decodes on its own and a stack of layers decodes cheaply too.
- **Only what is used**: the clip's range on the timeline plus a few
  seconds of handles, made in the background after it is added (on the
  ProRes engine where the Mac has one), and never while playing, on
  battery or in Low Power Mode. Trimming a clip longer copies the new
  part; until a copy is done, the original plays.
- **Only for the viewer.** Scrubbing, skimming and playing read the
  copy; export always reads the original, so nothing about the output
  changes, and untouched stretches still pass through as they are.
- **Exact timing**: each frame keeps the original's own time, variable
  frame rate included, checked against the original's frame times
  before the copy is used.
- **Disposable**: in `Cache/`, kept while a timeline uses the clip and
  thrown away when no timeline does or the file is replaced. Project
  Settings shows how much they take, with a button to clear them.
- **A setting**, in Project Settings with an app-wide default for new
  projects, off unless turned on.

The shared principles allow this ([README.md](README.md#shared-principles)):
viewer copies may be made as disposable caches, never read by export,
and footage is never re-encoded to be editable or in place of the
original.
