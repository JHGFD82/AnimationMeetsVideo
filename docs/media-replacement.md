# Media replacement ("bait and switch")

Status: **implemented, apart from the items under "Not yet implemented"
at the end.** Replacement, the comparison tiers, the alignment suggestion,
the sync dialog, folder replacement, the offset applied at playback and
export, and forgetting the original all work.

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
  are copied, so a person can point the asset back at an earlier file
  (**Use Earlier File** in the clip's context menu). The usual comparison
  and sync check still run.
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

If a file is replaced before its reference record finished generating,
there is nothing to compare against. The dialog says so, asks the person to
judge the alignment, and does not suggest an offset.

## What happens when a file is replaced

The app reads the new file's metadata, audio and (when needed) picture
changes and compares them with the saved reference. Differences fall into
three tiers. A replacement with no differences in tiers 2 and 3 that
aligns at the offset already in effect is applied without opening a
dialog, which keeps folder replacement quiet for the files that match.

### 1. Adjusted silently

| Difference | Handling |
| --- | --- |
| Resolution | Ignored. The new file is scaled to occupy the same frame as the old one, preserving aspect ratio. |
| Frame rate | Ignored. Times are stored as rational seconds, so the new file is sampled at the nearest frame for the project's frame rate. Variable-frame-rate files get a warning. |
| Color space, SDR to SDR | Not yet converted; the project's color space is only a label today (see Decisions). |

### 2. Confirmed with the person

| Difference | Why |
| --- | --- |
| Aspect ratio | Keeping the framing and cropping or letterboxing it is an editorial choice. |
| SDR to HDR (PQ or HLG) or the reverse | The look changes significantly and tone mapping is required. |
| Untagged or incompletely tagged color | The app can only guess, so it asks. A per-asset color override is not built yet. |

Each confirmation is a checkbox in the dialog; Replace stays disabled until
all are ticked.

### 3. Blocking: sync must be confirmed

The one hard requirement is that every range the project uses exists in the
new file and **lines up with the same content as before.** Equal duration is
neither necessary nor sufficient: two files can be the same length and still
be offset, and a differently trimmed file can be a different length and still
match. When the new file does not obviously line up, the app opens the sync
dialog.

The blocking differences are: the new file has no picture or no sound where
the original had one (the person can tick "Replace anyway"), and any used
range that falls outside the new file at the chosen offset. The last one
cannot be overridden; change the offset or choose another file.

## The sync dialog

The dialog shows the saved picture of the original nearest a chosen moment
next to the new file's frame at the matching time. A slider moves the
chosen moment (it starts at the first used range).

1. The app computes a **suggested alignment**. Audio is tried first: the
   loudness envelope (about 100 values a second, so accurate to roughly
   10 ms) of each file is cross-correlated, and the confidence is how far
   the best match stands above the runner-up. When audio is missing or not
   confident, the files' scene cuts are compared instead, which means
   scoring every frame of the new file and is slower. A suggestion with
   confidence below 0.25 is shown as weak.
2. The person can accept it, nudge the offset by a frame or a second until
   the two pictures show the same moment, use the suggestion again, or set
   the offset to zero.
3. The result is stored as an **alignment on the asset**: a single time
   offset, the file time minus the original time. Differences in speed
   between versions are not corrected.

Alignment is stored on the asset, not by rewriting timeline clips or
keyframes. Trims, scenes, cuts, beats and future keyframes all stay in the
original's time; a clip reading original time `t` reads the file at
`t + offset`. Re-aligning later changes one value.

After a replacement the asset's `duration` is the **new file's** duration,
and the used ranges are checked against it.

Limits: the original side can only show pictures that were saved, which are
sparse (at cuts and intervals), so the nearest saved picture can be a
little off the chosen moment. Footage with no cuts and no audio falls back
to a manual offset.

## Bulk replacement

**Replace Media from Folder…** matches the files in a folder (including
subfolders) to the project's media by name. An asset matches by its current
file name, then by the original's name, ignoring case; failing that, a
single file with the same name apart from the extension is accepted, since a
stand-in is often a different container. A name that more than one file
could match is skipped rather than guessed, and one file is never given to
two assets. Each match goes through the same checks; only the ones that need
a decision open the dialog, and a summary lists what was not replaced.

## Files changed outside the app

Each asset remembers the size and modification time of the file it last
accepted (set at import, save, or replacement). The app compares these when
a project opens, when the app becomes active, and every few seconds while it
runs. A file that no longer matches is flagged once, with a message naming
it, and the caches that might hold its old contents are dropped. The clip's
context menu then offers **File Changed — Check Sync…**, which runs the same
analysis on the file already in place and stores the result as the new
accepted state. A file that matches again is unflagged.

A file that goes missing or can't be read is reported once, and its clip's
context menu says **File Is Missing**. It is not flagged as changed, since
there is nothing to check sync against; when it comes back it is compared
as usual. **Replace Media…** points the asset at another file.

The file reads run off the main thread, so a slow or sleeping network volume
does not stall the editor. Their result is applied to the project as it is
when they finish, and a reading of a path the asset no longer uses is
ignored.

Until the change is reviewed, playback and export keep using the file as it
is on disk, at the old offset. Accepting is an ordinary edit, so undoing it
flags the file again.

Checking is by polling rather than by file-system events, so that a file
replaced by renaming over it is noticed too.

## Forgetting the original

**Forget Original…** in the clip's context menu deletes what was captured of
the original file: its metadata snapshot, audio envelope and reference
pictures. It asks for confirmation first. Without that data a replacement can
no longer be compared with the original or aligned automatically. The change
scores stay, because scene detection uses them, and clips and trims are
untouched.

Forgetting marks the asset `referenceForgotten`, an ordinary edit that undo
reverses. The data is deleted from `Reference/` when the project is next
saved with the mark set, and dropped from memory then; until that save the
app just stops using it. A capture still running when the original is
forgotten can't write it back, because saving never writes reference data
for a forgotten asset.

Reference data is never captured from a file that replaced the original
(an asset with earlier paths or a non-zero offset). So undoing a forget after
the save, or opening a project whose reference data is missing, leaves the
asset without a reference rather than describing the replacement as the
original.

## Not yet implemented

- A per-asset color override and actual SDR/HDR conversion.
- Dense reference frames near cuts and used ranges, which would allow
  frame-exact matching on the original's side.
- Variable-frame-rate warnings.
