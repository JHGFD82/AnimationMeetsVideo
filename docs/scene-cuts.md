# Scene cuts and virtual clips

Status: **planned, not implemented.**

The app is built for editing existing long-form footage that already
contains cuts. This document describes how the app finds those cuts and lets
the browser present one media file as a list of scenes that can be dropped
onto the timeline.

## The key idea: scenes are metadata, not files

Separating a file into scenes **does not split, copy, or re-encode the
file.** The video file on disk is never touched. A scene is just a record:

```
Scene
  id            stable ID
  asset         the media asset it belongs to
  range         start and duration in the asset's own time (rational seconds)
  name          optional, user-editable
  origin        auto (detected) or manual (created or adjusted by the user)
```

Conceptually a scene is a named, saved trim range of an existing asset. The
timeline already represents a clip as "an asset plus a trim start and trim
end", so dropping a scene onto the timeline creates an ordinary timeline clip
with those trims. No new kind of timeline object is needed.

Consequences:

- Deleting, renaming, merging, or re-detecting scenes never changes the
  media or any timeline clip that was already created from them.
- Timeline clips created from a scene are independent afterwards. Trimming
  one does not move the scene boundary in the browser.
- Scenes cost almost nothing to store: a few numbers each.

## Detecting cuts

Detection runs once per asset, in the background, at low priority, so import
is not blocked. Until it finishes the asset appears in the browser as a
single clip, with a progress indicator.

1. Decode the video at reduced size (a small luma image per frame is enough).
2. Compare each frame with the previous one. A cut is a sudden, large change
   that is not followed by a return to the earlier picture.
3. Record each cut as the timestamp of the **first frame of the new scene**,
   exactly aligned to a source frame.

Notes and limits:

- **Hard cuts** are detected reliably. **Dissolves, fades, and fast motion or
  flashes** are ambiguous, so detection has a sensitivity setting and the
  scene list is always editable.
- **Footage with no cuts** (a single static shot) simply yields one scene.
- **Variable frame rate** files are detected using their real timestamps, not
  an assumed rate.

Detection results are cached. They are only recomputed if the file's
metadata snapshot (size, modification date, duration) no longer matches, or
if the person asks for a re-detect.

## What is saved for each asset

The same pass that finds cuts also saves the small amount of data that the
[media replacement](media-replacement.md) workflow needs later. It lives in
the project package's `Reference/` folder, one subfolder per asset:

| Item | Purpose |
| --- | --- |
| Cut list (`cuts.json`) | Scene boundaries, with `origin` for each. |
| Thumbnails at each cut | The last frame before and the first frame after every cut, at low resolution (for example 160 px wide). Shown in the browser, and used for frame-accurate comparison when media is replaced. |
| Interval thumbnails | A sparse fixed-interval strip so scenes and long shots can be scrubbed visually. |
| Dense frames near used ranges | Extra low-resolution frames around the in and out points of ranges used on the timeline. |
| Signatures | A tiny frame-luma signature and an audio envelope, used to suggest an alignment automatically. |
| Metadata snapshot | Resolution, frame rate, duration, color tags, and start timecode as they were at capture time. |

This data is **not part of the evictable render cache.** It can be the only
surviving record of an original file after the file is replaced, so it is never
deleted automatically. See [project-package.md](project-package.md).

## In the browser

Planned behavior:

- A media file that has scenes shows a disclosure control. Expanding it lists
  its scenes as a strip or list: thumbnail, name, start timecode, and
  duration.
- Selecting a scene previews that range in the viewer without touching the
  timeline.
- Dragging a scene onto the timeline creates a timeline clip using that
  scene's range. Dragging several selected scenes places them one after
  another in source order.
- The original file stays available as a single whole-file item as well.

Editing the scene list:

- **Split** a scene at the playhead, **merge** adjacent scenes, **move** a
  boundary by dragging, **rename** a scene.
- Any scene or boundary the person has changed is marked `manual`. Re-running
  detection replaces only `auto` scenes and keeps manual ones, so hand
  corrections are not lost.
- **Ignore** a detected cut to merge across it without deleting the
  record, so a later re-detect does not bring it back.

## How it fits the existing model

- The media asset (today's `MediaClip`) gains a list of scenes.
- `TimelineClip` is unchanged: a source reference plus `trimStart`,
  `trimEnd`, and `startOffset`.
- Scene ranges are stored in the asset's own source time. If the file is
  later replaced and re-aligned, the alignment offset is applied at the asset
  level, so scenes and timeline clips stay valid without being edited. See
  [media-replacement.md](media-replacement.md).

## Decisions

- **Sensitivity** is a project-wide default with a per-asset override, so one
  stubborn file can be re-detected without touching the others.
- **Dropping several scenes** places them back to back, in source order, on
  a single layer with no gaps.
- **Reference density** defaults to "balanced": thumbnails before and after
  every cut, a frame every 2 seconds, and dense frames near used ranges.
  Sparse and dense presets can come later.
- **Detection is picture-based** in the first version. Audio-based cut
  detection is deferred. (Audio is still used for sync alignment, see
  [media-replacement.md](media-replacement.md).)

## Open questions

- Default sensitivity value, and the exact thumbnail size.
