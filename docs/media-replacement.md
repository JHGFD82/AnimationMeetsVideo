# Media replacement ("bait and switch")

Status: **planned, not implemented.**

Editors often cut with one version of a file and finish with another, for
example a lower-quality copy for speed and the full-quality original for the
final render. The app supports this by letting a media file be **replaced**,
not by generating proxies. Generating and storing proxy copies of long-form
footage costs a lot of disk space, so the app does not do it.

## Model

- A media asset has a stable ID. Timeline clips, scenes, and trims refer to
  the asset ID, never to a file path.
- Replacing media changes only the file behind the asset. Nothing that
  refers to the asset needs to change.
- The asset records its previous file paths. These are only paths, no files
  are copied, so a person can point the asset back at an earlier file.
- The person is responsible for choosing the right footage. The app compares
  the old and new file, adjusts what it safely can, and flags the rest.

## Why reference data is required

After a replacement the old file is assumed to be gone, so it cannot be
read to compare against. The app therefore saves a small **reference record**
of every asset at import time, while the original still exists. This is the
same data described in [scene-cuts.md](scene-cuts.md): thumbnails at cuts,
sparse interval thumbnails, dense frames near used ranges, a frame-luma
signature, an audio envelope, and a metadata snapshot.

Because it is the only record of the original, it is kept separately from
the render cache and is never evicted automatically. See
[project-package.md](project-package.md).

If a file is swapped outside the app before its reference record finished
generating, the comparison uses whatever exists so far and says so.

## What happens when a file is replaced

The app reads the new file's metadata and compares it with the snapshot.
Differences fall into three tiers.

### 1. Adjusted silently

| Difference | Handling |
| --- | --- |
| Resolution | Ignored. The new file is scaled to occupy the same frame as the old one, preserving aspect ratio. |
| Frame rate | Ignored. Times are stored as rational seconds, so the new file is sampled at the nearest frame for the project's frame rate. Variable-frame-rate files get a warning. |
| Color space, SDR to SDR | Converted as needed. |

### 2. Confirmed with the person

| Difference | Why |
| --- | --- |
| Aspect ratio | Keeping the framing and cropping or letterboxing it is an editorial choice. |
| SDR to HDR (PQ or HLG) or the reverse | The look changes significantly and tone mapping is required. |
| Untagged or inconsistently tagged color | The app can only guess, so it asks and offers a per-asset color override. |

### 3. Blocking: sync must be confirmed

The one hard requirement is that every range the project uses exists in the
new file and **lines up with the same content as before.** Equal duration is
neither necessary nor sufficient: two files can be the same length and still
be offset, and a differently trimmed file can be a different length and still
match. When the new file does not obviously line up, the app opens the sync
dialog.

## The sync dialog

The dialog shows the saved reference frames of the original on one side and
the new file on the other, each with its own timeline.

1. The app computes a **suggested alignment** by matching signatures:
   the audio envelope when both files have audio (the most reliable, down to
   individual samples), otherwise scene cuts and frame-luma.
2. The person can accept it, or navigate each side to the same scene change
   and mark them as the same moment. Reference frames are dense around cuts
   and used ranges, so those points can be matched to the exact frame.
3. The result is stored as an **alignment on the asset**: a time offset, and
   a rate if the files differ in speed.

Alignment is stored on the asset, not by rewriting timeline clips or
keyframes. Trims, scenes, and future keyframes all stay in the original
source time and the offset is applied at playback and export. Re-aligning
later changes one value.

Limits: the original side can only show frames that were saved, so
frame-exact matching depends on cuts and used ranges. Footage with no cuts
and no audio falls back to a manual offset.

## Bulk replacement

Replacing a folder of files at once (matching by filename, and checking each
match with the same tiers above) should be supported, since the common case
is "point everything at the full-quality folder".

## Export

Exports render from whatever each asset currently points at. If an asset
points at a file the person knowingly chose as a lower-quality stand-in, that
is their responsibility. The app should make the current file for each asset
visible before export.

## Open questions

- Whether a "forget original" action (which deletes the reference record and
  disables the sync dialog for that asset) should require confirmation.
- Whether the rate part of alignment is needed in practice, or an offset is
  enough.
- How much of the color handling can wait until the project's color space is
  actually applied when rendering. Today it is only a label.
