# Scene cuts and virtual clips

Status: **core implemented**: frame scoring, cut detection, saved scores and
edits, the browser scene list, preview, merge, the sensitivity slider, and
placing scenes on the timeline. The browser UI is compile-checked and its
logic is unit tested, but it has not been exercised on screen yet. What is
not built yet is listed under [Not implemented yet](#not-implemented-yet).

The app is built for editing existing long-form footage that already
contains cuts. This document describes how the app finds those cuts and lets
the browser present one media file as a list of scenes that can be dropped
onto the timeline.

## The key idea: scenes are derived, not stored

Separating a file into scenes **does not split, copy, or re-encode the
file.** The video file on disk is never touched. A scene is only a range of
the asset's own time (`SceneRange`: start, end, and whether the cut that
starts it is automatic or manual).

Scene ranges themselves are **not saved**. They are computed from two things:

1. the asset's saved per-frame change scores, and
2. the person's hand-made edits (`SceneEdits`), plus the project default
   sensitivity.

That is why changing a sensitivity updates scenes instantly and why a
re-detect can never lose hand corrections: automatic cuts are recomputed,
while everything the person did is stored separately and re-applied.

The timeline already represents a clip as "an asset plus a trim start and trim
end", so dropping a scene onto the timeline creates an ordinary timeline clip
with those trims. No new kind of timeline object is needed.

Consequences:

- Deleting, merging, or re-detecting scenes never changes the media or any
  timeline clip that was already created from them.
- Timeline clips created from a scene are independent afterwards. Trimming
  one does not move the scene boundary in the browser.
- Scenes cost almost nothing to store: only the edits are saved.

## Detecting cuts

Detection runs once per asset, in the background at utility priority, one
asset at a time, so import is not blocked. Until it finishes the asset
appears in the browser with a progress indicator and, expanded, as a single
scene.

1. `FrameScorer` decodes the first video track at 64x36 luma.
2. For every frame it records the mean absolute luma difference from the
   previous frame, scaled to 0-255 (one byte per frame, first frame 0), with
   the frame's real presentation timestamp.
3. `SceneDetector` applies a threshold to those scores (see below).

Notes and limits:

- **Hard cuts** are detected reliably. **Dissolves, fades, and fast motion or
  flashes** are ambiguous, so sensitivity is adjustable and the scene list is
  always editable. A flash frame (a one-frame bright spike) produces one cut,
  not two, because cuts closer than the minimum scene length merge.
- **Footage with no cuts** (a single static shot) yields one scene.
- **Variable frame rate** files use their real timestamps, not an assumed rate.
- A cut is a frame whose change is at or over the threshold **and** is a
  local peak, so a slow dissolve or camera move is not split down the middle.
- Cuts closer together than **0.4 seconds** are treated as one; the
  stronger wins.
- Threshold as a fraction of 255 is `0.4 * exp(ln(0.03 / 0.4) * s)` for a
  sensitivity `s` from 0 to 1, so each step of the slider feels even. The
  default, balanced (0.5), is about 0.11, roughly 28 out of 255.

Scores are saved with the project (see below) and recomputed when the
person chooses "Find Scenes Again", or when the asset's file changes.

**Scores describe the file the asset uses now**, because they find the
scenes and splits of the media being edited. They are not original
reference data: when a file is replaced its scores are retired and found
again from the new file, and the original's scores are not used to split
replacement media. (The reference pictures and metadata, which do describe
the original, are kept; see below.) Each saved score file has a record in
`provenance.json` next to it: the size and modification time of the file it
was computed from (the one the project accepted), the analysis settings, an
algorithm version, and a digest of the score file. A score is loaded only
when all of that still applies. A score with no record, as saved by an
earlier version, is not assumed to belong to the current file and is
computed again. The accepted stamp says which file the project means; the file on disk is
also looked at, before analysis and cache use and again before a result is
committed. If it differs from the accepted stamp the file was changed
outside the app: no current-file analysis is made, saved scores and beats
are not used, and the asset is listed in `AssetAnalysis.changedFiles` until
the change is accepted or the person asks to look again. A result is never
recorded under the old stamp for a file that has changed. (Size and
modification time are a heuristic: a change that keeps both escapes it.)
A retired score is deleted; if the file can't be deleted its
record is marked invalidated instead, so it is still rejected. If neither
can be done the retirement stays pending, is retried with the next write or
save, and is reported by `AssetAnalysis.invalidationFailures`; saving fails
rather than leave an outdated score that could come back.

### Three levels of sensitivity

1. **Project default**, balanced (0.5). Stored in `project.json` only when
   changed. There is no screen to change it yet.
2. **Per-asset override**, set from the media's context menu ("Cut
   Sensitivity..."), with "Use Project Default" to clear it.
3. **Per-selection region**, set from the context menu on selected scenes
   ("Adjust Cut Sensitivity...").

### Adjusting sensitivity for a selection

One setting rarely fits a whole long-form file. A person can select **a range
of scenes, or a single scene** that did not cut enough (or cut too much), and
adjust the sensitivity for just that selection:

- The sheet shows a slider and lists the scenes the span would become, live.
  This is instant because detection saved its per-frame scores; the video is
  not decoded again. Nothing changes until **Apply**; Cancel leaves the
  project untouched and adds nothing to undo.
- Only the time span covered by the selected scenes is re-evaluated. The
  region applies **strictly between** the span's two outer edges, so the cuts
  at the edges keep the sensitivity they had and every scene and boundary
  outside the span is left exactly as it was. (One known limit: if a newly
  found cut lands within 0.4 seconds of an outer edge and is stronger than the
  edge cut, the merge rule can drop the edge cut.)
- Boundaries inside the span that the person made by hand (`manual`) are
  always kept. Only automatic boundaries are replaced.
- Cuts the person had **ignored** inside the span become available again,
  because they are deliberately re-deciding that stretch. Ignored cuts
  outside the span stay ignored.
- The value is saved as a **sensitivity region** (a range and a value), so a
  later full re-detect does not overwrite it. Applying again over a span that
  fully covers older regions replaces them; later regions win where they
  overlap partially.
- Applying the slider to a single scene is how to split it further. Applying
  it to a range is how to merge over-split scenes (lower sensitivity) or
  find more cuts (higher sensitivity).

## What is saved for each asset

In `project.json`, per asset, only when non-empty (`sceneEdits`):

| Field | Meaning |
| --- | --- |
| `sensitivity` | The asset override. |
| `regions` | Sensitivity regions: id, start, end, value. |
| `manualCuts` | Cuts the person added or moved a boundary to. |
| `ignoredCuts` | Automatic cuts the person removed, so they don't return. |

plus `defaultSensitivity` for the project. Files without these fields load as
balanced with no edits, and untouched projects write the same bytes as
before.

In the package's `Reference/<asset id>/` folder:

| Item | Status |
| --- | --- |
| `signature.bin`: the per-frame change scores (magic `AMVS`, version 1, little endian: timescale, frame count, an Int64 time per frame, one score byte per frame; about 9 bytes per frame). | Implemented. A damaged file, or one whose `provenance.json` record doesn't fit the current file, reads as "not analyzed" and is recomputed. |
| `thumbs/<value>_<timescale>.jpg`: pictures of the original (256x144 JPEG, quality 0.7) at the first and last frame, just before and at each cut found at a loose sensitivity (strongest 600 cuts at most), and every 10 seconds. | Implemented. Captured once, after scoring, into a scratch folder that is renamed into place, so a `thumbs/` folder that exists is complete. |
| Dense frames near used ranges | Not implemented. The sync dialog will have to match by cuts and intervals. |
| `reference.json`: metadata snapshot of the original file (name and path, size and modification time, duration as a rational, frame rate, displayed size, codec, color tags, audio sample rate, capture time). | Implemented. Captured once, in the background, before scoring. A damaged file reads as "no reference". |
| `audio.bin`: audio envelope, 100 loudness values a second (magic `AMVE`, version 1, little endian: windows per second, start window, count, one byte per window; 0 is silence, 255 full scale). Absent for files without audio. | Implemented. A damaged file only loses the audio match. |
| Frame-luma signature | The change-score track in `signature.bin` serves as the picture signature, since cut times and picture activity are what two versions of a file share. There is no separate absolute-luma file. |

This data is **not part of the evictable render cache.** It can be the only
surviving record of an original file after the file is replaced, so it is never
deleted automatically. See [project-package.md](project-package.md).

Reference data is captured once per asset and never captured again: if the
file is replaced, the saved reference keeps describing the original. The
snapshot's size and modification time show whether the file at the saved
path is still the one described. A project saved before reference capture
existed gets its reference taken from whatever file is there when it is
next opened, so it describes that file, not necessarily the original.

New scores and reference data are written on the next save. A project that was never saved has
nowhere to put them yet, so they are recomputed after reopening if the
project was closed before saving.

## Failures and retries

A stage that can't finish is recorded per asset and stage
(`AssetAnalysis.stageFailures`) as an `AnalysisFailure`: the stage, a kind,
the system's message, and the file it ran on. The kinds are a missing file,
permission denied, unsupported media (no suitable track, or a format that
can't be decoded), damaged media, a result that could not be saved into the
project (`persistenceFailures`, which doesn't stop the result from being
used), an interruption, and anything else. A file that is missing is not a
failure: the asset waits for it and is tried again when its file changes or
`retryUnavailable` is called.

A failure belongs to the file it happened on, so it is dropped when the
asset's file changes (and, for beats, when the sound is gone). It is
otherwise kept, so a broken file isn't analyzed again on every change.
`retry(_:for:in:)` tries one stage of one asset again without resetting
anything else, and `retryFailures(for:in:)` all its failed stages; the
asset's context menu offers "Retry Failed Analysis". Retrying never
captures the original: for an asset whose original is forgotten or whose
file was replaced, retrying the reference or its pictures is refused and
the failure stays.

## In the browser

Implemented:

- Each video in the library has a disclosure control. Expanded, it lists its
  scenes: thumbnail (the first frame of the scene), number, start timecode,
  and duration. A hand-set boundary shows a small marker.
- Scenes can be multi-selected. **Add to Timeline** (context menu, or double
  click) places the selected scenes of an asset back to back, in source order
  with no gaps, on one new layer at the top, starting at time zero (the same
  placement as importing a whole file). Dragging selected scenes onto the
  timeline does the same.
- **Preview...** (one scene) opens a sheet with its own player limited to the
  scene's range, so the timeline is untouched. **Split Here** starts a new
  scene at the frame shown (snapped to a real frame).
- **Merge with Previous Scene** (one scene) and **Merge Selected Scenes**
  (adjacent picks). Merging an automatic cut records it as ignored so it does
  not return when sensitivity changes; merging a manual cut deletes it.
- **Adjust Cut Sensitivity...** and the per-asset **Cut Sensitivity...**.
- **Find Scenes Again** discards the asset's scores and re-scores it. Edits
  are kept.

All edits go through the project, so they are undoable and tracked as unsaved
changes like any other.

### Not implemented yet

- Rename a scene, and the optional name field.
- Moving a boundary by dragging, and splitting at the timeline playhead.
- The original whole file as a separate item next to its scenes.
- A screen for the project default sensitivity.
- Dense reference frames near the ranges the project uses.
- Dropping onto a specific layer or time; a drop always creates a new layer.

## How it fits the existing model

- The media asset (`MediaClip`) carries `sceneEdits`; the change scores live
  in `AssetAnalysis` at runtime and in `Reference/` on disk, outside the
  project model, so they never count as an edit and never enter undo.
- `TimelineClip` is unchanged: a source reference plus `trimStart`,
  `trimEnd`, and `startOffset`.
- Scene ranges are in the asset's own source time. If the file is later
  replaced and re-aligned, the alignment offset is applied at the asset
  level, so scenes and timeline clips stay valid without being edited. See
  [media-replacement.md](media-replacement.md).

## Decisions

- **Sensitivity** has three levels: a project-wide default (balanced), a
  per-asset override, and a per-selection region applying only to the
  selected scenes' span.
- **Dropping several scenes** places them back to back, in source order, on
  a single layer with no gaps.
- **Detection is picture-based** in the first version. Audio-based cut
  detection is deferred. (Audio is still used for sync alignment, see
  [media-replacement.md](media-replacement.md).)
- **Default sensitivity** is 0.5 (balanced). It is a starting point to tune
  against real footage.
- **Reference density** will default to "balanced": thumbnails before and
  after every cut, a frame every 2 seconds, and dense frames near used
  ranges. Not built yet.

## Open questions

- Whether balanced (0.5) is the right default once real footage is tried.
- The exact thumbnail size for the saved reference thumbnails (the on-screen
  ones are 160 px wide maximum).
