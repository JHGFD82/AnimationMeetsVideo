# Project package format

Status: **steps 1 and 2 implemented**: package layout, `formatVersion` 1,
stable IDs, rational times, deterministic output, media copy on save, undo
and redo, the single-writer `.lock`, unsaved-change tracking, and autosave
into `Backups/`. Step 3 is partly implemented: `Reference/<asset id>/
signature.bin` holds each video's change scores, `reference.json` and
`audio.bin` hold the metadata snapshot and audio envelope captured at import,
and `project.json` holds scene edits (see [scene-cuts.md](scene-cuts.md)).
`thumbs/` holds reference pictures. `beats.bin` holds detected beats (see
[beat-detection.md](beat-detection.md)). Not yet implemented: dense reference frames, the render cache, a restore-from-backup screen (copy a backup over
`project.json` by hand for now), and a Finder-visible package type (that
needs an app bundle that declares the `.amv` type).
Step 4 is implemented (see [media-replacement.md](media-replacement.md)):
`project.json` stores each asset's alignment offset, earlier file paths, the
file stamp accepted at the last save, and whether its original was forgotten.

## Goals

- Open and hand-editable: text files a person or another tool can read,
  diff, and modify.
- A project is a file plus a folder of assets, in the style of Logic Pro,
  rather than a single locked-in library as in Final Cut Pro.
- Support [media replacement](media-replacement.md) and per-asset
  [scene data](scene-cuts.md) without storing duplicate footage.
- A render cache that lives with the project but is clearly disposable.

## Layout

A project is a folder that macOS treats as a single package:

```
MyProject.amv/
  project.json        the edit: assets, timelines, layers, clips
  Media/              optional: assets copied in by choice
  Reference/          per-asset reference data (never auto-deleted)
    <assetID>/
      reference.json      metadata snapshot of the original file
      audio.bin           audio envelope
      signature.bin       per-frame picture change scores
      beats.bin           beat times of the audio (see beat-detection.md)
      thumbs/ ...         pictures of the original at cuts and intervals
  Cache/              render cache (disposable, size-capped)
  Backups/            autosaves
  .lock               single-writer lock (an flock held while the project is open)
```

Media may be copied into `Media/` or referenced from elsewhere, chosen per
asset. **Copying into the package is the default.** To avoid duplicating
large footage, the copy is an APFS clone (copy-on-write) whenever the source
is on the same volume, which uses no extra disk space until a file changes.
If the source is on a different volume, the app shows the size and warns
before making a real copy. References from `project.json` use paths relative
to the package where possible, so the project can be moved or archived.

### Clones, deleting, and backups

A clone is an ordinary, independent file that shares disk blocks with its
source:

- Finder shows both files at full size, but the volume stores the shared
  data once. Per-file sizes add up to more than the space actually used.
- Deleting either file is safe. The shared blocks are freed only when the
  last file using them is gone, and the other file is unaffected. This also
  means deleting the original after cloning does not free space, because the
  package's copy still uses it.
- Editing one file writes the changed blocks to new space (copy-on-write),
  so the two only start costing extra for the parts that differ.
- Cloning only works within one APFS volume. Copying a package to another
  drive, a non-APFS volume, or a network share makes a full copy, so an
  archived package can be much larger than it looked on the original disk.

**Backup advisory.** Time Machine and most sync or backup tools see each
clone as a separate full-size file and do not preserve the sharing. Copying
media into a package therefore makes backups store that footage again, even
though the local disk does not. This is intended for setups where source
footage is excluded from backup and only becomes backed up once it is used
in a project, but anyone who backs up both the source folder and their
projects will store the footage twice. To avoid that, exclude the source
footage or the packages' `Media/` folders from the backup, or choose
"Reference in Place" when saving.

The package is a macOS package folder (`.amv`) rather than a plain visible
folder: it appears as one file in Finder and "Show Package Contents" gives
the plain folder.

## project.json

JSON was chosen over XML and YAML:

- It is already handled by `Codable` and is easy to edit by hand.
- YAML's implicit typing and indentation rules cause subtle errors in
  hand-edited files, and it is not part of Foundation.
- The reliability of Final Cut's XML comes from its strict schema and exact
  rational time, not from XML itself. We get the same with a published JSON
  Schema and rational time values.

Requirements for the file:

- **`formatVersion`** field, with migrations when it changes.
- **Stable IDs** for every asset, timeline, layer, clip, and scene, written
  to the file. (Today IDs are regenerated on load and references use array
  indices, which is the main obstacle to live reload and diffing.)
- **Deterministic output**: sorted keys and fixed formatting so that two saves
  of the same project are byte-identical and diffs show only real changes.
- **Rational times** such as `"1001/24000s"`, never floating-point seconds.
- Written atomically so a crash cannot leave a half-written file.

## Retention

| Folder | May the app delete it? |
| --- | --- |
| `Reference/` | No, only through an explicit "forget original" action, applied at the next save. It may be the only record of a replaced file, so Save As copies each asset's folder into the new package. |
| `Cache/` | Yes. It has a size cap and evicts oldest-first. Entries are keyed by a hash of the exact content they render, so any upstream edit invalidates them. |
| `Backups/` | Yes, by age and count. |

`Cache/` is marked excluded from backup and sync, and should be kept out of
version control. Settings to move the cache elsewhere come later.

## Live reload

Status: **implemented** for `project.json`. (Changes to the media files
themselves are covered in [media-replacement.md](media-replacement.md).)

The project file may be edited outside the app, and the app picks up the
change:

- The app checks the file every two seconds and whenever it becomes active,
  rather than using `NSFilePresenter`, so that a file replaced by renaming
  over it is noticed too. It remembers the size, date and hash of what it
  last read or wrote, so its own saves never trigger a reload and touching
  the file without changing it is ignored.
- If the file changed and there are no unsaved edits, the file's version
  replaces the project. Selection is kept when its clip still exists and
  cleared otherwise; the playhead is left where it is.
- If there are unsaved edits, ask which version to keep. Keeping the
  person's version leaves the next save to overwrite the file.
- The switch is an ordinary edit, so undo brings back the previous version.
  Because the file's version counts as saved, the restored version shows as
  unsaved.
- Nothing is reloaded while a save or another reload is running or while the
  replace-media dialog is open. An export already running keeps rendering the
  project as it was when it started.
- If the new file does not parse, keep the in-memory project and show the
  error. The app does not overwrite the file itself, but the next save will.
- Media the new file lists that can't be opened is dropped from the
  timelines, as when opening a project.

A diff engine is not needed for this. Stable IDs and deterministic output
make a structural comparison cheap. A visual diff is only useful later for a
"compare versions" screen when both sides have changes.

## Build order

Foundation first, because the other features depend on it:

1. Persist stable IDs in the model and the file, add `formatVersion`, and
   write the package layout. **Done.**
2. Undo and redo, single-writer lock, and autosave, and define how reloads
   interact with undo. **Done.**
3. Scene detection and the browser ([scene-cuts.md](scene-cuts.md)),
   including the reference data capture. **Mostly done**: detection, saved
   scores and edits, and the browser. Reference capture
   (metadata snapshot, audio envelope, thumbnails at cuts and intervals) is
   done.
4. Media replacement and the sync dialog
   ([media-replacement.md](media-replacement.md)). **Done**: the
   comparison, alignment suggestion, dialog, folder replacement, offset at
   playback and export, and forget original.
5. Live reload. **Done** for `project.json`.
