# Project package format

Status: **steps 1 and 2 implemented**: package layout, `formatVersion` 2,
stable IDs, rational times, deterministic output, media copy on import, undo
and redo, the single-writer `.lock`, unsaved-change tracking, and autosave
into `Backups/`. Step 3 is partly implemented: `Reference/<asset id>/
signature.bin` holds each video's change scores, `reference.json` and
`audio.bin` hold the metadata snapshot and audio envelope captured at import,
and `project.json` holds scene edits (see [scene-cuts.md](scene-cuts.md)).
`thumbs/` holds reference pictures. `beats.bin` holds detected beats (see
[beat-detection.md](beat-detection.md)). The render cache is implemented (see [rendering.md](rendering.md)). Not yet implemented: dense reference frames, a list of backups to restore from (copy one over
`project.json` by hand for now).
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
      provenance.json     what signature.bin and beats.bin were computed from
      thumbs/ ...         pictures of the original at cuts and intervals
  Cache/              disposable, excluded from backup
    Renders/            rendered timeline segments (see rendering.md)
  Backups/            autosaves
  .lock               single-writer lock (an flock held while the project is open;
                      skipped on volumes that don't support flock)
```

Finder and the open and save panels show the package as one item, not a
folder to browse into. The app sets the folder's package flag whenever it
creates, opens or saves a project, which works even when it runs from
`swift run`. The flag is file metadata that zip, git and some sync
services drop, so a project copied that way shows as a folder until it's
next opened.

The app bundle built by `scripts/build-app.sh` also declares the type
(`com.jhgfd.animationmeetsvideo.project`, extension `.amv`, conforming to
`com.apple.package`) in `Packaging/Info.plist`. With it installed, every
`.amv` folder is a single document whether or not its flag survived, and
double-clicking one, or dropping it on the app's Dock icon, opens it in the
app. The window asks to save unsaved changes first, as Open does.

Media may be copied into `Media/` or referenced from elsewhere. **Copying
into the package is the default**, and it happens at import: the file is
copied first and the copy is what the project imports. The project's
default (`copiesMediaOnImport`) is set by a checkbox in the New Project
dialog and changed later in File > Project Settings… (⌘J). The import
dialog has a "Copy into the project" checkbox that starts at the default
and can be changed for that import. To avoid duplicating
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
"Reference in Place" when importing.

The package is a macOS package folder (`.amv`) rather than a plain visible
folder: it appears as one file in Finder and "Show Package Contents" gives
the plain folder.

## Creating and opening

Status: **implemented**.

There is always a package to write into. At launch the app reopens the
project used last; when there is none, or it has gone, a start sheet offers
New Project and Open Project and stays until one exists. New Project asks
where to save before the editor opens and writes the package and an empty
`project.json` right away.

**Saving is still explicit.** Imports, edits and the clip list live in
`project.json`, which only Save writes. Quitting (including closing the last
window), New Project and Open Project ask to Save, Don't Save or Cancel
when there are unsaved changes; cancelling a quit brings the window back.
Every minute with unsaved changes an autosave goes into `Backups/`. When a
project opens and its newest autosave is newer than `project.json` and
differs from it, as after a crash or a quit that skipped saving, the app
offers to restore it. Restoring is an ordinary, undoable edit on top of
the saved version and isn't written until saved. Declining, or choosing
Don't Save, marks the autosaves as seen (their dates are set back to just
before the save's) so they aren't offered again; the files stay.

Because of that, analysis results (change scores, reference data, pictures
and beats) are written into `Reference/` as soon as each is computed, and
pictures are then dropped from memory. They are keyed by asset ID and
recomputable, so writing them ahead of `project.json` is safe; a result
waits for the next save only if writing it fails. Outdated beats are
deleted at once. Forgetting an original still waits for the save so it can
be undone.

Saving writes `project.json` and copies nothing, since imports are already
in place. Save As copies what the old package holds in `Media/` and
`Reference/` into the new one; media referenced from elsewhere stays where
it is. Saving as a package that already exists, once the save panel's
replace prompt is confirmed, moves the old package to the Trash first (as
New Project does), so none of its media, backups or render cache end up in
the new one. It is refused if the old package is open in another window or
app, or if the project uses media stored inside it.

**Importing a file again reuses what was made from it.** When an imported
file matches an asset's reference data in `Reference/` by size and
modification date, and no asset in the project uses that ID, the new asset
takes the old ID, so its scores, pictures and beats are loaded instead of
computed again (the analysis loads whatever the package holds for an
asset before analyzing it). Likewise an unused file in `Media/` with the
same size and date is imported instead of making another copy. Copies keep
the original's modification date, so a copy and its original match.

An asset imported and then removed without saving leaves its copy in
`Media/` and its folder in `Reference/`. They are kept: an autosave in
`Backups/` may still list the asset, and the app never deletes reference
data on its own (see Retention).

## project.json

JSON was chosen over XML and YAML:

- It is already handled by `Codable` and is easy to edit by hand.
- YAML's implicit typing and indentation rules cause subtle errors in
  hand-edited files, and it is not part of Foundation.
- The reliability of Final Cut's XML comes from its strict schema and exact
  rational time, not from XML itself. We get the same with a published JSON
  Schema and rational time values.

Requirements for the file:

- **`formatVersion`** field. It is 2 today. Old versions aren't migrated,
  on purpose: the layer-transform and effects redesign changed what a
  layer is, and a one-way conversion wasn't worth carrying. They are
  refused with a message ("This project uses format version 1, which
  this version of the app can't open"), and loading rejects anything it doesn't
  recognize, naming it and where it is (see
  [effects.md](effects.md#loading-is-strict)).
- **Stable IDs** for every asset, timeline, layer, clip, and scene, written
  to the file. (Today IDs are regenerated on load and references use array
  indices, which is the main obstacle to live reload and diffing.)
- **Deterministic output**: sorted keys and fixed formatting so that two saves
  of the same project are byte-identical and diffs show only real changes.
- **Rational times** such as `"1001/24000s"`, never floating-point seconds.
- **Defaults are left out**, so untouched data adds nothing to a diff. For
  example a clip's `effects`, `anchorPoint` and `volume` (see
  [effects.md](effects.md#saving) and [audio.md](audio.md)) are written
  only once they aren't empty, (0, 0) or 0 dB, and a Sound or Music layer's
  `volume` likewise.
  A timeline's `sections` are written only once it has one. Likewise a
  clip's `streams` (`"video"` or `"audio"`) is written only once
  a video's sound has been detached, and `transitionIn` / `transitionOut`
  (`{"kind": "crossDissolve", "duration": "1s"}`) only when the clip has
  one. A transition's
  `curve` is written only when it isn't linear, as its points:
  `{"time": 0.4, "value": 0.2, "in": [-0.1, 0], "out": [0.2, 0]}`, with
  handles as offsets and absent for a corner. A way in joining two clips
  also has `lead`, the part played before the cut, when it isn't zero. A curve that doesn't run from
  (0, 0) to (1, 1) in increasing time loads as linear. The project's
  `copiesMediaOnImport` is written only as `false`, once imports are set to
  be referenced in place instead of copied into `Media/`, and its
  `canvasMargin` only when it isn't 0.5.
- Written atomically so a crash cannot leave a half-written file.

## Retention

| Folder | May the app delete it? |
| --- | --- |
| `Reference/` | No, only through an explicit "forget original" action, applied at the next save. It may be the only record of a replaced file, so Save As copies each asset's folder into the new package. |
| `Cache/` | Yes. It has a size cap and evicts oldest-first. Entries are keyed by a hash of the exact content they render, so any upstream edit invalidates them. |
| `Backups/` | Yes, by age and count. |

`Cache/` is marked excluded from backup and sync, and should be kept out of
version control. Settings to move the cache elsewhere come later.

The exception inside `Reference/` is `signature.bin` and `beats.bin`: they
describe the file the asset uses now, not the original, so they are retired
(deleted, or marked invalidated in `provenance.json`) when that file changes
or the person asks to detect again. See [scene-cuts.md](scene-cuts.md).

## Writing to the package

Every change to a package, whether a save, Save As, an analysis result, the
retirement of one, an autosave or a copy into `Media/`, goes through
`PackageCoordinator`, which runs them one at a time per package in the order
they were asked. Atomic writes keep each file whole but don't order writes
against each other: without the queue a deletion could finish before an
older write of the same file and let it come back, and Save As could copy
`Reference/` while a result was half-way in. An operation on two packages
(Save As) waits on both. Reading saved analysis results goes through the same queue, away from the
main actor, and is an explicit phase: `AssetAnalysis` decides what an asset
still needs only after its saved results have been read and checked, so what
the package already holds is never analyzed twice, and a read can't see a
result whose retirement was already asked for. The scorer, reference
capture, picture capture and beat detector do their decoding and arithmetic
on background tasks or the sample-reading queue, not on the main actor.
Replacing an existing package and marking backups
as seen are not queued, since no save of that package can be running then.

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
- Media the new file lists that can't be opened stays in the project,
  offline, as when opening a project (see "Offline media" below).

### Offline media

A file that can't be opened when a project is opened or reloaded, as when
a drive isn't plugged in, doesn't take its asset or clips with it: dropping
them would lose them for good at the next save. Each asset in
`project.json` records what its file was (`kind`, `duration`,
`frameRate`, `codec`, `colorSpace`, `hasAudio`), and an asset whose file
is gone is rebuilt from those (`ProjectStore.offlineClip`). Files saved
before these fields existed fall back to the original's reference data,
unless the asset has since been replaced, and then to how its clips use
it; the length always covers its clips, so their trims stay valid.

While a file is offline:

- The library says **File missing**, and opening warns once with the
  names. The file check keeps watching for it.
- The viewer plays its clips as gaps and says which files are offline, so
  the rest of the timeline can still be watched.
- Export and background renders stop with the file's name instead of
  writing a gap.
- Analysis waits for it rather than recording a failure.
- Saving writes the asset and its clips back unchanged.

When the file is back, the viewer rebuilds and analysis resumes on their
own.

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
