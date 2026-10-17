# Scene detection and splitting: review findings

Status: **review notes** for existing behavior, with the tests that measure
it (`SceneReviewTests.swift`, fixtures in `SceneFixtures.swift`). The
review itself changed no code; fixes made since are marked below. Tests marked as known
issues assert what should happen and are wrapped in `withKnownIssue`; the
suite fails when a defect is fixed, as a reminder to remove the wrapper.

Scope read: `FrameScorer`, `ChangeScoreTrack`, `SceneDetector` (cuts and
scenes), `SceneEdits`, `EditingProject.addScenes` and `scenes(ofAsset:)`,
`split`, `coveringWholeFrames`, and the undo history. Fixtures are real
H.264 movies decoded by `FrameScorer`, so timestamps are measured end to
end; the boundary properties run over 400 seeded random tracks each.

## Confirmed correct (measured)

- **Hard cuts** score about 163/255 and are found at the first frame of the
  new shot, exactly.
- **Variable frame rate**: times are the real presentation times (a cut after
  a 24 to 12 fps change is at 1.000 s; later frames are 1/12 s apart).
- **Dropped frames**: the cut keeps its real time; frame count drops by two.
- **Timebase**: with the file's own timescale (30000 for NTSC) a cut is
  exactly 30030/30000. A file written at 600 units a second rounds by under
  half a tick (0.83 ms).
- **Late start** (a first picture one second into the movie): times are on
  the asset's timeline, the cut is at 2.0 s of 3.0 s, and the last frame
  ends where the asset does.
- **Boundaries**: automatic cuts are strictly ascending, inside the track,
  on real frame times, and never closer than 0.4 s to each other. Scenes
  always start at 0, end at the asset's duration, abut exactly, and have
  positive length, including with manual cuts in different timescales.
- **Fades and dissolves** are not split at the default sensitivity.
- **Splitting a clip** leaves no gap or overlap and footage continuous
  across the cut, drops the transitions at the cut, and keeps picture and
  sound together (they are one clip). Adding scenes and splitting each
  undo and redo as one step.
- **Scenes on a timeline of another frame rate** (24 fps footage on a 30 fps
  timeline): clips abut on the timeline, nothing is repeated in the footage,
  at most one timeline frame is left out where a scene end was trimmed back
  to a whole frame.

## Defects

1. **Replacement media was not mapped into original time. (High; fixed.)**
   See "Replacement media: original time and the file's time" in
   [scene-cuts.md](scene-cuts.md) for the convention, the domain policy and
   the tests. The description of the defect, as found: Scores are in the current
   file's time, but scenes, manual cuts, ignored cuts and trims are in
   original time, and the file is read at `original + alignmentOffset`.
   `scenes(ofAsset:)` uses the cut times as they are. For a replacement
   aligned 2 s later, a cut at 5 s of the file becomes a scene boundary at
   5 s of original time, which plays file time 7 s. Fix: subtract
   `alignmentOffset` from detected cuts (and add it when snapping a
   hand-placed cut to a frame, `nearestFrameTime`), and decide what the
   scene range covers when the file is shorter or longer than the original.
2. **Sustained motion got a cut on the last frame. (Medium; fixed.)** Fixed
   by measuring a cut as its rise over the median change of the frames
   around it, so a steady change has no cut anywhere (see "Notes and limits"
   in [scene-cuts.md](scene-cuts.md)). As found: A plateau has
   no peak, except that `i + 1 == frameCount` counts the end as lower, so
   any shot whose change stays over the threshold (a pan of a busy picture
   scores 30 to 57 a frame) ends in a one-frame scene at every sensitivity
   tried. A genuine mid-track plateau gets no cut at all, so the behavior
   depends on where the track ends.
3. **A fade was split mid-way at high sensitivity. (Low; fixed.)** Fixed by
   the same change as 2: no frame of a steady fade rises over its
   neighbours. As found: At 0.8 and above a
   steady 13/14 per frame fade yields a cut in the middle; the document
   says a slow dissolve isn't split.
4. **A single flash frame was a scene change. (Medium; fixed.)** Fixed by
   recording skip scores (the change from the frame two back) and not
   cutting where the picture after a one-frame jump in and out is close to
   the one before it; see [scene-cuts.md](scene-cuts.md). The scoring
   algorithm went to version 3, so saved scores are made again. As found:
   The change into and
   out of the flash both score about 115; the stronger-wins merge keeps the
   later one, so a cut lands on the frame after the flash.
5. **Edge scenes can be shorter than the minimum. (Decided: kept.)**
   The 0.4 s rule applies between cuts only; a cut 3 frames in or 2 frames
   from the end is kept. Policy for now: preserve short leading and
   trailing scenes rather than drop footage or suppress a genuine boundary
   to enforce a length. The minimum is a rule between cuts, not a guarantee
   of every scene's length (`shortScenesAtTheEndsOfAnAssetAreKept`).

6. **Frame times were not validated on load. (Low; fixed.)**
   `ChangeScoreTrack(decoding:)` accepted times that went backwards or
   repeated, and `autoCuts` then returned unsorted cuts. Now a track is
   validated (`ChangeScoreTrack.validate`): positive timescale, non-negative
   strictly increasing frame times (a repeated or backwards time is an
   error, never sorted or merged away), and a first score of 0. A saved file
   that fails reads as damaged and is analyzed again; a track the scorer
   produces that fails is a failure, not a result. The scorer itself drops
   frames before time 0 and frames whose time does not increase.

## Limitations by design, recorded

- **Luma only**: red to green at equal brightness scores 20/255 and is
  missed at the default sensitivity.
- **Short shots merge**: a 3-frame shot yields one cut (the earlier on a
  tie); the shot belongs to the one after it.
- **Greedy merge**: cuts 0.3 s apart in a chain keep only the strongest, even
  when the outer two are 0.6 s apart.
- **Late-start filler frame (fixed; the description below is of the defect).**
  Fixed: samples inside an empty stretch of the track's edit list are not
  frames, the first real frame after one is the scoring baseline (it scores
  0 and keeps its real timestamp), and the stretches are saved with the
  scores. See "Empty stretches" in [scene-cuts.md](scene-cuts.md). For a
  file whose first picture comes after an empty stretch, the reader emits a
  synthetic black frame at time 0 (luma 16, no duration) to fill it. The
  scorer takes it as a frame, so the first real frame is scored against
  black: bright footage reads as a hard cut at its own first frame at
  every sensitivity, 0 included. The track's time range (0 to the asset's
  duration) includes the empty stretch, so the frame cannot be told from
  the range alone; the track's segments (`AVAssetTrackSegment.isEmpty`)
  say where the empty stretch is. Proposed, not made: skip samples inside
  an empty segment before scoring, so the track starts at the first
  observed frame and the first frame scores 0. No threshold changes. See
  `theFillerFrameDoesNotMakeACutAtTheStartOfTheFootage` (known issue).
- **Scene thresholds** (0.4 to 0.03 of 255) were not changed; sensitivity 0.5
  needs about 28/255.

## Not covered

- Playback-speed changes on timeline clips: `addScenes` creates 1x clips and
  `split` is covered by `BladeRetimeTests`; no new test here.
- Original scores for aligning a later replacement: the replacement flow
  used to read `analysis.tracks[asset]` as the original's scores, so after
  a first replacement a second one aligned against the first replacement's
  scores. Fixed: the original's scores are stored separately
  (`original-signature.bin`) and read explicitly; see
  [media-replacement.md](media-replacement.md).
- Cross-dissolve and fade detection quality beyond "not cut by default".
