# Project package format

Status: **planned, not implemented.** Today a project is a single JSON file
written by `ProjectStore`. Clip times are stored as exact value and
timescale, and clips and timelines are referenced by array index.

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
      cuts.json
      thumbs/ ...
      signature.bin
  Cache/              render cache (disposable, size-capped)
  Backups/            autosaves
  .lock               single-writer lock
```

Media may be copied into `Media/` or referenced from elsewhere, chosen per
asset. **Copying into the package is the default.** To avoid duplicating
large footage, the copy is an APFS clone (copy-on-write) whenever the source
is on the same volume, which uses no extra disk space until a file changes.
If the source is on a different volume, the app shows the size and warns
before making a real copy. References from `project.json` use paths relative
to the package where possible, so the project can be moved or archived.

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
| `Reference/` | No, only through an explicit "forget original" action. It may be the only record of a replaced file. |
| `Cache/` | Yes. It has a size cap and evicts oldest-first. Entries are keyed by a hash of the exact content they render, so any upstream edit invalidates them. |
| `Backups/` | Yes, by age and count. |

`Cache/` is marked excluded from backup and sync, and should be kept out of
version control. Settings to move the cache elsewhere come later.

## Live reload

The project file may be edited outside the app, and the app picks up the
change:

- Watch the file using `NSFilePresenter`, not only on window focus. The app
  remembers the hash of what it last wrote, so its own saves never trigger a
  reload.
- If the file changed and there are no unsaved edits, reload and restore
  selection and the playhead by ID.
- If there are unsaved edits, ask which version to keep.
- Do not reload during an export, a drag, or a save. Wait until the app is
  idle.
- If the new file does not parse, keep the in-memory project, show the
  error, and do not overwrite the file.

A diff engine is not needed for this. Stable IDs and deterministic output
make a structural comparison cheap. A visual diff is only useful later for a
"compare versions" screen when both sides have changes.

## Build order

Foundation first, because the other features depend on it:

1. Persist stable IDs in the model and the file, add `formatVersion`, and
   write the package layout.
2. Undo and redo, single-writer lock, and autosave, and define how reloads
   interact with undo.
3. Scene detection and the browser ([scene-cuts.md](scene-cuts.md)),
   including the reference data capture.
4. Media replacement and the sync dialog
   ([media-replacement.md](media-replacement.md)).
5. Live reload.
